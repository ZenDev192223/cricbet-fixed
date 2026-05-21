import { serve } from 'https://deno.land/std@0.168.0/http/server.ts'
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
}

serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors })
  try {
    const authHeader = req.headers.get('Authorization')
    if (!authHeader) throw new Error('Missing authorization')

    const supabase = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
    )

    const { data: { user }, error: authErr } = await supabase.auth.getUser(
      authHeader.replace('Bearer ', ''),
    )
    if (authErr || !user) throw new Error('Invalid token')

    const { receiver_id, league_id, amount, note } = await req.json()
    if (!receiver_id || !league_id || !amount || amount <= 0) {
      throw new Error('Missing or invalid params (receiver_id, league_id, amount required)')
    }

    const ip = req.headers.get('x-forwarded-for') || 'unknown'
    const { data, error } = await supabase.rpc('process_donation', {
      p_sender_id:   user.id,
      p_receiver_id: receiver_id,
      p_league_id:   league_id,
      p_amount:      amount,
      p_note:        note || '',
      p_sender_ip:   ip,
    })
    if (error) throw new Error(error.message)

    return new Response(JSON.stringify(data), {
      headers: { ...cors, 'Content-Type': 'application/json' },
    })
  } catch (err) {
    return new Response(JSON.stringify({ success: false, error: err.message }), {
      headers: { ...cors, 'Content-Type': 'application/json' },
      status: 400,
    })
  }
})

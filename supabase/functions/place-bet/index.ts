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
    const supabase = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!)
    const { data: { user }, error: authErr } = await supabase.auth.getUser(authHeader.replace('Bearer ', ''))
    if (authErr || !user) throw new Error('Invalid token')
    const { league_id, match_id, bet_team, multiplier, bet_amount, idempotency_key } = await req.json()
    if (!league_id || !match_id || !bet_team || !multiplier || !bet_amount || !idempotency_key) throw new Error('Missing fields')
    if (bet_amount <= 0) throw new Error('Invalid amount')
    if (![1.5, 2, 3, 4, 5].includes(multiplier)) throw new Error('Invalid multiplier')
    const ip = req.headers.get('x-forwarded-for') || 'unknown'
    const { data, error } = await supabase.rpc('place_bet', {
      p_user_id: user.id, p_league_id: league_id, p_match_id: match_id,
      p_bet_team: bet_team, p_multiplier: multiplier, p_bet_amount: bet_amount,
      p_idempotency_key: idempotency_key, p_ip_address: ip,
    })
    if (error) throw new Error(error.message)
    return new Response(JSON.stringify(data), { headers: { ...cors, 'Content-Type': 'application/json' } })
  } catch (err) {
    return new Response(JSON.stringify({ success: false, error: err.message }), { headers: { ...cors, 'Content-Type': 'application/json' }, status: 400 })
  }
})

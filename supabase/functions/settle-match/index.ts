import { serve } from 'https://deno.land/std@0.168.0/http/server.ts'
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

const cors = { 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type' }

serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors })
  try {
    const authHeader = req.headers.get('Authorization')
    if (!authHeader) throw new Error('Missing authorization')
    const supabase = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!)
    const { data: { user }, error: authErr } = await supabase.auth.getUser(authHeader.replace('Bearer ', ''))
    if (authErr || !user) throw new Error('Invalid token')
    const { data: userData } = await supabase.from('users').select('role').eq('id', user.id).single()
    if (!userData || !['admin','superadmin'].includes(userData.role)) throw new Error('Admin access required')
    const { match_id, result, winning_team } = await req.json()
    if (!match_id || !result) throw new Error('Missing fields')
    const settlement_id = `settle_${match_id}_${Date.now()}`
    const { data, error } = await supabase.rpc('settle_match', {
      p_match_id: match_id, p_result: result, p_winning_team: winning_team || null,
      p_admin_id: user.id, p_settlement_id: settlement_id,
    })
    if (error) throw new Error(error.message)
    return new Response(JSON.stringify(data), { headers: { ...cors, 'Content-Type': 'application/json' } })
  } catch (err) {
    return new Response(JSON.stringify({ success: false, error: err.message }), { headers: { ...cors, 'Content-Type': 'application/json' }, status: 400 })
  }
})

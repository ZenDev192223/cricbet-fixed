import { serve } from 'https://deno.land/std@0.168.0/http/server.ts'
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

serve(async (req) => {
  try {
    const auth = req.headers.get('Authorization')
    if (auth !== `Bearer ${Deno.env.get('CRON_SECRET')}`) throw new Error('Unauthorized')
    const supabase = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!)
    const { data, error } = await supabase.rpc('apply_inactivity_penalties')
    if (error) throw new Error(error.message)
    return new Response(JSON.stringify(data), { headers: { 'Content-Type': 'application/json' } })
  } catch (err) {
    return new Response(JSON.stringify({ error: err.message }), { headers: { 'Content-Type': 'application/json' }, status: 400 })
  }
})

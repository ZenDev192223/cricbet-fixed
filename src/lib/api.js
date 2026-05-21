import { supabase } from './supabase'

const EDGE_BASE = import.meta.env.VITE_SUPABASE_URL + '/functions/v1'

async function callEdge(path, body) {
  const { data: { session } } = await supabase.auth.getSession()
  if (!session) throw new Error('Not authenticated')
  const res = await fetch(`${EDGE_BASE}/${path}`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'Authorization': `Bearer ${session.access_token}`,
    },
    body: JSON.stringify(body),
  })
  const data = await res.json()
  if (!res.ok || data.success === false) throw new Error(data.error || 'Request failed')
  return data
}

// ── Edge Function calls ──────────────────────────────────────
export const placeBet        = (payload) => callEdge('place-bet',        payload)
export const settleMatch     = (payload) => callEdge('settle-match',      payload)
// Requires league_id so the transfer is scoped to a league
export const processDonation = (payload) => callEdge('process-donation', payload)

// ── Direct Supabase queries ──────────────────────────────────

/**
 * Get user state. Pass leagueId to get league-scoped streaks,
 * unlocks, cooldowns and credits. Omit for a global summary.
 */
export const getUserState = async (userId, leagueId = null) => {
  const params = { p_user_id: userId }
  if (leagueId) params.p_league_id = leagueId
  const { data, error } = await supabase.rpc('get_user_state', params)
  if (error) throw error
  return data
}

export const adminAdjustWallet = async ({ userId, amount, type, reason }) => {
  const { data: { user } } = await supabase.auth.getUser()
  const { data, error } = await supabase.rpc('admin_adjust_wallet', {
    p_admin_id: user.id,
    p_user_id:  userId,
    p_amount:   amount,
    p_type:     type,
    p_reason:   reason,
  })
  if (error) throw error
  return data
}

export const getSystemConfig = async () => {
  const { data, error } = await supabase.from('system_config').select('*')
  if (error) throw error
  return data.reduce((acc, row) => ({
    ...acc,
    [row.key]: typeof row.value === 'object' && row.value !== null && 'value' in row.value
      ? row.value.value
      : row.value,
  }), {})
}

export const updateSystemConfig = async (key, value) => {
  const { data: { user } } = await supabase.auth.getUser()
  const { error } = await supabase.from('system_config')
    .update({ value, updated_at: new Date().toISOString(), updated_by: user.id })
    .eq('key', key)
  if (error) throw error
  await supabase.from('admin_logs').insert({
    admin_id: user.id, action: 'config_update',
    target_type: 'system_config',
    new_value: { key, value },
  })
}

export const createLeague = async (name, startingCredits, maxBet = null) => {
  const code = Math.random().toString(36).substring(2, 8).toUpperCase()
  const { data: { user } } = await supabase.auth.getUser()
  const { data, error } = await supabase.from('leagues').insert({
    name, code, created_by: user.id,
    starting_credits: startingCredits,
    max_bet: maxBet || null,
  }).select().single()
  if (error) throw error
  // Auto-join creator — trigger will seed credits from starting_credits
  await supabase.from('league_members').insert({ league_id: data.id, user_id: user.id })
  return data
}

export const joinLeague = async (code) => {
  const { data: { user } } = await supabase.auth.getUser()
  const { data: leagues, error } = await supabase.from('leagues')
    .select('*').eq('code', code.toUpperCase().trim()).eq('is_active', true)
  if (error || !leagues?.length) throw new Error('Invalid or inactive league code')
  const league = leagues[0]
  const { error: memErr } = await supabase.from('league_members')
    .insert({ league_id: league.id, user_id: user.id })
  if (memErr) throw new Error('You are already a member of this league')
  // Trigger handle_league_join() seeds credits automatically
  return league
}
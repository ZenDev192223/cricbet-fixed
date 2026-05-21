import { create } from 'zustand'
import { supabase } from '../lib/supabase'
import { getUserState } from '../lib/api'

export const useDashboardStore = create((set, get) => ({
  leagueBalances: [],   // [{ league_id, credits, locked_credits }]

  // League-scoped streak/unlock/cooldown state
  // keyed by league_id: { streaks: {}, unlocks: [], cooldowns: {} }
  leagueState: {},

  recentBets: [],
  matches:   [],
  leagues:   [],
  transactions: [],
  loading:   false,

  // Helper: get credits for a specific league
  getLeagueCredits: (leagueId) => {
    const bal = get().leagueBalances.find(b => b.league_id === leagueId)
    return bal ?? { credits: 0, locked_credits: 0 }
  },

  // Helper: get streaks/unlocks/cooldowns for a specific league
  getLeagueGameState: (leagueId) => {
    return get().leagueState[leagueId] ?? { streaks: {}, unlocks: [], cooldowns: {} }
  },

  loadDashboard: async (userId) => {
    set({ loading: true })
    try {
      const [matchRes, leagueRes] = await Promise.all([
        supabase.from('matches').select('*').in('status', ['upcoming', 'live']).order('match_date'),
        supabase.from('league_members').select('league_id, credits, locked_credits, leagues(*)').eq('user_id', userId),
      ])

      const leagueRows = leagueRes.data || []
      const leagues    = leagueRows.map(r => r.leagues).filter(Boolean)

      // Build leagueBalances from the direct league_members query (no global wallet needed)
      const leagueBalances = leagueRows.map(r => ({
        league_id:      r.league_id,
        credits:        r.credits,
        locked_credits: r.locked_credits,
      }))

      // Fetch league-scoped game state for each league in parallel
      const leagueStateEntries = await Promise.all(
        leagueRows.map(async (r) => {
          try {
            const state = await getUserState(userId, r.league_id)
            return [r.league_id, {
              streaks:   state?.streaks   ?? {},
              unlocks:   state?.unlocks   ?? [],
              cooldowns: state?.cooldowns ?? {},
            }]
          } catch {
            return [r.league_id, { streaks: {}, unlocks: [], cooldowns: {} }]
          }
        })
      )

      const leagueState = Object.fromEntries(leagueStateEntries)

      set({
        leagueBalances,
        leagueState,
        matches:  matchRes.data || [],
        leagues,
        loading:  false,
      })
    } catch (e) {
      console.error('Dashboard load error:', e)
      set({ loading: false })
    }
  },

  /**
   * Refresh game state (streaks/unlocks/cooldowns) for a single league.
   * Call this after a bet is placed or a match is settled.
   */
  refreshLeagueGameState: async (userId, leagueId) => {
    try {
      const state = await getUserState(userId, leagueId)
      set((prev) => ({
        leagueState: {
          ...prev.leagueState,
          [leagueId]: {
            streaks:   state?.streaks   ?? {},
            unlocks:   state?.unlocks   ?? [],
            cooldowns: state?.cooldowns ?? {},
          },
        },
      }))
    } catch (e) {
      console.error('Failed to refresh league game state:', e)
    }
  },

  loadTransactions: async (userId) => {
    const { data } = await supabase.from('transactions')
      .select('*').eq('user_id', userId)
      .order('created_at', { ascending: false }).limit(100)
    set({ transactions: data || [] })
  },

  subscribeLeagueBalance: (userId, leagueId) => {
    const channel = supabase.channel(`lm:${userId}:${leagueId}`)
      .on('postgres_changes', {
        event: 'UPDATE', schema: 'public', table: 'league_members',
        filter: `user_id=eq.${userId}`,
      }, (payload) => {
        set((state) => ({
          leagueBalances: state.leagueBalances.map(b =>
            b.league_id === payload.new.league_id
              ? { league_id: payload.new.league_id, credits: payload.new.credits, locked_credits: payload.new.locked_credits }
              : b
          ),
        }))
      })
      .subscribe()
    return () => supabase.removeChannel(channel)
  },

  subscribeMatches: () => {
    const channel = supabase.channel('matches')
      .on('postgres_changes', {
        event: '*', schema: 'public', table: 'matches',
      }, async () => {
        const { data } = await supabase.from('matches')
          .select('*').in('status', ['upcoming', 'live']).order('match_date')
        set({ matches: data || [] })
      })
      .subscribe()
    return () => supabase.removeChannel(channel)
  },

  refreshLeagueBalance: async (userId, leagueId) => {
    const { data } = await supabase.from('league_members')
      .select('credits, locked_credits')
      .eq('user_id', userId)
      .eq('league_id', leagueId)
      .single()
    if (data) {
      set((state) => ({
        leagueBalances: state.leagueBalances.map(b =>
          b.league_id === leagueId
            ? { league_id: leagueId, credits: data.credits, locked_credits: data.locked_credits }
            : b
        ),
      }))
    }
  },
}))
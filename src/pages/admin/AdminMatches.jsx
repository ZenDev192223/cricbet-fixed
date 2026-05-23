import { useEffect, useState } from 'react'
import { useAuthStore } from '../../store/auth'
import Navbar from '../../components/shared/Navbar'
import { supabase } from '../../lib/supabase'
import { settleMatch } from '../../lib/api'
import { IPL_TEAMS } from '../../lib/constants'
import { Plus, CheckCircle2, Clock, Zap, ChevronDown, ChevronUp, Users, CheckCircle, XCircle } from 'lucide-react'
import { format } from 'date-fns'
import toast from 'react-hot-toast'
import clsx from 'clsx'

const RESULTS = [
  { value: 'team_a',    label: 'Team A Wins' },
  { value: 'team_b',    label: 'Team B Wins' },
  { value: 'tie',       label: 'Tie / NR' },
  { value: 'no_result', label: 'No Result' },
  { value: 'void',      label: 'Void Match' },
]

export default function AdminMatches() {
  const { user } = useAuthStore()
  const [matches, setMatches]   = useState([])
  const [loading, setLoading]   = useState(true)
  const [showForm, setShowForm] = useState(false)
  const [settling, setSettling] = useState(null)
  const [form, setForm]         = useState({
    team_a: '', team_b: '', match_date: '', venue: '', league_id: '',
  })
  const [leagues, setLeagues]   = useState([])
  const [settleData, setSettleData] = useState({}) // matchId → { result, winning_team }
  const [expandedBets, setExpandedBets] = useState(null)  // matchId currently expanded
  const [matchBets, setMatchBets]       = useState({})     // matchId → { betters, nonBetters }
  const [betsLoading, setBetsLoading]   = useState(false)

  useEffect(() => { loadAll() }, [])

  const loadAll = async () => {
    setLoading(true)
    const [matchRes, leagueRes] = await Promise.all([
      supabase.from('matches').select('*, leagues(name)').order('match_date', { ascending: false }),
      supabase.from('leagues').select('id, name').eq('is_active', true),
    ])
    setMatches(matchRes.data || [])
    setLeagues(leagueRes.data || [])
    setLoading(false)
  }

  const loadMatchBets = async (match) => {
    if (expandedBets === match.id) { setExpandedBets(null); return }
    setBetsLoading(true)
    setExpandedBets(match.id)
    try {
      // Get all members of this match's league
      const { data: members } = await supabase
        .from('league_members')
        .select('user_id, users(display_name, email)')
        .eq('league_id', match.league_id)

      // Get all bets for this match
      const { data: bets } = await supabase
        .from('bets')
        .select('user_id, bet_team, multiplier, bet_amount, status')
        .eq('match_id', match.id)
        .neq('status', 'canceled')

      const bettedIds = new Set((bets || []).map(b => b.user_id))
      const betMap    = (bets || []).reduce((acc, b) => { acc[b.user_id] = b; return acc }, {})

      const betters    = (members || []).filter(m => bettedIds.has(m.user_id))
        .map(m => ({ ...m.users, bet: betMap[m.user_id] }))
      const nonBetters = (members || []).filter(m => !bettedIds.has(m.user_id))
        .map(m => m.users)

      setMatchBets(prev => ({ ...prev, [match.id]: { betters, nonBetters } }))
    } catch { toast.error('Failed to load bets') }
    finally { setBetsLoading(false) }
  }

  const handleCreate = async () => {
    if (!form.team_a || !form.team_b || !form.match_date) return toast.error('Fill required fields')
    if (form.team_a === form.team_b) return toast.error('Teams must be different')
    try {
      const { error } = await supabase.from('matches').insert({
        ...form,
        created_by: user.id,
        league_id: form.league_id || null,
      })
      if (error) throw error
      toast.success('Match created')
      setForm({ team_a: '', team_b: '', match_date: '', venue: '', league_id: '' })
      setShowForm(false)
      loadAll()
    } catch (e) { toast.error(e.message) }
  }

  const handleSetLive = async (matchId) => {
    const { error } = await supabase.from('matches').update({ status: 'live' }).eq('id', matchId)
    if (error) toast.error(error.message)
    else { toast.success('Match set to live'); loadAll() }
  }

  const handleSettle = async (match) => {
    const sd = settleData[match.id]
    if (!sd?.result) return toast.error('Select a result')
    if ((sd.result === 'team_a' || sd.result === 'team_b') && !sd.winning_team) {
      // auto-assign winning team
      sd.winning_team = sd.result === 'team_a' ? match.team_a : match.team_b
    }
    setSettling(match.id)
    try {
      await settleMatch({ match_id: match.id, result: sd.result, winning_team: sd.winning_team || null })
      toast.success('Match settled!')
      setSettleData(prev => { const n = { ...prev }; delete n[match.id]; return n })
      loadAll()
    } catch (e) { toast.error(e.message) }
    finally { setSettling(null) }
  }

  const setSD = (matchId, key, val) => setSettleData(prev => ({
    ...prev, [matchId]: { ...(prev[matchId] || {}), [key]: val }
  }))

  const STATUS_CLS = {
    upcoming:  'badge-blue',
    live:      'badge-red',
    completed: 'badge-green',
    canceled:  'badge-gray',
    abandoned: 'badge-gray',
    postponed: 'badge-gold',
  }

  return (
    <div className="min-h-screen bg-surface-900">
      <Navbar />
      <div className="max-w-6xl mx-auto px-4 sm:px-6 py-8 space-y-8">
        <div className="flex items-center justify-between">
          <div>
            <h1 className="font-display text-4xl text-white tracking-wide">Match Management</h1>
            <p className="text-gray-500 text-sm mt-1 font-mono">Create and settle matches</p>
          </div>
          <button onClick={() => setShowForm(s => !s)} className="btn-primary flex items-center gap-2">
            <Plus size={16} /> New Match
          </button>
        </div>

        {/* Create form */}
        {showForm && (
          <div className="card p-6 space-y-4 animate-in">
            <h2 className="font-semibold text-white">New Match</h2>
            <div className="grid grid-cols-2 gap-4">
              <div>
                <label className="text-xs text-gray-500 font-mono uppercase mb-1 block">Team A *</label>
                <select className="input" value={form.team_a} onChange={e => setForm(f => ({ ...f, team_a: e.target.value }))}>
                  <option value="">Select team</option>
                  {IPL_TEAMS.map(t => <option key={t.code} value={t.name}>{t.name} ({t.code})</option>)}
                </select>
              </div>
              <div>
                <label className="text-xs text-gray-500 font-mono uppercase mb-1 block">Team B *</label>
                <select className="input" value={form.team_b} onChange={e => setForm(f => ({ ...f, team_b: e.target.value }))}>
                  <option value="">Select team</option>
                  {IPL_TEAMS.map(t => <option key={t.code} value={t.name}>{t.name} ({t.code})</option>)}
                </select>
              </div>
              <div>
                <label className="text-xs text-gray-500 font-mono uppercase mb-1 block">Match Date & Time *</label>
                <input className="input" type="datetime-local" value={form.match_date}
                  onChange={e => setForm(f => ({ ...f, match_date: e.target.value }))} />
              </div>
              <div>
                <label className="text-xs text-gray-500 font-mono uppercase mb-1 block">Venue</label>
                <input className="input" placeholder="Stadium name" value={form.venue}
                  onChange={e => setForm(f => ({ ...f, venue: e.target.value }))} />
              </div>
              <div className="col-span-2">
                <label className="text-xs text-gray-500 font-mono uppercase mb-1 block">League (optional)</label>
                <select className="input" value={form.league_id} onChange={e => setForm(f => ({ ...f, league_id: e.target.value }))}>
                  <option value="">No league (global)</option>
                  {leagues.map(l => <option key={l.id} value={l.id}>{l.name}</option>)}
                </select>
              </div>
            </div>
            <div className="flex gap-3">
              <button onClick={handleCreate} className="btn-primary px-6 py-2.5">Create Match</button>
              <button onClick={() => setShowForm(false)} className="btn-ghost px-4 py-2.5">Cancel</button>
            </div>
          </div>
        )}

        {/* Matches list */}
        {loading ? (
          <div className="space-y-3">
            {[...Array(4)].map((_, i) => <div key={i} className="card p-5 h-20 animate-pulse bg-surface-700" />)}
          </div>
        ) : matches.length === 0 ? (
          <div className="card p-10 text-center">
            <Zap size={28} className="mx-auto mb-3 text-gray-600" />
            <p className="text-gray-400">No matches yet</p>
          </div>
        ) : (
          <div className="space-y-3">
            {matches.map(m => {
              const isSettleable = ['upcoming', 'live'].includes(m.status)
              const sd = settleData[m.id] || {}

              return (
                <div key={m.id} className="card p-5">
                  <div className="flex items-start justify-between gap-4">
                    <div className="flex-1">
                      <div className="flex items-center gap-3 mb-1">
                        <span className={clsx('badge', STATUS_CLS[m.status] || 'badge-gray')}>{m.status}</span>
                        {m.leagues?.name && <span className="text-xs text-gray-500 font-mono">{m.leagues.name}</span>}
                      </div>
                      <div className="flex items-center gap-3">
                        <span className="font-bold text-white text-lg">{m.team_a}</span>
                        <span className="text-gray-600 font-mono text-xs">VS</span>
                        <span className="font-bold text-white text-lg">{m.team_b}</span>
                      </div>
                      <div className="text-xs text-gray-500 font-mono mt-1">
                        {format(new Date(m.match_date), 'MMM d, yyyy · h:mm a')}
                        {m.venue && ` · ${m.venue}`}
                      </div>
                      {m.winning_team && (
                        <div className="text-xs text-accent-green font-mono mt-1">✓ {m.winning_team} won · {m.result}</div>
                      )}
                    </div>

                    {/* Actions */}
                    <div className="flex items-center gap-2 shrink-0">
                      {m.status === 'upcoming' && (
                        <button onClick={() => handleSetLive(m.id)}
                          className="btn-secondary text-xs px-3 py-2 flex items-center gap-1">
                          <Zap size={12} /> Set Live
                        </button>
                      )}
                    </div>
                  </div>

                  {/* Settle row */}
                  {isSettleable && (
                    <div className="mt-4 pt-4 border-t border-surface-700 flex items-center gap-3 flex-wrap">
                      <select
                        className="input flex-1 min-w-[160px] text-sm py-2"
                        value={sd.result || ''}
                        onChange={e => setSD(m.id, 'result', e.target.value)}>
                        <option value="">— Select result —</option>
                        {RESULTS.map(r => <option key={r.value} value={r.value}>{r.label}</option>)}
                      </select>
                      {sd.result === 'team_a' && (
                        <div className="text-xs text-gray-400 font-mono">Winner: {m.team_a}</div>
                      )}
                      {sd.result === 'team_b' && (
                        <div className="text-xs text-gray-400 font-mono">Winner: {m.team_b}</div>
                      )}
                      <button
                        onClick={() => handleSettle(m)}
                        disabled={!sd.result || settling === m.id}
                        className="btn-primary text-sm px-4 py-2 flex items-center gap-1">
                        <CheckCircle2 size={14} />
                        {settling === m.id ? 'Settling…' : 'Settle'}
                      </button>
                    </div>
                  )}

                  {/* Who bet / who didn't */}
                  {m.league_id && (
                    <div className="mt-3 pt-3 border-t border-surface-700">
                      <button
                        onClick={() => loadMatchBets(m)}
                        className="flex items-center gap-2 text-xs text-gray-400 hover:text-white font-mono transition-colors">
                        <Users size={12} />
                        {expandedBets === m.id ? 'Hide bets' : 'Show who bet / who didn\'t'}
                        {expandedBets === m.id ? <ChevronUp size={12} /> : <ChevronDown size={12} />}
                      </button>

                      {expandedBets === m.id && (
                        <div className="mt-3 grid grid-cols-2 gap-4">
                          {/* Betters */}
                          <div>
                            <div className="flex items-center gap-1.5 mb-2">
                              <CheckCircle size={12} className="text-accent-green" />
                              <span className="text-xs font-mono font-semibold text-accent-green uppercase tracking-wider">
                                Bet ({matchBets[m.id]?.betters?.length ?? 0})
                              </span>
                            </div>
                            {betsLoading && !matchBets[m.id] ? (
                              <p className="text-xs text-gray-600 font-mono">Loading…</p>
                            ) : matchBets[m.id]?.betters?.length === 0 ? (
                              <p className="text-xs text-gray-600 font-mono">Nobody bet yet</p>
                            ) : (
                              <div className="space-y-1.5">
                                {matchBets[m.id]?.betters?.map(u => (
                                  <div key={u.bet?.user_id} className="flex items-center justify-between bg-surface-700 rounded-lg px-3 py-1.5">
                                    <div>
                                      <p className="text-xs text-white font-semibold">{u.display_name}</p>
                                      <p className="text-xs text-gray-500 font-mono">{u.bet?.bet_team} · {u.bet?.multiplier}×</p>
                                    </div>
                                    <span className="text-xs font-mono text-brand-400">₹{u.bet?.bet_amount}</span>
                                  </div>
                                ))}
                              </div>
                            )}
                          </div>

                          {/* Non-betters */}
                          <div>
                            <div className="flex items-center gap-1.5 mb-2">
                              <XCircle size={12} className="text-accent-red" />
                              <span className="text-xs font-mono font-semibold text-accent-red uppercase tracking-wider">
                                Didn\'t Bet ({matchBets[m.id]?.nonBetters?.length ?? 0})
                              </span>
                            </div>
                            {betsLoading && !matchBets[m.id] ? (
                              <p className="text-xs text-gray-600 font-mono">Loading…</p>
                            ) : matchBets[m.id]?.nonBetters?.length === 0 ? (
                              <p className="text-xs text-gray-600 font-mono">Everyone bet ✓</p>
                            ) : (
                              <div className="space-y-1.5">
                                {matchBets[m.id]?.nonBetters?.map(u => (
                                  <div key={u?.email} className="flex items-center bg-surface-700 rounded-lg px-3 py-1.5">
                                    <div>
                                      <p className="text-xs text-white font-semibold">{u?.display_name}</p>
                                      <p className="text-xs text-gray-500 font-mono">{u?.email}</p>
                                    </div>
                                  </div>
                                ))}
                              </div>
                            )}
                          </div>
                        </div>
                      )}
                    </div>
                  )}
                </div>
              )
            })}
          </div>
        )}
      </div>
    </div>
  )
}
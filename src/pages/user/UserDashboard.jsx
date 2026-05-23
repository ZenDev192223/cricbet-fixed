import { useEffect, useState } from 'react'
import { Link } from 'react-router-dom'
import { useAuthStore } from '../../store/auth'
import { useDashboardStore } from '../../store/dashboard'
import Navbar from '../../components/shared/Navbar'
import LeagueWalletCard from '../../components/shared/WalletCard'
import StreakDisplay from '../../components/user/StreakDisplay'
import UnlockDisplay from '../../components/user/UnlockDisplay'
import LoadingSpinner from '../../components/shared/LoadingSpinner'
import { formatCurrency, MULTIPLIERS } from '../../lib/constants'
import { Trophy, Clock, Zap, Plus, Hash, TrendingUp, CheckCircle2, XCircle, RotateCcw } from 'lucide-react'
import { format } from 'date-fns'
import clsx from 'clsx'
import toast from 'react-hot-toast'
import { joinLeague, createLeague } from '../../lib/api'

const STATUS_BADGE = {
  won:      { cls: 'badge-green',  icon: CheckCircle2, label: 'Won'      },
  lost:     { cls: 'badge-red',    icon: XCircle,      label: 'Lost'     },
  pending:  { cls: 'badge-gold',   icon: Clock,        label: 'Pending'  },
  refunded: { cls: 'badge-blue',   icon: RotateCcw,    label: 'Refunded' },
  void:     { cls: 'badge-gray',   icon: RotateCcw,    label: 'Voided'   },
}

export default function UserDashboard() {
  const { user, profile } = useAuthStore()
  const {
    leagueBalances, leagueState, recentBets, matches,
    leagues, loading, loadDashboard, subscribeMatches,
    subscribeLeagueBalance, getLeagueCredits, getLeagueGameState,
  } = useDashboardStore()

  // Aggregate streaks and unlocks across all leagues for the global dashboard view.
  // Each league's streaks/unlocks are independent; we show them concatenated.
  const streaks = Object.values(leagueState).reduce((acc, ls) => {
    Object.entries(ls.streaks || {}).forEach(([tier, count]) => {
      acc[tier] = Math.max(acc[tier] ?? 0, count)
    })
    return acc
  }, {})
  const unlocks = Object.values(leagueState).flatMap(ls => ls.unlocks || [])

  const [showJoin, setShowJoin]           = useState(false)
  const [showCreate, setShowCreate]       = useState(false)
  const [leagueCode, setLeagueCode]       = useState('')
  const [newLeagueName, setNewLeagueName] = useState('')
  const [newLeagueCredits, setNewLeagueCredits] = useState('1000')
  const [leagueLoading, setLeagueLoading] = useState(false)

  useEffect(() => {
    if (!user?.id) return
    loadDashboard(user.id)
    const unsubMatches = subscribeMatches()
    // Subscribe to all league balance changes
    const unsubs = leagueBalances.map(b => subscribeLeagueBalance(user.id, b.league_id))
    return () => {
      unsubMatches()
      unsubs.forEach(fn => fn())
    }
  }, [user?.id])

  const handleJoinLeague = async () => {
    if (!leagueCode.trim()) return
    setLeagueLoading(true)
    try {
      await joinLeague(leagueCode.trim())
      toast.success('Joined league!')
      setShowJoin(false)
      setLeagueCode('')
      loadDashboard(user.id)
    } catch (e) { toast.error(e.message) }
    finally { setLeagueLoading(false) }
  }

  const handleCreateLeague = async () => {
    if (!newLeagueName.trim()) return toast.error('League name required')
    setLeagueLoading(true)
    try {
      await createLeague(newLeagueName.trim(), parseFloat(newLeagueCredits) || 1000)
      toast.success('League created!')
      setShowCreate(false)
      setNewLeagueName('')
      loadDashboard(user.id)
    } catch (e) { toast.error(e.message) }
    finally { setLeagueLoading(false) }
  }

  if (loading) return <LoadingSpinner />

  // Total credits across all leagues (for display only)
  const totalCredits = leagueBalances.reduce((sum, b) => sum + parseFloat(b.credits ?? 0), 0)

  return (
    <div className="min-h-screen bg-surface-900">
      <Navbar />
      <div className="max-w-7xl mx-auto px-4 sm:px-6 py-8 space-y-8">

        {/* Welcome */}
        <div>
          <h1 className="font-display text-4xl text-white tracking-wide">
            Hey, {profile?.display_name?.split(' ')[0] ?? 'Player'} 👋
          </h1>
          <p className="text-gray-500 text-sm mt-1 font-mono">
            {matches.length} match{matches.length !== 1 ? 'es' : ''} open for betting
          </p>
        </div>

        {/* Streaks + Unlocks */}
        <div className="grid grid-cols-1 lg:grid-cols-3 gap-6">
          {/* Summary of credits across all leagues */}
          <div className="card p-5 flex flex-col justify-center">
            <div className="text-xs text-gray-500 font-mono uppercase tracking-widest mb-3">
              Total Credits (all leagues)
            </div>
            <div className="text-4xl font-display font-bold text-white text-glow-orange mb-1">
              {formatCurrency(totalCredits)}
            </div>
            <div className="text-xs text-gray-500 font-mono">
              Across {leagueBalances.length} league{leagueBalances.length !== 1 ? 's' : ''}
            </div>
          </div>
          <div className="lg:col-span-2 space-y-4">
            <StreakDisplay streaks={streaks} />
            <UnlockDisplay unlocks={unlocks} />
          </div>
        </div>

        {/* Open Matches */}
        <div>
          <h2 className="font-display text-2xl text-white mb-4 flex items-center gap-2">
            <Zap size={20} className="text-brand-500" /> Open Matches
          </h2>
          {matches.length === 0 ? (
            <div className="card p-10 text-center">
              <Clock size={32} className="mx-auto mb-3 text-gray-600" />
              <p className="text-gray-400">No matches open right now</p>
              <p className="text-gray-600 text-sm mt-1">Check back before the next match</p>
            </div>
          ) : (
            <div className="grid grid-cols-1 md:grid-cols-2 xl:grid-cols-3 gap-4">
              {matches.map(m => (
                <MatchCard key={m.id} match={m} leagues={leagues} />
              ))}
            </div>
          )}
        </div>

        {/* My Leagues */}
        <div>
          <div className="flex items-center justify-between mb-4">
            <h2 className="font-display text-2xl text-white flex items-center gap-2">
              <Trophy size={20} className="text-accent-gold" /> My Leagues
            </h2>
            <div className="flex gap-2">
              <button onClick={() => { setShowJoin(true); setShowCreate(false) }} className="btn-secondary text-sm px-4 py-2">
                Join
              </button>
              <button onClick={() => { setShowCreate(true); setShowJoin(false) }} className="btn-primary text-sm px-4 py-2">
                <Plus size={14} className="inline mr-1" /> Create
              </button>
            </div>
          </div>

          {/* Join / Create inline forms */}
          {showJoin && (
            <div className="card p-4 mb-4 flex gap-3 items-center animate-in">
              <Hash size={16} className="text-gray-400 shrink-0" />
              <input className="input flex-1" placeholder="Enter league code" value={leagueCode}
                onChange={e => setLeagueCode(e.target.value.toUpperCase())}
                onKeyDown={e => e.key === 'Enter' && handleJoinLeague()} />
              <button onClick={handleJoinLeague} disabled={leagueLoading} className="btn-primary px-4 py-2 text-sm shrink-0">
                {leagueLoading ? '…' : 'Join'}
              </button>
              <button onClick={() => setShowJoin(false)} className="btn-ghost px-3 py-2 text-sm">✕</button>
            </div>
          )}
          {showCreate && (
            <div className="card p-4 mb-4 animate-in space-y-3">
              <div className="flex gap-3">
                <input className="input flex-1" placeholder="League name" value={newLeagueName}
                  onChange={e => setNewLeagueName(e.target.value)} />
                <input className="input w-32" placeholder="Credits" type="number" value={newLeagueCredits}
                  onChange={e => setNewLeagueCredits(e.target.value)} />
              </div>
              <div className="flex gap-2">
                <button onClick={handleCreateLeague} disabled={leagueLoading} className="btn-primary px-4 py-2 text-sm">
                  {leagueLoading ? '…' : 'Create League'}
                </button>
                <button onClick={() => setShowCreate(false)} className="btn-ghost px-3 py-2 text-sm">Cancel</button>
              </div>
            </div>
          )}

          {leagues.length === 0 ? (
            <div className="card p-8 text-center">
              <Trophy size={28} className="mx-auto mb-3 text-gray-600" />
              <p className="text-gray-400">No leagues yet — join or create one</p>
            </div>
          ) : (
            <div className="grid grid-cols-1 md:grid-cols-2 xl:grid-cols-3 gap-4">
              {leagues.map(l => {
                const bal = getLeagueCredits(l.id)
                return (
                  <Link key={l.id} to={`/league/${l.id}`}
                    className="card-hover p-5 block group">
                    <div className="flex items-center justify-between mb-3">
                      <div className="font-semibold text-white group-hover:text-brand-400 transition-colors">{l.name}</div>
                      <span className="badge badge-gray font-mono">{l.code}</span>
                    </div>
                    {/* Per-league balance */}
                    <div className="mt-2">
                      <div className="text-2xl font-display font-bold text-accent-green">
                        {formatCurrency(bal.credits)}
                      </div>
                      <div className="text-xs text-gray-500 font-mono mt-0.5">
                        Available credits
                        {parseFloat(bal.locked_credits) > 0 && (
                          <span className="text-accent-red ml-2">
                            · {formatCurrency(bal.locked_credits)} locked
                          </span>
                        )}
                      </div>
                    </div>
                  </Link>
                )
              })}
            </div>
          )}
        </div>

        {/* Recent Bets */}
        {recentBets.length > 0 && (
          <div>
            <h2 className="font-display text-2xl text-white mb-4 flex items-center gap-2">
              <TrendingUp size={20} className="text-brand-500" /> Recent Bets
            </h2>
            <div className="card overflow-hidden">
              <table className="w-full text-sm">
                <thead>
                  <tr className="border-b border-surface-700 text-left text-xs text-gray-500 font-mono uppercase">
                    <th className="px-4 py-3">Match</th>
                    <th className="px-4 py-3">Multiplier</th>
                    <th className="px-4 py-3">Bet</th>
                    <th className="px-4 py-3">Locked</th>
                    <th className="px-4 py-3">Potential</th>
                    <th className="px-4 py-3">Status</th>
                  </tr>
                </thead>
                <tbody>
                  {recentBets.slice(0, 10).map(b => {
                    const st = STATUS_BADGE[b.status] || STATUS_BADGE.pending
                    const Icon = st.icon
                    return (
                      <tr key={b.id} className="table-row">
                        <td className="px-4 py-3 text-gray-300 font-mono text-xs">{b.match_id?.slice(0, 8)}…</td>
                        <td className="px-4 py-3">
                          <span className={clsx('font-mono font-bold',
                            b.multiplier >= 5 ? 'text-accent-red' :
                            b.multiplier >= 4 ? 'text-purple-400' :
                            b.multiplier >= 3 ? 'text-accent-gold' :
                            b.multiplier >= 2 ? 'text-blue-400' : 'text-gray-300'
                          )}>{b.multiplier}×</span>
                        </td>
                        <td className="px-4 py-3 text-gray-300">{formatCurrency(b.bet_amount)}</td>
                        <td className="px-4 py-3 text-accent-red font-mono">{formatCurrency(b.locked_amount)}</td>
                        <td className="px-4 py-3 text-accent-green font-mono">{formatCurrency(b.potential_win)}</td>
                        <td className="px-4 py-3">
                          <span className={clsx('badge', st.cls, 'gap-1')}>
                            <Icon size={10} /> {st.label}
                          </span>
                        </td>
                      </tr>
                    )
                  })}
                </tbody>
              </table>
            </div>
          </div>
        )}
      </div>
    </div>
  )
}

function MatchCard({ match, leagues }) {
  const isLive = match.status === 'live'
  // Only show leagues that this match belongs to.
  // If match.league_id is null the match is global — show all user leagues.
  const eligibleLeagues = match.league_id
    ? leagues.filter(l => l.id === match.league_id)
    : leagues
  return (
    <div className="card-hover p-5">
      {isLive && (
        <div className="flex items-center gap-1.5 mb-3">
          <div className="w-2 h-2 bg-accent-red rounded-full animate-pulse" />
          <span className="text-xs font-mono font-semibold text-accent-red uppercase tracking-widest">Live</span>
        </div>
      )}
      {!isLive && (
        <div className="text-xs text-gray-500 font-mono mb-3 flex items-center gap-1">
          <Clock size={10} /> {format(new Date(match.match_date), 'MMM d · h:mm a')}
        </div>
      )}
      <div className="flex items-center justify-between mb-4">
        <div className="text-lg font-bold text-white">{match.team_a}</div>
        <div className="text-xs text-gray-600 font-mono font-bold">VS</div>
        <div className="text-lg font-bold text-white text-right">{match.team_b}</div>
      </div>
      {match.venue && (
        <div className="text-xs text-gray-600 font-mono mb-4 text-center">{match.venue}</div>
      )}
      {eligibleLeagues.length > 0 ? (
        <div className="space-y-1.5">
          {eligibleLeagues.map(l => (
            <Link key={l.id} to={`/league/${l.id}/match/${match.id}`}
              className="flex items-center justify-between px-3 py-2 bg-surface-700 rounded-lg hover:bg-surface-600 transition-colors group">
              <span className="text-xs text-gray-400 group-hover:text-white transition-colors">{l.name}</span>
              <span className="text-xs font-mono text-brand-400">Bet →</span>
            </Link>
          ))}
        </div>
      ) : (
        <p className="text-xs text-gray-600 text-center font-mono">You are not in this match's league</p>
      )}
    </div>
  )
}
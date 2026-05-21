import { useEffect, useState } from 'react'
import { useParams, Link } from 'react-router-dom'
import { useAuthStore } from '../../store/auth'
import { useDashboardStore } from '../../store/dashboard'
import Navbar from '../../components/shared/Navbar'
import LeagueWalletCard from '../../components/shared/WalletCard'
import LoadingSpinner from '../../components/shared/LoadingSpinner'
import { supabase } from '../../lib/supabase'
import { formatCurrency } from '../../lib/constants'
import { Trophy, Clock, CheckCircle2, XCircle, RotateCcw, Zap, Hash, Send } from 'lucide-react'
import { format } from 'date-fns'
import clsx from 'clsx'
import toast from 'react-hot-toast'

const BET_ICON = { won: CheckCircle2, lost: XCircle, pending: Clock, refunded: RotateCcw }
const BET_CLS  = { won: 'text-accent-green', lost: 'text-accent-red', pending: 'text-accent-gold', refunded: 'text-blue-400' }

export default function LeaguePage() {
  const { leagueId } = useParams()
  const { user } = useAuthStore()
  const { getLeagueCredits, subscribeLeagueBalance, loadDashboard } = useDashboardStore()

  const [league, setLeague]       = useState(null)
  const [matches, setMatches]     = useState([])
  const [members, setMembers]     = useState([])
  const [myBets, setMyBets]       = useState([])
  const [loading, setLoading]     = useState(true)
  const [activeTab, setActiveTab] = useState('matches')

  useEffect(() => {
    loadAll()
    // Subscribe to real-time balance updates for this league
    const unsub = subscribeLeagueBalance(user?.id, leagueId)
    return () => unsub()
  }, [leagueId, user?.id])

  const loadAll = async () => {
    setLoading(true)
    try {
      const [leagueRes, matchRes, memberRes, betRes] = await Promise.all([
        supabase.from('leagues').select('*').eq('id', leagueId).single(),
        supabase.from('matches').select('*').eq('league_id', leagueId).order('match_date', { ascending: false }),
        supabase.from('league_members')
          .select('user_id, credits, locked_credits, users(display_name)')
          .eq('league_id', leagueId),
        supabase.from('bets').select('*, matches(team_a, team_b, status, result)')
          .eq('user_id', user.id).eq('league_id', leagueId).order('created_at', { ascending: false }),
      ])
      setLeague(leagueRes.data)
      setMatches(matchRes.data || [])
      setMembers(memberRes.data || [])
      setMyBets(betRes.data || [])
      // Also refresh the dashboard store so leagueBalances is up-to-date
      await loadDashboard(user.id)
    } catch { toast.error('Failed to load league') }
    finally { setLoading(false) }
  }

  if (loading) return <LoadingSpinner />

  const openMatches  = matches.filter(m => ['upcoming', 'live'].includes(m.status))
  const pastMatches  = matches.filter(m => !['upcoming', 'live'].includes(m.status))
  // Leaderboard sorted by total credits (available + locked = total wealth)
  const leaderboard  = [...members].sort((a, b) => {
    const totalA = parseFloat(b.credits || 0) + parseFloat(b.locked_credits || 0)
    const totalB = parseFloat(a.credits || 0) + parseFloat(a.locked_credits || 0)
    return totalA - totalB
  })

  // My live balance from the store (real-time)
  const myBal = getLeagueCredits(leagueId)

  return (
    <div className="min-h-screen bg-surface-900">
      <Navbar />
      <div className="max-w-5xl mx-auto px-4 sm:px-6 py-8 space-y-8">

        {/* Header */}
        <div className="flex flex-col md:flex-row md:items-start md:justify-between gap-6">
          <div>
            <h1 className="font-display text-4xl text-white tracking-wide">{league?.name}</h1>
            <div className="flex items-center gap-2 mt-2">
              <span className="badge badge-gray font-mono flex items-center gap-1">
                <Hash size={10} /> {league?.code}
              </span>
              <span className="text-xs text-gray-500 font-mono">{members.length} members</span>
            </div>
          </div>
          {/* My league balance — always visible */}
          <div className="md:w-64 shrink-0">
            <LeagueWalletCard
              credits={myBal.credits}
              lockedCredits={myBal.locked_credits}
              leagueName="My Balance"
            />
          </div>
        </div>

        {/* Tabs */}
        <div className="flex gap-1 bg-surface-800 rounded-xl p-1 w-fit">
          {['matches', 'bets', 'leaderboard'].map(tab => (
            <button key={tab} onClick={() => setActiveTab(tab)}
              className={clsx('px-4 py-2 rounded-lg text-sm font-semibold transition-all capitalize',
                activeTab === tab ? 'bg-brand-500 text-white' : 'text-gray-400 hover:text-white'
              )}>
              {tab}
            </button>
          ))}
        </div>

        {/* Matches tab */}
        {activeTab === 'matches' && (
          <div className="space-y-6">
            {openMatches.length > 0 && (
              <div>
                <h2 className="text-sm font-mono text-gray-400 uppercase tracking-widest mb-3 flex items-center gap-2">
                  <Zap size={12} className="text-brand-500" /> Open for Betting
                </h2>
                <div className="grid md:grid-cols-2 gap-4">
                  {openMatches.map(m => (
                    <Link key={m.id} to={`/league/${leagueId}/match/${m.id}`}
                      className="card-hover p-5 block group">
                      {m.status === 'live' && (
                        <div className="flex items-center gap-1.5 mb-2">
                          <div className="w-2 h-2 bg-accent-red rounded-full animate-pulse" />
                          <span className="text-xs font-mono text-accent-red">LIVE</span>
                        </div>
                      )}
                      <div className="text-xs text-gray-500 font-mono mb-3">
                        {format(new Date(m.match_date), 'MMM d · h:mm a')}
                      </div>
                      <div className="flex justify-between items-center">
                        <div className="font-bold text-white">{m.team_a}</div>
                        <div className="text-xs text-gray-600 font-mono">VS</div>
                        <div className="font-bold text-white">{m.team_b}</div>
                      </div>
                      <div className="mt-3 text-xs text-brand-400 font-mono group-hover:text-brand-300 transition-colors text-right">
                        Bet now →
                      </div>
                    </Link>
                  ))}
                </div>
              </div>
            )}
            {pastMatches.length > 0 && (
              <div>
                <h2 className="text-sm font-mono text-gray-400 uppercase tracking-widest mb-3">Past Matches</h2>
                <div className="card overflow-hidden">
                  <table className="w-full text-sm">
                    <thead>
                      <tr className="border-b border-surface-700 text-left text-xs text-gray-500 font-mono uppercase">
                        <th className="px-4 py-3">Match</th>
                        <th className="px-4 py-3">Date</th>
                        <th className="px-4 py-3">Result</th>
                        <th className="px-4 py-3">Status</th>
                      </tr>
                    </thead>
                    <tbody>
                      {pastMatches.map(m => (
                        <tr key={m.id} className="table-row">
                          <td className="px-4 py-3 text-white">{m.team_a} vs {m.team_b}</td>
                          <td className="px-4 py-3 text-gray-400 font-mono text-xs">{format(new Date(m.match_date), 'MMM d')}</td>
                          <td className="px-4 py-3 text-gray-300 font-mono">{m.winning_team || m.result || '—'}</td>
                          <td className="px-4 py-3">
                            <span className={clsx('badge', m.status === 'completed' ? 'badge-green' : 'badge-gray')}>
                              {m.status}
                            </span>
                          </td>
                        </tr>
                      ))}
                    </tbody>
                  </table>
                </div>
              </div>
            )}
            {matches.length === 0 && (
              <div className="card p-10 text-center">
                <Clock size={28} className="mx-auto mb-3 text-gray-600" />
                <p className="text-gray-400">No matches scheduled yet</p>
              </div>
            )}
          </div>
        )}

        {/* My Bets tab */}
        {activeTab === 'bets' && (
          <div>
            {myBets.length === 0 ? (
              <div className="card p-10 text-center">
                <Trophy size={28} className="mx-auto mb-3 text-gray-600" />
                <p className="text-gray-400">No bets placed yet in this league</p>
              </div>
            ) : (
              <div className="card overflow-hidden">
                <table className="w-full text-sm">
                  <thead>
                    <tr className="border-b border-surface-700 text-left text-xs text-gray-500 font-mono uppercase">
                      <th className="px-4 py-3">Match</th>
                      <th className="px-4 py-3">Team</th>
                      <th className="px-4 py-3">Mult</th>
                      <th className="px-4 py-3">Bet</th>
                      <th className="px-4 py-3">Locked</th>
                      <th className="px-4 py-3">Won</th>
                      <th className="px-4 py-3">Status</th>
                    </tr>
                  </thead>
                  <tbody>
                    {myBets.map(b => {
                      const Icon = BET_ICON[b.status] || Clock
                      return (
                        <tr key={b.id} className="table-row">
                          <td className="px-4 py-3 text-gray-300 text-xs">
                            {b.matches?.team_a} vs {b.matches?.team_b}
                          </td>
                          <td className="px-4 py-3 font-semibold text-white">{b.bet_team}</td>
                          <td className="px-4 py-3 font-mono font-bold text-accent-gold">{b.multiplier}×</td>
                          <td className="px-4 py-3 font-mono text-gray-300">{formatCurrency(b.bet_amount)}</td>
                          <td className="px-4 py-3 font-mono text-accent-red">{formatCurrency(b.locked_amount)}</td>
                          <td className="px-4 py-3 font-mono text-accent-green">
                            {b.status === 'won' ? formatCurrency(b.credits_won) : '—'}
                          </td>
                          <td className="px-4 py-3">
                            <span className={clsx('flex items-center gap-1 text-xs font-mono font-semibold', BET_CLS[b.status] || 'text-gray-400')}>
                              <Icon size={12} /> {b.status}
                            </span>
                          </td>
                        </tr>
                      )
                    })}
                  </tbody>
                </table>
              </div>
            )}
          </div>
        )}

        {/* Leaderboard tab */}
        {activeTab === 'leaderboard' && (
          <div>
            <p className="text-xs text-gray-500 font-mono mb-3">
              Ranked by total credits (available + locked in active bets)
            </p>
            <div className="card overflow-hidden">
              <table className="w-full text-sm">
                <thead>
                  <tr className="border-b border-surface-700 text-left text-xs text-gray-500 font-mono uppercase">
                    <th className="px-4 py-3">#</th>
                    <th className="px-4 py-3">Player</th>
                    <th className="px-4 py-3 text-right">Available</th>
                    <th className="px-4 py-3 text-right">Locked</th>
                    <th className="px-4 py-3 text-right">Total</th>
                  </tr>
                </thead>
                <tbody>
                  {leaderboard.map((m, i) => {
                    const total = parseFloat(m.credits || 0) + parseFloat(m.locked_credits || 0)
                    return (
                      <tr key={m.user_id} className={clsx('table-row', m.user_id === user?.id && 'bg-brand-500/5')}>
                        <td className="px-4 py-3">
                          <span className={clsx('font-mono font-bold',
                            i === 0 ? 'text-accent-gold' : i === 1 ? 'text-gray-300' : i === 2 ? 'text-amber-600' : 'text-gray-500')}>
                            {i === 0 ? '🥇' : i === 1 ? '🥈' : i === 2 ? '🥉' : `#${i + 1}`}
                          </span>
                        </td>
                        <td className="px-4 py-3">
                          <span className="text-white font-medium">{m.users?.display_name ?? 'Unknown'}</span>
                          {m.user_id === user?.id && <span className="ml-2 badge badge-blue text-[10px]">You</span>}
                        </td>
                        <td className="px-4 py-3 text-right font-mono text-accent-green">
                          {formatCurrency(m.credits)}
                        </td>
                        <td className="px-4 py-3 text-right font-mono text-accent-red text-xs">
                          {parseFloat(m.locked_credits) > 0 ? formatCurrency(m.locked_credits) : '—'}
                        </td>
                        <td className="px-4 py-3 text-right font-mono font-bold text-white">
                          {formatCurrency(total)}
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

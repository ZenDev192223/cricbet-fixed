import { useEffect, useState, useCallback } from 'react'
import { useParams, useNavigate } from 'react-router-dom'
import { useAuthStore } from '../../store/auth'
import { useDashboardStore } from '../../store/dashboard'
import Navbar from '../../components/shared/Navbar'
import MultiplierChip from '../../components/user/MultiplierChip'
import LoadingSpinner from '../../components/shared/LoadingSpinner'
import { formatCurrency, calcLiabilityLock, calcWinReturn } from '../../lib/constants'
import { placeBet } from '../../lib/api'
import { supabase } from '../../lib/supabase'
import { ArrowLeft, AlertTriangle, Lock, Trophy, Flame, Shield, Info } from 'lucide-react'
import toast from 'react-hot-toast'
import clsx from 'clsx'
import { format } from 'date-fns'

const AVAILABLE_MULTIPLIERS = [1.5, 2, 3, 4, 5]

export default function MatchBetPage() {
  const { leagueId, matchId } = useParams()
  const navigate = useNavigate()
  const { user } = useAuthStore()
  const { getLeagueGameState, loadDashboard, getLeagueCredits, refreshLeagueBalance, refreshLeagueGameState } = useDashboardStore()

  // Derive league-scoped unlocks and cooldowns once leagueId is known
  const { unlocks, cooldowns } = getLeagueGameState(leagueId)

  const [match, setMatch]               = useState(null)
  const [league, setLeague]             = useState(null)
  const [existingBet, setExistingBet]   = useState(null)
  const [multiplier, setMultiplier]     = useState(1.5)
  const [betAmount, setBetAmount]       = useState('')
  const [selectedTeam, setSelectedTeam] = useState(null)
  const [loading, setLoading]           = useState(true)
  const [placing, setPlacing]           = useState(false)

  useEffect(() => { loadData() }, [matchId, leagueId, user?.id])

  const loadData = async () => {
    setLoading(true)
    try {
      const [matchRes, leagueRes, betRes] = await Promise.all([
        supabase.from('matches').select('*').eq('id', matchId).single(),
        supabase.from('leagues').select('*').eq('id', leagueId).single(),
        supabase.from('bets').select('*')
          .eq('user_id', user.id).eq('match_id', matchId).eq('league_id', leagueId)
          .neq('status', 'canceled').maybeSingle(),
      ])
      setMatch(matchRes.data)
      setLeague(leagueRes.data)
      setExistingBet(betRes.data)
    } catch {
      toast.error('Failed to load match data')
    } finally {
      setLoading(false)
    }
  }

  const isMultiplierAvailable = useCallback((m) => {
    if (m <= 2) return true
    return unlocks.some(u => u.multiplier === String(m) && !u.is_consumed)
  }, [unlocks])

  const getCooldown = useCallback((m) => cooldowns[String(m)] ?? 0, [cooldowns])

  // Use league-specific credits (not global wallet)
  const leagueBal   = getLeagueCredits(leagueId)
  const available   = parseFloat(leagueBal.credits ?? 0)
  const maxBetAmt   = Math.floor(available * 0.25)
  const lockAmount  = betAmount ? calcLiabilityLock(parseFloat(betAmount) || 0, multiplier) : 0
  const winAmount   = betAmount ? calcWinReturn(parseFloat(betAmount) || 0, multiplier)     : 0
  const penaltyPct  = multiplier === 1.5 ? 0 : multiplier === 2 ? 30 : multiplier === 3 ? 50 : multiplier === 4 ? 65 : 80

  const canBet = match?.status === 'upcoming' || match?.status === 'live'

  const handlePlace = async () => {
    if (!selectedTeam)  return toast.error('Select a team to bet on')
    if (!betAmount || parseFloat(betAmount) <= 0) return toast.error('Enter a valid bet amount')
    if (parseFloat(betAmount) > maxBetAmt) return toast.error(`Max bet is ${formatCurrency(maxBetAmt)} (25% of balance)`)
    if (lockAmount > available) return toast.error('Insufficient league credits (including penalty reserve)')

    setPlacing(true)
    try {
      const idempotencyKey = `${user.id}_${matchId}_${leagueId}_${Date.now()}`
      await placeBet({
        league_id: leagueId,
        match_id: matchId,
        bet_team: selectedTeam,
        multiplier: parseFloat(multiplier),
        bet_amount: parseFloat(betAmount),
        idempotency_key: idempotencyKey,
      })
      toast.success(`Bet placed! ${formatCurrency(lockAmount)} locked.`)
      // Refresh balance and league game state (streaks/unlocks/cooldowns)
      await Promise.all([
        refreshLeagueBalance(user.id, leagueId),
        refreshLeagueGameState(user.id, leagueId),
      ])
      await loadData()
    } catch (e) {
      toast.error(e.message)
    } finally {
      setPlacing(false)
    }
  }

  if (loading) return <LoadingSpinner />

  return (
    <div className="min-h-screen bg-surface-900">
      <Navbar />
      <div className="max-w-2xl mx-auto px-4 sm:px-6 py-8">

        {/* Back */}
        <button onClick={() => navigate(-1)} className="flex items-center gap-2 text-gray-400 hover:text-white mb-6 transition-colors">
          <ArrowLeft size={16} /> Back
        </button>

        {/* Match card */}
        <div className="card p-6 mb-6">
          <div className="flex items-center gap-2 mb-2">
            <span className={clsx('badge', match?.status === 'live' ? 'badge-red' : 'badge-blue')}>
              {match?.status === 'live' ? '🔴 LIVE' : match?.status?.toUpperCase()}
            </span>
            <span className="text-xs text-gray-500 font-mono">{league?.name}</span>
          </div>
          <div className="text-xs text-gray-500 font-mono mb-4">
            {match && format(new Date(match.match_date), 'EEEE, MMMM d · h:mm a')}
          </div>
          <div className="flex items-center justify-between">
            <div className="text-2xl font-display font-bold text-white">{match?.team_a}</div>
            <div className="text-sm text-gray-600 font-mono font-bold px-4">VS</div>
            <div className="text-2xl font-display font-bold text-white text-right">{match?.team_b}</div>
          </div>
          {match?.venue && <div className="text-xs text-gray-600 text-center mt-3 font-mono">{match.venue}</div>}
        </div>

        {/* Existing bet */}
        {existingBet && (
          <div className="card p-5 mb-6 border-accent-gold/30 bg-yellow-500/5">
            <div className="flex items-center gap-2 mb-3">
              <Trophy size={16} className="text-accent-gold" />
              <span className="text-sm font-semibold text-accent-gold">Your Bet</span>
            </div>
            <div className="grid grid-cols-3 gap-4 text-center">
              <div>
                <div className="text-xs text-gray-500 font-mono mb-1">Team</div>
                <div className="font-bold text-white">{existingBet.bet_team}</div>
              </div>
              <div>
                <div className="text-xs text-gray-500 font-mono mb-1">Multiplier</div>
                <div className="font-bold text-accent-gold font-mono">{existingBet.multiplier}×</div>
              </div>
              <div>
                <div className="text-xs text-gray-500 font-mono mb-1">Status</div>
                <div className={clsx('badge', existingBet.status === 'won' ? 'badge-green' : existingBet.status === 'lost' ? 'badge-red' : 'badge-gold')}>
                  {existingBet.status}
                </div>
              </div>
            </div>
            <div className="grid grid-cols-2 gap-4 text-center mt-4 pt-4 border-t border-surface-600">
              <div>
                <div className="text-xs text-gray-500 font-mono mb-1">Bet Amount</div>
                <div className="font-mono text-white">{formatCurrency(existingBet.bet_amount)}</div>
              </div>
              <div>
                <div className="text-xs text-gray-500 font-mono mb-1">Locked</div>
                <div className="font-mono text-accent-red">{formatCurrency(existingBet.locked_amount)}</div>
              </div>
            </div>
          </div>
        )}

        {/* Bet placement form */}
        {!existingBet && canBet && (
          <div className="space-y-6">
            {/* League balance summary */}
            <div className="card p-4 flex items-center justify-between">
              <div className="flex items-center gap-2 text-gray-400 text-sm">
                <Shield size={14} /> League credits available
              </div>
              <div>
                <span className="font-mono font-bold text-accent-green">{formatCurrency(available)}</span>
                {parseFloat(leagueBal.locked_credits) > 0 && (
                  <span className="font-mono text-xs text-accent-red ml-2">
                    ({formatCurrency(leagueBal.locked_credits)} locked)
                  </span>
                )}
              </div>
            </div>

            {/* Team selection */}
            <div>
              <h3 className="text-sm font-mono text-gray-400 uppercase tracking-widest mb-3">Bet on</h3>
              <div className="grid grid-cols-2 gap-3">
                {[match?.team_a, match?.team_b].map(team => (
                  <button key={team} onClick={() => setSelectedTeam(team)}
                    className={clsx(
                      'py-4 px-6 rounded-xl border-2 font-bold text-lg transition-all duration-200 active:scale-95',
                      selectedTeam === team
                        ? 'border-brand-500 bg-brand-500/20 text-white shadow-glow-orange'
                        : 'border-surface-500 bg-surface-700 text-gray-300 hover:border-surface-400'
                    )}>
                    {team}
                  </button>
                ))}
              </div>
            </div>

            {/* Multiplier selection */}
            <div>
              <h3 className="text-sm font-mono text-gray-400 uppercase tracking-widest mb-3">Multiplier</h3>
              <div className="flex gap-3 flex-wrap">
                {AVAILABLE_MULTIPLIERS.map(m => (
                  <MultiplierChip
                    key={m}
                    multiplier={m}
                    selected={multiplier === m}
                    onClick={setMultiplier}
                    notUnlocked={m > 2 && !isMultiplierAvailable(m)}
                    cooldown={getCooldown(m)}
                  />
                ))}
              </div>
              {multiplier > 2 && (
                <div className="mt-2 flex items-start gap-1.5 text-xs text-gray-500 font-mono">
                  <Flame size={11} className="mt-0.5 shrink-0 text-accent-gold" />
                  Consumable — this multiplier is used after settlement regardless of outcome
                </div>
              )}
            </div>

            {/* Bet amount */}
            <div>
              <div className="flex items-center justify-between mb-2">
                <h3 className="text-sm font-mono text-gray-400 uppercase tracking-widest">Amount</h3>
                <button onClick={() => setBetAmount(String(maxBetAmt))}
                  className="text-xs text-brand-400 hover:text-brand-300 font-mono transition-colors">
                  Max {formatCurrency(maxBetAmt)}
                </button>
              </div>
              <div className="relative">
                <span className="absolute left-4 top-1/2 -translate-y-1/2 text-gray-400 font-mono">₹</span>
                <input
                  className="input pl-8 text-lg font-mono"
                  placeholder="0"
                  type="number"
                  min="1"
                  max={maxBetAmt}
                  value={betAmount}
                  onChange={e => setBetAmount(e.target.value)}
                />
              </div>
              <div className="flex gap-2 mt-2">
                {[100, 250, 500, 1000].filter(v => v <= maxBetAmt).map(v => (
                  <button key={v} onClick={() => setBetAmount(String(v))}
                    className="btn-ghost text-xs px-3 py-1.5 font-mono border border-surface-600 rounded-lg">
                    ₹{v}
                  </button>
                ))}
              </div>
            </div>

            {/* Summary */}
            {betAmount && parseFloat(betAmount) > 0 && (
              <div className="card p-5 space-y-3 animate-in">
                <h3 className="text-sm font-mono text-gray-400 uppercase tracking-widest">Bet Summary</h3>
                <div className="space-y-2 text-sm">
                  <div className="flex justify-between">
                    <span className="text-gray-400">Bet amount</span>
                    <span className="font-mono text-white">{formatCurrency(parseFloat(betAmount))}</span>
                  </div>
                  <div className="flex justify-between">
                    <span className="text-gray-400">Multiplier</span>
                    <span className="font-mono text-white">{multiplier}×</span>
                  </div>
                  {penaltyPct > 0 && (
                    <div className="flex justify-between">
                      <span className="text-gray-400">Loss penalty</span>
                      <span className="font-mono text-accent-red">+{penaltyPct}%</span>
                    </div>
                  )}
                  <div className="border-t border-surface-600 pt-2 space-y-2">
                    <div className="flex justify-between items-center">
                      <span className="flex items-center gap-1 text-gray-400">
                        <Lock size={12} /> Credits locked
                      </span>
                      <span className="font-mono font-bold text-accent-red">{formatCurrency(lockAmount)}</span>
                    </div>
                    <div className="flex justify-between items-center">
                      <span className="flex items-center gap-1 text-gray-400">
                        <Trophy size={12} /> If you win
                      </span>
                      <span className="font-mono font-bold text-accent-green">{formatCurrency(winAmount)}</span>
                    </div>
                  </div>
                </div>
                {penaltyPct > 0 && (
                  <div className="flex items-start gap-2 bg-red-500/10 border border-red-500/20 rounded-lg p-3 text-xs text-red-300 font-mono">
                    <AlertTriangle size={12} className="shrink-0 mt-0.5" />
                    On loss: {formatCurrency(lockAmount)} deducted from league credits (bet + {penaltyPct}% penalty)
                  </div>
                )}
              </div>
            )}

            {/* Place button */}
            <button onClick={handlePlace} disabled={placing || !selectedTeam || !betAmount}
              className="btn-primary w-full text-lg py-4">
              {placing ? 'Placing Bet…' : selectedTeam
                ? `Bet ${formatCurrency(parseFloat(betAmount) || 0)} on ${selectedTeam}`
                : 'Select a team to continue'}
            </button>
          </div>
        )}

        {!canBet && !existingBet && (
          <div className="card p-8 text-center">
            <Info size={28} className="mx-auto mb-3 text-gray-600" />
            <p className="text-gray-400">This match is no longer open for betting</p>
            <p className="text-xs text-gray-600 mt-1 font-mono">Status: {match?.status}</p>
          </div>
        )}
      </div>
    </div>
  )
}
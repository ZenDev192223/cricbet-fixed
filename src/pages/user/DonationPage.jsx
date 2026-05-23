import { useEffect, useState } from 'react'
import { useAuthStore } from '../../store/auth'
import { useDashboardStore } from '../../store/dashboard'
import Navbar from '../../components/shared/Navbar'
import { processDonation } from '../../lib/api'
import { supabase } from '../../lib/supabase'
import { formatCurrency } from '../../lib/constants'
import { ArrowRight, Send, Clock, Shield, Info, Search, ChevronDown } from 'lucide-react'
import { formatDistanceToNow } from 'date-fns'
import toast from 'react-hot-toast'
import clsx from 'clsx'

export default function DonationPage() {
  const { user, profile } = useAuthStore()
  const { leagues, leagueBalances, loadDashboard, refreshLeagueBalance, getLeagueCredits } = useDashboardStore()

  const [selectedLeagueId, setSelectedLeagueId] = useState('')
  const [searchEmail, setSearchEmail]           = useState('')
  const [foundUser, setFoundUser]               = useState(null)
  const [searching, setSearching]               = useState(false)
  const [amount, setAmount]                     = useState('')
  const [note, setNote]                         = useState('')
  const [sending, setSending]                   = useState(false)
  const [history, setHistory]                   = useState([])
  const [loadingHistory, setLoadingHistory]     = useState(true)

  useEffect(() => {
    loadHistory()
    // Default to first league if available
    if (leagues.length > 0 && !selectedLeagueId) {
      setSelectedLeagueId(leagues[0].id)
    }
  }, [user?.id, leagues])

  const loadHistory = async () => {
    setLoadingHistory(true)
    const { data } = await supabase.from('donations')
      .select('*, sender:sender_id(display_name), receiver:receiver_id(display_name), leagues(name)')
      .or(`sender_id.eq.${user.id},receiver_id.eq.${user.id}`)
      .order('created_at', { ascending: false })
      .limit(20)
    setHistory(data || [])
    setLoadingHistory(false)
  }

  const searchUser = async () => {
    if (!searchEmail.trim()) return
    setSearching(true)
    setFoundUser(null)
    try {
      const { data } = await supabase.from('users')
        .select('id, display_name, email')
        .ilike('email', searchEmail.trim())
        .neq('id', user.id)
        .single()
      if (data) {
        // Verify they are in the selected league
        if (selectedLeagueId) {
          const { data: mem } = await supabase.from('league_members')
            .select('id, week_received, week_reset_at').eq('user_id', data.id).eq('league_id', selectedLeagueId).maybeSingle()
          if (!mem) {
            toast.error('This player is not a member of the selected league')
            setSearching(false)
            return
          }
          // Attach cap info to foundUser
          setFoundUser({ ...data, week_received: mem.week_received ?? 0, week_reset_at: mem.week_reset_at })
          setSearching(false)
          return
        }
        setFoundUser({ ...data, week_received: 0 })
      } else {
        toast.error('User not found')
      }
    } catch { toast.error('User not found') }
    finally { setSearching(false) }
  }

  const handleSend = async () => {
    if (!selectedLeagueId) return toast.error('Select a league first')
    if (!foundUser)        return toast.error('Search for a recipient first')
    if (!amount || parseFloat(amount) <= 0) return toast.error('Enter a valid amount')

    const bal = getLeagueCredits(selectedLeagueId)
    const avail = parseFloat(bal.credits ?? 0)
    if (parseFloat(amount) > avail) return toast.error('Insufficient league credits')

    setSending(true)
    try {
      await processDonation({
        receiver_id: foundUser.id,
        league_id:   selectedLeagueId,
        amount:      parseFloat(amount),
        note,
      })
      toast.success(`Sent ${formatCurrency(parseFloat(amount))} to ${foundUser.display_name}`)
      setAmount('')
      setNote('')
      setFoundUser(null)
      setSearchEmail('')
      await Promise.all([
        loadDashboard(user.id),
        refreshLeagueBalance(user.id, selectedLeagueId),
        loadHistory(),
      ])
    } catch (e) { toast.error(e.message) }
    finally { setSending(false) }
  }

  const selectedLeague = leagues.find(l => l.id === selectedLeagueId)
  const bal = selectedLeagueId ? getLeagueCredits(selectedLeagueId) : { credits: 0, locked_credits: 0 }
  const available = parseFloat(bal.credits ?? 0)

  return (
    <div className="min-h-screen bg-surface-900">
      <Navbar />
      <div className="max-w-2xl mx-auto px-4 sm:px-6 py-8 space-y-8">

        <div>
          <h1 className="font-display text-4xl text-white tracking-wide">Transfer Credits</h1>
          <p className="text-gray-500 text-sm mt-1 font-mono">Send credits to another player within a league</p>
        </div>

        {/* League selector */}
        <div className="card p-5 space-y-4">
          <div>
            <label className="text-xs text-gray-500 font-mono uppercase mb-2 block">Select League</label>
            {leagues.length === 0 ? (
              <p className="text-gray-500 text-sm font-mono">You are not in any leagues yet.</p>
            ) : (
              <div className="relative">
                <select
                  className="input w-full appearance-none pr-10"
                  value={selectedLeagueId}
                  onChange={e => {
                    setSelectedLeagueId(e.target.value)
                    setFoundUser(null)
                    setSearchEmail('')
                  }}>
                  <option value="">— choose a league —</option>
                  {leagues.map(l => (
                    <option key={l.id} value={l.id}>{l.name} ({l.code})</option>
                  ))}
                </select>
                <ChevronDown size={14} className="absolute right-3 top-1/2 -translate-y-1/2 text-gray-400 pointer-events-none" />
              </div>
            )}
          </div>

          {/* Balance for selected league */}
          {selectedLeagueId && (
            <div className="grid grid-cols-2 gap-4 pt-2 border-t border-surface-700">
              <div>
                <div className="text-xs text-gray-500 font-mono uppercase mb-1">Available to Send</div>
                <div className="text-2xl font-display font-bold text-accent-green">{formatCurrency(available)}</div>
              </div>
              {parseFloat(bal.locked_credits) > 0 && (
                <div>
                  <div className="text-xs text-gray-500 font-mono uppercase mb-1">Locked (cannot send)</div>
                  <div className="text-xl font-display font-semibold text-accent-red">{formatCurrency(bal.locked_credits)}</div>
                </div>
              )}
            </div>
          )}

          <div className="flex items-start gap-2 text-xs text-gray-500 font-mono">
            <Shield size={11} className="mt-0.5 shrink-0" />
            Only available credits (not locked in bets) can be transferred
          </div>
        </div>

        {/* Send form */}
        {selectedLeagueId && (
          <div className="card p-6 space-y-5">
            <h2 className="font-semibold text-white text-lg">Send Credits in {selectedLeague?.name}</h2>

            {/* Recipient search */}
            <div>
              <label className="text-xs text-gray-500 font-mono uppercase mb-2 block">Recipient Email</label>
              <div className="flex gap-2">
                <div className="relative flex-1">
                  <Search size={14} className="absolute left-3 top-1/2 -translate-y-1/2 text-gray-500" />
                  <input className="input pl-9" placeholder="Enter email address"
                    value={searchEmail} onChange={e => setSearchEmail(e.target.value)}
                    onKeyDown={e => e.key === 'Enter' && searchUser()} />
                </div>
                <button onClick={searchUser} disabled={searching} className="btn-secondary px-4 py-3 shrink-0">
                  {searching ? '…' : 'Search'}
                </button>
              </div>
              {foundUser && (() => {
                const weeklyCapVal  = 1000 // from config — matches donation_weekly_cap
                const received      = parseFloat(foundUser.week_received ?? 0)
                const remaining     = Math.max(0, weeklyCapVal - received)
                const pct           = (received / weeklyCapVal) * 100
                const capColor      = pct >= 100 ? 'text-accent-red' : pct >= 60 ? 'text-yellow-400' : 'text-accent-green'
                const barColor      = pct >= 100 ? 'bg-accent-red' : pct >= 60 ? 'bg-yellow-400' : 'bg-accent-green'
                const borderColor   = pct >= 100 ? 'border-accent-red/40' : pct >= 60 ? 'border-yellow-400/30' : 'border-accent-green/30'
                const bgColor       = pct >= 100 ? 'bg-accent-red/10' : pct >= 60 ? 'bg-yellow-400/10' : 'bg-accent-green/10'
                return (
                  <div className={`mt-2 p-3 border rounded-xl animate-in ${bgColor} ${borderColor}`}>
                    <div className="flex items-center gap-3 mb-3">
                      <div className={`w-8 h-8 rounded-full flex items-center justify-center font-bold text-sm ${bgColor} ${capColor}`}>
                        {foundUser.display_name[0]?.toUpperCase()}
                      </div>
                      <div>
                        <div className="font-semibold text-white text-sm">{foundUser.display_name}</div>
                        <div className="text-xs text-gray-400">{foundUser.email}</div>
                      </div>
                    </div>
                    {/* Weekly cap bar */}
                    <div className="space-y-1">
                      <div className="flex items-center justify-between text-xs font-mono mb-1">
                        <span className="text-gray-400">Weekly cap</span>
                        <span className={capColor}>{Math.round(pct)}% used</span>
                      </div>
                      <div className="w-full h-1.5 bg-surface-700 rounded-full overflow-hidden">
                        <div
                          className={`h-full rounded-full transition-all ${barColor}`}
                          style={{ width: `${Math.min(pct, 100)}%` }}
                        />
                      </div>
                      <div className="flex items-center justify-between text-xs font-mono mt-1">
                        <span className="text-gray-500">{formatCurrency(received)} used of {formatCurrency(weeklyCapVal)}</span>
                        <span className={capColor}>
                          {pct >= 100 ? 'Cap reached' : `${formatCurrency(remaining)} left`}
                        </span>
                      </div>
                    </div>
                  </div>
                )
              })()}
            </div>

            {/* Amount */}
            <div>
              <label className="text-xs text-gray-500 font-mono uppercase mb-2 block">Amount</label>
              <div className="relative">
                <span className="absolute left-4 top-1/2 -translate-y-1/2 text-gray-400 font-mono">₹</span>
                <input className="input pl-8 font-mono text-lg" placeholder="0" type="number" min="1"
                  value={amount} onChange={e => setAmount(e.target.value)} />
              </div>
              <div className="flex gap-2 mt-2">
                {[100, 250, 500].filter(v => v <= available).map(v => (
                  <button key={v} onClick={() => setAmount(String(v))}
                    className="btn-ghost text-xs px-3 py-1.5 font-mono border border-surface-600 rounded-lg">
                    ₹{v}
                  </button>
                ))}
              </div>
            </div>

            {/* Note */}
            <div>
              <label className="text-xs text-gray-500 font-mono uppercase mb-2 block">Note (optional)</label>
              <input className="input" placeholder="What's this for?" maxLength={100}
                value={note} onChange={e => setNote(e.target.value)} />
            </div>

            {/* Limits info */}
            <div className="flex items-start gap-2 text-xs text-gray-500 font-mono bg-surface-700 rounded-lg p-3">
              <Info size={12} className="mt-0.5 shrink-0" />
              <span>Max 3 transfers/day · Receiver limit: ₹1,000/week per league · 60 min cooldown between transfers</span>
            </div>

            <button onClick={handleSend}
              disabled={sending || !foundUser || !amount || parseFloat(amount) <= 0 || parseFloat(amount) > available}
              className="btn-primary w-full flex items-center justify-center gap-2">
              <Send size={16} />
              {sending ? 'Sending…' : `Send ${amount ? formatCurrency(parseFloat(amount)) : 'Credits'}`}
            </button>
          </div>
        )}

        {/* Transfer history */}
        <div>
          <h2 className="font-display text-2xl text-white mb-4">Transfer History</h2>
          {loadingHistory ? (
            <div className="card p-8 text-center text-gray-500">Loading…</div>
          ) : history.length === 0 ? (
            <div className="card p-8 text-center">
              <ArrowRight size={28} className="mx-auto mb-3 text-gray-600" />
              <p className="text-gray-400">No transfers yet</p>
            </div>
          ) : (
            <div className="card overflow-hidden">
              {history.map(d => {
                const isSent = d.sender_id === user.id
                return (
                  <div key={d.id} className="flex items-center justify-between px-4 py-3 border-b border-surface-700 last:border-0">
                    <div className="flex items-center gap-3">
                      <div className={clsx('w-8 h-8 rounded-full flex items-center justify-center',
                        isSent ? 'bg-red-500/20' : 'bg-accent-green/20')}>
                        <ArrowRight size={14} className={clsx(isSent ? 'text-accent-red rotate-0' : 'text-accent-green rotate-180')} />
                      </div>
                      <div>
                        <div className="text-sm text-white">
                          {isSent
                            ? `To ${d.receiver?.display_name ?? 'Unknown'}`
                            : `From ${d.sender?.display_name ?? 'Unknown'}`}
                        </div>
                        {d.leagues?.name && (
                          <div className="text-xs text-brand-400 font-mono">{d.leagues.name}</div>
                        )}
                        {d.note && <div className="text-xs text-gray-500 mt-0.5">{d.note}</div>}
                        <div className="text-xs text-gray-600 font-mono">
                          {formatDistanceToNow(new Date(d.created_at), { addSuffix: true })}
                        </div>
                      </div>
                    </div>
                    <div className={clsx('font-mono font-bold', isSent ? 'text-accent-red' : 'text-accent-green')}>
                      {isSent ? '-' : '+'}{formatCurrency(d.amount)}
                    </div>
                  </div>
                )
              })}
            </div>
          )}
        </div>
      </div>
    </div>
  )
}
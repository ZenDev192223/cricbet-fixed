import { useEffect, useState } from 'react'
import { useAuthStore } from '../../store/auth'
import Navbar from '../../components/shared/Navbar'
import { supabase } from '../../lib/supabase'
import { adminAdjustWallet } from '../../lib/api'
import { formatCurrency } from '../../lib/constants'
import {
  Users, Search, Shield, Ban, CheckCircle2, Wallet,
  ChevronDown, ChevronUp, RefreshCw, AlertTriangle, X, Building2
} from 'lucide-react'
import { formatDistanceToNow, format } from 'date-fns'
import toast from 'react-hot-toast'
import clsx from 'clsx'

export default function AdminUsers() {
  const { user: adminUser } = useAuthStore()
  const [users, setUsers]       = useState([])
  const [loading, setLoading]   = useState(true)
  const [search, setSearch]     = useState('')
  const [expanded, setExpanded] = useState(null)
  const [walletModal, setWalletModal] = useState(null) // { userId, name }
  const [walletForm, setWalletForm]   = useState({ amount: '', type: 'credit', reason: '' })
  const [leagues, setLeagues]           = useState([]) // all leagues for wallet modal
  const [adjusting, setAdjusting]     = useState(false)
  const [suspendModal, setSuspendModal] = useState(null)
  const [suspendReason, setSuspendReason] = useState('')

  useEffect(() => { loadUsers(); loadLeagues() }, [])

  const loadUsers = async () => {
    setLoading(true)
    try {
      const { data, error } = await supabase
        .from('users')
        .select(`
          *,
          wallets(available_balance, locked_balance, total_donated, total_received),
          streaks(multiplier_tier, current_streak),
          multiplier_unlocks(multiplier, is_consumed),
          bets(count)
        `)
        .order('created_at', { ascending: false })
      if (error) throw error
      setUsers(data || [])
    } catch (e) { toast.error('Failed to load users') }
    finally { setLoading(false) }
  }


  const loadLeagues = async () => {
    const { data } = await supabase.from('leagues').select('id, name').order('name')
    setLeagues(data || [])
  }

  const handleWalletAdjust = async () => {
    if (!walletForm.amount || parseFloat(walletForm.amount) <= 0) return toast.error('Enter a valid amount')
    if (!walletForm.reason.trim()) return toast.error('Reason is required')
    setAdjusting(true)
    try {
      await adminAdjustWallet({
        userId: walletModal.userId,
        amount: parseFloat(walletForm.amount),
        type: walletForm.type,
        reason: walletForm.reason,
      })
      toast.success(`Wallet ${walletForm.type === 'credit' ? 'credited' : 'debited'} successfully`)
      setWalletModal(null)
      setWalletForm({ amount: '', type: 'credit', reason: '', leagueId: '' })
      loadUsers()
    } catch (e) { toast.error(e.message) }
    finally { setAdjusting(false) }
  }

  const handleSuspend = async (userId, suspend) => {
    if (suspend && !suspendReason.trim()) return toast.error('Enter a suspension reason')
    try {
      const { error } = await supabase.from('users')
        .update({ is_suspended: suspend, suspend_reason: suspend ? suspendReason : null })
        .eq('id', userId)
      if (error) throw error
      // Audit log
      await supabase.from('admin_logs').insert({
        admin_id: adminUser.id,
        action: suspend ? 'suspend_user' : 'unsuspend_user',
        target_type: 'user', target_id: userId,
        new_value: { reason: suspendReason },
      })
      toast.success(suspend ? 'User suspended' : 'User unsuspended')
      setSuspendModal(null)
      setSuspendReason('')
      loadUsers()
    } catch (e) { toast.error(e.message) }
  }

  const handleGrantMultiplier = async (userId, multiplier) => {
    try {
      const { error } = await supabase.from('multiplier_unlocks').upsert({
        user_id: userId, multiplier: String(multiplier),
        unlock_source: 'admin_grant', is_consumed: false,
        unlocked_at: new Date().toISOString(),
      }, { onConflict: 'user_id,multiplier' })
      if (error) throw error
      await supabase.from('admin_logs').insert({
        admin_id: adminUser.id, action: 'grant_multiplier',
        target_type: 'user', target_id: userId,
        new_value: { multiplier },
      })
      toast.success(`${multiplier}× granted`)
      loadUsers()
    } catch (e) { toast.error(e.message) }
  }

  const handleResetStreak = async (userId) => {
    try {
      const { error } = await supabase.from('streaks')
        .update({ current_streak: 0, last_updated: new Date().toISOString() })
        .eq('user_id', userId)
      if (error) throw error
      await supabase.from('admin_logs').insert({
        admin_id: adminUser.id, action: 'reset_streaks',
        target_type: 'user', target_id: userId,
      })
      toast.success('Streaks reset')
      loadUsers()
    } catch (e) { toast.error(e.message) }
  }

  const filtered = users.filter(u =>
    !search ||
    u.display_name?.toLowerCase().includes(search.toLowerCase()) ||
    u.email?.toLowerCase().includes(search.toLowerCase())
  )

  return (
    <div className="min-h-screen bg-surface-900">
      <Navbar />
      <div className="max-w-7xl mx-auto px-4 sm:px-6 py-8 space-y-6">

        {/* Header */}
        <div className="flex items-center justify-between">
          <div>
            <h1 className="font-display text-4xl text-white tracking-wide">User Management</h1>
            <p className="text-gray-500 text-sm mt-1 font-mono">{users.length} total users</p>
          </div>
          <button onClick={loadUsers} className="btn-secondary flex items-center gap-2 px-4 py-2 text-sm">
            <RefreshCw size={14} /> Refresh
          </button>
        </div>

        {/* Search */}
        <div className="relative max-w-md">
          <Search size={16} className="absolute left-3 top-1/2 -translate-y-1/2 text-gray-500" />
          <input className="input pl-10" placeholder="Search by name or email…"
            value={search} onChange={e => setSearch(e.target.value)} />
        </div>

        {/* Users table */}
        {loading ? (
          <div className="space-y-2">
            {[...Array(5)].map((_, i) => (
              <div key={i} className="card p-4 h-16 animate-pulse bg-surface-700" />
            ))}
          </div>
        ) : (
          <div className="space-y-2">
            {filtered.map(u => {
              const wallet   = u.wallets?.[0] ?? u.wallets ?? {}
              const unlocks  = u.multiplier_unlocks || []
              const streaks  = u.streaks || []
              const avail    = parseFloat(wallet.available_balance ?? 0)
              const locked   = parseFloat(wallet.locked_balance ?? 0)
              const isOpen   = expanded === u.id

              return (
                <div key={u.id} className={clsx('card overflow-hidden transition-all', u.is_suspended && 'border-accent-red/30')}>
                  {/* Row */}
                  <div className="flex items-center gap-4 p-4 cursor-pointer hover:bg-surface-700/40 transition-colors"
                    onClick={() => setExpanded(isOpen ? null : u.id)}>
                    {/* Avatar */}
                    <div className={clsx('w-9 h-9 rounded-full flex items-center justify-center font-bold text-sm shrink-0',
                      u.is_suspended ? 'bg-accent-red/20 text-accent-red' : 'bg-brand-500/20 text-brand-400')}>
                      {u.display_name?.[0]?.toUpperCase() ?? '?'}
                    </div>

                    {/* Name + email */}
                    <div className="flex-1 min-w-0">
                      <div className="flex items-center gap-2">
                        <span className="font-semibold text-white truncate">{u.display_name}</span>
                        {u.role !== 'user' && (
                          <span className="badge badge-purple">{u.role}</span>
                        )}
                        {u.is_suspended && <span className="badge badge-red">Suspended</span>}
                        {u.exploit_flagged && <span className="badge badge-gold">Flagged</span>}
                      </div>
                      <div className="text-xs text-gray-500 font-mono truncate">{u.email}</div>
                    </div>

                    {/* Wallet */}
                    <div className="hidden sm:block text-right">
                      <div className="font-mono font-bold text-accent-green text-sm">{formatCurrency(avail)}</div>
                      {locked > 0 && <div className="font-mono text-accent-red text-xs">{formatCurrency(locked)} locked</div>}
                    </div>

                    {/* Fraud score */}
                    <div className="hidden md:block text-center">
                      <div className={clsx('font-mono font-bold text-sm',
                        u.fraud_score >= 80 ? 'text-accent-red' :
                        u.fraud_score >= 40 ? 'text-orange-400' : 'text-gray-500')}>
                        {u.fraud_score}
                      </div>
                      <div className="text-xs text-gray-600">fraud</div>
                    </div>

                    {/* Joined */}
                    <div className="hidden lg:block text-xs text-gray-500 font-mono text-right">
                      {formatDistanceToNow(new Date(u.created_at), { addSuffix: true })}
                    </div>

                    {isOpen ? <ChevronUp size={16} className="text-gray-400 shrink-0" /> : <ChevronDown size={16} className="text-gray-400 shrink-0" />}
                  </div>

                  {/* Expanded panel */}
                  {isOpen && (
                    <div className="border-t border-surface-700 p-5 space-y-5 bg-surface-800/50 animate-in">
                      {/* Info grid */}
                      <div className="grid grid-cols-2 md:grid-cols-4 gap-4 text-sm">
                        <div>
                          <div className="text-xs text-gray-500 font-mono mb-1">Available</div>
                          <div className="font-mono font-bold text-accent-green">{formatCurrency(avail)}</div>
                        </div>
                        <div>
                          <div className="text-xs text-gray-500 font-mono mb-1">Locked</div>
                          <div className="font-mono font-bold text-accent-red">{formatCurrency(locked)}</div>
                        </div>
                        <div>
                          <div className="text-xs text-gray-500 font-mono mb-1">Total Donated</div>
                          <div className="font-mono text-gray-300">{formatCurrency(wallet.total_donated ?? 0)}</div>
                        </div>
                        <div>
                          <div className="text-xs text-gray-500 font-mono mb-1">Total Received</div>
                          <div className="font-mono text-gray-300">{formatCurrency(wallet.total_received ?? 0)}</div>
                        </div>
                        <div>
                          <div className="text-xs text-gray-500 font-mono mb-1">Completed Bets</div>
                          <div className="font-mono text-gray-300">{u.completed_bets}</div>
                        </div>
                        <div>
                          <div className="text-xs text-gray-500 font-mono mb-1">Fraud Score</div>
                          <div className={clsx('font-mono font-bold',
                            u.fraud_score >= 80 ? 'text-accent-red' :
                            u.fraud_score >= 40 ? 'text-orange-400' : 'text-gray-400')}>
                            {u.fraud_score}
                          </div>
                        </div>
                        <div>
                          <div className="text-xs text-gray-500 font-mono mb-1">Last Bet</div>
                          <div className="font-mono text-gray-400 text-xs">
                            {u.last_bet_at ? formatDistanceToNow(new Date(u.last_bet_at), { addSuffix: true }) : 'Never'}
                          </div>
                        </div>
                        <div>
                          <div className="text-xs text-gray-500 font-mono mb-1">Member Since</div>
                          <div className="font-mono text-gray-400 text-xs">
                            {format(new Date(u.created_at), 'MMM d, yyyy')}
                          </div>
                        </div>
                      </div>

                      {/* Streaks */}
                      {streaks.length > 0 && (
                        <div>
                          <div className="text-xs text-gray-500 font-mono uppercase mb-2">Active Streaks</div>
                          <div className="flex gap-2 flex-wrap">
                            {streaks.filter(s => s.current_streak > 0).map(s => (
                              <span key={s.multiplier_tier} className="badge badge-gold font-mono">
                                {s.multiplier_tier}× · {s.current_streak} wins
                              </span>
                            ))}
                            {streaks.every(s => s.current_streak === 0) && (
                              <span className="text-xs text-gray-600">No active streaks</span>
                            )}
                          </div>
                        </div>
                      )}

                      {/* Unlocked multipliers */}
                      {unlocks.length > 0 && (
                        <div>
                          <div className="text-xs text-gray-500 font-mono uppercase mb-2">Unlocked Multipliers</div>
                          <div className="flex gap-2 flex-wrap">
                            {unlocks.map(ul => (
                              <span key={ul.multiplier} className={clsx('badge font-mono',
                                ul.is_consumed ? 'badge-gray' : 'badge-purple')}>
                                {ul.multiplier}× {ul.is_consumed ? '(used)' : '(active)'}
                              </span>
                            ))}
                          </div>
                        </div>
                      )}

                      {/* Action buttons */}
                      <div className="flex flex-wrap gap-2 pt-2 border-t border-surface-700">
                        <button
                          onClick={() => { setWalletModal({ userId: u.id, name: u.display_name }); setWalletForm({ amount: '', type: 'credit', reason: '' }) }}
                          className="btn-secondary text-xs px-3 py-2 flex items-center gap-1.5">
                          <Wallet size={12} /> Adjust Wallet
                        </button>
                        {!u.is_suspended ? (
                          <button onClick={() => setSuspendModal(u.id)}
                            className="text-xs px-3 py-2 rounded-lg flex items-center gap-1.5 bg-red-500/10 text-accent-red border border-red-500/30 hover:bg-red-500/20 transition-colors">
                            <Ban size={12} /> Suspend
                          </button>
                        ) : (
                          <button onClick={() => handleSuspend(u.id, false)}
                            className="text-xs px-3 py-2 rounded-lg flex items-center gap-1.5 bg-accent-green/10 text-accent-green border border-accent-green/30 hover:bg-accent-green/20 transition-colors">
                            <CheckCircle2 size={12} /> Unsuspend
                          </button>
                        )}
                        <button onClick={() => handleGrantMultiplier(u.id, 3)}
                          className="btn-ghost text-xs px-3 py-2 border border-surface-600 rounded-lg">
                          Grant 3×
                        </button>
                        <button onClick={() => handleGrantMultiplier(u.id, 4)}
                          className="btn-ghost text-xs px-3 py-2 border border-surface-600 rounded-lg">
                          Grant 4×
                        </button>
                        <button onClick={() => handleGrantMultiplier(u.id, 5)}
                          className="btn-ghost text-xs px-3 py-2 border border-surface-600 rounded-lg">
                          Grant 5×
                        </button>
                        <button onClick={() => handleResetStreak(u.id)}
                          className="btn-ghost text-xs px-3 py-2 border border-surface-600 rounded-lg text-orange-400 hover:text-orange-300">
                          Reset Streaks
                        </button>
                      </div>
                    </div>
                  )}
                </div>
              )
            })}

            {filtered.length === 0 && (
              <div className="card p-10 text-center">
                <Users size={28} className="mx-auto mb-3 text-gray-600" />
                <p className="text-gray-400">No users found</p>
              </div>
            )}
          </div>
        )}
      </div>

      {/* Wallet Adjust Modal */}
      {walletModal && (
        <div className="fixed inset-0 z-50 flex items-center justify-center p-4 bg-black/60 backdrop-blur-sm">
          <div className="card p-6 w-full max-w-md space-y-4 animate-in">
            <div className="flex items-center justify-between">
              <h2 className="font-semibold text-white">Adjust Wallet — {walletModal.name}</h2>
              <button onClick={() => setWalletModal(null)} className="text-gray-400 hover:text-white">
                <X size={18} />
              </button>
            </div>
            <div className="flex gap-2">
              {['credit', 'debit'].map(t => (
                <button key={t} onClick={() => setWalletForm(f => ({ ...f, type: t }))}
                  className={clsx('flex-1 py-2 rounded-lg text-sm font-semibold transition-all capitalize',
                    walletForm.type === t
                      ? t === 'credit' ? 'bg-accent-green/20 text-accent-green border border-accent-green/40'
                        : 'bg-accent-red/20 text-accent-red border border-accent-red/40'
                      : 'bg-surface-700 text-gray-400 border border-surface-600')}>
                  {t}
                </button>
              ))}
            </div>
            {/* League selector — leave blank for global wallet */}
            <div>
              <label className="text-xs text-gray-500 font-mono uppercase mb-1 block flex items-center gap-1">
                <Building2 size={11} /> League (optional — leave blank for global wallet)
              </label>
              <select
                className="input font-mono"
                value={walletForm.leagueId}
                onChange={e => setWalletForm(f => ({ ...f, leagueId: e.target.value }))}>
                <option value="">🌐 Global Wallet</option>
                {leagues.map(l => (
                  <option key={l.id} value={l.id}>{l.name}</option>
                ))}
              </select>
              {walletForm.leagueId && (
                <p className="text-xs text-brand-400 font-mono mt-1">
                  ✦ Adjusting league credits for selected league only
                </p>
              )}
            </div>
            <div>
              <label className="text-xs text-gray-500 font-mono uppercase mb-1 block">Amount (₹)</label>
              <input className="input font-mono" type="number" placeholder="0" min="1"
                value={walletForm.amount} onChange={e => setWalletForm(f => ({ ...f, amount: e.target.value }))} />
            </div>
            <div>
              <label className="text-xs text-gray-500 font-mono uppercase mb-1 block">Reason (required for audit log)</label>
              <input className="input" placeholder="e.g. Correction, bonus, prize…"
                value={walletForm.reason} onChange={e => setWalletForm(f => ({ ...f, reason: e.target.value }))} />
            </div>
            <div className="flex gap-3 pt-2">
              <button onClick={handleWalletAdjust} disabled={adjusting}
                className={clsx('flex-1 py-2.5 rounded-xl font-semibold text-sm transition-all',
                  walletForm.type === 'credit'
                    ? 'bg-accent-green/20 text-accent-green border border-accent-green/40 hover:bg-accent-green/30'
                    : 'bg-accent-red/20 text-accent-red border border-accent-red/40 hover:bg-accent-red/30')}>
                {adjusting ? 'Processing…' : `Confirm ${walletForm.type}`}
              </button>
              <button onClick={() => setWalletModal(null)} className="btn-ghost px-4 py-2.5 text-sm">Cancel</button>
            </div>
          </div>
        </div>
      )}

      {/* Suspend Modal */}
      {suspendModal && (
        <div className="fixed inset-0 z-50 flex items-center justify-center p-4 bg-black/60 backdrop-blur-sm">
          <div className="card p-6 w-full max-w-md space-y-4 animate-in">
            <div className="flex items-center gap-3">
              <AlertTriangle size={20} className="text-accent-red" />
              <h2 className="font-semibold text-white">Suspend User</h2>
            </div>
            <div>
              <label className="text-xs text-gray-500 font-mono uppercase mb-1 block">Suspension Reason</label>
              <input className="input" placeholder="Reason for suspension…"
                value={suspendReason} onChange={e => setSuspendReason(e.target.value)} />
            </div>
            <div className="flex gap-3">
              <button onClick={() => handleSuspend(suspendModal, true)}
                className="flex-1 py-2.5 rounded-xl font-semibold text-sm bg-accent-red/20 text-accent-red border border-accent-red/40 hover:bg-accent-red/30 transition-all">
                Confirm Suspend
              </button>
              <button onClick={() => { setSuspendModal(null); setSuspendReason('') }}
                className="btn-ghost px-4 py-2.5 text-sm">Cancel</button>
            </div>
          </div>
        </div>
      )}
    </div>
  )
}
import { useEffect, useState } from 'react'
import { useAuthStore } from '../../store/auth'
import Navbar from '../../components/shared/Navbar'
import { supabase } from '../../lib/supabase'
import {
  AlertTriangle, CheckCircle2, Eye, RefreshCw, Shield,
  ArrowRight, Users, Zap, Filter
} from 'lucide-react'
import { formatDistanceToNow, format } from 'date-fns'
import toast from 'react-hot-toast'
import clsx from 'clsx'

const FLAG_META = {
  circular_transfer:    { label: 'Circular Transfer',     color: 'text-accent-red',    bg: 'bg-red-500/10',    border: 'border-red-500/30' },
  rapid_farming:        { label: 'Rapid Farming',         color: 'text-orange-400',    bg: 'bg-orange-500/10', border: 'border-orange-500/30' },
  multi_account_device: { label: 'Multi-Account Device',  color: 'text-purple-400',    bg: 'bg-purple-500/10', border: 'border-purple-500/30' },
  abnormal_spike:       { label: 'Abnormal Spike',        color: 'text-yellow-400',    bg: 'bg-yellow-500/10', border: 'border-yellow-500/30' },
  smurf_detection:      { label: 'Smurf Detection',       color: 'text-blue-400',      bg: 'bg-blue-500/10',   border: 'border-blue-500/30' },
  exploit_attempt:      { label: 'Exploit Attempt',       color: 'text-accent-red',    bg: 'bg-red-500/10',    border: 'border-red-500/30' },
}

export default function AdminFraud() {
  const { user: adminUser } = useAuthStore()
  const [flags, setFlags]       = useState([])
  const [loading, setLoading]   = useState(true)
  const [filter, setFilter]     = useState('unreviewed') // 'all' | 'unreviewed' | 'reviewed'
  const [reviewing, setReviewing] = useState(null)
  const [reviewNote, setReviewNote] = useState('')
  const [auditLog, setAuditLog] = useState([])

  useEffect(() => { loadAll() }, [filter])

  const loadAll = async () => {
    setLoading(true)
    try {
      let query = supabase
        .from('fraud_flags')
        .select('*, users!fraud_flags_user_id_fkey(display_name, email, fraud_score, is_suspended)')
        .order('created_at', { ascending: false })

      if (filter === 'unreviewed') query = query.eq('reviewed', false)
      if (filter === 'reviewed')   query = query.eq('reviewed', true)

      const { data, error } = await query
      if (error) throw error
      setFlags(data || [])

      const { data: logs } = await supabase
        .from('admin_logs')
        .select('*, users(display_name)')
        .eq('action', 'review_fraud_flag')
        .order('created_at', { ascending: false })
        .limit(10)
      setAuditLog(logs || [])
    } catch (e) { toast.error('Failed to load fraud flags') }
    finally { setLoading(false) }
  }

  const handleReview = async (flagId, action) => {
    setReviewing(flagId)
    try {
      const { error } = await supabase.from('fraud_flags').update({
        reviewed: true,
        reviewed_by: adminUser.id,
        reviewed_at: new Date().toISOString(),
        action_taken: action + (reviewNote ? `: ${reviewNote}` : ''),
      }).eq('id', flagId)
      if (error) throw error

      await supabase.from('admin_logs').insert({
        admin_id: adminUser.id,
        action: 'review_fraud_flag',
        target_type: 'fraud_flag', target_id: flagId,
        new_value: { action, note: reviewNote },
      })

      toast.success(`Flag marked as ${action}`)
      setReviewNote('')
      loadAll()
    } catch (e) { toast.error(e.message) }
    finally { setReviewing(null) }
  }

  const handleAutoSuspend = async (userId, flagId) => {
    try {
      await supabase.from('users').update({
        is_suspended: true,
        suspend_reason: 'Admin action: fraud review',
      }).eq('id', userId)

      await supabase.from('admin_logs').insert({
        admin_id: adminUser.id, action: 'suspend_user',
        target_type: 'user', target_id: userId,
        new_value: { reason: 'Fraud flag review', flag_id: flagId },
      })

      await handleReview(flagId, 'suspended')
      toast.success('User suspended')
    } catch (e) { toast.error(e.message) }
  }

  const handleClearFraudScore = async (userId) => {
    try {
      await supabase.from('users').update({ fraud_score: 0 }).eq('id', userId)
      await supabase.from('admin_logs').insert({
        admin_id: adminUser.id, action: 'clear_fraud_score',
        target_type: 'user', target_id: userId,
      })
      toast.success('Fraud score cleared')
      loadAll()
    } catch (e) { toast.error(e.message) }
  }

  const unreviewedCount = flags.filter(f => !f.reviewed).length

  return (
    <div className="min-h-screen bg-surface-900">
      <Navbar />
      <div className="max-w-5xl mx-auto px-4 sm:px-6 py-8 space-y-6">

        <div className="flex items-center justify-between">
          <div>
            <h1 className="font-display text-4xl text-white tracking-wide flex items-center gap-3">
              Fraud Review
              {unreviewedCount > 0 && filter !== 'reviewed' && (
                <span className="text-lg bg-accent-red/20 text-accent-red border border-accent-red/40 px-3 py-0.5 rounded-full font-mono">
                  {unreviewedCount} pending
                </span>
              )}
            </h1>
            <p className="text-gray-500 text-sm mt-1 font-mono">Suspicious activity flags</p>
          </div>
          <button onClick={loadAll} className="btn-secondary flex items-center gap-2 px-4 py-2 text-sm">
            <RefreshCw size={14} /> Refresh
          </button>
        </div>

        {/* Filter tabs */}
        <div className="flex gap-1 bg-surface-800 rounded-xl p-1 w-fit">
          {['unreviewed', 'reviewed', 'all'].map(f => (
            <button key={f} onClick={() => setFilter(f)}
              className={clsx('px-4 py-2 rounded-lg text-sm font-semibold transition-all capitalize',
                filter === f ? 'bg-brand-500 text-white' : 'text-gray-400 hover:text-white')}>
              {f}
            </button>
          ))}
        </div>

        {/* Flags list */}
        {loading ? (
          <div className="space-y-3">
            {[...Array(3)].map((_, i) => <div key={i} className="card p-5 h-28 animate-pulse bg-surface-700" />)}
          </div>
        ) : flags.length === 0 ? (
          <div className="card p-12 text-center">
            <Shield size={32} className="mx-auto mb-3 text-gray-600" />
            <p className="text-gray-400 font-semibold">No {filter !== 'all' ? filter : ''} flags</p>
            <p className="text-gray-600 text-sm mt-1">All clear 🎉</p>
          </div>
        ) : (
          <div className="space-y-3">
            {flags.map(flag => {
              const meta = FLAG_META[flag.flag_type] || FLAG_META.exploit_attempt
              const u    = flag.users

              return (
                <div key={flag.id} className={clsx('card overflow-hidden border', meta.border, !flag.reviewed && 'shadow-glow-red')}>
                  <div className={clsx('px-5 py-4', meta.bg)}>
                    <div className="flex items-start justify-between gap-4">
                      <div className="flex items-start gap-3">
                        <AlertTriangle size={16} className={clsx(meta.color, 'mt-0.5 shrink-0')} />
                        <div>
                          <div className="flex items-center gap-2 flex-wrap">
                            <span className={clsx('font-semibold text-sm', meta.color)}>{meta.label}</span>
                            {flag.reviewed && (
                              <span className="badge badge-green text-[10px]">Reviewed</span>
                            )}
                          </div>
                          <div className="text-sm text-white font-semibold mt-1">
                            {u?.display_name ?? 'Unknown'}
                            <span className="text-gray-400 font-normal ml-2 text-xs">{u?.email}</span>
                          </div>
                          <div className="flex items-center gap-3 mt-1 flex-wrap">
                            {u?.fraud_score > 0 && (
                              <span className={clsx('text-xs font-mono',
                                u.fraud_score >= 80 ? 'text-accent-red' :
                                u.fraud_score >= 40 ? 'text-orange-400' : 'text-gray-400')}>
                                Fraud score: {u.fraud_score}
                              </span>
                            )}
                            {u?.is_suspended && <span className="badge badge-red text-[10px]">Suspended</span>}
                            <span className="text-xs text-gray-500 font-mono">
                              {formatDistanceToNow(new Date(flag.created_at), { addSuffix: true })}
                            </span>
                          </div>
                        </div>
                      </div>

                      {!flag.reviewed && (
                        <div className="flex items-center gap-2 shrink-0">
                          <span className="w-2 h-2 bg-accent-red rounded-full animate-pulse" />
                          <span className="text-xs font-mono text-accent-red">ACTION REQUIRED</span>
                        </div>
                      )}
                    </div>

                    {/* Details */}
                    {flag.details && (
                      <div className="mt-3 bg-surface-900/50 rounded-lg p-3 font-mono text-xs text-gray-400 overflow-x-auto">
                        {JSON.stringify(flag.details, null, 2)}
                      </div>
                    )}

                    {/* Action taken */}
                    {flag.action_taken && (
                      <div className="mt-2 flex items-center gap-1.5 text-xs text-accent-green font-mono">
                        <CheckCircle2 size={11} /> {flag.action_taken}
                      </div>
                    )}
                  </div>

                  {/* Actions */}
                  {!flag.reviewed && (
                    <div className="px-5 py-3 border-t border-surface-700 bg-surface-800/50 flex flex-wrap gap-2 items-center">
                      <input className="input flex-1 min-w-[200px] text-sm py-2"
                        placeholder="Review note (optional)"
                        value={reviewing === flag.id ? reviewNote : ''}
                        onChange={e => { if (reviewing !== flag.id) setReviewing(flag.id); setReviewNote(e.target.value) }}
                      />
                      <button onClick={() => handleReview(flag.id, 'dismissed')}
                        disabled={reviewing === flag.id && !reviewNote && reviewing !== flag.id}
                        className="btn-ghost text-xs px-3 py-2 border border-surface-600 rounded-lg flex items-center gap-1">
                        <CheckCircle2 size={12} className="text-accent-green" /> Dismiss
                      </button>
                      <button onClick={() => handleClearFraudScore(flag.user_id)}
                        className="btn-ghost text-xs px-3 py-2 border border-surface-600 rounded-lg flex items-center gap-1">
                        <Zap size={12} className="text-blue-400" /> Clear Score
                      </button>
                      {!u?.is_suspended && (
                        <button onClick={() => handleAutoSuspend(flag.user_id, flag.id)}
                          className="text-xs px-3 py-2 rounded-lg flex items-center gap-1.5 bg-accent-red/10 text-accent-red border border-accent-red/30 hover:bg-accent-red/20 transition-colors">
                          <AlertTriangle size={12} /> Suspend User
                        </button>
                      )}
                    </div>
                  )}
                </div>
              )
            })}
          </div>
        )}

        {/* Recent review actions */}
        {auditLog.length > 0 && (
          <div className="card p-6">
            <h2 className="font-semibold text-white mb-4">Recent Review Actions</h2>
            <div className="space-y-2">
              {auditLog.map(log => (
                <div key={log.id} className="flex items-start gap-3 py-2 border-b border-surface-700 last:border-0">
                  <CheckCircle2 size={14} className="text-accent-green mt-0.5 shrink-0" />
                  <div>
                    <div className="text-sm text-white">
                      {log.new_value?.action}
                      {log.new_value?.note && <span className="text-gray-400"> — {log.new_value.note}</span>}
                    </div>
                    <div className="text-xs text-gray-500 font-mono mt-0.5">
                      by {log.users?.display_name ?? 'Admin'} · {format(new Date(log.created_at), 'MMM d · h:mm a')}
                    </div>
                  </div>
                </div>
              ))}
            </div>
          </div>
        )}
      </div>
    </div>
  )
}

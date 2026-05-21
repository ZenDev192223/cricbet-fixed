import { useEffect, useState } from 'react'
import { useAuthStore } from '../../store/auth'
import Navbar from '../../components/shared/Navbar'
import { getSystemConfig, updateSystemConfig } from '../../lib/api'
import { supabase } from '../../lib/supabase'
import { Settings, Save, RefreshCw, ChevronRight, AlertTriangle } from 'lucide-react'
import { format } from 'date-fns'
import toast from 'react-hot-toast'
import clsx from 'clsx'

const SECTIONS = [
  {
    title: 'Bet Limits',
    icon: '🎯',
    fields: [
      { key: 'max_bet_pct',    label: 'Max Bet (% of wallet)', type: 'number', unit: '%', min: 5, max: 100, hint: 'Max % of available balance a user can bet. Spec: 20–30%' },
      { key: 'min_wallet_3x',  label: 'Min Wallet for 3×', type: 'number', unit: '₹', hint: 'Minimum balance required to place 3× bets' },
      { key: 'min_wallet_4x',  label: 'Min Wallet for 4×', type: 'number', unit: '₹', hint: 'Minimum balance required to place 4× bets' },
      { key: 'min_wallet_5x',  label: 'Min Wallet for 5×', type: 'number', unit: '₹', hint: 'Minimum balance required to place 5× bets' },
      { key: 'max_active_4x_bets', label: 'Max Active 4× Bets', type: 'number', hint: 'Max simultaneous pending 4× bets per user' },
      { key: 'max_active_5x_bets', label: 'Max Active 5× Bets', type: 'number', hint: 'Max simultaneous pending 5× bets per user' },
    ],
  },
  {
    title: 'Penalty Rates',
    icon: '⚠️',
    fields: [
      { key: 'penalty_2x', label: '2× Loss Penalty', type: 'number', unit: '%', hint: 'Extra % deducted on top of bet amount when a 2× bet is lost' },
      { key: 'penalty_3x', label: '3× Loss Penalty', type: 'number', unit: '%', hint: 'Extra % deducted on top of bet amount when a 3× bet is lost' },
      { key: 'penalty_4x', label: '4× Loss Penalty', type: 'number', unit: '%', hint: 'Extra % deducted on top of bet amount when a 4× bet is lost' },
      { key: 'penalty_5x', label: '5× Loss Penalty', type: 'number', unit: '%', hint: 'Extra % deducted on top of bet amount when a 5× bet is lost' },
    ],
  },
  {
    title: 'Cooldowns',
    icon: '⏱️',
    fields: [
      { key: 'cooldown_4x_matches', label: '4× Cooldown (matches)', type: 'number', hint: 'Number of matches 4× is locked after use' },
      { key: 'cooldown_5x_matches', label: '5× Cooldown (matches)', type: 'number', hint: 'Number of matches 5× is locked after use' },
    ],
  },
  {
    title: 'Streak Unlock Thresholds',
    icon: '🔥',
    fields: [
      { key: 'streak_unlock_3x', label: 'Unlock 3× Thresholds (JSON)', type: 'json', hint: 'e.g. {"1.5":3,"2":2} — consecutive wins needed per multiplier' },
      { key: 'streak_unlock_4x', label: 'Unlock 4× Thresholds (JSON)', type: 'json', hint: 'e.g. {"1.5":5,"2":3,"3":2}' },
      { key: 'streak_unlock_5x', label: 'Unlock 5× Thresholds (JSON)', type: 'json', hint: 'e.g. {"1.5":7,"2":5,"3":3,"4":1}' },
    ],
  },
  {
    title: 'Donation Rules',
    icon: '💸',
    fields: [
      { key: 'donation_weekly_cap',   label: 'Weekly Receive Cap', type: 'number', unit: '₹', hint: 'Max ₹ a user can receive via donations per week' },
      { key: 'donation_daily_max',    label: 'Max Donations per Day', type: 'number', hint: 'Max number of outgoing donations per user per day' },
      { key: 'donation_daily_amount', label: 'Max Donation Amount per Day', type: 'number', unit: '₹', hint: 'Total ₹ a user can send in donations per day' },
      { key: 'donation_cooldown_min', label: 'Cooldown Between Donations', type: 'number', unit: 'min', hint: 'Minutes a user must wait between donations' },
      { key: 'min_account_age_days',  label: 'Min Account Age to Donate', type: 'number', unit: 'days', hint: 'Account must be this many days old to send donations' },
      { key: 'min_completed_bets',    label: 'Min Bets to Donate', type: 'number', hint: 'User must have completed this many bets to send donations' },
    ],
  },
  {
    title: 'Inactivity & Decay',
    icon: '📉',
    fields: [
      {
        key:   'inactivity_matches',
        label: 'Inactivity Threshold',
        type:  'number',
        unit:  'matches',
        min:   1,
        hint:  'Settled matches without a bet (per league) before decay fires. e.g. 3 = miss 3 matches in a row → penalised',
      },
      {
        key:   'wallet_decay_pct',
        label: 'Wallet Decay per Trigger',
        type:  'number',
        unit:  '%',
        min:   0,
        max:   100,
        hint:  '% of league credits deducted each time apply_inactivity runs for an inactive member. Spec: max 2–3%',
      },
    ],
  },
]

export default function AdminConfig() {
  const { user: adminUser } = useAuthStore()
  const [config, setConfig]     = useState({})
  const [edited, setEdited]     = useState({})
  const [loading, setLoading]   = useState(true)
  const [saving, setSaving]     = useState({})
  const [auditLog, setAuditLog] = useState([])

  useEffect(() => { loadAll() }, [])

  const loadAll = async () => {
    setLoading(true)
    try {
      const [cfg, { data: logs }] = await Promise.all([
        getSystemConfig(),
        supabase.from('admin_logs')
          .select('*, users(display_name)')
          .eq('target_type', 'system_config')
          .order('created_at', { ascending: false })
          .limit(20),
      ])
      setConfig(cfg)
      setAuditLog(logs || [])
    } catch (e) { toast.error('Failed to load config') }
    finally { setLoading(false) }
  }

  const getValue = (key) => {
    if (key in edited) return edited[key]
    const v = config[key]
    if (typeof v === 'object' && v !== null) return JSON.stringify(v)
    return v ?? ''
  }

  const handleSave = async (key, type) => {
    let val = edited[key] ?? config[key]
    if (type === 'json') {
      try { val = JSON.parse(val) } catch { return toast.error('Invalid JSON') }
    } else {
      val = parseFloat(val)
      if (isNaN(val)) return toast.error('Invalid number')
    }
    setSaving(s => ({ ...s, [key]: true }))
    try {
      await updateSystemConfig(key, val)
      toast.success(`${key} saved`)
      setEdited(e => { const n = { ...e }; delete n[key]; return n })
      loadAll()
    } catch (e) { toast.error(e.message) }
    finally { setSaving(s => ({ ...s, [key]: false })) }
  }

  const isDirty = (key) => key in edited && edited[key] !== String(config[key])

  return (
    <div className="min-h-screen bg-surface-900">
      <Navbar />
      <div className="max-w-4xl mx-auto px-4 sm:px-6 py-8 space-y-8">

        <div className="flex items-center justify-between">
          <div>
            <h1 className="font-display text-4xl text-white tracking-wide">System Config</h1>
            <p className="text-gray-500 text-sm mt-1 font-mono">All changes are audit-logged</p>
          </div>
          <button onClick={loadAll} className="btn-secondary flex items-center gap-2 px-4 py-2 text-sm">
            <RefreshCw size={14} /> Reload
          </button>
        </div>

        {loading ? (
          <div className="space-y-4">
            {[...Array(4)].map((_, i) => <div key={i} className="card p-6 h-40 animate-pulse bg-surface-700" />)}
          </div>
        ) : (
          SECTIONS.map(section => (
            <div key={section.title} className="card p-6 space-y-5">
              <h2 className="font-semibold text-white flex items-center gap-2 text-lg">
                <span>{section.icon}</span> {section.title}
              </h2>
              <div className="space-y-4">
                {section.fields.map(({ key, label, type, unit, hint, min, max }) => (
                  <div key={key}>
                    <div className="flex items-center justify-between mb-1">
                      <label className="text-sm font-medium text-gray-300">{label}</label>
                      {isDirty(key) && (
                        <span className="text-xs text-orange-400 font-mono">● unsaved</span>
                      )}
                    </div>
                    {hint && <p className="text-xs text-gray-600 font-mono mb-2">{hint}</p>}
                    <div className="flex gap-2">
                      {type === 'json' ? (
                        <textarea
                          className="input flex-1 font-mono text-xs h-20 resize-none"
                          value={getValue(key)}
                          onChange={e => setEdited(ed => ({ ...ed, [key]: e.target.value }))}
                        />
                      ) : (
                        <div className="relative flex-1">
                          <input
                            className="input pr-12 font-mono"
                            type="number" min={min} max={max}
                            value={getValue(key)}
                            onChange={e => setEdited(ed => ({ ...ed, [key]: e.target.value }))}
                          />
                          {unit && (
                            <span className="absolute right-3 top-1/2 -translate-y-1/2 text-xs text-gray-500 font-mono">{unit}</span>
                          )}
                        </div>
                      )}
                      <button
                        onClick={() => handleSave(key, type)}
                        disabled={saving[key]}
                        className={clsx(
                          'px-4 py-3 rounded-xl text-sm font-semibold transition-all flex items-center gap-1.5 shrink-0',
                          isDirty(key)
                            ? 'bg-brand-500 text-white hover:bg-brand-400 shadow-glow-orange'
                            : 'bg-surface-700 text-gray-400 hover:bg-surface-600'
                        )}>
                        {saving[key] ? <RefreshCw size={14} className="animate-spin" /> : <Save size={14} />}
                        {saving[key] ? '' : 'Save'}
                      </button>
                    </div>
                  </div>
                ))}
              </div>
            </div>
          ))
        )}

        {/* Audit log */}
        {auditLog.length > 0 && (
          <div className="card p-6">
            <h2 className="font-semibold text-white mb-4">Config Change Log</h2>
            <div className="space-y-2">
              {auditLog.map(log => (
                <div key={log.id} className="flex items-start gap-3 py-2 border-b border-surface-700 last:border-0">
                  <ChevronRight size={14} className="text-brand-500 mt-0.5 shrink-0" />
                  <div className="flex-1 min-w-0">
                    <div className="text-sm text-white font-mono">
                      {log.new_value?.key}
                      <span className="text-gray-500"> = </span>
                      <span className="text-accent-green">{JSON.stringify(log.new_value?.value)}</span>
                    </div>
                    <div className="text-xs text-gray-500 mt-0.5">
                      by {log.users?.display_name ?? 'Admin'} · {format(new Date(log.created_at), 'MMM d, yyyy · h:mm a')}
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
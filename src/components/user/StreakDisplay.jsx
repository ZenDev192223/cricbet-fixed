import { Flame } from 'lucide-react'
import clsx from 'clsx'

// Goals: which streak on which multiplier unlocks what
const STREAK_GOALS = {
  '1.5': [{ at: 3, label: '→ 3×' }, { at: 5, label: '→ 4×' }, { at: 7, label: '→ 5×' }],
  '2':   [{ at: 2, label: '→ 3×' }, { at: 3, label: '→ 4×' }, { at: 5, label: '→ 5×' }],
  '3':   [{ at: 2, label: '→ 4×' }, { at: 3, label: '→ 5×' }],
  '4':   [{ at: 1, label: '→ 5×' }],
}

const TIER_STYLES = {
  '1.5': { color: 'text-brand-400', border: 'border-brand-500/30', bg: 'bg-brand-500/10', fill: 'bg-brand-500' },
  '2':   { color: 'text-blue-400',  border: 'border-blue-500/30',  bg: 'bg-blue-500/10',  fill: 'bg-blue-500'  },
  '3':   { color: 'text-accent-gold', border: 'border-yellow-500/30', bg: 'bg-yellow-500/10', fill: 'bg-yellow-500' },
  '4':   { color: 'text-purple-400', border: 'border-purple-500/30', bg: 'bg-purple-500/10', fill: 'bg-purple-500' },
}

export default function StreakDisplay({ streaks = {} }) {
  // streaks is an object: { "1.5": 3, "2": 0, ... }
  const entries = Object.entries(streaks).filter(([, v]) => Number(v) > 0)

  if (!entries.length) return (
    <div className="card p-5">
      <div className="flex items-center gap-2 text-xs text-gray-500 font-mono uppercase tracking-widest mb-4">
        <Flame size={12} /> Win Streaks
      </div>
      <div className="text-center py-6">
        <Flame size={28} className="mx-auto mb-2 text-gray-600" />
        <p className="text-gray-500 text-sm">Win consecutive bets with the same multiplier to build streaks and unlock higher tiers</p>
      </div>
    </div>
  )

  return (
    <div className="card p-5">
      <div className="flex items-center gap-2 text-xs text-gray-500 font-mono uppercase tracking-widest mb-4">
        <Flame size={12} /> Win Streaks
      </div>
      <div className="space-y-3">
        {entries.map(([tier, count]) => {
          const s = TIER_STYLES[tier] || TIER_STYLES['1.5']
          const goals = STREAK_GOALS[tier] || []
          const maxGoal = goals[goals.length - 1]?.at || 1
          const pct = Math.min((Number(count) / maxGoal) * 100, 100)

          return (
            <div key={tier} className={clsx('p-3 rounded-xl border', s.border, s.bg)}>
              <div className="flex items-center justify-between mb-2">
                <div className="flex items-center gap-2">
                  <Flame size={14} className={s.color} />
                  <span className={clsx('text-sm font-mono font-semibold', s.color)}>{tier}× streak</span>
                </div>
                <div className={clsx('text-3xl font-display font-bold', s.color)}>{count}</div>
              </div>
              <div className="h-1.5 bg-surface-700 rounded-full overflow-hidden mb-2">
                <div className={clsx('h-full rounded-full transition-all duration-700', s.fill)}
                  style={{ width: `${pct}%` }} />
              </div>
              <div className="flex gap-2 flex-wrap">
                {goals.map(g => (
                  <span key={g.at} className={clsx(
                    'text-xs font-mono px-2 py-0.5 rounded-full border',
                    Number(count) >= g.at
                      ? 'bg-accent-green/20 text-accent-green border-accent-green/30'
                      : 'bg-surface-700 text-gray-500 border-surface-600'
                  )}>
                    {g.at}W {g.label}
                  </span>
                ))}
              </div>
            </div>
          )
        })}
      </div>
    </div>
  )
}

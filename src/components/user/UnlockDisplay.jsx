import { Star, Crown, Flame, CheckCircle2, Lock } from 'lucide-react'
import clsx from 'clsx'
import { formatDistanceToNow } from 'date-fns'

const META = {
  '3': { icon: Flame,  label: '3× Multiplier', color: 'text-accent-gold', border: 'border-yellow-500/30', bg: 'bg-yellow-500/10', penalty: 50  },
  '4': { icon: Star,   label: '4× Multiplier', color: 'text-purple-400',  border: 'border-purple-500/30', bg: 'bg-purple-500/10', penalty: 65  },
  '5': { icon: Crown,  label: '5× Multiplier', color: 'text-accent-red',  border: 'border-red-500/30',    bg: 'bg-red-500/10',    penalty: 80  },
}

export default function UnlockDisplay({ unlocks = [] }) {
  const active = unlocks.filter(u => !u.is_consumed)
  if (!active.length) return null

  return (
    <div className="card p-5">
      <div className="flex items-center gap-2 text-xs text-gray-500 font-mono uppercase tracking-widest mb-4">
        <Star size={12} /> Unlocked Multipliers
      </div>
      <div className="space-y-2">
        {active.map(u => {
          const meta = META[u.multiplier] || META['3']
          const Icon = meta.icon
          return (
            <div key={u.multiplier}
              className={clsx('flex items-center justify-between p-3 rounded-xl border', meta.border, meta.bg)}>
              <div className="flex items-center gap-3">
                <div className={clsx('w-9 h-9 rounded-lg flex items-center justify-center border', meta.border, meta.bg)}>
                  <Icon size={16} className={meta.color} />
                </div>
                <div>
                  <div className={clsx('font-mono font-semibold text-sm', meta.color)}>{meta.label}</div>
                  <div className="text-xs text-gray-500">
                    {meta.penalty}% penalty on loss ·{' '}
                    {u.unlocked_at && formatDistanceToNow(new Date(u.unlocked_at), { addSuffix: true })}
                  </div>
                  {u.unlock_source && (
                    <div className="text-xs text-gray-600 font-mono mt-0.5">{u.unlock_source}</div>
                  )}
                </div>
              </div>
              <div className="flex items-center gap-1.5 text-accent-green">
                <CheckCircle2 size={14} />
                <span className="text-xs font-mono font-semibold">Ready</span>
              </div>
            </div>
          )
        })}
      </div>
      <p className="text-xs text-gray-600 mt-3 font-mono">
        Consumable — used after any settlement (win or loss)
      </p>
    </div>
  )
}

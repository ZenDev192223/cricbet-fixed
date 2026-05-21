import clsx from 'clsx'
import { Lock, Flame, Star, Crown } from 'lucide-react'

const META = {
  1.5: { label: '1.5×', icon: null,   selectedCls: 'border-brand-500 bg-brand-500/15 text-white shadow-glow-orange', penalty: 0    },
  2:   { label: '2×',   icon: null,   selectedCls: 'border-blue-500 bg-blue-500/15 text-blue-300',                    penalty: 30   },
  3:   { label: '3×',   icon: Flame,  selectedCls: 'border-accent-gold bg-yellow-500/15 text-accent-gold shadow-glow-gold', penalty: 50 },
  4:   { label: '4×',   icon: Star,   selectedCls: 'border-purple-500 bg-purple-500/15 text-purple-300',               penalty: 65   },
  5:   { label: '5×',   icon: Crown,  selectedCls: 'border-accent-red bg-red-500/15 text-red-300 shadow-glow-red',     penalty: 80   },
}

export default function MultiplierChip({ multiplier, selected, onClick, locked, cooldown, notUnlocked }) {
  const meta   = META[multiplier] || META[1.5]
  const Icon   = meta.icon
  const isLocked = locked || cooldown > 0 || notUnlocked
  const reason = notUnlocked ? 'Not yet unlocked'
    : cooldown > 0 ? `Cooldown: ${cooldown} match${cooldown > 1 ? 'es' : ''} remaining`
    : locked ? 'Unavailable' : ''

  return (
    <button
      onClick={() => !isLocked && onClick?.(multiplier)}
      disabled={isLocked}
      title={reason}
      className={clsx(
        'relative flex flex-col items-center justify-center px-4 py-3 rounded-xl border-2 transition-all duration-200 min-w-[72px] select-none',
        selected && !isLocked
          ? meta.selectedCls
          : 'border-surface-500 bg-surface-700 text-gray-300',
        isLocked
          ? 'opacity-40 cursor-not-allowed'
          : 'hover:border-surface-400 hover:bg-surface-600 cursor-pointer active:scale-95',
      )}>
      {Icon && <Icon size={12} className="mb-0.5 opacity-70" />}
      <span className="text-lg font-mono font-bold leading-none">{meta.label}</span>
      {meta.penalty > 0 && (
        <span className="text-[9px] font-mono mt-0.5 opacity-60">-{meta.penalty}% loss</span>
      )}
      {!isLocked && !selected && meta.penalty === 0 && (
        <span className="text-[9px] font-mono mt-0.5 opacity-60">no penalty</span>
      )}
      {isLocked && <Lock size={9} className="absolute top-1 right-1 opacity-50" />}
      {cooldown > 0 && (
        <div className="absolute -top-2 -right-2 w-5 h-5 bg-accent-red rounded-full flex items-center justify-center">
          <span className="text-[9px] font-mono font-bold text-white">{cooldown}</span>
        </div>
      )}
    </button>
  )
}

export { META as MULTIPLIER_META }

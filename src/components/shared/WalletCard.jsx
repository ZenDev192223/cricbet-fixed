import { Lock, Coins, TrendingUp } from 'lucide-react'
import { formatCurrency } from '../../lib/constants'

/**
 * LeagueWalletCard — shows credits for a single league.
 * Props: credits (number), lockedCredits (number), leagueName (string)
 */
export default function LeagueWalletCard({ credits = 0, lockedCredits = 0, leagueName }) {
  const avail  = parseFloat(credits ?? 0)
  const locked = parseFloat(lockedCredits ?? 0)
  const total  = avail + locked
  const lockedPct = total > 0 ? (locked / total) * 100 : 0

  return (
    <div className="card p-5 relative overflow-hidden">
      <div className="absolute top-0 right-0 w-40 h-40 bg-brand-500/5 rounded-full -translate-y-1/2 translate-x-1/2 pointer-events-none" />
      <div className="absolute bottom-0 left-0 w-24 h-24 bg-accent-green/5 rounded-full translate-y-1/2 -translate-x-1/2 pointer-events-none" />

      <div className="relative">
        <div className="flex items-center gap-2 text-xs text-gray-500 font-mono uppercase tracking-widest mb-1">
          <Coins size={12} /> League Balance
        </div>
        {leagueName && (
          <div className="text-xs text-brand-400 font-mono mb-3 truncate">{leagueName}</div>
        )}

        <div className="grid grid-cols-2 gap-4 mb-4">
          <div>
            <div className="text-4xl font-display font-bold text-white mb-1 text-glow-orange">
              {formatCurrency(avail)}
            </div>
            <div className="text-xs text-gray-500 font-mono">Available Credits</div>
          </div>
          {locked > 0 && (
            <div className="text-right">
              <div className="flex items-center justify-end gap-1.5 mb-1">
                <Lock size={12} className="text-accent-red" />
                <span className="text-2xl font-display font-semibold text-accent-red">
                  {formatCurrency(locked)}
                </span>
              </div>
              <div className="text-xs text-gray-500 font-mono">Locked in Bets</div>
            </div>
          )}
        </div>

        {locked > 0 && (
          <div>
            <div className="flex justify-between text-xs text-gray-500 mb-1.5">
              <span className="text-accent-green">Available {(100 - lockedPct).toFixed(0)}%</span>
              <span className="text-accent-red">Locked {lockedPct.toFixed(0)}%</span>
            </div>
            <div className="h-2 bg-surface-700 rounded-full overflow-hidden flex">
              <div className="h-full bg-accent-green/70 transition-all duration-700 rounded-l-full"
                style={{ width: `${100 - lockedPct}%` }} />
              <div className="h-full bg-accent-red/70 transition-all duration-700 rounded-r-full"
                style={{ width: `${lockedPct}%` }} />
            </div>
          </div>
        )}
        {locked === 0 && (
          <div className="flex items-center gap-1.5 text-xs text-accent-green mt-2">
            <TrendingUp size={12} /> All credits available
          </div>
        )}
      </div>
    </div>
  )
}

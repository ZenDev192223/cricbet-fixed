import { useEffect } from 'react'
import { useAuthStore } from '../../store/auth'
import { useDashboardStore } from '../../store/dashboard'
import Navbar from '../../components/shared/Navbar'
import { formatCurrency } from '../../lib/constants'
import { TrendingUp, TrendingDown, Lock, Unlock, Gift, ArrowRight, Shield, AlertCircle } from 'lucide-react'
import { format } from 'date-fns'
import clsx from 'clsx'

const TX_META = {
  bet_lock:           { icon: Lock,        color: 'text-accent-red',    label: 'Bet Locked',      sign: '-' },
  bet_win:            { icon: TrendingUp,   color: 'text-accent-green',  label: 'Bet Won',         sign: '+' },
  bet_loss:           { icon: TrendingDown, color: 'text-accent-red',    label: 'Bet Lost',        sign: '-' },
  refund:             { icon: Unlock,       color: 'text-blue-400',      label: 'Refunded',        sign: '+' },
  donation_sent:      { icon: ArrowRight,   color: 'text-accent-red',    label: 'Sent',            sign: '-' },
  donation_received:  { icon: Gift,         color: 'text-accent-green',  label: 'Received',        sign: '+' },
  admin_credit:       { icon: Shield,       color: 'text-accent-green',  label: 'Admin Credit',    sign: '+' },
  admin_debit:        { icon: Shield,       color: 'text-accent-red',    label: 'Admin Debit',     sign: '-' },
  wallet_decay:       { icon: AlertCircle,  color: 'text-orange-400',    label: 'Inactivity Decay', sign: '-' },
  bonus_credit:       { icon: Gift,         color: 'text-accent-gold',   label: 'Bonus',           sign: '+' },
}

export default function TransactionsPage() {
  const { user } = useAuthStore()
  const { transactions, loadTransactions } = useDashboardStore()

  useEffect(() => { if (user?.id) loadTransactions(user.id) }, [user?.id])

  return (
    <div className="min-h-screen bg-surface-900">
      <Navbar />
      <div className="max-w-3xl mx-auto px-4 sm:px-6 py-8 space-y-6">
        <div>
          <h1 className="font-display text-4xl text-white tracking-wide">Transaction History</h1>
          <p className="text-gray-500 text-sm mt-1 font-mono">Complete immutable ledger of all wallet activity</p>
        </div>

        {transactions.length === 0 ? (
          <div className="card p-12 text-center">
            <TrendingUp size={28} className="mx-auto mb-3 text-gray-600" />
            <p className="text-gray-400">No transactions yet</p>
          </div>
        ) : (
          <div className="card overflow-hidden">
            {transactions.map(tx => {
              const meta  = TX_META[tx.type] || { icon: TrendingUp, color: 'text-gray-400', label: tx.type, sign: '' }
              const Icon  = meta.icon
              const isPos = meta.sign === '+'
              return (
                <div key={tx.id} className="flex items-center justify-between px-5 py-4 border-b border-surface-700 last:border-0 hover:bg-surface-700/30 transition-colors">
                  <div className="flex items-center gap-3">
                    <div className={clsx('w-9 h-9 rounded-xl flex items-center justify-center',
                      isPos ? 'bg-accent-green/10' : 'bg-accent-red/10')}>
                      <Icon size={15} className={meta.color} />
                    </div>
                    <div>
                      <div className="text-sm font-semibold text-white">{meta.label}</div>
                      {tx.note && <div className="text-xs text-gray-500 mt-0.5 max-w-xs truncate">{tx.note}</div>}
                      <div className="text-xs text-gray-600 font-mono mt-0.5">
                        {format(new Date(tx.created_at), 'MMM d, yyyy · h:mm a')}
                      </div>
                    </div>
                  </div>
                  <div className="text-right">
                    <div className={clsx('font-mono font-bold', isPos ? 'text-accent-green' : 'text-accent-red')}>
                      {meta.sign}{formatCurrency(tx.amount)}
                    </div>
                    <div className="text-xs text-gray-600 font-mono mt-0.5">
                      → {formatCurrency(tx.balance_after)}
                    </div>
                  </div>
                </div>
              )
            })}
          </div>
        )}
      </div>
    </div>
  )
}

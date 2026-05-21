import { useEffect, useState } from 'react'
import { Link } from 'react-router-dom'
import { useAuthStore } from '../../store/auth'
import Navbar from '../../components/shared/Navbar'
import { supabase } from '../../lib/supabase'
import { formatCurrency } from '../../lib/constants'
import { Users, Zap, Trophy, AlertTriangle, TrendingUp, Settings, Flag, BarChart2 } from 'lucide-react'

export default function AdminDashboard() {
  const { user } = useAuthStore()
  const [stats, setStats] = useState(null)
  const [recentBets, setRecentBets] = useState([])
  const [loading, setLoading] = useState(true)

  useEffect(() => { loadStats() }, [])

  const loadStats = async () => {
    setLoading(true)
    try {
      const [usersRes, betsRes, matchRes, fraudRes, recentBetsRes] = await Promise.all([
        supabase.from('users').select('id, is_suspended, fraud_score, created_at'),
        supabase.from('bets').select('id, status, bet_amount, multiplier, locked_amount'),
        supabase.from('matches').select('id, status'),
        supabase.from('fraud_flags').select('id, reviewed').eq('reviewed', false),
        supabase.from('bets').select('*, users(display_name), matches(team_a, team_b)')
          .order('created_at', { ascending: false }).limit(10),
      ])

      const users     = usersRes.data   || []
      const bets      = betsRes.data    || []
      const matches   = matchRes.data   || []
      const fraudOpen = fraudRes.data   || []

      const totalLocked = bets.filter(b => b.status === 'pending').reduce((s, b) => s + parseFloat(b.locked_amount || 0), 0)
      const totalWon    = bets.filter(b => b.status === 'won').reduce((s, b) => s + parseFloat(b.bet_amount || 0), 0)

      setStats({
        totalUsers:    users.length,
        activeUsers:   users.filter(u => !u.is_suspended).length,
        suspended:     users.filter(u => u.is_suspended).length,
        totalBets:     bets.length,
        pendingBets:   bets.filter(b => b.status === 'pending').length,
        totalLocked,
        totalWon,
        liveMatches:   matches.filter(m => m.status === 'live').length,
        openMatches:   matches.filter(m => m.status === 'upcoming').length,
        fraudAlerts:   fraudOpen.length,
      })
      setRecentBets(recentBetsRes.data || [])
    } catch (e) { console.error(e) }
    finally { setLoading(false) }
  }

  const STAT_CARDS = stats ? [
    { icon: Users,        label: 'Total Users',    value: stats.totalUsers,   sub: `${stats.suspended} suspended`, color: 'text-blue-400',    bg: 'bg-blue-500/10' },
    { icon: Zap,          label: 'Active Bets',    value: stats.pendingBets,  sub: `${formatCurrency(stats.totalLocked)} locked`, color: 'text-accent-red', bg: 'bg-red-500/10' },
    { icon: Trophy,       label: 'Total Won',      value: formatCurrency(stats.totalWon), sub: `${stats.totalBets} total bets`, color: 'text-accent-green', bg: 'bg-green-500/10' },
    { icon: AlertTriangle,label: 'Fraud Alerts',   value: stats.fraudAlerts,  sub: 'unreviewed flags', color: 'text-orange-400', bg: 'bg-orange-500/10', alert: stats.fraudAlerts > 0 },
    { icon: BarChart2,    label: 'Live Matches',   value: stats.liveMatches,  sub: `${stats.openMatches} upcoming`, color: 'text-brand-400', bg: 'bg-brand-500/10' },
  ] : []

  const QUICK_LINKS = [
    { to: '/admin/matches', icon: Zap,           label: 'Manage Matches',   desc: 'Add, settle, void matches' },
    { to: '/admin/users',   icon: Users,          label: 'Manage Users',    desc: 'Wallets, suspension, roles' },
    { to: '/admin/leagues', icon: Trophy,         label: 'Manage Leagues',  desc: 'View and configure leagues' },
    { to: '/admin/fraud',   icon: Flag,           label: 'Fraud Review',    desc: 'Review flagged accounts' },
    { to: '/admin/config',  icon: Settings,       label: 'System Config',   desc: 'Penalties, limits, cooldowns' },
  ]

  return (
    <div className="min-h-screen bg-surface-900">
      <Navbar />
      <div className="max-w-7xl mx-auto px-4 sm:px-6 py-8 space-y-8">
        <div>
          <h1 className="font-display text-4xl text-white tracking-wide">Admin Dashboard</h1>
          <p className="text-gray-500 text-sm mt-1 font-mono">System overview and controls</p>
        </div>

        {/* Stats grid */}
        {loading ? (
          <div className="grid grid-cols-2 md:grid-cols-3 lg:grid-cols-5 gap-4">
            {[...Array(5)].map((_, i) => <div key={i} className="card p-5 h-24 animate-pulse bg-surface-700" />)}
          </div>
        ) : (
          <div className="grid grid-cols-2 md:grid-cols-3 lg:grid-cols-5 gap-4">
            {STAT_CARDS.map(({ icon: Icon, label, value, sub, color, bg, alert }) => (
              <div key={label} className={`card p-5 ${alert ? 'border-orange-500/40' : ''}`}>
                <div className={`w-9 h-9 ${bg} rounded-xl flex items-center justify-center mb-3`}>
                  <Icon size={16} className={color} />
                </div>
                <div className={`text-2xl font-display font-bold ${alert ? 'text-orange-400' : 'text-white'}`}>{value}</div>
                <div className="text-xs text-gray-400 font-medium mt-0.5">{label}</div>
                <div className="text-xs text-gray-600 font-mono mt-1">{sub}</div>
              </div>
            ))}
          </div>
        )}

        {/* Quick links */}
        <div>
          <h2 className="font-display text-2xl text-white mb-4">Admin Controls</h2>
          <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-4">
            {QUICK_LINKS.map(({ to, icon: Icon, label, desc }) => (
              <Link key={to} to={to} className="card-hover p-5 group block">
                <Icon size={20} className="text-brand-500 mb-3 group-hover:text-brand-400 transition-colors" />
                <div className="font-semibold text-white group-hover:text-brand-400 transition-colors">{label}</div>
                <div className="text-xs text-gray-500 mt-1">{desc}</div>
              </Link>
            ))}
          </div>
        </div>

        {/* Recent bets */}
        {recentBets.length > 0 && (
          <div>
            <h2 className="font-display text-2xl text-white mb-4 flex items-center gap-2">
              <TrendingUp size={20} className="text-brand-500" /> Recent Bets
            </h2>
            <div className="card overflow-hidden">
              <table className="w-full text-sm">
                <thead>
                  <tr className="border-b border-surface-700 text-left text-xs text-gray-500 font-mono uppercase">
                    <th className="px-4 py-3">User</th>
                    <th className="px-4 py-3">Match</th>
                    <th className="px-4 py-3">Mult</th>
                    <th className="px-4 py-3">Amount</th>
                    <th className="px-4 py-3">Locked</th>
                    <th className="px-4 py-3">Status</th>
                  </tr>
                </thead>
                <tbody>
                  {recentBets.map(b => (
                    <tr key={b.id} className="table-row">
                      <td className="px-4 py-3 text-white">{b.users?.display_name ?? '—'}</td>
                      <td className="px-4 py-3 text-gray-400 text-xs">{b.matches?.team_a} vs {b.matches?.team_b}</td>
                      <td className="px-4 py-3 font-mono font-bold text-accent-gold">{b.multiplier}×</td>
                      <td className="px-4 py-3 font-mono text-gray-300">{formatCurrency(b.bet_amount)}</td>
                      <td className="px-4 py-3 font-mono text-accent-red">{formatCurrency(b.locked_amount)}</td>
                      <td className="px-4 py-3">
                        <span className={`badge ${b.status === 'won' ? 'badge-green' : b.status === 'lost' ? 'badge-red' : b.status === 'pending' ? 'badge-gold' : 'badge-gray'}`}>
                          {b.status}
                        </span>
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          </div>
        )}
      </div>
    </div>
  )
}

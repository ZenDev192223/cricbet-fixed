import { useEffect, useState } from 'react'
import { useAuthStore } from '../../store/auth'
import Navbar from '../../components/shared/Navbar'
import { supabase } from '../../lib/supabase'
import { formatCurrency } from '../../lib/constants'
import { Trophy, Users, Hash, ToggleLeft, ToggleRight, RefreshCw, ChevronDown, ChevronUp } from 'lucide-react'
import { format } from 'date-fns'
import toast from 'react-hot-toast'
import clsx from 'clsx'

export default function AdminLeagues() {
  const { user: adminUser } = useAuthStore()
  const [leagues, setLeagues]   = useState([])
  const [loading, setLoading]   = useState(true)
  const [expanded, setExpanded] = useState(null)
  const [members, setMembers]   = useState({}) // leagueId → members[]

  useEffect(() => { loadLeagues() }, [])

  const loadLeagues = async () => {
    setLoading(true)
    try {
      const { data, error } = await supabase
        .from('leagues')
        .select('*, users!leagues_created_by_fkey(display_name), league_members(count)')
        .order('created_at', { ascending: false })
      if (error) throw error
      setLeagues(data || [])
    } catch (e) { toast.error('Failed to load leagues') }
    finally { setLoading(false) }
  }

  const loadMembers = async (leagueId) => {
    if (members[leagueId]) return
    const { data } = await supabase
      .from('league_members')
      .select('user_id, credits, joined_at, users(display_name, email)')
      .eq('league_id', leagueId)
      .order('credits', { ascending: false })
    setMembers(prev => ({ ...prev, [leagueId]: data || [] }))
  }

  const toggleActive = async (league) => {
    try {
      const { error } = await supabase.from('leagues')
        .update({ is_active: !league.is_active }).eq('id', league.id)
      if (error) throw error
      await supabase.from('admin_logs').insert({
        admin_id: adminUser.id,
        action: league.is_active ? 'deactivate_league' : 'activate_league',
        target_type: 'league', target_id: league.id,
        new_value: { is_active: !league.is_active },
      })
      toast.success(`League ${league.is_active ? 'deactivated' : 'activated'}`)
      loadLeagues()
    } catch (e) { toast.error(e.message) }
  }

  const handleExpand = async (id) => {
    const next = expanded === id ? null : id
    setExpanded(next)
    if (next) await loadMembers(next)
  }

  return (
    <div className="min-h-screen bg-surface-900">
      <Navbar />
      <div className="max-w-5xl mx-auto px-4 sm:px-6 py-8 space-y-6">
        <div className="flex items-center justify-between">
          <div>
            <h1 className="font-display text-4xl text-white tracking-wide">League Management</h1>
            <p className="text-gray-500 text-sm mt-1 font-mono">{leagues.length} leagues total</p>
          </div>
          <button onClick={loadLeagues} className="btn-secondary flex items-center gap-2 px-4 py-2 text-sm">
            <RefreshCw size={14} /> Refresh
          </button>
        </div>

        {loading ? (
          <div className="space-y-2">
            {[...Array(4)].map((_, i) => <div key={i} className="card p-4 h-20 animate-pulse bg-surface-700" />)}
          </div>
        ) : leagues.length === 0 ? (
          <div className="card p-12 text-center">
            <Trophy size={28} className="mx-auto mb-3 text-gray-600" />
            <p className="text-gray-400">No leagues yet</p>
          </div>
        ) : (
          <div className="space-y-2">
            {leagues.map(l => {
              const memberCount = l.league_members?.[0]?.count ?? l.league_members?.length ?? 0
              const isOpen = expanded === l.id

              return (
                <div key={l.id} className={clsx('card overflow-hidden', !l.is_active && 'opacity-70')}>
                  <div className="flex items-center gap-4 p-4 cursor-pointer hover:bg-surface-700/40 transition-colors"
                    onClick={() => handleExpand(l.id)}>
                    <div className="w-9 h-9 bg-accent-gold/20 rounded-xl flex items-center justify-center shrink-0">
                      <Trophy size={16} className="text-accent-gold" />
                    </div>
                    <div className="flex-1 min-w-0">
                      <div className="flex items-center gap-2 flex-wrap">
                        <span className="font-semibold text-white">{l.name}</span>
                        <span className="badge badge-gray font-mono flex items-center gap-1">
                          <Hash size={9} /> {l.code}
                        </span>
                        {!l.is_active && <span className="badge badge-red">Inactive</span>}
                      </div>
                      <div className="text-xs text-gray-500 font-mono mt-0.5">
                        Created by {l.users?.display_name ?? '—'} · {format(new Date(l.created_at), 'MMM d, yyyy')}
                      </div>
                    </div>
                    <div className="hidden sm:flex items-center gap-4 text-right shrink-0">
                      <div>
                        <div className="text-xs text-gray-500 font-mono">Members</div>
                        <div className="font-mono font-bold text-white flex items-center gap-1 justify-end">
                          <Users size={12} className="text-gray-400" /> {memberCount}
                        </div>
                      </div>
                      <div>
                        <div className="text-xs text-gray-500 font-mono">Start Credits</div>
                        <div className="font-mono font-bold text-accent-green">{formatCurrency(l.starting_credits)}</div>
                      </div>
                    </div>
                    <button onClick={e => { e.stopPropagation(); toggleActive(l) }}
                      className={clsx('p-1.5 rounded-lg transition-colors shrink-0',
                        l.is_active ? 'text-accent-green hover:bg-accent-green/10' : 'text-gray-500 hover:bg-surface-600')}>
                      {l.is_active ? <ToggleRight size={20} /> : <ToggleLeft size={20} />}
                    </button>
                    {isOpen ? <ChevronUp size={16} className="text-gray-400 shrink-0" /> : <ChevronDown size={16} className="text-gray-400 shrink-0" />}
                  </div>

                  {/* Members panel */}
                  {isOpen && (
                    <div className="border-t border-surface-700 bg-surface-800/50">
                      {!members[l.id] ? (
                        <div className="p-4 text-center text-gray-500 text-sm">Loading members…</div>
                      ) : members[l.id].length === 0 ? (
                        <div className="p-4 text-center text-gray-500 text-sm">No members yet</div>
                      ) : (
                        <table className="w-full text-sm">
                          <thead>
                            <tr className="border-b border-surface-700 text-left text-xs text-gray-500 font-mono uppercase">
                              <th className="px-4 py-3">#</th>
                              <th className="px-4 py-3">Player</th>
                              <th className="px-4 py-3">Email</th>
                              <th className="px-4 py-3">Joined</th>
                              <th className="px-4 py-3 text-right">Credits</th>
                            </tr>
                          </thead>
                          <tbody>
                            {members[l.id].map((m, i) => (
                              <tr key={m.user_id} className="table-row">
                                <td className="px-4 py-3 font-mono text-gray-500">
                                  {i === 0 ? '🥇' : i === 1 ? '🥈' : i === 2 ? '🥉' : `#${i + 1}`}
                                </td>
                                <td className="px-4 py-3 font-semibold text-white">{m.users?.display_name ?? '—'}</td>
                                <td className="px-4 py-3 text-gray-400 text-xs font-mono">{m.users?.email ?? '—'}</td>
                                <td className="px-4 py-3 text-gray-500 text-xs font-mono">
                                  {m.joined_at ? format(new Date(m.joined_at), 'MMM d') : '—'}
                                </td>
                                <td className="px-4 py-3 text-right font-mono font-bold text-accent-green">
                                  {formatCurrency(m.credits ?? 0)}
                                </td>
                              </tr>
                            ))}
                          </tbody>
                        </table>
                      )}
                    </div>
                  )}
                </div>
              )
            })}
          </div>
        )}
      </div>
    </div>
  )
}

import { Link, useLocation } from 'react-router-dom'
import { useAuthStore } from '../../store/auth'
import { Zap, LogOut, Menu, X } from 'lucide-react'
import { useState } from 'react'
import clsx from 'clsx'

const USER_LINKS = [
  { to: '/',             label: 'Home' },
  { to: '/donate',       label: 'Transfer' },
  { to: '/transactions', label: 'History' },
]
const ADMIN_LINKS = [
  { to: '/admin',          label: 'Dashboard' },
  { to: '/admin/matches',  label: 'Matches' },
  { to: '/admin/leagues',  label: 'Leagues' },
  { to: '/admin/users',    label: 'Users' },
  { to: '/admin/fraud',    label: 'Fraud' },
  { to: '/admin/config',   label: 'Config' },
]

export default function Navbar() {
  const { profile, isAdmin, signOut } = useAuthStore()
  const location = useLocation()
  const [open, setOpen] = useState(false)
  const links = isAdmin ? ADMIN_LINKS : USER_LINKS

  return (
    <nav className="border-b border-surface-700 bg-surface-900/80 backdrop-blur sticky top-0 z-50">
      <div className="max-w-7xl mx-auto px-4 sm:px-6 h-16 flex items-center justify-between">
        <Link to={isAdmin ? '/admin' : '/'} className="flex items-center gap-2 font-display text-xl text-white">
          <Zap size={20} className="text-brand-500" /> Cretex
        </Link>

        {/* Desktop links */}
        <div className="hidden md:flex items-center gap-1">
          {links.map(l => (
            <Link key={l.to} to={l.to}
              className={clsx('px-4 py-2 rounded-lg text-sm font-medium transition-colors',
                location.pathname === l.to
                  ? 'bg-brand-500/20 text-brand-400'
                  : 'text-gray-400 hover:text-white hover:bg-surface-700'
              )}>
              {l.label}
            </Link>
          ))}
        </div>

        <div className="hidden md:flex items-center gap-3">
          <span className="text-sm text-gray-400 font-mono">{profile?.display_name}</span>
          <button onClick={signOut} className="btn-ghost p-2 text-gray-400 hover:text-white">
            <LogOut size={16} />
          </button>
        </div>

        {/* Mobile hamburger */}
        <button className="md:hidden btn-ghost p-2" onClick={() => setOpen(o => !o)}>
          {open ? <X size={20} /> : <Menu size={20} />}
        </button>
      </div>

      {/* Mobile menu */}
      {open && (
        <div className="md:hidden border-t border-surface-700 bg-surface-900 px-4 py-3 space-y-1">
          {links.map(l => (
            <Link key={l.to} to={l.to} onClick={() => setOpen(false)}
              className={clsx('block px-4 py-2 rounded-lg text-sm font-medium transition-colors',
                location.pathname === l.to
                  ? 'bg-brand-500/20 text-brand-400'
                  : 'text-gray-400 hover:text-white hover:bg-surface-700'
              )}>
              {l.label}
            </Link>
          ))}
          <div className="pt-2 border-t border-surface-700 flex items-center justify-between">
            <span className="text-sm text-gray-400 font-mono">{profile?.display_name}</span>
            <button onClick={signOut} className="btn-ghost p-2 text-gray-400 hover:text-white">
              <LogOut size={16} />
            </button>
          </div>
        </div>
      )}
    </nav>
  )
}

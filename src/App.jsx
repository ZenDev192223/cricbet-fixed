import { useEffect } from 'react'
import { Routes, Route, Navigate } from 'react-router-dom'
import { useAuthStore } from './store/auth'

import AuthPage from './pages/AuthPage'
import UserDashboard from './pages/user/UserDashboard'
import MatchBetPage from './pages/user/MatchBetPage'
import LeaguePage from './pages/user/LeaguePage'
import DonationPage from './pages/user/DonationPage'
import TransactionsPage from './pages/user/TransactionsPage'
import AdminDashboard from './pages/admin/AdminDashboard'
import AdminMatches from './pages/admin/AdminMatches'
import AdminLeagues from './pages/admin/AdminLeagues'
import AdminUsers from './pages/admin/AdminUsers'
import AdminConfig from './pages/admin/AdminConfig'
import AdminFraud from './pages/admin/AdminFraud'
import LoadingSpinner from './components/shared/LoadingSpinner'

function Guard({ children, adminOnly = false }) {
  const { user, isAdmin, loading } = useAuthStore()
  if (loading) return <LoadingSpinner />
  if (!user) return <Navigate to="/auth" replace />
  if (adminOnly && !isAdmin) return <Navigate to="/" replace />
  return children
}

export default function App() {
  const { initialize, user, isAdmin, loading } = useAuthStore()
  useEffect(() => { initialize() }, [])
  if (loading) return <LoadingSpinner />

  return (
    <Routes>
      <Route path="/auth" element={user ? <Navigate to={isAdmin ? '/admin' : '/'} replace /> : <AuthPage />} />
      <Route path="/" element={<Guard><UserDashboard /></Guard>} />
      <Route path="/league/:leagueId" element={<Guard><LeaguePage /></Guard>} />
      <Route path="/league/:leagueId/match/:matchId" element={<Guard><MatchBetPage /></Guard>} />
      <Route path="/donate" element={<Guard><DonationPage /></Guard>} />
      <Route path="/transactions" element={<Guard><TransactionsPage /></Guard>} />
      <Route path="/admin" element={<Guard adminOnly><AdminDashboard /></Guard>} />
      <Route path="/admin/matches" element={<Guard adminOnly><AdminMatches /></Guard>} />
      <Route path="/admin/leagues" element={<Guard adminOnly><AdminLeagues /></Guard>} />
      <Route path="/admin/users" element={<Guard adminOnly><AdminUsers /></Guard>} />
      <Route path="/admin/config" element={<Guard adminOnly><AdminConfig /></Guard>} />
      <Route path="/admin/fraud" element={<Guard adminOnly><AdminFraud /></Guard>} />
      <Route path="*" element={<Navigate to="/" replace />} />
    </Routes>
  )
}

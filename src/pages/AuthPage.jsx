import { useState } from 'react'
import { useAuthStore } from '../store/auth'
import { Zap, Eye, EyeOff, User, Mail, Phone, Lock } from 'lucide-react'
import toast from 'react-hot-toast'

export default function AuthPage() {
  const [mode, setMode] = useState('signin')
  const [loading, setLoading] = useState(false)
  const [showPwd, setShowPwd] = useState(false)
  const [form, setForm] = useState({ email: '', password: '', displayName: '', phone: '' })
  const { signIn, signUp } = useAuthStore()

  const set = (k, v) => setForm(f => ({ ...f, [k]: v }))

  const handleSubmit = async () => {
    if (!form.email || !form.password) return toast.error('Email and password required')
    if (mode === 'signup' && !form.displayName) return toast.error('Display name required')
    setLoading(true)
    try {
      if (mode === 'signin') {
        await signIn(form.email, form.password)
      } else {
        await signUp(form.email, form.password, form.displayName, form.phone)
        toast.success('Account created! Welcome to Cretex.')
      }
    } catch (e) {
      toast.error(e.message)
    } finally {
      setLoading(false)
    }
  }

  return (
    <div className="min-h-screen bg-surface-900 flex items-center justify-center p-4"
      style={{ backgroundImage: 'radial-gradient(ellipse at 30% 20%, rgba(249,115,22,0.1) 0%, transparent 60%), radial-gradient(ellipse at 70% 80%, rgba(168,85,247,0.07) 0%, transparent 60%)' }}>

      <div className="w-full max-w-md">
        {/* Logo */}
        <div className="text-center mb-10">
          <div className="inline-flex items-center justify-center w-16 h-16 bg-brand-500 rounded-2xl mb-4 shadow-glow-orange">
            <Zap size={28} className="text-white" />
          </div>
          <h1 className="font-display text-5xl text-white tracking-wide">Crextex</h1>
          <p className="text-gray-500 text-sm mt-2 font-mono">Live Fantasy Betting · Streak System</p>
        </div>

        {/* Card */}
        <div className="card p-8">
          {/* Tab toggle */}
          <div className="flex bg-surface-700 rounded-xl p-1 mb-8">
            {['signin', 'signup'].map(m => (
              <button key={m} onClick={() => setMode(m)}
                className={`flex-1 py-2.5 text-sm font-semibold rounded-lg transition-all duration-200 ${
                  mode === m
                    ? 'bg-brand-500 text-white shadow-glow-orange'
                    : 'text-gray-400 hover:text-white'
                }`}>
                {m === 'signin' ? 'Sign In' : 'Create Account'}
              </button>
            ))}
          </div>

          <div className="space-y-4">
            {mode === 'signup' && (
              <>
                <div className="relative">
                  <User size={16} className="absolute left-3 top-1/2 -translate-y-1/2 text-gray-500" />
                  <input className="input pl-10" placeholder="Display name"
                    value={form.displayName} onChange={e => set('displayName', e.target.value)} />
                </div>
                <div className="relative">
                  <Phone size={16} className="absolute left-3 top-1/2 -translate-y-1/2 text-gray-500" />
                  <input className="input pl-10" placeholder="Phone (optional)" type="tel"
                    value={form.phone} onChange={e => set('phone', e.target.value)} />
                </div>
              </>
            )}
            <div className="relative">
              <Mail size={16} className="absolute left-3 top-1/2 -translate-y-1/2 text-gray-500" />
              <input className="input pl-10" placeholder="Email address" type="email"
                value={form.email} onChange={e => set('email', e.target.value)}
                onKeyDown={e => e.key === 'Enter' && handleSubmit()} />
            </div>
            <div className="relative">
              <Lock size={16} className="absolute left-3 top-1/2 -translate-y-1/2 text-gray-500" />
              <input className="input pl-10 pr-10" placeholder="Password" type={showPwd ? 'text' : 'password'}
                value={form.password} onChange={e => set('password', e.target.value)}
                onKeyDown={e => e.key === 'Enter' && handleSubmit()} />
              <button type="button" onClick={() => setShowPwd(s => !s)}
                className="absolute right-3 top-1/2 -translate-y-1/2 text-gray-500 hover:text-gray-300">
                {showPwd ? <EyeOff size={16} /> : <Eye size={16} />}
              </button>
            </div>

            <button onClick={handleSubmit} disabled={loading} className="btn-primary w-full mt-2">
              {loading ? 'Please wait…' : mode === 'signin' ? 'Sign In' : 'Create Account'}
            </button>
          </div>

          {mode === 'signup' && (
            <p className="text-xs text-gray-600 text-center mt-4 font-mono">
              New accounts start with ₹1,000 wallet balance
            </p>
          )}
        </div>
      </div>
    </div>
  )
}

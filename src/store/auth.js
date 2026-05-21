import { create } from 'zustand'
import { supabase } from '../lib/supabase'

export const useAuthStore = create((set, get) => ({
  user:    null,
  profile: null,
  isAdmin: false,
  loading: true,

  initialize: async () => {
    const { data: { session } } = await supabase.auth.getSession()
    if (session?.user) await get().loadProfile(session.user)
    else set({ loading: false })

    supabase.auth.onAuthStateChange(async (event, session) => {
      if (session?.user) await get().loadProfile(session.user)
      else set({ user: null, profile: null, isAdmin: false, loading: false })
    })
  },

  loadProfile: async (user) => {
    try {
      const { data: profile } = await supabase.from('users').select('*').eq('id', user.id).single()
      set({
        user,
        profile,
        isAdmin: profile?.role === 'admin' || profile?.role === 'superadmin',
        loading: false,
      })
    } catch {
      set({ user, profile: null, isAdmin: false, loading: false })
    }
  },

  signUp: async (email, password, displayName, phone) => {
    const { data, error } = await supabase.auth.signUp({ email, password })
    if (error) throw error
    if (data.user) {
      const { error: profErr } = await supabase.from('users').insert({
        id: data.user.id,
        display_name: displayName,
        email,
        phone: phone || null,
      })
      if (profErr) throw profErr
      // Wallet is auto-created by DB trigger
    }
    return data
  },

  signIn: async (email, password) => {
    const { data, error } = await supabase.auth.signInWithPassword({ email, password })
    if (error) throw error
    return data
  },

  signOut: async () => {
    await supabase.auth.signOut()
    set({ user: null, profile: null, isAdmin: false })
  },
}))

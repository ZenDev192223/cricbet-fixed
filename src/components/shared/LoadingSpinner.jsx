export default function LoadingSpinner({ size = 'full' }) {
  if (size === 'full') return (
    <div className="min-h-screen bg-surface-900 flex items-center justify-center">
      <div className="flex flex-col items-center gap-4">
        <div className="relative w-16 h-16">
          <div className="absolute inset-0 rounded-full border-2 border-brand-500/20"></div>
          <div className="absolute inset-0 rounded-full border-2 border-transparent border-t-brand-500 animate-spin"></div>
          <div className="absolute inset-3 rounded-full border-2 border-transparent border-t-brand-400/50 animate-spin"
            style={{ animationDuration: '0.6s', animationDirection: 'reverse' }}></div>
        </div>
        <p className="text-gray-500 text-sm font-mono tracking-widest uppercase">Loading</p>
      </div>
    </div>
  )
  return (
    <div className="flex items-center justify-center p-8">
      <div className="w-8 h-8 rounded-full border-2 border-brand-500/20 border-t-brand-500 animate-spin"></div>
    </div>
  )
}

// ─── Multiplier definitions ──────────────────────────────────────────────────
export const MULTIPLIERS = {
  1.5: {
    value:       1.5,
    label:       '1.5×',
    type:        'permanent',
    penalty:     0,
    color:       'text-gray-300',
    glow:        '',
    minWallet:   0,
    description: 'No penalty on loss',
  },
  2: {
    value:       2,
    label:       '2×',
    type:        'permanent',
    penalty:     0.30,
    color:       'text-blue-400',
    glow:        'glow-blue',
    minWallet:   0,
    description: '30% penalty on loss',
  },
  3: {
    value:       3,
    label:       '3×',
    type:        'consumable',
    penalty:     0.50,
    color:       'text-accent-gold',
    glow:        'glow-gold',
    minWallet:   500,
    description: '50% penalty on loss · Consumable',
  },
  4: {
    value:       4,
    label:       '4×',
    type:        'consumable',
    penalty:     0.65,
    color:       'text-purple-400',
    glow:        'glow-purple',
    minWallet:   1000,
    description: '65% penalty on loss · Consumable · 1 match cooldown',
  },
  5: {
    value:       5,
    label:       '5×',
    type:        'consumable',
    penalty:     0.80,
    color:       'text-red-400',
    glow:        'glow-red',
    minWallet:   2500,
    description: '80% penalty on loss · Consumable · 2 match cooldown',
  },
}

// ─── Streak unlock requirements ──────────────────────────────────────────────
export const UNLOCK_REQUIREMENTS = {
  3: [
    { multiplier: 1.5, streak: 3 },
    { multiplier: 2,   streak: 2 },
  ],
  4: [
    { multiplier: 1.5, streak: 5 },
    { multiplier: 2,   streak: 3 },
    { multiplier: 3,   streak: 2 },
  ],
  5: [
    { multiplier: 1.5, streak: 7 },
    { multiplier: 2,   streak: 5 },
    { multiplier: 3,   streak: 3 },
    { multiplier: 4,   streak: 1 },
  ],
}

// ─── Bet status values ───────────────────────────────────────────────────────
export const BET_STATUS = {
  PENDING:   'pending',
  WON:       'won',
  LOST:      'lost',
  REFUNDED:  'refunded',
  VOIDED:    'voided',
  CANCELLED: 'cancelled',
}

// ─── Match status values ─────────────────────────────────────────────────────
export const MATCH_STATUS = {
  UPCOMING:   'upcoming',
  LIVE:       'live',
  COMPLETED:  'completed',
  CANCELLED:  'cancelled',
  ABANDONED:  'abandoned',
  POSTPONED:  'postponed',
}

// ─── Transaction types ───────────────────────────────────────────────────────
export const TX_TYPE = {
  BET_PLACE:      'bet_place',
  BET_WIN:        'bet_win',
  BET_LOSS:       'bet_loss',
  BET_REFUND:     'bet_refund',
  BET_VOID:       'bet_void',
  DONATION_SENT:  'donation_sent',
  DONATION_RECV:  'donation_received',
  ADMIN_ADJUST:   'admin_adjust',
  WALLET_DECAY:   'wallet_decay',
  LOCK:           'lock',
  UNLOCK:         'unlock',
}

// ─── Fraud risk thresholds ───────────────────────────────────────────────────
export const FRAUD = {
  MAX_DONATIONS_PER_DAY:    3,
  MAX_DONATION_AMOUNT_DAY:  5000,
  MIN_ACCOUNT_AGE_DAYS:     7,
  MIN_COMPLETED_BETS:       5,
  COOLDOWN_MINUTES:         60,
  WEEKLY_RECEIVE_CAP:       1000,
  CIRCULAR_LOOKBACK_DAYS:   7,
}

// ─── IPL teams ───────────────────────────────────────────────────────────────
export const IPL_TEAMS = [
  { code: 'CSK', name: 'Chennai Super Kings',    color: '#F9CD1C', bg: '#0A1628' },
  { code: 'MI',  name: 'Mumbai Indians',          color: '#005DA0', bg: '#FFFFFF' },
  { code: 'RCB', name: 'Royal Challengers Bengaluru', color: '#EC1C24', bg: '#2B2A29' },
  { code: 'KKR', name: 'Kolkata Knight Riders',  color: '#3B215A', bg: '#F4C013' },
  { code: 'DC',  name: 'Delhi Capitals',          color: '#0078BC', bg: '#EF1C25' },
  { code: 'PBKS', name: 'Punjab Kings',           color: '#ED1B24', bg: '#DCDDDF' },
  { code: 'RR',  name: 'Rajasthan Royals',        color: '#EA1A85', bg: '#254AA5' },
  { code: 'SRH', name: 'Sunrisers Hyderabad',     color: '#F7A721', bg: '#E95F0A' },
  { code: 'GT',  name: 'Gujarat Titans',          color: '#1C1C1C', bg: '#1D9BF0' },
  { code: 'LSG', name: 'Lucknow Super Giants',    color: '#A72056', bg: '#FCCF15' },
]

export const getTeam = (code) => IPL_TEAMS.find(t => t.code === code)

// ─── Helpers ─────────────────────────────────────────────────────────────────
export const formatCurrency = (n) =>
  new Intl.NumberFormat('en-IN', { style: 'currency', currency: 'INR', maximumFractionDigits: 0 }).format(n ?? 0)

export const calcLiabilityLock = (amount, multiplier) => {
  const penalty = MULTIPLIERS[multiplier]?.penalty ?? 0
  return Math.round(amount + amount * penalty)
}

export const calcWinReturn = (amount, multiplier) =>
  Math.round(amount * multiplier)

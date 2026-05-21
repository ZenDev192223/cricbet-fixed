# CricBet v2 — Complete Deployment Guide

## Tech Stack
- **Frontend**: React 18 + Vite + Tailwind CSS
- **Backend**: Supabase (PostgreSQL + Edge Functions + Realtime)
- **Auth**: Supabase Auth (email/password)
- **Fonts**: Bebas Neue · DM Sans · JetBrains Mono

---

## Project Structure

```
cricbet/
├── src/
│   ├── pages/
│   │   ├── AuthPage.jsx
│   │   ├── user/
│   │   │   ├── UserDashboard.jsx    ← Main dashboard, matches, leagues
│   │   │   ├── MatchBetPage.jsx     ← Bet placement with multiplier UI
│   │   │   ├── LeaguePage.jsx       ← League matches, bets, leaderboard
│   │   │   ├── DonationPage.jsx     ← Transfer credits with anti-abuse
│   │   │   └── TransactionsPage.jsx ← Immutable ledger view
│   │   └── admin/
│   │       ├── AdminDashboard.jsx   ← Stats overview + quick links
│   │       ├── AdminMatches.jsx     ← Create, go-live, settle matches
│   │       ├── AdminUsers.jsx       ← Wallet adjust, suspend, grant multipliers
│   │       ├── AdminLeagues.jsx     ← League management + member lists
│   │       ├── AdminConfig.jsx      ← All system settings (penalties, limits…)
│   │       └── AdminFraud.jsx       ← Fraud flag review queue
│   ├── components/
│   │   ├── shared/
│   │   │   ├── Navbar.jsx           ← Sticky nav, wallet display
│   │   │   ├── WalletCard.jsx       ← Available + locked balance card
│   │   │   └── LoadingSpinner.jsx
│   │   └── user/
│   │       ├── MultiplierChip.jsx   ← Bet multiplier selector
│   │       ├── StreakDisplay.jsx     ← Streak progress bars + unlock goals
│   │       └── UnlockDisplay.jsx    ← Active unlocked multipliers
│   ├── store/
│   │   ├── auth.js                  ← Zustand auth store
│   │   └── dashboard.js             ← Zustand dashboard + realtime store
│   └── lib/
│       ├── supabase.js              ← Supabase client
│       ├── api.js                   ← Edge function + RPC calls
│       └── constants.js             ← Multiplier config, IPL teams, formatters
├── supabase/
│   ├── migrations/
│   │   └── 001_initial_schema.sql   ← Complete schema + RPCs + RLS
│   └── functions/
│       ├── place-bet/               ← Validates + calls place_bet RPC
│       ├── settle-match/            ← Admin-only match settlement
│       ├── process-donation/        ← Fraud-checked transfer
│       └── apply-inactivity/        ← Cron: decay + streak reduction
```

---

## Setup Steps

### 1. Create Supabase Project
1. Go to [supabase.com](https://supabase.com) → New project
2. Copy your **Project URL** and **Anon Key** from Settings → API

### 2. Run the Database Migration
In Supabase SQL Editor, paste and run:
```
supabase/migrations/001_initial_schema.sql
```
This creates all 14 tables, 7 RPCs, RLS policies, and triggers.

### 3. Set Environment Variables
```bash
cp .env.example .env
# Fill in VITE_SUPABASE_URL and VITE_SUPABASE_ANON_KEY
```

### 4. Deploy Edge Functions
```bash
npm install -g supabase
supabase login
supabase link --project-ref YOUR_PROJECT_REF
supabase functions deploy place-bet
supabase functions deploy settle-match
supabase functions deploy process-donation
supabase functions deploy apply-inactivity
```

Set Edge Function secrets:
```bash
supabase secrets set CRON_SECRET=your-random-secret
```

### 5. Install & Run Frontend
```bash
npm install
npm run dev
```

### 6. Create First Admin User
1. Sign up normally through the app
2. In Supabase SQL Editor:
```sql
UPDATE users SET role = 'admin' WHERE email = 'your@email.com';
```

### 7. Schedule Inactivity Job (Optional)
In Supabase → Edge Functions → Schedules, create a daily cron:
```
0 0 * * *  →  apply-inactivity
```
With header: `Authorization: Bearer YOUR_CRON_SECRET`

---

## Key System Rules (enforced server-side)

| Rule | Value |
|------|-------|
| Max bet | 25% of available balance |
| 1.5× penalty | 0% |
| 2× penalty | 30% |
| 3× penalty | 50% |
| 4× penalty | 65% |
| 5× penalty | 80% |
| 4× cooldown | 1 match |
| 5× cooldown | 3 matches |
| Min wallet for 3× | ₹500 |
| Min wallet for 4× | ₹1,000 |
| Min wallet for 5× | ₹2,500 |
| Max donations/day | 3 |
| Donation weekly cap (receive) | ₹1,000 |
| Inactivity decay | 2%/day after 3 days |

All values are configurable in Admin → Config without code changes.

---

## Streak Unlock Paths

| Unlock | Via 1.5× | Via 2× | Via 3× | Via 4× |
|--------|----------|--------|--------|--------|
| **3×** | 3 wins   | 2 wins | —      | —      |
| **4×** | 5 wins   | 3 wins | 2 wins | —      |
| **5×** | 7 wins   | 5 wins | 3 wins | 1 win  |

---

## Security Architecture

- All wallet mutations go through **PostgreSQL RPCs** with `FOR UPDATE` row locks
- Edge Functions validate JWT before calling any RPC
- `place_bet` is **idempotent** — duplicate requests return early safely
- `settle_match` uses a `settlement_id` — re-running same settlement is a no-op
- Transactions table has `NO UPDATE / NO DELETE` rules — fully immutable ledger
- Admin logs table is similarly immutable
- RLS policies enforce row-level access — users can only see their own data
- Fraud scoring auto-suspends accounts that hit score ≥ 100

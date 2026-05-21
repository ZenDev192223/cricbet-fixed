-- ============================================================
-- CricBet v2 — Complete Schema
-- PostgreSQL + Supabase
-- ============================================================

CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- ============================================================
-- ENUMS
-- ============================================================

CREATE TYPE user_role AS ENUM ('user', 'admin', 'superadmin');
CREATE TYPE match_status AS ENUM ('upcoming', 'live', 'completed', 'canceled', 'abandoned', 'postponed');
CREATE TYPE match_result_type AS ENUM ('team_a', 'team_b', 'tie', 'no_result', 'void');
CREATE TYPE bet_status AS ENUM ('pending', 'won', 'lost', 'refunded', 'void', 'canceled');
CREATE TYPE transaction_type AS ENUM (
  'bet_lock', 'bet_unlock', 'bet_win', 'bet_loss',
  'donation_sent', 'donation_received',
  'admin_credit', 'admin_debit',
  'wallet_decay', 'bonus_credit', 'refund'
);
CREATE TYPE fraud_flag_type AS ENUM (
  'circular_transfer', 'rapid_farming', 'multi_account_device',
  'abnormal_spike', 'smurf_detection', 'exploit_attempt'
);

-- ============================================================
-- SYSTEM CONFIG
-- ============================================================

CREATE TABLE system_config (
  key         TEXT PRIMARY KEY,
  value       JSONB NOT NULL,
  updated_at  TIMESTAMPTZ DEFAULT now(),
  updated_by  UUID
);

INSERT INTO system_config (key, value) VALUES
  ('max_bet_pct',           '25'),
  ('inactivity_days',       '3'),
  ('wallet_decay_pct',      '2'),
  ('donation_weekly_cap',   '1000'),
  ('donation_daily_max',    '3'),
  ('donation_daily_amount', '5000'),
  ('donation_cooldown_min', '60'),
  ('min_account_age_days',  '7'),
  ('min_completed_bets',    '5'),
  ('cooldown_4x_matches',   '1'),
  ('cooldown_5x_matches',   '3'),
  ('max_active_5x_bets',    '1'),
  ('max_active_4x_bets',    '2'),
  ('min_wallet_3x',         '500'),
  ('min_wallet_4x',         '1000'),
  ('min_wallet_5x',         '2500'),
  ('penalty_1_5x',          '0'),
  ('penalty_2x',            '30'),
  ('penalty_3x',            '50'),
  ('penalty_4x',            '65'),
  ('penalty_5x',            '80'),
  ('streak_unlock_3x',      '{"1.5": 3, "2": 2}'),
  ('streak_unlock_4x',      '{"1.5": 5, "2": 3, "3": 2}'),
  ('streak_unlock_5x',      '{"1.5": 7, "2": 5, "3": 3, "4": 1}'),
  ('week_start_day',        '1');

-- ============================================================
-- USERS
-- ============================================================

CREATE TABLE users (
  id               UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  display_name     TEXT NOT NULL,
  email            TEXT NOT NULL,
  phone            TEXT,
  role             user_role DEFAULT 'user',
  is_suspended     BOOLEAN DEFAULT false,
  suspend_reason   TEXT,
  exploit_flagged  BOOLEAN DEFAULT false,
  fraud_score      INTEGER DEFAULT 0,
  device_fingerprints TEXT[] DEFAULT '{}',
  ip_addresses     TEXT[] DEFAULT '{}',
  completed_bets   INTEGER DEFAULT 0,
  created_at       TIMESTAMPTZ DEFAULT now(),
  last_bet_at      TIMESTAMPTZ,
  last_login_at    TIMESTAMPTZ DEFAULT now()
);

-- ============================================================
-- WALLETS
-- ============================================================

CREATE TABLE wallets (
  id                UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id           UUID NOT NULL UNIQUE REFERENCES users(id) ON DELETE CASCADE,
  available_balance NUMERIC(14,2) DEFAULT 1000 CHECK (available_balance >= 0),
  locked_balance    NUMERIC(14,2) DEFAULT 0 CHECK (locked_balance >= 0),
  total_donated     NUMERIC(14,2) DEFAULT 0,
  total_received    NUMERIC(14,2) DEFAULT 0,
  week_received     NUMERIC(14,2) DEFAULT 0,
  week_received_reset_at TIMESTAMPTZ DEFAULT now(),
  updated_at        TIMESTAMPTZ DEFAULT now()
);

-- ============================================================
-- LEAGUES
-- ============================================================

CREATE TABLE leagues (
  id               UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  name             TEXT NOT NULL,
  code             TEXT NOT NULL UNIQUE,
  created_by       UUID NOT NULL REFERENCES users(id),
  starting_credits NUMERIC(14,2) DEFAULT 1000,
  max_bet          NUMERIC(14,2),
  is_active        BOOLEAN DEFAULT true,
  created_at       TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE league_members (
  id          UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  league_id   UUID NOT NULL REFERENCES leagues(id) ON DELETE CASCADE,
  user_id     UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  credits     NUMERIC(14,2) DEFAULT 0,
  joined_at   TIMESTAMPTZ DEFAULT now(),
  UNIQUE(league_id, user_id)
);

-- ============================================================
-- MATCHES
-- ============================================================

CREATE TABLE matches (
  id            UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  league_id     UUID REFERENCES leagues(id),
  team_a        TEXT NOT NULL,
  team_b        TEXT NOT NULL,
  match_date    TIMESTAMPTZ NOT NULL,
  venue         TEXT,
  status        match_status DEFAULT 'upcoming',
  result        match_result_type,
  winning_team  TEXT,
  auto_live_at  TIMESTAMPTZ,
  settled_at    TIMESTAMPTZ,
  settlement_id TEXT UNIQUE,
  created_at    TIMESTAMPTZ DEFAULT now(),
  created_by    UUID REFERENCES users(id)
);

-- ============================================================
-- BETS
-- ============================================================

CREATE TABLE bets (
  id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id         UUID NOT NULL REFERENCES users(id),
  league_id       UUID NOT NULL REFERENCES leagues(id),
  match_id        UUID NOT NULL REFERENCES matches(id),
  bet_team        TEXT NOT NULL,
  multiplier      NUMERIC(3,1) NOT NULL,
  bet_amount      NUMERIC(14,2) NOT NULL CHECK (bet_amount > 0),
  locked_amount   NUMERIC(14,2) NOT NULL,
  penalty_pct     INTEGER NOT NULL DEFAULT 0,
  potential_win   NUMERIC(14,2) NOT NULL,
  status          bet_status DEFAULT 'pending',
  credits_won     NUMERIC(14,2) DEFAULT 0,
  settlement_id   TEXT,
  idempotency_key TEXT UNIQUE,
  created_at      TIMESTAMPTZ DEFAULT now(),
  settled_at      TIMESTAMPTZ,
  UNIQUE(user_id, league_id, match_id)
);

-- ============================================================
-- TRANSACTIONS (immutable ledger)
-- ============================================================

CREATE TABLE transactions (
  id             UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id        UUID NOT NULL REFERENCES users(id),
  type           transaction_type NOT NULL,
  amount         NUMERIC(14,2) NOT NULL,
  balance_before NUMERIC(14,2) NOT NULL,
  balance_after  NUMERIC(14,2) NOT NULL,
  ref_id         UUID,
  ref_type       TEXT,
  note           TEXT,
  created_at     TIMESTAMPTZ DEFAULT now()
);

-- ============================================================
-- STREAKS
-- ============================================================

CREATE TABLE streaks (
  id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id         UUID NOT NULL REFERENCES users(id),
  multiplier_tier TEXT NOT NULL,
  current_streak  INTEGER DEFAULT 0,
  last_match_id   UUID REFERENCES matches(id),
  last_updated    TIMESTAMPTZ DEFAULT now(),
  UNIQUE(user_id, multiplier_tier)
);

-- ============================================================
-- MULTIPLIER UNLOCKS
-- ============================================================

CREATE TABLE multiplier_unlocks (
  id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id         UUID NOT NULL REFERENCES users(id),
  multiplier      TEXT NOT NULL,
  unlocked_at     TIMESTAMPTZ DEFAULT now(),
  unlock_source   TEXT,
  is_consumed     BOOLEAN DEFAULT false,
  consumed_at     TIMESTAMPTZ,
  consumed_by_bet UUID REFERENCES bets(id),
  UNIQUE(user_id, multiplier)
);

-- ============================================================
-- COOLDOWNS
-- ============================================================

CREATE TABLE cooldowns (
  id                UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id           UUID NOT NULL REFERENCES users(id),
  multiplier        TEXT NOT NULL,
  matches_remaining INTEGER DEFAULT 0,
  triggered_by      UUID REFERENCES bets(id),
  created_at        TIMESTAMPTZ DEFAULT now(),
  UNIQUE(user_id, multiplier)
);

-- ============================================================
-- DONATIONS
-- ============================================================

CREATE TABLE donations (
  id          UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  sender_id   UUID NOT NULL REFERENCES users(id),
  receiver_id UUID NOT NULL REFERENCES users(id),
  amount      NUMERIC(14,2) NOT NULL CHECK (amount > 0),
  note        TEXT,
  status      TEXT DEFAULT 'completed',
  sender_ip   TEXT,
  created_at  TIMESTAMPTZ DEFAULT now()
);

-- ============================================================
-- FRAUD FLAGS
-- ============================================================

CREATE TABLE fraud_flags (
  id           UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id      UUID NOT NULL REFERENCES users(id),
  flag_type    fraud_flag_type NOT NULL,
  details      JSONB,
  reviewed     BOOLEAN DEFAULT false,
  reviewed_by  UUID REFERENCES users(id),
  reviewed_at  TIMESTAMPTZ,
  action_taken TEXT,
  created_at   TIMESTAMPTZ DEFAULT now()
);

-- ============================================================
-- ADMIN AUDIT LOGS (immutable)
-- ============================================================

CREATE TABLE admin_logs (
  id          UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  admin_id    UUID NOT NULL REFERENCES users(id),
  action      TEXT NOT NULL,
  target_type TEXT,
  target_id   UUID,
  old_value   JSONB,
  new_value   JSONB,
  ip_address  TEXT,
  user_agent  TEXT,
  created_at  TIMESTAMPTZ DEFAULT now()
);

-- ============================================================
-- INACTIVITY RECORDS
-- ============================================================

CREATE TABLE inactivity_records (
  id             UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id        UUID NOT NULL REFERENCES users(id),
  days_inactive  INTEGER NOT NULL,
  decay_applied  NUMERIC(14,2) DEFAULT 0,
  streak_reduced BOOLEAN DEFAULT false,
  processed_at   TIMESTAMPTZ DEFAULT now()
);

-- ============================================================
-- INDEXES
-- ============================================================

CREATE INDEX idx_bets_user       ON bets(user_id);
CREATE INDEX idx_bets_match      ON bets(match_id);
CREATE INDEX idx_bets_league     ON bets(league_id);
CREATE INDEX idx_bets_status     ON bets(status);
CREATE INDEX idx_txn_user        ON transactions(user_id);
CREATE INDEX idx_streaks_user    ON streaks(user_id);
CREATE INDEX idx_unlocks_user    ON multiplier_unlocks(user_id);
CREATE INDEX idx_donations_from  ON donations(sender_id);
CREATE INDEX idx_donations_to    ON donations(receiver_id);
CREATE INDEX idx_fraud_user      ON fraud_flags(user_id);
CREATE INDEX idx_matches_status  ON matches(status);
CREATE INDEX idx_matches_date    ON matches(match_date);

-- ============================================================
-- FUNCTIONS
-- ============================================================

CREATE OR REPLACE FUNCTION get_config_value(config_key TEXT)
RETURNS JSONB LANGUAGE plpgsql STABLE AS $$
DECLARE v JSONB;
BEGIN
  SELECT value INTO v FROM system_config WHERE key = config_key;
  RETURN COALESCE(v, 'null'::JSONB);
END;
$$;

-- ============================================================
-- place_bet RPC
-- ============================================================

CREATE OR REPLACE FUNCTION place_bet(
  p_user_id         UUID,
  p_league_id       UUID,
  p_match_id        UUID,
  p_bet_team        TEXT,
  p_multiplier      NUMERIC,
  p_bet_amount      NUMERIC,
  p_idempotency_key TEXT,
  p_ip_address      TEXT DEFAULT NULL
)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_wallet         wallets%ROWTYPE;
  v_match          matches%ROWTYPE;
  v_user           users%ROWTYPE;
  v_penalty_pct    INTEGER;
  v_locked_amount  NUMERIC;
  v_potential_win  NUMERIC;
  v_bet_id         UUID;
  v_max_bet_pct    NUMERIC;
  v_max_bet        NUMERIC;
  v_min_wallet     NUMERIC;
  v_league_max_bet NUMERIC;
  v_active_count   INTEGER;
  v_cooldown_rem   INTEGER;
  v_multiplier_str TEXT;
  v_has_unlock     BOOLEAN;
BEGIN
  v_multiplier_str := p_multiplier::TEXT;

  IF EXISTS (SELECT 1 FROM bets WHERE idempotency_key = p_idempotency_key) THEN
    RETURN jsonb_build_object('success', true, 'idempotent', true);
  END IF;

  SELECT * INTO v_user FROM users WHERE id = p_user_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'User not found'; END IF;
  IF v_user.is_suspended THEN RAISE EXCEPTION 'Account suspended'; END IF;
  IF v_user.exploit_flagged THEN RAISE EXCEPTION 'Account flagged for review'; END IF;

  SELECT * INTO v_wallet FROM wallets WHERE user_id = p_user_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Wallet not found'; END IF;

  SELECT * INTO v_match FROM matches WHERE id = p_match_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Match not found'; END IF;
  IF v_match.status NOT IN ('upcoming', 'live') THEN
    RAISE EXCEPTION 'Match is not open for betting';
  END IF;

  IF EXISTS (
    SELECT 1 FROM bets
    WHERE user_id = p_user_id AND match_id = p_match_id
      AND league_id = p_league_id AND status != 'canceled'
  ) THEN
    RAISE EXCEPTION 'You already have an active bet on this match';
  END IF;

  IF p_multiplier NOT IN (1.5, 2.0) THEN
    SELECT COUNT(*) > 0 INTO v_has_unlock
    FROM multiplier_unlocks
    WHERE user_id = p_user_id AND multiplier = v_multiplier_str AND is_consumed = false;
    IF NOT v_has_unlock THEN
      RAISE EXCEPTION 'Multiplier %sx not unlocked', p_multiplier;
    END IF;
  END IF;

  SELECT matches_remaining INTO v_cooldown_rem
  FROM cooldowns WHERE user_id = p_user_id AND multiplier = v_multiplier_str;
  IF v_cooldown_rem IS NOT NULL AND v_cooldown_rem > 0 THEN
    RAISE EXCEPTION 'Multiplier on cooldown: % match(es) remaining', v_cooldown_rem;
  END IF;

  IF p_multiplier = 5 THEN
    SELECT COUNT(*) INTO v_active_count FROM bets
    WHERE user_id = p_user_id AND multiplier = 5 AND status = 'pending';
    IF v_active_count >= (get_config_value('max_active_5x_bets'))::INTEGER THEN
      RAISE EXCEPTION 'Maximum active 5x bets reached';
    END IF;
  ELSIF p_multiplier = 4 THEN
    SELECT COUNT(*) INTO v_active_count FROM bets
    WHERE user_id = p_user_id AND multiplier = 4 AND status = 'pending';
    IF v_active_count >= (get_config_value('max_active_4x_bets'))::INTEGER THEN
      RAISE EXCEPTION 'Maximum active 4x bets reached';
    END IF;
  END IF;

  v_penalty_pct := CASE
    WHEN p_multiplier = 1.5 THEN 0
    WHEN p_multiplier = 2.0 THEN (get_config_value('penalty_2x'))::INTEGER
    WHEN p_multiplier = 3.0 THEN (get_config_value('penalty_3x'))::INTEGER
    WHEN p_multiplier = 4.0 THEN (get_config_value('penalty_4x'))::INTEGER
    WHEN p_multiplier = 5.0 THEN (get_config_value('penalty_5x'))::INTEGER
    ELSE 0
  END;

  v_locked_amount := p_bet_amount + (p_bet_amount * v_penalty_pct / 100.0);
  v_potential_win := p_bet_amount * p_multiplier;

  v_max_bet_pct := (get_config_value('max_bet_pct'))::NUMERIC;
  v_max_bet     := FLOOR(v_wallet.available_balance * v_max_bet_pct / 100.0);
  SELECT max_bet INTO v_league_max_bet FROM leagues WHERE id = p_league_id;
  IF v_league_max_bet IS NOT NULL THEN
    v_max_bet := LEAST(v_max_bet, v_league_max_bet);
  END IF;
  IF p_bet_amount > v_max_bet THEN
    RAISE EXCEPTION 'Bet exceeds maximum allowed: ₹%', v_max_bet;
  END IF;

  v_min_wallet := CASE
    WHEN p_multiplier = 3 THEN (get_config_value('min_wallet_3x'))::NUMERIC
    WHEN p_multiplier = 4 THEN (get_config_value('min_wallet_4x'))::NUMERIC
    WHEN p_multiplier = 5 THEN (get_config_value('min_wallet_5x'))::NUMERIC
    ELSE 0
  END;
  IF v_wallet.available_balance < v_min_wallet THEN
    RAISE EXCEPTION 'Minimum balance of ₹% required for %sx bets', v_min_wallet, p_multiplier;
  END IF;

  IF v_wallet.available_balance < v_locked_amount THEN
    RAISE EXCEPTION 'Insufficient balance. Need ₹% (bet + penalty reserve)', v_locked_amount;
  END IF;

  UPDATE wallets SET
    available_balance = available_balance - v_locked_amount,
    locked_balance    = locked_balance    + v_locked_amount,
    updated_at        = now()
  WHERE user_id = p_user_id;

  INSERT INTO bets (
    user_id, league_id, match_id, bet_team, multiplier,
    bet_amount, locked_amount, penalty_pct, potential_win, idempotency_key
  ) VALUES (
    p_user_id, p_league_id, p_match_id, p_bet_team, p_multiplier,
    p_bet_amount, v_locked_amount, v_penalty_pct, v_potential_win, p_idempotency_key
  ) RETURNING id INTO v_bet_id;

  INSERT INTO transactions (user_id, type, amount, balance_before, balance_after, ref_id, ref_type, note)
  VALUES (
    p_user_id, 'bet_lock', v_locked_amount,
    v_wallet.available_balance,
    v_wallet.available_balance - v_locked_amount,
    v_bet_id, 'bet',
    format('Locked ₹%s for %sx bet', v_locked_amount, p_multiplier)
  );

  UPDATE users SET
    last_bet_at = now(),
    ip_addresses = array_append(ip_addresses, p_ip_address)
  WHERE id = p_user_id;

  RETURN jsonb_build_object(
    'success',       true,
    'bet_id',        v_bet_id,
    'locked_amount', v_locked_amount,
    'potential_win', v_potential_win,
    'penalty_pct',   v_penalty_pct
  );
END;
$$;

-- ============================================================
-- update_streak_on_win RPC
-- ============================================================

CREATE OR REPLACE FUNCTION update_streak_on_win(
  p_user_id    UUID,
  p_multiplier TEXT,
  p_match_id   UUID
)
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_streak       INTEGER;
  v_thresh_3x    INTEGER;
  v_thresh_4x    INTEGER;
  v_thresh_5x    INTEGER;
  v_unlock_3x    JSONB;
  v_unlock_4x    JSONB;
  v_unlock_5x    JSONB;
BEGIN
  INSERT INTO streaks (user_id, multiplier_tier, current_streak, last_match_id)
  VALUES (p_user_id, p_multiplier, 1, p_match_id)
  ON CONFLICT (user_id, multiplier_tier) DO UPDATE
    SET current_streak = streaks.current_streak + 1,
        last_match_id  = p_match_id,
        last_updated   = now()
  RETURNING current_streak INTO v_streak;

  v_unlock_3x := get_config_value('streak_unlock_3x');
  v_unlock_4x := get_config_value('streak_unlock_4x');
  v_unlock_5x := get_config_value('streak_unlock_5x');

  v_thresh_3x := (v_unlock_3x->>p_multiplier)::INTEGER;
  IF v_thresh_3x IS NOT NULL AND v_streak >= v_thresh_3x THEN
    INSERT INTO multiplier_unlocks (user_id, multiplier, unlock_source)
    VALUES (p_user_id, '3', format('%sx×%s streak', p_multiplier, v_streak))
    ON CONFLICT (user_id, multiplier) DO UPDATE
      SET is_consumed = false, consumed_at = NULL, consumed_by_bet = NULL, unlocked_at = now()
      WHERE multiplier_unlocks.is_consumed = true;
  END IF;

  v_thresh_4x := (v_unlock_4x->>p_multiplier)::INTEGER;
  IF v_thresh_4x IS NOT NULL AND v_streak >= v_thresh_4x THEN
    INSERT INTO multiplier_unlocks (user_id, multiplier, unlock_source)
    VALUES (p_user_id, '4', format('%sx×%s streak', p_multiplier, v_streak))
    ON CONFLICT (user_id, multiplier) DO UPDATE
      SET is_consumed = false, consumed_at = NULL, consumed_by_bet = NULL, unlocked_at = now()
      WHERE multiplier_unlocks.is_consumed = true;
  END IF;

  v_thresh_5x := (v_unlock_5x->>p_multiplier)::INTEGER;
  IF v_thresh_5x IS NOT NULL AND v_streak >= v_thresh_5x THEN
    INSERT INTO multiplier_unlocks (user_id, multiplier, unlock_source)
    VALUES (p_user_id, '5', format('%sx×%s streak', p_multiplier, v_streak))
    ON CONFLICT (user_id, multiplier) DO UPDATE
      SET is_consumed = false, consumed_at = NULL, consumed_by_bet = NULL, unlocked_at = now()
      WHERE multiplier_unlocks.is_consumed = true;
  END IF;
END;
$$;

-- ============================================================
-- settle_match RPC
-- ============================================================

CREATE OR REPLACE FUNCTION settle_match(
  p_match_id      UUID,
  p_result        TEXT,
  p_winning_team  TEXT,
  p_admin_id      UUID,
  p_settlement_id TEXT
)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_match     matches%ROWTYPE;
  v_bet       RECORD;
  v_wallet    wallets%ROWTYPE;
  v_win_amt   NUMERIC;
  v_settled   INTEGER := 0;
  v_refunded  INTEGER := 0;
  v_is_void   BOOLEAN;
BEGIN
  SELECT * INTO v_match FROM matches WHERE id = p_match_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Match not found'; END IF;

  IF v_match.settlement_id = p_settlement_id THEN
    RETURN jsonb_build_object('success', true, 'idempotent', true);
  END IF;

  IF v_match.status = 'completed' THEN
    RAISE EXCEPTION 'Match already settled';
  END IF;

  v_is_void := p_result IN ('void', 'no_result');

  UPDATE matches SET
    status        = CASE WHEN v_is_void THEN 'canceled'::match_status ELSE 'completed'::match_status END,
    result        = p_result::match_result_type,
    winning_team  = p_winning_team,
    settled_at    = now(),
    settlement_id = p_settlement_id
  WHERE id = p_match_id;

  FOR v_bet IN
    SELECT b.* FROM bets b WHERE b.match_id = p_match_id AND b.status = 'pending'
  LOOP
    SELECT * INTO v_wallet FROM wallets WHERE user_id = v_bet.user_id FOR UPDATE;

    IF v_is_void THEN
      UPDATE wallets SET
        available_balance = available_balance + v_bet.locked_amount,
        locked_balance    = locked_balance    - v_bet.locked_amount,
        updated_at        = now()
      WHERE user_id = v_bet.user_id;

      UPDATE bets SET status = 'refunded', credits_won = v_bet.bet_amount,
        settlement_id = p_settlement_id, settled_at = now()
      WHERE id = v_bet.id;

      INSERT INTO transactions (user_id, type, amount, balance_before, balance_after, ref_id, ref_type, note)
      VALUES (v_bet.user_id, 'refund', v_bet.locked_amount,
        v_wallet.available_balance, v_wallet.available_balance + v_bet.locked_amount,
        v_bet.id, 'bet', 'Match voided — full refund');

      UPDATE multiplier_unlocks SET is_consumed = false, consumed_at = NULL, consumed_by_bet = NULL
      WHERE user_id = v_bet.user_id AND consumed_by_bet = v_bet.id;

      UPDATE streaks SET current_streak = 0, last_updated = now()
      WHERE user_id = v_bet.user_id;

      v_refunded := v_refunded + 1;

    ELSIF v_bet.bet_team = p_winning_team THEN
      v_win_amt := v_bet.potential_win;

      UPDATE wallets SET
        available_balance = available_balance + v_bet.locked_amount + v_win_amt,
        locked_balance    = locked_balance    - v_bet.locked_amount,
        updated_at        = now()
      WHERE user_id = v_bet.user_id;

      UPDATE bets SET status = 'won', credits_won = v_win_amt,
        settlement_id = p_settlement_id, settled_at = now()
      WHERE id = v_bet.id;

      INSERT INTO transactions (user_id, type, amount, balance_before, balance_after, ref_id, ref_type, note)
      VALUES (v_bet.user_id, 'bet_win', v_bet.locked_amount + v_win_amt,
        v_wallet.available_balance, v_wallet.available_balance + v_bet.locked_amount + v_win_amt,
        v_bet.id, 'bet', format('Won — ₹%s at %sx', v_win_amt, v_bet.multiplier));

      PERFORM update_streak_on_win(v_bet.user_id, v_bet.multiplier::TEXT, p_match_id);

      IF v_bet.multiplier IN (3, 4, 5) THEN
        UPDATE multiplier_unlocks SET is_consumed = true, consumed_at = now(), consumed_by_bet = v_bet.id
        WHERE user_id = v_bet.user_id AND multiplier = v_bet.multiplier::TEXT AND is_consumed = false;

        IF v_bet.multiplier = 4 THEN
          INSERT INTO cooldowns (user_id, multiplier, matches_remaining, triggered_by)
          VALUES (v_bet.user_id, '4', (get_config_value('cooldown_4x_matches'))::INTEGER, v_bet.id)
          ON CONFLICT (user_id, multiplier) DO UPDATE
            SET matches_remaining = (get_config_value('cooldown_4x_matches'))::INTEGER;
        ELSIF v_bet.multiplier = 5 THEN
          INSERT INTO cooldowns (user_id, multiplier, matches_remaining, triggered_by)
          VALUES (v_bet.user_id, '5', (get_config_value('cooldown_5x_matches'))::INTEGER, v_bet.id)
          ON CONFLICT (user_id, multiplier) DO UPDATE
            SET matches_remaining = (get_config_value('cooldown_5x_matches'))::INTEGER;
        END IF;
      END IF;

      UPDATE users SET completed_bets = completed_bets + 1 WHERE id = v_bet.user_id;
      v_settled := v_settled + 1;

    ELSE
      UPDATE wallets SET
        locked_balance = locked_balance - v_bet.locked_amount,
        updated_at     = now()
      WHERE user_id = v_bet.user_id;

      UPDATE bets SET status = 'lost', credits_won = 0,
        settlement_id = p_settlement_id, settled_at = now()
      WHERE id = v_bet.id;

      INSERT INTO transactions (user_id, type, amount, balance_before, balance_after, ref_id, ref_type, note)
      VALUES (v_bet.user_id, 'bet_loss', v_bet.locked_amount,
        v_wallet.available_balance, v_wallet.available_balance,
        v_bet.id, 'bet', format('Lost — ₹%s at %sx', v_bet.locked_amount, v_bet.multiplier));

      UPDATE streaks SET current_streak = 0, last_updated = now()
      WHERE user_id = v_bet.user_id AND multiplier_tier = v_bet.multiplier::TEXT;

      IF v_bet.multiplier IN (3, 4, 5) THEN
        UPDATE multiplier_unlocks SET is_consumed = true, consumed_at = now(), consumed_by_bet = v_bet.id
        WHERE user_id = v_bet.user_id AND multiplier = v_bet.multiplier::TEXT AND is_consumed = false;

        IF v_bet.multiplier = 4 THEN
          INSERT INTO cooldowns (user_id, multiplier, matches_remaining, triggered_by)
          VALUES (v_bet.user_id, '4', (get_config_value('cooldown_4x_matches'))::INTEGER, v_bet.id)
          ON CONFLICT (user_id, multiplier) DO UPDATE
            SET matches_remaining = (get_config_value('cooldown_4x_matches'))::INTEGER;
        ELSIF v_bet.multiplier = 5 THEN
          INSERT INTO cooldowns (user_id, multiplier, matches_remaining, triggered_by)
          VALUES (v_bet.user_id, '5', (get_config_value('cooldown_5x_matches'))::INTEGER, v_bet.id)
          ON CONFLICT (user_id, multiplier) DO UPDATE
            SET matches_remaining = (get_config_value('cooldown_5x_matches'))::INTEGER;
        END IF;
      END IF;

      UPDATE users SET completed_bets = completed_bets + 1 WHERE id = v_bet.user_id;
      v_settled := v_settled + 1;
    END IF;
  END LOOP;

  UPDATE cooldowns SET matches_remaining = GREATEST(0, matches_remaining - 1)
  WHERE matches_remaining > 0;

  INSERT INTO admin_logs (admin_id, action, target_type, target_id, new_value)
  VALUES (p_admin_id, 'settle_match', 'match', p_match_id,
    jsonb_build_object('result', p_result, 'settled', v_settled, 'refunded', v_refunded));

  RETURN jsonb_build_object('success', true, 'settled', v_settled, 'refunded', v_refunded);
END;
$$;

-- ============================================================
-- process_donation RPC
-- ============================================================

CREATE OR REPLACE FUNCTION process_donation(
  p_sender_id   UUID,
  p_receiver_id UUID,
  p_amount      NUMERIC,
  p_note        TEXT,
  p_sender_ip   TEXT DEFAULT NULL
)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_sw         wallets%ROWTYPE;
  v_rw         wallets%ROWTYPE;
  v_su         users%ROWTYPE;
  v_donation_id UUID;
  v_today_count INTEGER;
  v_today_amt   NUMERIC;
  v_last_don    TIMESTAMPTZ;
  v_fraud_score INTEGER := 0;
BEGIN
  IF p_sender_id = p_receiver_id THEN RAISE EXCEPTION 'Cannot donate to yourself'; END IF;

  SELECT * INTO v_su FROM users WHERE id = p_sender_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Sender not found'; END IF;
  IF v_su.is_suspended THEN RAISE EXCEPTION 'Account suspended'; END IF;

  SELECT * INTO v_sw FROM wallets WHERE user_id = p_sender_id FOR UPDATE;
  SELECT * INTO v_rw FROM wallets WHERE user_id = p_receiver_id FOR UPDATE;

  IF v_su.created_at > now() - ((get_config_value('min_account_age_days'))::INTEGER || ' days')::INTERVAL THEN
    RAISE EXCEPTION 'Account must be older to donate';
  END IF;

  IF v_su.completed_bets < (get_config_value('min_completed_bets'))::INTEGER THEN
    RAISE EXCEPTION 'Complete more bets before donating';
  END IF;

  SELECT COUNT(*), COALESCE(SUM(amount), 0) INTO v_today_count, v_today_amt
  FROM donations WHERE sender_id = p_sender_id AND created_at > now() - INTERVAL '24 hours';

  IF v_today_count >= (get_config_value('donation_daily_max'))::INTEGER THEN
    RAISE EXCEPTION 'Daily donation limit reached';
  END IF;
  IF v_today_amt + p_amount > (get_config_value('donation_daily_amount'))::NUMERIC THEN
    RAISE EXCEPTION 'Daily donation amount limit reached';
  END IF;

  SELECT created_at INTO v_last_don FROM donations WHERE sender_id = p_sender_id
  ORDER BY created_at DESC LIMIT 1;
  IF FOUND AND v_last_don > now() - ((get_config_value('donation_cooldown_min'))::INTEGER || ' minutes')::INTERVAL THEN
    RAISE EXCEPTION 'Cooldown active between donations';
  END IF;

  IF v_rw.week_received_reset_at < now() - INTERVAL '7 days' THEN
    UPDATE wallets SET week_received = 0, week_received_reset_at = now() WHERE user_id = p_receiver_id;
    v_rw.week_received := 0;
  END IF;

  IF v_rw.week_received + p_amount > (get_config_value('donation_weekly_cap'))::NUMERIC THEN
    RAISE EXCEPTION 'Receiver weekly cap reached';
  END IF;

  IF p_amount > v_sw.available_balance THEN
    RAISE EXCEPTION 'Insufficient available balance';
  END IF;

  IF EXISTS (SELECT 1 FROM donations WHERE sender_id = p_receiver_id AND receiver_id = p_sender_id
             AND created_at > now() - INTERVAL '24 hours') THEN
    v_fraud_score := v_fraud_score + 50;
    INSERT INTO fraud_flags (user_id, flag_type, details)
    VALUES (p_sender_id, 'circular_transfer',
      jsonb_build_object('with_user', p_receiver_id, 'amount', p_amount));
  END IF;

  IF v_fraud_score > 0 THEN
    UPDATE users SET fraud_score = fraud_score + v_fraud_score WHERE id = p_sender_id;
    IF (SELECT fraud_score FROM users WHERE id = p_sender_id) >= 100 THEN
      UPDATE users SET is_suspended = true, suspend_reason = 'Auto-suspended: fraud score'
      WHERE id = p_sender_id;
      RAISE EXCEPTION 'Account suspended for suspicious activity';
    END IF;
  END IF;

  UPDATE wallets SET available_balance = available_balance - p_amount,
    total_donated = total_donated + p_amount, updated_at = now()
  WHERE user_id = p_sender_id;

  UPDATE wallets SET available_balance = available_balance + p_amount,
    total_received = total_received + p_amount,
    week_received = week_received + p_amount, updated_at = now()
  WHERE user_id = p_receiver_id;

  INSERT INTO donations (sender_id, receiver_id, amount, note, sender_ip)
  VALUES (p_sender_id, p_receiver_id, p_amount, p_note, p_sender_ip)
  RETURNING id INTO v_donation_id;

  INSERT INTO transactions (user_id, type, amount, balance_before, balance_after, ref_id, ref_type, note)
  VALUES
    (p_sender_id,   'donation_sent',     p_amount, v_sw.available_balance, v_sw.available_balance - p_amount, v_donation_id, 'donation', 'Donation sent'),
    (p_receiver_id, 'donation_received', p_amount, v_rw.available_balance, v_rw.available_balance + p_amount, v_donation_id, 'donation', 'Donation received');

  RETURN jsonb_build_object('success', true, 'donation_id', v_donation_id);
END;
$$;

-- ============================================================
-- admin_adjust_wallet RPC
-- ============================================================

CREATE OR REPLACE FUNCTION admin_adjust_wallet(
  p_admin_id  UUID,
  p_user_id   UUID,
  p_amount    NUMERIC,
  p_type      TEXT,
  p_reason    TEXT,
  p_ip        TEXT DEFAULT NULL
)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_wallet  wallets%ROWTYPE;
  v_new_bal NUMERIC;
BEGIN
  SELECT * INTO v_wallet FROM wallets WHERE user_id = p_user_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Wallet not found'; END IF;

  IF p_type = 'credit' THEN
    v_new_bal := v_wallet.available_balance + p_amount;
    UPDATE wallets SET available_balance = v_new_bal, updated_at = now() WHERE user_id = p_user_id;
    INSERT INTO transactions (user_id, type, amount, balance_before, balance_after, note)
    VALUES (p_user_id, 'admin_credit', p_amount, v_wallet.available_balance, v_new_bal, p_reason);
  ELSE
    IF v_wallet.available_balance < p_amount THEN RAISE EXCEPTION 'Insufficient balance'; END IF;
    v_new_bal := v_wallet.available_balance - p_amount;
    UPDATE wallets SET available_balance = v_new_bal, updated_at = now() WHERE user_id = p_user_id;
    INSERT INTO transactions (user_id, type, amount, balance_before, balance_after, note)
    VALUES (p_user_id, 'admin_debit', p_amount, v_wallet.available_balance, v_new_bal, p_reason);
  END IF;

  INSERT INTO admin_logs (admin_id, action, target_type, target_id, old_value, new_value, ip_address)
  VALUES (p_admin_id, 'wallet_' || p_type, 'user', p_user_id,
    jsonb_build_object('balance', v_wallet.available_balance),
    jsonb_build_object('balance', v_new_bal, 'reason', p_reason), p_ip);

  RETURN jsonb_build_object('success', true, 'new_balance', v_new_bal);
END;
$$;

-- ============================================================
-- apply_inactivity_penalties RPC
-- ============================================================

CREATE OR REPLACE FUNCTION apply_inactivity_penalties()
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_user       RECORD;
  v_inact_days INTEGER;
  v_decay_pct  NUMERIC;
  v_decay_amt  NUMERIC;
  v_threshold  INTEGER;
  v_processed  INTEGER := 0;
BEGIN
  v_threshold := (get_config_value('inactivity_days'))::INTEGER;
  v_decay_pct := (get_config_value('wallet_decay_pct'))::NUMERIC;

  FOR v_user IN
    SELECT u.id, u.last_bet_at, w.available_balance
    FROM users u JOIN wallets w ON w.user_id = u.id
    WHERE u.last_bet_at IS NOT NULL
      AND u.last_bet_at < now() - (v_threshold || ' days')::INTERVAL
      AND w.available_balance > 0
  LOOP
    v_inact_days := EXTRACT(DAY FROM now() - v_user.last_bet_at)::INTEGER;
    v_decay_amt  := GREATEST(0, FLOOR(v_user.available_balance * v_decay_pct / 100.0));

    IF v_decay_amt > 0 THEN
      UPDATE wallets SET
        available_balance = GREATEST(0, available_balance - v_decay_amt),
        updated_at = now()
      WHERE user_id = v_user.id;

      INSERT INTO transactions (user_id, type, amount, balance_before, balance_after, note)
      VALUES (v_user.id, 'wallet_decay', v_decay_amt,
        v_user.available_balance, GREATEST(0, v_user.available_balance - v_decay_amt),
        format('%s days inactive — decay applied', v_inact_days));

      UPDATE streaks SET current_streak = GREATEST(0, current_streak - 1), last_updated = now()
      WHERE user_id = v_user.id;

      INSERT INTO inactivity_records (user_id, days_inactive, decay_applied, streak_reduced)
      VALUES (v_user.id, v_inact_days, v_decay_amt, true);
    END IF;

    v_processed := v_processed + 1;
  END LOOP;

  RETURN jsonb_build_object('success', true, 'processed', v_processed);
END;
$$;

-- ============================================================
-- get_user_state RPC
-- ============================================================

CREATE OR REPLACE FUNCTION get_user_state(p_user_id UUID)
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER AS $$
DECLARE
  v_wallet    wallets%ROWTYPE;
  v_user      users%ROWTYPE;
  v_streaks   JSONB;
  v_unlocks   JSONB;
  v_cooldowns JSONB;
  v_bets      JSONB;
BEGIN
  SELECT * INTO v_user FROM users WHERE id = p_user_id;
  SELECT * INTO v_wallet FROM wallets WHERE user_id = p_user_id;

  SELECT COALESCE(jsonb_object_agg(multiplier_tier, current_streak), '{}')
  INTO v_streaks FROM streaks WHERE user_id = p_user_id;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'multiplier', multiplier, 'is_consumed', is_consumed,
    'unlocked_at', unlocked_at, 'unlock_source', unlock_source
  )), '[]') INTO v_unlocks
  FROM multiplier_unlocks WHERE user_id = p_user_id;

  SELECT COALESCE(jsonb_object_agg(multiplier, matches_remaining), '{}')
  INTO v_cooldowns FROM cooldowns WHERE user_id = p_user_id AND matches_remaining > 0;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'id', id, 'match_id', match_id, 'multiplier', multiplier,
    'bet_amount', bet_amount, 'locked_amount', locked_amount,
    'potential_win', potential_win, 'status', status, 'credits_won', credits_won
  ) ORDER BY created_at DESC), '[]') INTO v_bets
  FROM bets WHERE user_id = p_user_id AND created_at > now() - INTERVAL '30 days';

  RETURN jsonb_build_object(
    'user', row_to_json(v_user),
    'wallet', row_to_json(v_wallet),
    'streaks', v_streaks,
    'unlocks', v_unlocks,
    'cooldowns', v_cooldowns,
    'recent_bets', v_bets
  );
END;
$$;

-- ============================================================
-- TRIGGER: auto-create wallet on user insert
-- ============================================================

CREATE OR REPLACE FUNCTION handle_new_user()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  INSERT INTO wallets (user_id, available_balance)
  VALUES (NEW.id, 1000)
  ON CONFLICT (user_id) DO NOTHING;
  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_create_wallet
  AFTER INSERT ON users
  FOR EACH ROW EXECUTE FUNCTION handle_new_user();

-- ============================================================
-- ROW LEVEL SECURITY
-- ============================================================

ALTER TABLE users              ENABLE ROW LEVEL SECURITY;
ALTER TABLE wallets            ENABLE ROW LEVEL SECURITY;
ALTER TABLE bets               ENABLE ROW LEVEL SECURITY;
ALTER TABLE transactions       ENABLE ROW LEVEL SECURITY;
ALTER TABLE streaks            ENABLE ROW LEVEL SECURITY;
ALTER TABLE multiplier_unlocks ENABLE ROW LEVEL SECURITY;
ALTER TABLE cooldowns          ENABLE ROW LEVEL SECURITY;
ALTER TABLE donations          ENABLE ROW LEVEL SECURITY;
ALTER TABLE fraud_flags        ENABLE ROW LEVEL SECURITY;
ALTER TABLE admin_logs         ENABLE ROW LEVEL SECURITY;
ALTER TABLE leagues            ENABLE ROW LEVEL SECURITY;
ALTER TABLE league_members     ENABLE ROW LEVEL SECURITY;
ALTER TABLE matches            ENABLE ROW LEVEL SECURITY;
ALTER TABLE system_config      ENABLE ROW LEVEL SECURITY;

-- Users
CREATE POLICY p_users_self  ON users FOR SELECT USING (auth.uid() = id);
CREATE POLICY p_users_admin ON users FOR ALL USING (
  EXISTS (SELECT 1 FROM users u WHERE u.id = auth.uid() AND u.role IN ('admin','superadmin'))
);
-- Wallets
CREATE POLICY p_wallets_self  ON wallets FOR SELECT USING (auth.uid() = user_id);
CREATE POLICY p_wallets_admin ON wallets FOR ALL USING (
  EXISTS (SELECT 1 FROM users u WHERE u.id = auth.uid() AND u.role IN ('admin','superadmin'))
);
-- Bets
CREATE POLICY p_bets_self  ON bets FOR SELECT USING (auth.uid() = user_id);
CREATE POLICY p_bets_league ON bets FOR SELECT USING (
  EXISTS (SELECT 1 FROM league_members WHERE league_id = bets.league_id AND user_id = auth.uid())
);
CREATE POLICY p_bets_admin ON bets FOR ALL USING (
  EXISTS (SELECT 1 FROM users u WHERE u.id = auth.uid() AND u.role IN ('admin','superadmin'))
);
-- Transactions
CREATE POLICY p_txn_self ON transactions FOR SELECT USING (auth.uid() = user_id);
-- Streaks/unlocks/cooldowns
CREATE POLICY p_streaks_self   ON streaks            FOR SELECT USING (auth.uid() = user_id);
CREATE POLICY p_unlocks_self   ON multiplier_unlocks FOR SELECT USING (auth.uid() = user_id);
CREATE POLICY p_cooldowns_self ON cooldowns          FOR SELECT USING (auth.uid() = user_id);
-- Donations
CREATE POLICY p_donations_self ON donations FOR SELECT USING (auth.uid() = sender_id OR auth.uid() = receiver_id);
-- Admin tables
CREATE POLICY p_logs_admin  ON admin_logs  FOR SELECT USING (
  EXISTS (SELECT 1 FROM users u WHERE u.id = auth.uid() AND u.role IN ('admin','superadmin'))
);
CREATE POLICY p_fraud_admin ON fraud_flags FOR ALL USING (
  EXISTS (SELECT 1 FROM users u WHERE u.id = auth.uid() AND u.role IN ('admin','superadmin'))
);
-- Leagues
CREATE POLICY p_leagues_read  ON leagues        FOR SELECT USING (auth.uid() IS NOT NULL);
CREATE POLICY p_leagues_admin ON leagues        FOR ALL    USING (
  EXISTS (SELECT 1 FROM users u WHERE u.id = auth.uid() AND u.role IN ('admin','superadmin'))
);
CREATE POLICY p_lm_read ON league_members FOR SELECT USING (
  auth.uid() = user_id OR
  EXISTS (SELECT 1 FROM users u WHERE u.id = auth.uid() AND u.role IN ('admin','superadmin'))
);
-- Matches
CREATE POLICY p_matches_read  ON matches FOR SELECT USING (auth.uid() IS NOT NULL);
CREATE POLICY p_matches_admin ON matches FOR ALL    USING (
  EXISTS (SELECT 1 FROM users u WHERE u.id = auth.uid() AND u.role IN ('admin','superadmin'))
);
-- Config
CREATE POLICY p_config_read  ON system_config FOR SELECT USING (auth.uid() IS NOT NULL);
CREATE POLICY p_config_admin ON system_config FOR ALL    USING (
  EXISTS (SELECT 1 FROM users u WHERE u.id = auth.uid() AND u.role IN ('admin','superadmin'))
);

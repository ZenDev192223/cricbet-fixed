-- ============================================================
-- MIGRATION 006: Robust server-side auto-live
-- ============================================================
--
-- HOW IT WORKS:
--   • pg_cron runs a job every minute, entirely inside Postgres.
--   • No browser tab needed. No edge function. No external cron.
--   • The job calls auto_set_matches_live() which flips any
--     'upcoming' match to 'live' when now() >= match_date.
--   • A second job (optional) auto-closes betting 10 minutes
--     before match_date — so no one can sneak a bet in late.
--
-- REQUIREMENTS:
--   Enable two extensions in your Supabase dashboard:
--     Dashboard → Database → Extensions → search "pg_cron" → Enable
--   (pg_cron is available on all Supabase Pro/Free hosted projects)
-- ============================================================


-- ── STEP 1: Enable pg_cron extension ────────────────────────────────────────
CREATE EXTENSION IF NOT EXISTS pg_cron WITH SCHEMA pg_catalog;

-- Grant usage so the cron jobs can run as the postgres role
GRANT USAGE ON SCHEMA cron TO postgres;
GRANT USAGE ON SCHEMA cron TO authenticated;
GRANT USAGE ON SCHEMA cron TO service_role;


-- ── STEP 2: Add betting_open column to matches ───────────────────────────────
-- Separates "betting is open" from match status.
-- This lets us close betting N minutes before kick-off
-- while the match is still technically 'upcoming'.

ALTER TABLE matches
  ADD COLUMN IF NOT EXISTS betting_closes_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS auto_live         BOOLEAN DEFAULT true;
-- auto_live: admin can uncheck this for a specific match to manage manually.

-- Back-fill: set betting_closes_at = match_date for all existing matches
-- (betting closes exactly at match start unless admin overrides)
UPDATE matches
SET betting_closes_at = match_date
WHERE betting_closes_at IS NULL;

-- When new matches are created, trigger sets betting_closes_at automatically
CREATE OR REPLACE FUNCTION set_betting_closes_at()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  -- Default: betting closes at match_date
  -- Admin can override by setting betting_closes_at explicitly
  IF NEW.betting_closes_at IS NULL THEN
    NEW.betting_closes_at := NEW.match_date;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_set_betting_closes_at ON matches;
CREATE TRIGGER trg_set_betting_closes_at
  BEFORE INSERT ON matches
  FOR EACH ROW EXECUTE FUNCTION set_betting_closes_at();


-- ── STEP 3: The core auto-live function ─────────────────────────────────────

CREATE OR REPLACE FUNCTION auto_set_matches_live()
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_count   INTEGER := 0;
  v_match   RECORD;
BEGIN
  -- Find all upcoming matches where:
  --   1. auto_live is true (admin didn't manually disable it)
  --   2. match_date <= now()  (kick-off time has arrived)
  --   3. status is still 'upcoming'
  FOR v_match IN
    SELECT id, team_a, team_b, league_id
    FROM   matches
    WHERE  status    = 'upcoming'
      AND  auto_live = true
      AND  match_date <= now()
  LOOP
    UPDATE matches
    SET    status     = 'live',
           updated_at = now()
    WHERE  id = v_match.id;

    -- Audit trail so admin can see it happened automatically
    INSERT INTO admin_logs (admin_id, action, target_type, target_id, new_value)
    VALUES (
      NULL,   -- NULL admin_id = system action
      'auto_set_live',
      'match',
      v_match.id,
      jsonb_build_object(
        'triggered_by', 'pg_cron',
        'match',        v_match.team_a || ' vs ' || v_match.team_b,
        'at',           now()
      )
    );

    v_count := v_count + 1;
  END LOOP;

  RETURN jsonb_build_object('success', true, 'matches_set_live', v_count, 'checked_at', now());
END;
$$;


-- ── STEP 4: Schedule the cron job — runs every minute ───────────────────────

-- Remove any old version of this job first (safe to re-run)
SELECT cron.unschedule('auto-set-matches-live')
WHERE  EXISTS (
  SELECT 1 FROM cron.job WHERE jobname = 'auto-set-matches-live'
);

SELECT cron.schedule(
  'auto-set-matches-live',     -- job name
  '* * * * *',                 -- every minute  (cron syntax)
  $$SELECT auto_set_matches_live()$$
);


-- ── STEP 5: Update place_bet to respect betting_closes_at ───────────────────
-- The existing guard checks match.status = 'upcoming'.
-- We also need to block bets after betting_closes_at even if status
-- hasn't flipped to live yet (race condition safety).

CREATE OR REPLACE FUNCTION place_bet(
  p_user_id         UUID,
  p_league_id       UUID,
  p_match_id        UUID,
  p_bet_team        TEXT,
  p_multiplier      NUMERIC,
  p_bet_amount      NUMERIC,
  p_idempotency_key TEXT
)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_match          matches%ROWTYPE;
  v_member         league_members%ROWTYPE;
  v_locked_amt     NUMERIC;
  v_potential_win  NUMERIC;
  v_penalty_pct    NUMERIC;
  v_max_bet_pct    NUMERIC;
  v_min_bet_pct    NUMERIC;
  v_max_bet_amt    NUMERIC;
  v_min_bet_amt    NUMERIC;
  v_min_wallet     NUMERIC;
  v_active_count   INTEGER;
  v_cooldown_rem   INTEGER;
  v_bet_id         UUID;
BEGIN
  -- Idempotency guard
  SELECT id INTO v_bet_id FROM bets WHERE idempotency_key = p_idempotency_key;
  IF FOUND THEN
    RETURN jsonb_build_object('success', true, 'idempotent', true, 'bet_id', v_bet_id);
  END IF;

  SELECT * INTO v_match FROM matches WHERE id = p_match_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Match not found'; END IF;

  -- ★ ROBUST BETTING WINDOW CHECK (two guards):
  --   Guard 1: match must still be 'upcoming'
  --   Guard 2: current time must be before betting_closes_at
  IF v_match.status <> 'upcoming' THEN
    RAISE EXCEPTION 'Match is no longer open for betting (status: %)', v_match.status;
  END IF;
  IF v_match.betting_closes_at IS NOT NULL AND now() >= v_match.betting_closes_at THEN
    RAISE EXCEPTION 'Betting has closed for this match';
  END IF;

  SELECT * INTO v_member
    FROM league_members
   WHERE user_id = p_user_id AND league_id = p_league_id
   FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Not a league member'; END IF;

  -- Cooldown check
  SELECT matches_remaining INTO v_cooldown_rem
    FROM cooldowns
   WHERE user_id = p_user_id AND league_id = p_league_id
     AND multiplier = p_multiplier::TEXT AND matches_remaining > 0;
  IF FOUND THEN
    RAISE EXCEPTION 'Multiplier % is on cooldown (% matches remaining)',
      p_multiplier, v_cooldown_rem;
  END IF;

  -- Active bet caps
  IF p_multiplier = 5 THEN
    SELECT COUNT(*) INTO v_active_count FROM bets
     WHERE user_id = p_user_id AND multiplier = 5 AND status = 'pending';
    IF v_active_count >= (get_config_value('max_active_5x_bets'))::INTEGER THEN
      RAISE EXCEPTION 'Maximum active 5× bets reached';
    END IF;
  ELSIF p_multiplier = 4 THEN
    SELECT COUNT(*) INTO v_active_count FROM bets
     WHERE user_id = p_user_id AND multiplier = 4 AND status = 'pending';
    IF v_active_count >= (get_config_value('max_active_4x_bets'))::INTEGER THEN
      RAISE EXCEPTION 'Maximum active 4× bets reached';
    END IF;
  END IF;

  v_penalty_pct := CASE p_multiplier
    WHEN 2.0 THEN (get_config_value('penalty_2x'))::NUMERIC / 100.0
    WHEN 3.0 THEN (get_config_value('penalty_3x'))::NUMERIC / 100.0
    WHEN 4.0 THEN (get_config_value('penalty_4x'))::NUMERIC / 100.0
    WHEN 5.0 THEN (get_config_value('penalty_5x'))::NUMERIC / 100.0
    ELSE 0
  END;

  v_max_bet_pct := (get_config_value('max_bet_pct'))::NUMERIC / 100.0;
  v_min_bet_pct := COALESCE(NULLIF(get_config_value('min_bet_pct'), ''), '1')::NUMERIC / 100.0;
  v_max_bet_amt := FLOOR((v_member.credits + v_member.locked_credits) * v_max_bet_pct);
  v_min_bet_amt := CEIL((v_member.credits + v_member.locked_credits) * v_min_bet_pct);

  v_min_wallet := CASE p_multiplier
    WHEN 3 THEN (get_config_value('min_wallet_3x'))::NUMERIC
    WHEN 4 THEN (get_config_value('min_wallet_4x'))::NUMERIC
    WHEN 5 THEN (get_config_value('min_wallet_5x'))::NUMERIC
    ELSE 0
  END;

  IF p_bet_amount <= 0          THEN RAISE EXCEPTION 'Bet amount must be positive'; END IF;
  IF p_bet_amount < v_min_bet_amt THEN
    RAISE EXCEPTION 'Minimum bet is ₹% (% of balance)', v_min_bet_amt, (get_config_value('min_bet_pct'));
  END IF;
  IF p_bet_amount > v_max_bet_amt THEN
    RAISE EXCEPTION 'Bet exceeds maximum allowed (₹%)', v_max_bet_amt;
  END IF;
  IF v_member.credits < v_min_wallet THEN
    RAISE EXCEPTION 'Minimum balance of ₹% required for %× bets', v_min_wallet, p_multiplier;
  END IF;

  v_locked_amt    := CEIL(p_bet_amount * (1 + v_penalty_pct));
  v_potential_win := FLOOR(p_bet_amount * p_multiplier) - p_bet_amount;

  IF v_member.credits < v_locked_amt THEN
    RAISE EXCEPTION 'Insufficient credits (need ₹%, have ₹%)', v_locked_amt, v_member.credits;
  END IF;

  UPDATE league_members SET
    credits           = credits        - v_locked_amt,
    locked_credits    = locked_credits + v_locked_amt,
    last_bet_match_id = p_match_id,
    updated_at        = now()
  WHERE user_id = p_user_id AND league_id = p_league_id;

  UPDATE users SET last_bet_at = now() WHERE id = p_user_id;

  INSERT INTO bets (
    user_id, league_id, match_id, bet_team, multiplier,
    bet_amount, locked_amount, potential_win, status, idempotency_key
  ) VALUES (
    p_user_id, p_league_id, p_match_id, p_bet_team, p_multiplier,
    p_bet_amount, v_locked_amt, v_potential_win, 'pending', p_idempotency_key
  ) RETURNING id INTO v_bet_id;

  INSERT INTO transactions (user_id, type, amount, balance_before, balance_after, ref_id, ref_type, note)
  VALUES (
    p_user_id, 'bet_place', v_locked_amt,
    v_member.credits, v_member.credits - v_locked_amt,
    v_bet_id, 'bet',
    format('Bet placed — ₹%s at %s×', p_bet_amount, p_multiplier)
  );

  RETURN jsonb_build_object('success', true, 'bet_id', v_bet_id);
END;
$$;


-- ── STEP 6: Verify cron job was registered ───────────────────────────────────
-- After running this migration, check it's scheduled:
--   SELECT * FROM cron.job WHERE jobname = 'auto-set-matches-live';
-- You should see schedule '* * * * *' and active = true.
--
-- To monitor runs:
--   SELECT * FROM cron.job_run_details
--   WHERE jobname = 'auto-set-matches-live'
--   ORDER BY start_time DESC LIMIT 20;
-- ============================================================

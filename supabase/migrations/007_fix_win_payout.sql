-- ============================================================
-- MIGRATION 007: Fix win payout double-counting
-- ============================================================
-- BUG: potential_win was stored as bet_amount × multiplier (gross)
--      but settle_match credited locked_amount + potential_win,
--      which counted the original bet twice.
--
-- Example (₹1,000 bet at 2×, 30% penalty):
--   locked_amount  = ₹1,300
--   potential_win  = ₹2,000  ← was gross (wrong)
--   credited       = ₹1,300 + ₹2,000 = ₹3,300 → balance ₹7,660 (wrong)
--
-- Fix: potential_win = profit only = (bet × multiplier) - bet
--   potential_win  = ₹1,000  ← net profit only
--   credited       = ₹1,300 + ₹1,000 = ₹2,300 → balance ₹6,660 ✓
-- ============================================================


-- ── STEP 1: Fix place_bet — store profit-only in potential_win ───────────────

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
  SELECT id INTO v_bet_id FROM bets WHERE idempotency_key = p_idempotency_key;
  IF FOUND THEN
    RETURN jsonb_build_object('success', true, 'idempotent', true, 'bet_id', v_bet_id);
  END IF;

  SELECT * INTO v_match FROM matches WHERE id = p_match_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Match not found'; END IF;

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

  SELECT matches_remaining INTO v_cooldown_rem
    FROM cooldowns
   WHERE user_id = p_user_id AND league_id = p_league_id
     AND multiplier = p_multiplier::TEXT AND matches_remaining > 0;
  IF FOUND THEN
    RAISE EXCEPTION 'Multiplier % is on cooldown (% matches remaining)',
      p_multiplier, v_cooldown_rem;
  END IF;

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

  IF p_bet_amount <= 0             THEN RAISE EXCEPTION 'Bet amount must be positive'; END IF;
  IF p_bet_amount < v_min_bet_amt  THEN
    RAISE EXCEPTION 'Minimum bet is ₹% (% of balance)', v_min_bet_amt, (get_config_value('min_bet_pct'));
  END IF;
  IF p_bet_amount > v_max_bet_amt  THEN
    RAISE EXCEPTION 'Bet exceeds maximum allowed (₹%)', v_max_bet_amt;
  END IF;
  IF v_member.credits < v_min_wallet THEN
    RAISE EXCEPTION 'Minimum balance of ₹% required for %× bets', v_min_wallet, p_multiplier;
  END IF;

  v_locked_amt := CEIL(p_bet_amount * (1 + v_penalty_pct));

  -- ★ FIX: profit only — NOT gross return
  -- potential_win = what the user GAINS on top of getting their bet back
  -- = (bet × multiplier) - bet
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
    format('Bet placed — ₹%s at %s× (profit if win: ₹%s)', p_bet_amount, p_multiplier, v_potential_win)
  );

  RETURN jsonb_build_object('success', true, 'bet_id', v_bet_id);
END;
$$;


-- ── STEP 2: Correct existing pending bets that have wrong potential_win ───────
-- Fix any bets placed before this migration that used gross formula

UPDATE bets
SET potential_win = FLOOR(bet_amount * multiplier) - bet_amount
WHERE status = 'pending'
  AND potential_win = FLOOR(bet_amount * multiplier);  -- only fix the gross ones


-- ── STEP 3: Fix frontend calcWinReturn to show profit only ───────────────────
-- See constants.js fix below (separate file)
-- calcWinReturn should return: amount * multiplier - amount  (profit only)
-- NOT: amount * multiplier  (gross)

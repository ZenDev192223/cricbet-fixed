-- ============================================================
-- MIGRATION 002: League-Scoped Wallet Fix
--
-- Problem: Bets and donations used a global `wallets` table,
-- but the leaderboard used `league_members.credits`. These
-- were never in sync.
--
-- Fix: All betting, settlement, and donation flows now operate
-- on `league_members.credits` (+ a locked_credits column).
-- The global wallet is removed from all gameplay logic.
-- ============================================================

-- Step 1: Add locked_credits to league_members
ALTER TABLE league_members
  ADD COLUMN IF NOT EXISTS locked_credits NUMERIC(14,2) DEFAULT 0 CHECK (locked_credits >= 0);

-- Step 2: Initialise credits from starting_credits when joining a league
-- (The trigger below handles new joins; existing rows with 0 credits get seeded)
UPDATE league_members lm
SET credits = l.starting_credits
FROM leagues l
WHERE lm.league_id = l.id
  AND lm.credits = 0;

-- Step 3: Drop and recreate place_bet to use league_members.credits
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
  v_member         league_members%ROWTYPE;
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

  -- Use league_members.credits instead of global wallet
  SELECT * INTO v_member
    FROM league_members
   WHERE user_id = p_user_id AND league_id = p_league_id
   FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'You are not a member of this league'; END IF;

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
  v_max_bet     := FLOOR(v_member.credits * v_max_bet_pct / 100.0);
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
  IF v_member.credits < v_min_wallet THEN
    RAISE EXCEPTION 'Minimum balance of ₹% required for %sx bets', v_min_wallet, p_multiplier;
  END IF;

  IF v_member.credits < v_locked_amount THEN
    RAISE EXCEPTION 'Insufficient balance. Need ₹% (bet + penalty reserve)', v_locked_amount;
  END IF;

  -- Deduct from league_members.credits, lock into locked_credits
  UPDATE league_members SET
    credits        = credits        - v_locked_amount,
    locked_credits = locked_credits + v_locked_amount
  WHERE user_id = p_user_id AND league_id = p_league_id;

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
    v_member.credits,
    v_member.credits - v_locked_amount,
    v_bet_id, 'bet',
    format('Locked ₹%s for %sx bet (league: %s)', v_locked_amount, p_multiplier, p_league_id)
  );

  UPDATE users SET
    last_bet_at   = now(),
    ip_addresses  = array_append(ip_addresses, p_ip_address)
  WHERE id = p_user_id;

  RETURN jsonb_build_object(
    'success',       true,
    'bet_id',        v_bet_id,
    'locked_amount', v_locked_amount,
    'potential_win', v_potential_win
  );
END;
$$;

-- ============================================================
-- Step 4: Recreate settle_match to use league_members.credits
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
  v_member    league_members%ROWTYPE;
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
    SELECT * INTO v_member
      FROM league_members
     WHERE user_id = v_bet.user_id AND league_id = v_bet.league_id
     FOR UPDATE;

    IF v_is_void THEN
      -- Refund locked credits back
      UPDATE league_members SET
        credits        = credits        + v_bet.locked_amount,
        locked_credits = locked_credits - v_bet.locked_amount
      WHERE user_id = v_bet.user_id AND league_id = v_bet.league_id;

      UPDATE bets SET status = 'refunded', credits_won = v_bet.bet_amount,
        settlement_id = p_settlement_id, settled_at = now()
      WHERE id = v_bet.id;

      INSERT INTO transactions (user_id, type, amount, balance_before, balance_after, ref_id, ref_type, note)
      VALUES (v_bet.user_id, 'refund', v_bet.locked_amount,
        v_member.credits, v_member.credits + v_bet.locked_amount,
        v_bet.id, 'bet', 'Match voided — full refund');

      UPDATE multiplier_unlocks SET is_consumed = false, consumed_at = NULL, consumed_by_bet = NULL
      WHERE user_id = v_bet.user_id AND consumed_by_bet = v_bet.id;

      UPDATE streaks SET current_streak = 0, last_updated = now()
      WHERE user_id = v_bet.user_id;

      v_refunded := v_refunded + 1;

    ELSIF v_bet.bet_team = p_winning_team THEN
      v_win_amt := v_bet.potential_win;

      -- Return lock + add winnings to league credits
      UPDATE league_members SET
        credits        = credits        + v_bet.locked_amount + v_win_amt,
        locked_credits = locked_credits - v_bet.locked_amount
      WHERE user_id = v_bet.user_id AND league_id = v_bet.league_id;

      UPDATE bets SET status = 'won', credits_won = v_win_amt,
        settlement_id = p_settlement_id, settled_at = now()
      WHERE id = v_bet.id;

      INSERT INTO transactions (user_id, type, amount, balance_before, balance_after, ref_id, ref_type, note)
      VALUES (v_bet.user_id, 'bet_win', v_bet.locked_amount + v_win_amt,
        v_member.credits, v_member.credits + v_bet.locked_amount + v_win_amt,
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
      -- Lost — just remove the lock (credits were already deducted when bet was placed)
      UPDATE league_members SET
        locked_credits = locked_credits - v_bet.locked_amount
      WHERE user_id = v_bet.user_id AND league_id = v_bet.league_id;

      UPDATE bets SET status = 'lost', credits_won = 0,
        settlement_id = p_settlement_id, settled_at = now()
      WHERE id = v_bet.id;

      INSERT INTO transactions (user_id, type, amount, balance_before, balance_after, ref_id, ref_type, note)
      VALUES (v_bet.user_id, 'bet_loss', v_bet.locked_amount,
        v_member.credits, v_member.credits,
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
-- Step 5: process_donation — now league-scoped
-- New signature: adds p_league_id so transfers happen within a league
-- ============================================================
CREATE OR REPLACE FUNCTION process_donation(
  p_sender_id   UUID,
  p_receiver_id UUID,
  p_league_id   UUID,
  p_amount      NUMERIC,
  p_note        TEXT,
  p_sender_ip   TEXT DEFAULT NULL
)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_sm          league_members%ROWTYPE;
  v_rm          league_members%ROWTYPE;
  v_su          users%ROWTYPE;
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

  -- Verify both are members of the same league
  SELECT * INTO v_sm FROM league_members
   WHERE user_id = p_sender_id AND league_id = p_league_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'You are not a member of this league'; END IF;

  SELECT * INTO v_rm FROM league_members
   WHERE user_id = p_receiver_id AND league_id = p_league_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Recipient is not a member of this league'; END IF;

  IF v_su.created_at > now() - ((get_config_value('min_account_age_days'))::INTEGER || ' days')::INTERVAL THEN
    RAISE EXCEPTION 'Account must be older to donate';
  END IF;

  IF v_su.completed_bets < (get_config_value('min_completed_bets'))::INTEGER THEN
    RAISE EXCEPTION 'Complete more bets before donating';
  END IF;

  SELECT COUNT(*), COALESCE(SUM(amount), 0) INTO v_today_count, v_today_amt
  FROM donations
  WHERE sender_id = p_sender_id AND league_id = p_league_id
    AND created_at > now() - INTERVAL '24 hours';

  IF v_today_count >= (get_config_value('donation_daily_max'))::INTEGER THEN
    RAISE EXCEPTION 'Daily donation limit reached';
  END IF;
  IF v_today_amt + p_amount > (get_config_value('donation_daily_amount'))::NUMERIC THEN
    RAISE EXCEPTION 'Daily donation amount limit reached';
  END IF;

  SELECT created_at INTO v_last_don
  FROM donations WHERE sender_id = p_sender_id AND league_id = p_league_id
  ORDER BY created_at DESC LIMIT 1;
  IF FOUND AND v_last_don > now() - ((get_config_value('donation_cooldown_min'))::INTEGER || ' minutes')::INTERVAL THEN
    RAISE EXCEPTION 'Cooldown active between donations';
  END IF;

  -- Weekly cap per receiver per league
  -- (reuse week_received from wallets concept but track in donations)
  IF (
    SELECT COALESCE(SUM(amount), 0) FROM donations
    WHERE receiver_id = p_receiver_id AND league_id = p_league_id
      AND created_at > now() - INTERVAL '7 days'
  ) + p_amount > (get_config_value('donation_weekly_cap'))::NUMERIC THEN
    RAISE EXCEPTION 'Receiver weekly cap reached in this league';
  END IF;

  IF p_amount > v_sm.credits THEN
    RAISE EXCEPTION 'Insufficient league credits (available: ₹%)', v_sm.credits;
  END IF;

  -- Circular transfer fraud check
  IF EXISTS (SELECT 1 FROM donations
             WHERE sender_id = p_receiver_id AND receiver_id = p_sender_id
               AND league_id = p_league_id
               AND created_at > now() - INTERVAL '24 hours') THEN
    v_fraud_score := v_fraud_score + 50;
    INSERT INTO fraud_flags (user_id, flag_type, details)
    VALUES (p_sender_id, 'circular_transfer',
      jsonb_build_object('with_user', p_receiver_id, 'amount', p_amount, 'league_id', p_league_id));
  END IF;

  IF v_fraud_score > 0 THEN
    UPDATE users SET fraud_score = fraud_score + v_fraud_score WHERE id = p_sender_id;
    IF (SELECT fraud_score FROM users WHERE id = p_sender_id) >= 100 THEN
      UPDATE users SET is_suspended = true, suspend_reason = 'Auto-suspended: fraud score'
      WHERE id = p_sender_id;
      RAISE EXCEPTION 'Account suspended for suspicious activity';
    END IF;
  END IF;

  -- Transfer league credits
  UPDATE league_members
    SET credits = credits - p_amount
   WHERE user_id = p_sender_id AND league_id = p_league_id;

  UPDATE league_members
    SET credits = credits + p_amount
   WHERE user_id = p_receiver_id AND league_id = p_league_id;

  INSERT INTO donations (sender_id, receiver_id, league_id, amount, note, sender_ip)
  VALUES (p_sender_id, p_receiver_id, p_league_id, p_amount, p_note, p_sender_ip)
  RETURNING id INTO v_donation_id;

  INSERT INTO transactions (user_id, type, amount, balance_before, balance_after, ref_id, ref_type, note)
  VALUES
    (p_sender_id,   'donation_sent',     p_amount, v_sm.credits, v_sm.credits - p_amount, v_donation_id, 'donation', 'Donation sent in league'),
    (p_receiver_id, 'donation_received', p_amount, v_rm.credits, v_rm.credits + p_amount, v_donation_id, 'donation', 'Donation received in league');

  RETURN jsonb_build_object('success', true, 'donation_id', v_donation_id);
END;
$$;

-- ============================================================
-- Step 6: Add league_id column to donations if not present
-- ============================================================
ALTER TABLE donations ADD COLUMN IF NOT EXISTS league_id UUID REFERENCES leagues(id);

-- ============================================================
-- Step 7: Trigger — seed credits when a user joins a league
-- ============================================================
CREATE OR REPLACE FUNCTION handle_league_join()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_starting NUMERIC;
BEGIN
  SELECT starting_credits INTO v_starting FROM leagues WHERE id = NEW.league_id;
  UPDATE league_members
    SET credits = COALESCE(v_starting, 1000)
   WHERE id = NEW.id AND credits = 0;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_seed_league_credits ON league_members;
CREATE TRIGGER trg_seed_league_credits
  AFTER INSERT ON league_members
  FOR EACH ROW EXECUTE FUNCTION handle_league_join();

-- ============================================================
-- Step 8: Update get_user_state to return per-league balances
-- ============================================================
CREATE OR REPLACE FUNCTION get_user_state(p_user_id UUID)
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER AS $$
DECLARE
  v_user      users%ROWTYPE;
  v_streaks   JSONB;
  v_unlocks   JSONB;
  v_cooldowns JSONB;
  v_bets      JSONB;
  v_leagues   JSONB;
BEGIN
  SELECT * INTO v_user FROM users WHERE id = p_user_id;

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
    'id', id, 'match_id', match_id, 'league_id', league_id, 'multiplier', multiplier,
    'bet_amount', bet_amount, 'locked_amount', locked_amount,
    'potential_win', potential_win, 'status', status, 'credits_won', credits_won
  ) ORDER BY created_at DESC), '[]') INTO v_bets
  FROM bets WHERE user_id = p_user_id AND created_at > now() - INTERVAL '30 days';

  -- Per-league balances (replaces global wallet)
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'league_id',      lm.league_id,
    'credits',        lm.credits,
    'locked_credits', lm.locked_credits
  )), '[]') INTO v_leagues
  FROM league_members lm WHERE lm.user_id = p_user_id;

  RETURN jsonb_build_object(
    'user',        row_to_json(v_user),
    'league_balances', v_leagues,
    'streaks',     v_streaks,
    'unlocks',     v_unlocks,
    'cooldowns',   v_cooldowns,
    'recent_bets', v_bets
  );
END;
$$;

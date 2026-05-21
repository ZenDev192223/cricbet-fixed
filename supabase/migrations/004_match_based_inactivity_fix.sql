-- ============================================================
-- MIGRATION 004: Match-based inactivity & decay — CORRECTED
-- ============================================================
--
-- ROOT CAUSES FIXED:
--
--  1. league_members had no updated_at column — previous migration
--     was trying to SET updated_at = now() which would error silently.
--
--  2. apply_inactivity_penalties was a standalone edge function that
--     required an external cron job to call it. No cron = never runs.
--     FIX: inactivity logic is now embedded directly inside settle_match
--     so it fires automatically every time a match is settled — no cron,
--     no edge function, no timing issues.
--
--  3. Inactivity was day-based (users.last_bet_at, global).
--     FIX: per-league match-based tracking via last_bet_match_id on
--     league_members. After each settled match, any member who has
--     missed >= inactivity_matches consecutive matches gets penalised.
--
-- FLOW AFTER THIS MIGRATION:
--   Admin settles a match → settle_match() runs → for every league
--   member who did NOT bet on this match, increment their miss count
--   (or check directly via last_bet_match_id). If misses >= threshold
--   → deduct wallet_decay_pct from their league credits + reduce streak.
-- ============================================================


-- ── STEP 1: Add missing columns to league_members ───────────────────────────

ALTER TABLE league_members
  ADD COLUMN IF NOT EXISTS updated_at       TIMESTAMPTZ DEFAULT now(),
  ADD COLUMN IF NOT EXISTS last_bet_match_id UUID REFERENCES matches(id) ON DELETE SET NULL;

-- Back-fill updated_at for existing rows
UPDATE league_members SET updated_at = joined_at WHERE updated_at IS NULL;

-- Back-fill last_bet_match_id: point each member to the most recent
-- settled match they actually placed a bet on in that league
UPDATE league_members lm
SET last_bet_match_id = sub.match_id
FROM (
  SELECT DISTINCT ON (b.user_id, b.league_id)
         b.user_id,
         b.league_id,
         b.match_id
  FROM   bets b
  JOIN   matches m ON m.id = b.match_id
  WHERE  b.status IN ('won', 'lost', 'refunded', 'void', 'canceled')
  ORDER  BY b.user_id, b.league_id, m.settled_at DESC NULLS LAST
) sub
WHERE lm.user_id   = sub.user_id
  AND lm.league_id = sub.league_id;


-- ── STEP 2: Add inactivity_matches config key ────────────────────────────────

INSERT INTO system_config (key, value)
VALUES ('inactivity_matches', '3')
ON CONFLICT (key) DO NOTHING;
-- 3 = member must miss 3 consecutive settled matches before decay fires.
-- Change via Admin → System Config → Inactivity & Decay.


-- ── STEP 3: Rewrite settle_match with built-in inactivity check ─────────────
--
-- Key change: at the end of match settlement, loop over all league_members
-- who did NOT place a bet on this match. For each, count how many
-- completed matches in this league occurred after their last_bet_match_id.
-- If count >= inactivity_matches threshold → apply decay + streak penalty.

CREATE OR REPLACE FUNCTION settle_match(
  p_match_id      UUID,
  p_result        TEXT,
  p_winning_team  TEXT,
  p_admin_id      UUID,
  p_settlement_id TEXT
)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_match          matches%ROWTYPE;
  v_bet            RECORD;
  v_member         league_members%ROWTYPE;
  v_win_amt        NUMERIC;
  v_settled        INTEGER := 0;
  v_refunded       INTEGER := 0;
  v_is_void        BOOLEAN;
  -- inactivity
  v_inactive_row   RECORD;
  v_threshold      INTEGER;
  v_decay_pct      NUMERIC;
  v_decay_amt      NUMERIC;
  v_matches_missed INTEGER;
  v_penalised      INTEGER := 0;
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

  -- ── Settle all pending bets ──────────────────────────────────────────────
  FOR v_bet IN
    SELECT b.* FROM bets b WHERE b.match_id = p_match_id AND b.status = 'pending'
  LOOP
    SELECT * INTO v_member
      FROM league_members
     WHERE user_id = v_bet.user_id AND league_id = v_bet.league_id
     FOR UPDATE;

    IF v_is_void THEN
      UPDATE league_members SET
        credits        = credits        + v_bet.locked_amount,
        locked_credits = locked_credits - v_bet.locked_amount,
        -- ★ They participated: reset last_bet_match_id to this match
        last_bet_match_id = p_match_id,
        updated_at        = now()
      WHERE user_id = v_bet.user_id AND league_id = v_bet.league_id;

      UPDATE bets SET status = 'refunded', credits_won = v_bet.bet_amount,
        settlement_id = p_settlement_id, settled_at = now()
      WHERE id = v_bet.id;

      INSERT INTO transactions (user_id, type, amount, balance_before, balance_after, ref_id, ref_type, note)
      VALUES (v_bet.user_id, 'refund', v_bet.locked_amount,
        v_member.credits, v_member.credits + v_bet.locked_amount,
        v_bet.id, 'bet', 'Match voided — full refund');

      UPDATE multiplier_unlocks SET is_consumed = false, consumed_at = NULL, consumed_by_bet = NULL
      WHERE user_id = v_bet.user_id AND league_id = v_bet.league_id AND consumed_by_bet = v_bet.id;

      UPDATE streaks SET current_streak = 0, last_updated = now()
      WHERE user_id = v_bet.user_id AND league_id = v_bet.league_id;

      v_refunded := v_refunded + 1;

    ELSIF v_bet.bet_team = p_winning_team THEN
      v_win_amt := v_bet.potential_win;

      UPDATE league_members SET
        credits           = credits        + v_bet.locked_amount + v_win_amt,
        locked_credits    = locked_credits - v_bet.locked_amount,
        last_bet_match_id = p_match_id,
        updated_at        = now()
      WHERE user_id = v_bet.user_id AND league_id = v_bet.league_id;

      UPDATE bets SET status = 'won', credits_won = v_win_amt,
        settlement_id = p_settlement_id, settled_at = now()
      WHERE id = v_bet.id;

      INSERT INTO transactions (user_id, type, amount, balance_before, balance_after, ref_id, ref_type, note)
      VALUES (v_bet.user_id, 'bet_win', v_bet.locked_amount + v_win_amt,
        v_member.credits, v_member.credits + v_bet.locked_amount + v_win_amt,
        v_bet.id, 'bet', format('Won — ₹%s at %s×', v_win_amt, v_bet.multiplier));

      PERFORM update_streak_on_win(v_bet.user_id, v_bet.league_id, v_bet.multiplier::TEXT, p_match_id);

      IF v_bet.multiplier IN (3, 4, 5) THEN
        UPDATE multiplier_unlocks SET is_consumed = true, consumed_at = now(), consumed_by_bet = v_bet.id
        WHERE user_id = v_bet.user_id AND league_id = v_bet.league_id
          AND multiplier = v_bet.multiplier::TEXT AND is_consumed = false;

        IF v_bet.multiplier = 4 THEN
          INSERT INTO cooldowns (user_id, league_id, multiplier, matches_remaining, triggered_by)
          VALUES (v_bet.user_id, v_bet.league_id, '4', (get_config_value('cooldown_4x_matches'))::INTEGER, v_bet.id)
          ON CONFLICT (user_id, league_id, multiplier) DO UPDATE
            SET matches_remaining = (get_config_value('cooldown_4x_matches'))::INTEGER;
        ELSIF v_bet.multiplier = 5 THEN
          INSERT INTO cooldowns (user_id, league_id, multiplier, matches_remaining, triggered_by)
          VALUES (v_bet.user_id, v_bet.league_id, '5', (get_config_value('cooldown_5x_matches'))::INTEGER, v_bet.id)
          ON CONFLICT (user_id, league_id, multiplier) DO UPDATE
            SET matches_remaining = (get_config_value('cooldown_5x_matches'))::INTEGER;
        END IF;
      END IF;

      UPDATE users SET completed_bets = completed_bets + 1 WHERE id = v_bet.user_id;
      v_settled := v_settled + 1;

    ELSE
      -- Lost
      UPDATE league_members SET
        locked_credits    = locked_credits - v_bet.locked_amount,
        last_bet_match_id = p_match_id,
        updated_at        = now()
      WHERE user_id = v_bet.user_id AND league_id = v_bet.league_id;

      UPDATE bets SET status = 'lost', credits_won = 0,
        settlement_id = p_settlement_id, settled_at = now()
      WHERE id = v_bet.id;

      INSERT INTO transactions (user_id, type, amount, balance_before, balance_after, ref_id, ref_type, note)
      VALUES (v_bet.user_id, 'bet_loss', v_bet.locked_amount,
        v_member.credits, v_member.credits,
        v_bet.id, 'bet', format('Lost — ₹%s at %s×', v_bet.locked_amount, v_bet.multiplier));

      UPDATE streaks SET current_streak = 0, last_updated = now()
      WHERE user_id = v_bet.user_id AND league_id = v_bet.league_id
        AND multiplier_tier = v_bet.multiplier::TEXT;

      IF v_bet.multiplier IN (3, 4, 5) THEN
        UPDATE multiplier_unlocks SET is_consumed = true, consumed_at = now(), consumed_by_bet = v_bet.id
        WHERE user_id = v_bet.user_id AND league_id = v_bet.league_id
          AND multiplier = v_bet.multiplier::TEXT AND is_consumed = false;

        IF v_bet.multiplier = 4 THEN
          INSERT INTO cooldowns (user_id, league_id, multiplier, matches_remaining, triggered_by)
          VALUES (v_bet.user_id, v_bet.league_id, '4', (get_config_value('cooldown_4x_matches'))::INTEGER, v_bet.id)
          ON CONFLICT (user_id, league_id, multiplier) DO UPDATE
            SET matches_remaining = (get_config_value('cooldown_4x_matches'))::INTEGER;
        ELSIF v_bet.multiplier = 5 THEN
          INSERT INTO cooldowns (user_id, league_id, multiplier, matches_remaining, triggered_by)
          VALUES (v_bet.user_id, v_bet.league_id, '5', (get_config_value('cooldown_5x_matches'))::INTEGER, v_bet.id)
          ON CONFLICT (user_id, league_id, multiplier) DO UPDATE
            SET matches_remaining = (get_config_value('cooldown_5x_matches'))::INTEGER;
        END IF;
      END IF;

      UPDATE users SET completed_bets = completed_bets + 1 WHERE id = v_bet.user_id;
      v_settled := v_settled + 1;
    END IF;
  END LOOP;

  -- Decrement cooldowns for this league
  UPDATE cooldowns SET matches_remaining = GREATEST(0, matches_remaining - 1)
  WHERE league_id = v_match.league_id AND matches_remaining > 0;

  -- ── INACTIVITY CHECK (runs after every non-void settled match) ───────────
  -- Skip for voided matches — no one "missed" a voided match.
  IF NOT v_is_void THEN
    v_threshold := (get_config_value('inactivity_matches'))::INTEGER;
    v_decay_pct := (get_config_value('wallet_decay_pct'))::NUMERIC;

    -- Find every member of this league who did NOT bet on this match
    -- and has missed >= threshold consecutive settled matches
    FOR v_inactive_row IN
      SELECT
        lm.user_id,
        lm.league_id,
        lm.credits,
        lm.last_bet_match_id,
        -- Count completed matches in this league AFTER their last bet
        (
          SELECT COUNT(*)::INTEGER
          FROM   matches m2
          WHERE  m2.league_id = lm.league_id
            AND  m2.status    = 'completed'
            AND  (
                   lm.last_bet_match_id IS NULL
                   OR m2.settled_at > (
                        SELECT settled_at FROM matches WHERE id = lm.last_bet_match_id
                      )
                 )
        ) AS matches_missed
      FROM league_members lm
      WHERE lm.league_id = v_match.league_id
        AND lm.credits   > 0
        -- Exclude users who bet on THIS match (they just got updated above)
        AND NOT EXISTS (
          SELECT 1 FROM bets b
          WHERE b.match_id  = p_match_id
            AND b.user_id   = lm.user_id
            AND b.league_id = lm.league_id
        )
      FOR UPDATE OF lm
    LOOP
      v_matches_missed := v_inactive_row.matches_missed;

      -- Only penalise once threshold is hit (not every match after)
      CONTINUE WHEN v_matches_missed < v_threshold;
      -- Only penalise on exact multiples so decay doesn't compound every match
      CONTINUE WHEN (v_matches_missed % v_threshold) <> 0;

      v_decay_amt := GREATEST(0, FLOOR(v_inactive_row.credits * v_decay_pct / 100.0));

      IF v_decay_amt > 0 THEN
        UPDATE league_members SET
          credits    = GREATEST(0, credits - v_decay_amt),
          updated_at = now()
        WHERE user_id   = v_inactive_row.user_id
          AND league_id = v_inactive_row.league_id;

        INSERT INTO transactions (
          user_id, type, amount, balance_before, balance_after, note
        ) VALUES (
          v_inactive_row.user_id,
          'wallet_decay',
          v_decay_amt,
          v_inactive_row.credits,
          GREATEST(0, v_inactive_row.credits - v_decay_amt),
          format('%s matches inactive in league — decay applied', v_matches_missed)
        );

        UPDATE streaks SET
          current_streak = GREATEST(0, current_streak - 1),
          last_updated   = now()
        WHERE user_id   = v_inactive_row.user_id
          AND league_id = v_inactive_row.league_id;

        INSERT INTO inactivity_records (
          user_id, league_id, days_inactive, decay_applied, streak_reduced
        ) VALUES (
          v_inactive_row.user_id,
          v_inactive_row.league_id,
          v_matches_missed,   -- column reused to store matches_missed count
          v_decay_amt,
          true
        );

        v_penalised := v_penalised + 1;
      END IF;
    END LOOP;
  END IF;

  INSERT INTO admin_logs (admin_id, action, target_type, target_id, new_value)
  VALUES (p_admin_id, 'settle_match', 'match', p_match_id,
    jsonb_build_object(
      'result',    p_result,
      'settled',   v_settled,
      'refunded',  v_refunded,
      'penalised', v_penalised
    ));

  RETURN jsonb_build_object(
    'success',   true,
    'settled',   v_settled,
    'refunded',  v_refunded,
    'penalised', v_penalised
  );
END;
$$;


-- ── STEP 4: Update place_bet to stamp last_bet_match_id ─────────────────────
-- Ensures the inactivity counter resets when a user places a new bet.

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
  v_max_bet_amt    NUMERIC;
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
  IF v_match.status <> 'upcoming' THEN RAISE EXCEPTION 'Match is not open for betting'; END IF;

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
  v_max_bet_amt := FLOOR((v_member.credits + v_member.locked_credits) * v_max_bet_pct);

  v_min_wallet := CASE p_multiplier
    WHEN 3 THEN (get_config_value('min_wallet_3x'))::NUMERIC
    WHEN 4 THEN (get_config_value('min_wallet_4x'))::NUMERIC
    WHEN 5 THEN (get_config_value('min_wallet_5x'))::NUMERIC
    ELSE 0
  END;

  IF p_bet_amount <= 0     THEN RAISE EXCEPTION 'Bet amount must be positive'; END IF;
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
    last_bet_match_id = p_match_id,   -- ★ reset inactivity counter
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

-- ── Done ─────────────────────────────────────────────────────────────────────
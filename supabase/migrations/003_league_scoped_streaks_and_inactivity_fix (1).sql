-- ============================================================
-- MIGRATION 003: League-Scoped Streaks + Inactivity/Decay Fix
-- ============================================================
--
-- Bug 1: Streaks, multiplier_unlocks, and cooldowns are global.
--   A win in League A should not count toward streak in League B.
--   Fix: Add league_id to streaks, multiplier_unlocks, cooldowns
--        and update all logic to be league-scoped.
--
-- Bug 2: apply_inactivity_penalties reads wallets.available_balance
--   (old global wallet) and does nothing because migration 002
--   switched to league_members.credits — so decay was never actually
--   applied, and last_bet_at on the users table was still being set
--   per-league-bet which masked the problem.
--   Fix: Operate on league_members.credits instead of global wallets,
--        and update streaks per league.
-- ============================================================


-- ============================================================
-- STEP 1: Add league_id to streaks, multiplier_unlocks, cooldowns
-- ============================================================

-- streaks: drop old unique constraint, add league_id, new constraint
ALTER TABLE streaks ADD COLUMN IF NOT EXISTS league_id UUID REFERENCES leagues(id) ON DELETE CASCADE;

-- Backfill: remove orphan rows with no league context (they are meaningless now)
DELETE FROM streaks WHERE league_id IS NULL;

-- Make league_id NOT NULL and update the unique constraint
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name='streaks' AND column_name='league_id' AND is_nullable='YES') THEN
    ALTER TABLE streaks ALTER COLUMN league_id SET NOT NULL;
  END IF;
END $$;
ALTER TABLE streaks DROP CONSTRAINT IF EXISTS streaks_user_id_multiplier_tier_key;
ALTER TABLE streaks DROP CONSTRAINT IF EXISTS streaks_user_league_tier_key;
ALTER TABLE streaks ADD CONSTRAINT streaks_user_league_tier_key UNIQUE (user_id, league_id, multiplier_tier);

CREATE INDEX IF NOT EXISTS idx_streaks_user_league ON streaks(user_id, league_id);


-- multiplier_unlocks: add league_id, update unique constraint
ALTER TABLE multiplier_unlocks ADD COLUMN IF NOT EXISTS league_id UUID REFERENCES leagues(id) ON DELETE CASCADE;

DELETE FROM multiplier_unlocks WHERE league_id IS NULL;

DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name='multiplier_unlocks' AND column_name='league_id' AND is_nullable='YES') THEN
    ALTER TABLE multiplier_unlocks ALTER COLUMN league_id SET NOT NULL;
  END IF;
END $$;
ALTER TABLE multiplier_unlocks DROP CONSTRAINT IF EXISTS multiplier_unlocks_user_id_multiplier_key;
ALTER TABLE multiplier_unlocks DROP CONSTRAINT IF EXISTS multiplier_unlocks_user_league_multiplier_key;
ALTER TABLE multiplier_unlocks ADD CONSTRAINT multiplier_unlocks_user_league_multiplier_key UNIQUE (user_id, league_id, multiplier);

CREATE INDEX IF NOT EXISTS idx_unlocks_user_league ON multiplier_unlocks(user_id, league_id);


-- cooldowns: add league_id, update unique constraint
ALTER TABLE cooldowns ADD COLUMN IF NOT EXISTS league_id UUID REFERENCES leagues(id) ON DELETE CASCADE;

DELETE FROM cooldowns WHERE league_id IS NULL;

DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name='cooldowns' AND column_name='league_id' AND is_nullable='YES') THEN
    ALTER TABLE cooldowns ALTER COLUMN league_id SET NOT NULL;
  END IF;
END $$;
ALTER TABLE cooldowns DROP CONSTRAINT IF EXISTS cooldowns_user_id_multiplier_key;
ALTER TABLE cooldowns DROP CONSTRAINT IF EXISTS cooldowns_user_league_multiplier_key;
ALTER TABLE cooldowns ADD CONSTRAINT cooldowns_user_league_multiplier_key UNIQUE (user_id, league_id, multiplier);

CREATE INDEX IF NOT EXISTS idx_cooldowns_user_league ON cooldowns(user_id, league_id);


-- inactivity_records: add league_id for league-scoped tracking
ALTER TABLE inactivity_records ADD COLUMN IF NOT EXISTS league_id UUID REFERENCES leagues(id) ON DELETE CASCADE;


-- ============================================================
-- STEP 2: Update update_streak_on_win to be league-scoped
-- ============================================================
CREATE OR REPLACE FUNCTION update_streak_on_win(
  p_user_id    UUID,
  p_league_id  UUID,
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
  INSERT INTO streaks (user_id, league_id, multiplier_tier, current_streak, last_match_id)
  VALUES (p_user_id, p_league_id, p_multiplier, 1, p_match_id)
  ON CONFLICT (user_id, league_id, multiplier_tier) DO UPDATE
    SET current_streak = streaks.current_streak + 1,
        last_match_id  = p_match_id,
        last_updated   = now()
  RETURNING current_streak INTO v_streak;

  v_unlock_3x := get_config_value('streak_unlock_3x');
  v_unlock_4x := get_config_value('streak_unlock_4x');
  v_unlock_5x := get_config_value('streak_unlock_5x');

  v_thresh_3x := (v_unlock_3x->>p_multiplier)::INTEGER;
  IF v_thresh_3x IS NOT NULL AND v_streak >= v_thresh_3x THEN
    INSERT INTO multiplier_unlocks (user_id, league_id, multiplier, unlock_source)
    VALUES (p_user_id, p_league_id, '3', format('%sx×%s streak', p_multiplier, v_streak))
    ON CONFLICT (user_id, league_id, multiplier) DO UPDATE
      SET is_consumed = false, consumed_at = NULL, consumed_by_bet = NULL, unlocked_at = now()
      WHERE multiplier_unlocks.is_consumed = true;
  END IF;

  v_thresh_4x := (v_unlock_4x->>p_multiplier)::INTEGER;
  IF v_thresh_4x IS NOT NULL AND v_streak >= v_thresh_4x THEN
    INSERT INTO multiplier_unlocks (user_id, league_id, multiplier, unlock_source)
    VALUES (p_user_id, p_league_id, '4', format('%sx×%s streak', p_multiplier, v_streak))
    ON CONFLICT (user_id, league_id, multiplier) DO UPDATE
      SET is_consumed = false, consumed_at = NULL, consumed_by_bet = NULL, unlocked_at = now()
      WHERE multiplier_unlocks.is_consumed = true;
  END IF;

  v_thresh_5x := (v_unlock_5x->>p_multiplier)::INTEGER;
  IF v_thresh_5x IS NOT NULL AND v_streak >= v_thresh_5x THEN
    INSERT INTO multiplier_unlocks (user_id, league_id, multiplier, unlock_source)
    VALUES (p_user_id, p_league_id, '5', format('%sx×%s streak', p_multiplier, v_streak))
    ON CONFLICT (user_id, league_id, multiplier) DO UPDATE
      SET is_consumed = false, consumed_at = NULL, consumed_by_bet = NULL, unlocked_at = now()
      WHERE multiplier_unlocks.is_consumed = true;
  END IF;
END;
$$;


-- ============================================================
-- STEP 3: Update settle_match — all streak/unlock/cooldown ops
--         now scoped by league (via v_bet.league_id)
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
      -- Refund locked credits back to league wallet
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
      WHERE user_id = v_bet.user_id AND league_id = v_bet.league_id AND consumed_by_bet = v_bet.id;

      -- Reset streak only within this league
      UPDATE streaks SET current_streak = 0, last_updated = now()
      WHERE user_id = v_bet.user_id AND league_id = v_bet.league_id;

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

      -- League-scoped streak update (new signature)
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
      -- Lost — release the lock (credits already deducted when bet was placed)
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

      -- Reset streak only for this multiplier tier within this league
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

  -- Decrement cooldowns only within this match's league
  UPDATE cooldowns SET matches_remaining = GREATEST(0, matches_remaining - 1)
  WHERE league_id = v_match.league_id AND matches_remaining > 0;

  INSERT INTO admin_logs (admin_id, action, target_type, target_id, new_value)
  VALUES (p_admin_id, 'settle_match', 'match', p_match_id,
    jsonb_build_object('result', p_result, 'settled', v_settled, 'refunded', v_refunded));

  RETURN jsonb_build_object('success', true, 'settled', v_settled, 'refunded', v_refunded);
END;
$$;


-- ============================================================
-- STEP 4: Fix apply_inactivity_penalties
--
-- The old version queried wallets.available_balance which is
-- the global wallet — unused since migration 002.
-- We now iterate over league_members, apply decay per membership,
-- and reduce streaks per league.
-- ============================================================
CREATE OR REPLACE FUNCTION apply_inactivity_penalties()
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_row        RECORD;
  v_inact_days INTEGER;
  v_decay_pct  NUMERIC;
  v_decay_amt  NUMERIC;
  v_threshold  INTEGER;
  v_processed  INTEGER := 0;
BEGIN
  v_threshold := (get_config_value('inactivity_days'))::INTEGER;
  v_decay_pct := (get_config_value('wallet_decay_pct'))::NUMERIC;

  -- Iterate over each user–league pair where the user has been inactive
  -- "Inactive" = no bet placed in this league since the threshold.
  -- We use users.last_bet_at as a conservative global fallback because
  -- there is no per-league last_bet_at yet. This means we only penalise
  -- users who haven't bet in ANY league for the threshold period, which
  -- is the safe interpretation. See comment below if you want per-league
  -- last-activity tracking instead.
  FOR v_row IN
    SELECT
      lm.user_id,
      lm.league_id,
      lm.credits,
      u.last_bet_at
    FROM league_members lm
    JOIN users u ON u.id = lm.user_id
    WHERE u.last_bet_at IS NOT NULL
      AND u.last_bet_at < now() - (v_threshold || ' days')::INTERVAL
      AND lm.credits > 0
    FOR UPDATE OF lm
  LOOP
    v_inact_days := EXTRACT(DAY FROM now() - v_row.last_bet_at)::INTEGER;
    v_decay_amt  := GREATEST(0, FLOOR(v_row.credits * v_decay_pct / 100.0));

    IF v_decay_amt > 0 THEN
      -- Apply decay to league credits
      UPDATE league_members SET
        credits    = GREATEST(0, credits - v_decay_amt),
        updated_at = now()
      WHERE user_id = v_row.user_id AND league_id = v_row.league_id;

      INSERT INTO transactions (user_id, type, amount, balance_before, balance_after, note)
      VALUES (
        v_row.user_id, 'wallet_decay', v_decay_amt,
        v_row.credits, GREATEST(0, v_row.credits - v_decay_amt),
        format('%s days inactive — decay applied (league %s)', v_inact_days, v_row.league_id)
      );

      -- Reduce streak by 1 per multiplier tier, within this league only
      UPDATE streaks SET
        current_streak = GREATEST(0, current_streak - 1),
        last_updated   = now()
      WHERE user_id = v_row.user_id AND league_id = v_row.league_id;

      INSERT INTO inactivity_records (user_id, league_id, days_inactive, decay_applied, streak_reduced)
      VALUES (v_row.user_id, v_row.league_id, v_inact_days, v_decay_amt, true);

      v_processed := v_processed + 1;
    END IF;
  END LOOP;

  RETURN jsonb_build_object('success', true, 'processed', v_processed);
END;
$$;


-- ============================================================
-- STEP 5: Update get_user_state to return league-scoped data
--         (now requires a league_id parameter)
-- ============================================================
CREATE OR REPLACE FUNCTION get_user_state(p_user_id UUID, p_league_id UUID DEFAULT NULL)
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER AS $$
DECLARE
  v_wallet    wallets%ROWTYPE;
  v_user      users%ROWTYPE;
  v_member    league_members%ROWTYPE;
  v_streaks   JSONB;
  v_unlocks   JSONB;
  v_cooldowns JSONB;
  v_bets      JSONB;
BEGIN
  SELECT * INTO v_user   FROM users   WHERE id = p_user_id;
  SELECT * INTO v_wallet FROM wallets WHERE user_id = p_user_id;

  IF p_league_id IS NOT NULL THEN
    SELECT * INTO v_member FROM league_members
    WHERE user_id = p_user_id AND league_id = p_league_id;

    SELECT COALESCE(jsonb_object_agg(multiplier_tier, current_streak), '{}')
    INTO v_streaks
    FROM streaks
    WHERE user_id = p_user_id AND league_id = p_league_id;

    SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'multiplier', multiplier, 'is_consumed', is_consumed,
      'unlocked_at', unlocked_at, 'unlock_source', unlock_source
    )), '[]') INTO v_unlocks
    FROM multiplier_unlocks
    WHERE user_id = p_user_id AND league_id = p_league_id;

    SELECT COALESCE(jsonb_object_agg(multiplier, matches_remaining), '{}')
    INTO v_cooldowns
    FROM cooldowns
    WHERE user_id = p_user_id AND league_id = p_league_id AND matches_remaining > 0;

    SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'id', id, 'match_id', match_id, 'bet_team', bet_team,
      'multiplier', multiplier, 'bet_amount', bet_amount,
      'potential_win', potential_win, 'status', status, 'created_at', created_at
    ) ORDER BY created_at DESC), '[]') INTO v_bets
    FROM bets
    WHERE user_id = p_user_id AND league_id = p_league_id
    ORDER BY created_at DESC LIMIT 20;
  ELSE
    -- Fallback: global aggregates across all leagues (backward compat)
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
      'id', id, 'match_id', match_id, 'bet_team', bet_team,
      'multiplier', multiplier, 'bet_amount', bet_amount,
      'potential_win', potential_win, 'status', status, 'created_at', created_at
    ) ORDER BY created_at DESC), '[]') INTO v_bets
    FROM bets WHERE user_id = p_user_id ORDER BY created_at DESC LIMIT 20;
  END IF;

  RETURN jsonb_build_object(
    'user_id',           v_user.id,
    'role',              v_user.role,
    'completed_bets',    v_user.completed_bets,
    'league_credits',    CASE WHEN p_league_id IS NOT NULL THEN v_member.credits ELSE NULL END,
    'league_locked',     CASE WHEN p_league_id IS NOT NULL THEN v_member.locked_credits ELSE NULL END,
    'global_balance',    v_wallet.available_balance,
    'streaks',           v_streaks,
    'unlocks',           v_unlocks,
    'cooldowns',         v_cooldowns,
    'recent_bets',       v_bets
  );
END;
$$;


-- ============================================================
-- STEP 6: place_bet — also needs league-scoped cooldown check
--         (migration 002 rewrote this but the cooldown check
--          still reads globally from cooldowns without league filter)
--
-- NOTE: Must DROP first — PostgreSQL does not allow renaming
-- input parameters via CREATE OR REPLACE FUNCTION.
-- Original signature: place_bet(uuid,uuid,uuid,text,numeric,numeric,text,text)
-- ============================================================
DROP FUNCTION IF EXISTS place_bet(UUID, UUID, UUID, TEXT, NUMERIC, NUMERIC, TEXT, TEXT);

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
BEGIN
  -- Idempotency check
  IF p_idempotency_key IS NOT NULL THEN
    SELECT id INTO v_bet_id FROM bets WHERE idempotency_key = p_idempotency_key;
    IF FOUND THEN
      RETURN jsonb_build_object('success', true, 'bet_id', v_bet_id, 'idempotent', true);
    END IF;
  END IF;

  SELECT * INTO v_match FROM matches WHERE id = p_match_id;
  IF NOT FOUND OR v_match.status NOT IN ('upcoming', 'live') THEN
    RAISE EXCEPTION 'Match is not open for betting';
  END IF;

  IF v_match.league_id != p_league_id THEN
    RAISE EXCEPTION 'Match does not belong to this league';
  END IF;

  -- Duplicate bet check within this league
  IF EXISTS (
    SELECT 1 FROM bets
    WHERE user_id = p_user_id AND league_id = p_league_id
      AND match_id = p_match_id AND status != 'canceled'
  ) THEN
    RAISE EXCEPTION 'Already placed a bet on this match in this league';
  END IF;

  v_multiplier_str := p_multiplier::TEXT;

  -- Multiplier access checks (league-scoped for 3x/4x/5x)
  IF p_multiplier IN (3, 4, 5) THEN
    IF NOT EXISTS (
      SELECT 1 FROM multiplier_unlocks
      WHERE user_id = p_user_id AND league_id = p_league_id
        AND multiplier = v_multiplier_str AND is_consumed = false
    ) THEN
      RAISE EXCEPTION 'Multiplier %sx not unlocked in this league', p_multiplier;
    END IF;
  END IF;

  -- Cooldown check (league-scoped)
  SELECT matches_remaining INTO v_cooldown_rem
  FROM cooldowns
  WHERE user_id = p_user_id AND league_id = p_league_id
    AND multiplier = v_multiplier_str;
  IF v_cooldown_rem IS NOT NULL AND v_cooldown_rem > 0 THEN
    RAISE EXCEPTION 'Multiplier on cooldown: % match(es) remaining', v_cooldown_rem;
  END IF;

  -- Active bet limits for high multipliers (global across leagues is intentional)
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

  -- Penalty % based on multiplier (from system_config)
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

  -- Get league membership
  SELECT * INTO v_member FROM league_members
   WHERE user_id = p_user_id AND league_id = p_league_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'You are not a member of this league'; END IF;

  -- Max bet: percentage of league credits, capped by league setting
  v_max_bet_pct := (get_config_value('max_bet_pct'))::NUMERIC;
  v_max_bet     := FLOOR(v_member.credits * v_max_bet_pct / 100.0);
  SELECT max_bet INTO v_league_max_bet FROM leagues WHERE id = p_league_id;
  IF v_league_max_bet IS NOT NULL THEN
    v_max_bet := LEAST(v_max_bet, v_league_max_bet);
  END IF;
  IF p_bet_amount > v_max_bet THEN
    RAISE EXCEPTION 'Bet exceeds maximum allowed: ₹%', v_max_bet;
  END IF;

  -- Minimum wallet balance for high multipliers
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
    RAISE EXCEPTION 'Insufficient league credits (available: ₹%)', v_member.credits;
  END IF;

  -- Deduct from league credits, lock into locked_credits
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
    last_bet_at  = now(),
    ip_addresses = array_append(ip_addresses, p_ip_address)
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
-- STEP 7: RLS — allow league members to read their own league
--         rows in streaks, multiplier_unlocks, cooldowns
-- ============================================================
DROP POLICY IF EXISTS p_streaks_self ON streaks;
CREATE POLICY p_streaks_self ON streaks FOR SELECT
  USING (auth.uid() = user_id);

DROP POLICY IF EXISTS p_unlocks_self ON multiplier_unlocks;
CREATE POLICY p_unlocks_self ON multiplier_unlocks FOR SELECT
  USING (auth.uid() = user_id);

DROP POLICY IF EXISTS p_cooldowns_self ON cooldowns;
CREATE POLICY p_cooldowns_self ON cooldowns FOR SELECT
  USING (auth.uid() = user_id);
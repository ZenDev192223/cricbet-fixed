-- ============================================================
-- MIGRATION 011: Per-league donations
-- ============================================================
-- PROBLEM:
--   Donations were global — one shared ₹1,000/week cap across
--   all leagues. User receiving ₹1,000 in League A meant they
--   couldn't receive anything in League B.
--
-- FIX:
--   • Add league_id to donations table
--   • Track week_received per league in league_members
--   • Cap is now per-league: ₹1,000/week in each league independently
--   • Donations deduct/credit league_members.credits, not global wallet
--   • Global wallet syncs automatically via existing trigger (migration 009)
-- ============================================================


-- ── STEP 1: Add league_id to donations ──────────────────────────────────────

ALTER TABLE donations
  ADD COLUMN IF NOT EXISTS league_id UUID REFERENCES leagues(id) ON DELETE SET NULL;

-- ── STEP 2: Add per-league weekly tracking to league_members ─────────────────

ALTER TABLE league_members
  ADD COLUMN IF NOT EXISTS week_received       NUMERIC(14,2) DEFAULT 0,
  ADD COLUMN IF NOT EXISTS week_donated        NUMERIC(14,2) DEFAULT 0,
  ADD COLUMN IF NOT EXISTS week_reset_at       TIMESTAMPTZ   DEFAULT now(),
  ADD COLUMN IF NOT EXISTS total_received      NUMERIC(14,2) DEFAULT 0,
  ADD COLUMN IF NOT EXISTS total_donated       NUMERIC(14,2) DEFAULT 0;


-- ── STEP 3: Rewrite process_donation to be league-scoped ─────────────────────

CREATE OR REPLACE FUNCTION process_donation(
  p_sender_id   UUID,
  p_receiver_id UUID,
  p_amount      NUMERIC,
  p_note        TEXT,
  p_league_id   UUID DEFAULT NULL,   -- ★ new param, optional for backward compat
  p_sender_ip   TEXT DEFAULT NULL
)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_su           users%ROWTYPE;
  v_sm           league_members%ROWTYPE;   -- sender league member
  v_rm           league_members%ROWTYPE;   -- receiver league member
  v_donation_id  UUID;
  v_today_count  INTEGER;
  v_today_amt    NUMERIC;
  v_last_don     TIMESTAMPTZ;
  v_fraud_score  INTEGER := 0;
  v_weekly_cap   NUMERIC;
BEGIN
  IF p_sender_id = p_receiver_id THEN RAISE EXCEPTION 'Cannot donate to yourself'; END IF;

  SELECT * INTO v_su FROM users WHERE id = p_sender_id;
  IF NOT FOUND         THEN RAISE EXCEPTION 'Sender not found'; END IF;
  IF v_su.is_suspended THEN RAISE EXCEPTION 'Account suspended'; END IF;

  -- Account age & bet requirement
  IF v_su.created_at > now() - ((get_config_value('min_account_age_days'))::INTEGER || ' days')::INTERVAL THEN
    RAISE EXCEPTION 'Account must be older to donate';
  END IF;
  IF v_su.completed_bets < (get_config_value('min_completed_bets'))::INTEGER THEN
    RAISE EXCEPTION 'Complete more bets before donating';
  END IF;

  -- If league_id provided, work with league wallets
  IF p_league_id IS NOT NULL THEN

    SELECT * INTO v_sm FROM league_members
    WHERE user_id = p_sender_id AND league_id = p_league_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Sender is not a member of this league'; END IF;

    SELECT * INTO v_rm FROM league_members
    WHERE user_id = p_receiver_id AND league_id = p_league_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Receiver is not a member of this league'; END IF;

    -- Auto-reset receiver's weekly cap for this league
    IF v_rm.week_reset_at < now() - INTERVAL '7 days' THEN
      UPDATE league_members
      SET week_received = 0, week_donated = 0, week_reset_at = now()
      WHERE user_id = p_receiver_id AND league_id = p_league_id;
      SELECT * INTO v_rm FROM league_members
      WHERE user_id = p_receiver_id AND league_id = p_league_id FOR UPDATE;
    END IF;

    v_weekly_cap := (get_config_value('donation_weekly_cap'))::NUMERIC;

    IF v_rm.week_received + p_amount > v_weekly_cap THEN
      RAISE EXCEPTION 'Receiver weekly cap reached for this league (received ₹% this week, cap ₹%)',
        v_rm.week_received, v_weekly_cap;
    END IF;

    IF v_sm.credits < p_amount THEN
      RAISE EXCEPTION 'Insufficient league credits';
    END IF;

    -- Daily limits (league-scoped)
    SELECT COUNT(*), COALESCE(SUM(amount), 0) INTO v_today_count, v_today_amt
    FROM donations
    WHERE sender_id = p_sender_id AND league_id = p_league_id
      AND created_at > now() - INTERVAL '24 hours';
    IF v_today_count >= (get_config_value('donation_daily_max'))::INTEGER THEN
      RAISE EXCEPTION 'Daily donation limit reached for this league';
    END IF;
    IF v_today_amt + p_amount > (get_config_value('donation_daily_amount'))::NUMERIC THEN
      RAISE EXCEPTION 'Daily donation amount limit reached for this league';
    END IF;

    -- Cooldown (league-scoped)
    SELECT created_at INTO v_last_don FROM donations
    WHERE sender_id = p_sender_id AND league_id = p_league_id
    ORDER BY created_at DESC LIMIT 1;
    IF FOUND AND v_last_don > now() - ((get_config_value('donation_cooldown_min'))::INTEGER || ' minutes')::INTERVAL THEN
      RAISE EXCEPTION 'Cooldown active between donations';
    END IF;

    -- Fraud check
    IF EXISTS (
      SELECT 1 FROM donations
      WHERE sender_id = p_receiver_id AND receiver_id = p_sender_id
        AND league_id = p_league_id AND created_at > now() - INTERVAL '24 hours'
    ) THEN
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

    -- Deduct from sender league credits → trigger syncs global wallet
    UPDATE league_members SET
      credits        = credits        - p_amount,
      total_donated  = total_donated  + p_amount,
      week_donated   = week_donated   + p_amount,
      updated_at     = now()
    WHERE user_id = p_sender_id AND league_id = p_league_id;

    -- Credit receiver league credits → trigger syncs global wallet
    UPDATE league_members SET
      credits        = credits        + p_amount,
      total_received = total_received + p_amount,
      week_received  = week_received  + p_amount,
      updated_at     = now()
    WHERE user_id = p_receiver_id AND league_id = p_league_id;

  ELSE
    -- ── Fallback: global wallet donation (backward compat) ──────────────────
    RAISE EXCEPTION 'League ID required for donations';
    -- Remove this RAISE and restore old global logic if you ever need global donations
  END IF;

  INSERT INTO donations (sender_id, receiver_id, amount, note, sender_ip, status, league_id)
  VALUES (p_sender_id, p_receiver_id, p_amount, p_note, p_sender_ip, 'completed', p_league_id)
  RETURNING id INTO v_donation_id;

  INSERT INTO transactions (user_id, type, amount, balance_before, balance_after, ref_id, ref_type, note)
  VALUES
    (p_sender_id,   'donation_sent'::transaction_type,     p_amount,
      v_sm.credits, v_sm.credits - p_amount,
      v_donation_id, 'donation', COALESCE(NULLIF(p_note,''), 'Donation sent')),
    (p_receiver_id, 'donation_received'::transaction_type, p_amount,
      v_rm.credits, v_rm.credits + p_amount,
      v_donation_id, 'donation', COALESCE(NULLIF(p_note,''), 'Donation received'));

  RETURN jsonb_build_object('success', true, 'donation_id', v_donation_id);
END;
$$;

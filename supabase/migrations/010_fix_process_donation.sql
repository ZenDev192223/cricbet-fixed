-- ============================================================
-- MIGRATION 010: Harden process_donation
-- ============================================================
-- FIXES:
--   1. Re-read wallet AFTER the week_received auto-reset so the
--      stale v_rw.available_balance doesn't corrupt transaction logs.
--   2. Also track week_donated on the sender (was missing).
--   3. Add a DB trigger so ANY insert into donations table
--      (including direct admin inserts) always syncs wallets —
--      so bypassing process_donation never leaves wallets stale.
-- ============================================================


-- ── FIX 1 & 2: Rewrite process_donation with fresh read + week_donated ───────

CREATE OR REPLACE FUNCTION process_donation(
  p_sender_id   UUID,
  p_receiver_id UUID,
  p_amount      NUMERIC,
  p_note        TEXT,
  p_sender_ip   TEXT DEFAULT NULL
)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_sw          wallets%ROWTYPE;
  v_rw          wallets%ROWTYPE;
  v_su          users%ROWTYPE;
  v_donation_id UUID;
  v_today_count INTEGER;
  v_today_amt   NUMERIC;
  v_last_don    TIMESTAMPTZ;
  v_fraud_score INTEGER := 0;
BEGIN
  IF p_sender_id = p_receiver_id THEN RAISE EXCEPTION 'Cannot donate to yourself'; END IF;

  SELECT * INTO v_su FROM users WHERE id = p_sender_id;
  IF NOT FOUND         THEN RAISE EXCEPTION 'Sender not found'; END IF;
  IF v_su.is_suspended THEN RAISE EXCEPTION 'Account suspended'; END IF;

  SELECT * INTO v_sw FROM wallets WHERE user_id = p_sender_id   FOR UPDATE;
  SELECT * INTO v_rw FROM wallets WHERE user_id = p_receiver_id FOR UPDATE;

  -- Account age & bet requirement
  IF v_su.created_at > now() - ((get_config_value('min_account_age_days'))::INTEGER || ' days')::INTERVAL THEN
    RAISE EXCEPTION 'Account must be older to donate';
  END IF;
  IF v_su.completed_bets < (get_config_value('min_completed_bets'))::INTEGER THEN
    RAISE EXCEPTION 'Complete more bets before donating';
  END IF;

  -- Daily limits
  SELECT COUNT(*), COALESCE(SUM(amount), 0) INTO v_today_count, v_today_amt
  FROM donations WHERE sender_id = p_sender_id AND created_at > now() - INTERVAL '24 hours';
  IF v_today_count >= (get_config_value('donation_daily_max'))::INTEGER THEN
    RAISE EXCEPTION 'Daily donation limit reached';
  END IF;
  IF v_today_amt + p_amount > (get_config_value('donation_daily_amount'))::NUMERIC THEN
    RAISE EXCEPTION 'Daily donation amount limit reached';
  END IF;

  -- Cooldown
  SELECT created_at INTO v_last_don FROM donations WHERE sender_id = p_sender_id
  ORDER BY created_at DESC LIMIT 1;
  IF FOUND AND v_last_don > now() - ((get_config_value('donation_cooldown_min'))::INTEGER || ' minutes')::INTERVAL THEN
    RAISE EXCEPTION 'Cooldown active between donations';
  END IF;

  -- ★ FIX 1: Auto-reset receiver weekly cap then re-read fresh
  IF v_rw.week_received_reset_at < now() - INTERVAL '7 days' THEN
    UPDATE wallets SET week_received = 0, week_received_reset_at = now()
    WHERE user_id = p_receiver_id;
    SELECT * INTO v_rw FROM wallets WHERE user_id = p_receiver_id FOR UPDATE;
  END IF;

  IF v_rw.week_received + p_amount > (get_config_value('donation_weekly_cap'))::NUMERIC THEN
    RAISE EXCEPTION 'Receiver weekly cap reached (received ₹% this week, cap is ₹%)',
      v_rw.week_received, get_config_value('donation_weekly_cap');
  END IF;

  IF p_amount > v_sw.available_balance THEN
    RAISE EXCEPTION 'Insufficient available balance';
  END IF;

  -- Fraud check
  IF EXISTS (
    SELECT 1 FROM donations
    WHERE sender_id = p_receiver_id AND receiver_id = p_sender_id
      AND created_at > now() - INTERVAL '24 hours'
  ) THEN
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

  -- Deduct from sender
  UPDATE wallets SET
    available_balance = available_balance - p_amount,
    total_donated     = total_donated     + p_amount,
    -- ★ FIX 2: track week_donated (was missing)
    week_donated      = COALESCE(week_donated, 0) + p_amount,
    updated_at        = now()
  WHERE user_id = p_sender_id;

  -- Credit receiver
  UPDATE wallets SET
    available_balance    = available_balance + p_amount,
    total_received       = total_received    + p_amount,
    week_received        = week_received     + p_amount,
    updated_at           = now()
  WHERE user_id = p_receiver_id;

  INSERT INTO donations (sender_id, receiver_id, amount, note, sender_ip, status)
  VALUES (p_sender_id, p_receiver_id, p_amount, p_note, p_sender_ip, 'completed')
  RETURNING id INTO v_donation_id;

  INSERT INTO transactions (user_id, type, amount, balance_before, balance_after, ref_id, ref_type, note)
  VALUES
    (p_sender_id,   'donation_sent',     p_amount,
      v_sw.available_balance, v_sw.available_balance - p_amount,
      v_donation_id, 'donation', COALESCE(NULLIF(p_note,''), 'Donation sent')),
    (p_receiver_id, 'donation_received', p_amount,
      v_rw.available_balance, v_rw.available_balance + p_amount,
      v_donation_id, 'donation', COALESCE(NULLIF(p_note,''), 'Donation received'));

  RETURN jsonb_build_object('success', true, 'donation_id', v_donation_id);
END;
$$;


-- ── FIX 3: Trigger — any direct donation insert syncs wallets ────────────────
-- Protects against admin direct-inserts bypassing process_donation.

CREATE OR REPLACE FUNCTION trg_donation_sync_wallets()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  -- Only fire for completed donations not already handled by process_donation
  -- We detect "bypassed" donations by checking if no matching transaction exists
  IF NEW.status = 'completed' AND NOT EXISTS (
    SELECT 1 FROM transactions
    WHERE ref_id = NEW.id AND type = 'donation_received'
  ) THEN
    -- Sync receiver wallet
    UPDATE wallets SET
      available_balance = available_balance + NEW.amount,
      total_received    = total_received    + NEW.amount,
      week_received     = week_received     + NEW.amount,
      updated_at        = now()
    WHERE user_id = NEW.receiver_id;

    -- Sync sender wallet
    UPDATE wallets SET
      available_balance = available_balance - NEW.amount,
      total_donated     = total_donated     + NEW.amount,
      updated_at        = now()
    WHERE user_id = NEW.sender_id;

    -- Insert missing transactions
    INSERT INTO transactions (user_id, type, amount, balance_before, balance_after, ref_id, ref_type, note)
    SELECT
      NEW.sender_id, 'donation_sent'::transaction_type, NEW.amount,
      available_balance + NEW.amount, available_balance,
      NEW.id, 'donation', COALESCE(NULLIF(NEW.note,''), 'Donation sent')
    FROM wallets WHERE user_id = NEW.sender_id;

    INSERT INTO transactions (user_id, type, amount, balance_before, balance_after, ref_id, ref_type, note)
    SELECT
      NEW.receiver_id, 'donation_received'::transaction_type, NEW.amount,
      available_balance - NEW.amount, available_balance,
      NEW.id, 'donation', COALESCE(NULLIF(NEW.note,''), 'Donation received')
    FROM wallets WHERE user_id = NEW.receiver_id;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_donation_wallet_sync ON donations;
CREATE TRIGGER trg_donation_wallet_sync
  AFTER INSERT ON donations
  FOR EACH ROW EXECUTE FUNCTION trg_donation_sync_wallets();


-- ── Immediate fix: resync all wallets from transaction history ────────────────
UPDATE wallets w
SET week_received = COALESCE((
  SELECT SUM(amount) FROM transactions t
  WHERE t.user_id = w.user_id
    AND t.type = 'donation_received'
    AND t.created_at >= now() - INTERVAL '7 days'
), 0)
WHERE user_id IN (SELECT DISTINCT user_id FROM transactions WHERE type = 'donation_received');

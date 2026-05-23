-- ============================================================
-- MIGRATION 009: Real-time global wallet sync (delta-based)
-- ============================================================
--
-- DESIGN:
--   league_members.credits  = league wallet (betting/donations, isolated)
--   wallets.available_balance = global wallet (reflects all league activity)
--
--   They stay SEPARATE values. When league credits change by a delta,
--   the same delta is applied to the global wallet.
--
--   Example:
--     Win ₹500 in League A → league credits +₹500, global wallet +₹500
--     Lose ₹200 in League B → league credits -₹200, global wallet -₹200
--     Admin adjusts league +₹1000 → global wallet +₹1000
--
--   This preserves league individuality while keeping global wallet
--   as an accurate real-time total across all leagues.
--
-- TRIGGER APPROACH (delta, not replace):
--   ON UPDATE league_members:
--     delta = NEW.credits - OLD.credits
--     wallets.available_balance += delta
--   ON INSERT league_members (join league):
--     wallets.available_balance += NEW.credits  (starting credits added)
--   ON DELETE league_members (leave league):
--     wallets.available_balance -= OLD.credits  (credits removed)
-- ============================================================


-- ── STEP 1: Delta-based trigger on league_members ────────────────────────────

CREATE OR REPLACE FUNCTION trg_sync_global_wallet_delta()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_delta NUMERIC := 0;
  v_uid   UUID;
BEGIN
  IF TG_OP = 'INSERT' THEN
    -- User joined a league and got starting credits
    v_delta := NEW.credits + COALESCE(NEW.locked_credits, 0);
    v_uid   := NEW.user_id;

  ELSIF TG_OP = 'UPDATE' THEN
    -- Credits changed — apply only the difference
    v_delta := (NEW.credits + COALESCE(NEW.locked_credits, 0))
             - (OLD.credits + COALESCE(OLD.locked_credits, 0));
    v_uid   := NEW.user_id;

  ELSIF TG_OP = 'DELETE' THEN
    -- User left league — remove their credits from global
    v_delta := -1 * (OLD.credits + COALESCE(OLD.locked_credits, 0));
    v_uid   := OLD.user_id;
  END IF;

  -- Only update if there's an actual change
  IF v_delta <> 0 THEN
    UPDATE wallets
    SET
      available_balance = GREATEST(0, available_balance + v_delta),
      updated_at        = now()
    WHERE user_id = v_uid;
  END IF;

  RETURN COALESCE(NEW, OLD);
END;
$$;

DROP TRIGGER IF EXISTS trg_lm_sync_wallet ON league_members;
CREATE TRIGGER trg_lm_sync_wallet
  AFTER INSERT OR UPDATE OR DELETE ON league_members
  FOR EACH ROW EXECUTE FUNCTION trg_sync_global_wallet_delta();


-- ── STEP 2: Manual resync function (for corrections/admin use) ───────────────
-- Recalculates from scratch based on current league credits.
-- Use this if wallets ever drift out of sync.

CREATE OR REPLACE FUNCTION admin_resync_global_wallet(p_user_id UUID)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_league_total NUMERIC;
  v_old_bal      NUMERIC;
BEGIN
  SELECT COALESCE(SUM(credits + COALESCE(locked_credits, 0)), 0)
    INTO v_league_total
    FROM league_members
   WHERE user_id = p_user_id;

  SELECT available_balance INTO v_old_bal
    FROM wallets WHERE user_id = p_user_id;

  UPDATE wallets
  SET available_balance = v_league_total,
      updated_at        = now()
  WHERE user_id = p_user_id;

  RETURN jsonb_build_object(
    'success',       true,
    'old_balance',   v_old_bal,
    'new_balance',   v_league_total,
    'recalculated_from', 'league_members'
  );
END;
$$;


-- ── STEP 3: Backfill — resync ALL existing users from league credits ──────────
-- One-time correction to align existing global wallets with league credits.

DO $$
DECLARE
  v_uid          UUID;
  v_league_total NUMERIC;
BEGIN
  FOR v_uid IN SELECT DISTINCT user_id FROM league_members LOOP
    SELECT COALESCE(SUM(credits + COALESCE(locked_credits, 0)), 0)
      INTO v_league_total
      FROM league_members
     WHERE user_id = v_uid;

    UPDATE wallets
    SET available_balance = v_league_total,
        updated_at        = now()
    WHERE user_id = v_uid;
  END LOOP;
END;
$$;


-- ── STEP 4: Update admin_adjust_league_wallet ────────────────────────────────
-- Trigger now handles global wallet sync automatically.
-- This function stays identical — just needs the transaction_type cast fix.

CREATE OR REPLACE FUNCTION admin_adjust_league_wallet(
  p_admin_id   UUID,
  p_user_id    UUID,
  p_league_id  UUID,
  p_amount     NUMERIC,
  p_type       TEXT,
  p_reason     TEXT
)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_member  league_members%ROWTYPE;
  v_new_bal NUMERIC;
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM users
    WHERE id = p_admin_id AND role IN ('admin', 'superadmin')
  ) THEN
    RAISE EXCEPTION 'Unauthorized';
  END IF;

  SELECT * INTO v_member
    FROM league_members
   WHERE user_id = p_user_id AND league_id = p_league_id
   FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'User is not a member of this league';
  END IF;

  IF p_type = 'credit' THEN
    v_new_bal := v_member.credits + p_amount;
  ELSE
    IF v_member.credits < p_amount THEN
      RAISE EXCEPTION 'Insufficient league credits (has ₹%, trying to debit ₹%)',
        v_member.credits, p_amount;
    END IF;
    v_new_bal := v_member.credits - p_amount;
  END IF;

  -- Update league credits → trigger auto-applies delta to global wallet
  UPDATE league_members SET
    credits    = v_new_bal,
    updated_at = now()
  WHERE user_id = p_user_id AND league_id = p_league_id;

  INSERT INTO transactions (user_id, type, amount, balance_before, balance_after, note)
  VALUES (
    p_user_id,
    CASE WHEN p_type = 'credit' THEN 'admin_credit' ELSE 'admin_debit' END::transaction_type,
    p_amount,
    v_member.credits,
    v_new_bal,
    format('[League] %s', p_reason)
  );

  INSERT INTO admin_logs (admin_id, action, target_type, target_id, old_value, new_value)
  VALUES (
    p_admin_id,
    'league_wallet_' || p_type,
    'user', p_user_id,
    jsonb_build_object('league_credits', v_member.credits, 'league_id', p_league_id),
    jsonb_build_object('league_credits', v_new_bal, 'reason', p_reason, 'league_id', p_league_id)
  );

  RETURN jsonb_build_object('success', true, 'new_league_balance', v_new_bal);
END;
$$;


-- ── VERIFY after running ─────────────────────────────────────────────────────
-- Check trigger is active:
--   SELECT tgname, tgenabled FROM pg_trigger WHERE tgname = 'trg_lm_sync_wallet';
--
-- Check a user's sync:
--   SELECT
--     w.available_balance AS global,
--     SUM(lm.credits + COALESCE(lm.locked_credits,0)) AS league_total
--   FROM wallets w
--   JOIN league_members lm ON lm.user_id = w.user_id
--   WHERE w.user_id = '<uuid>'
--   GROUP BY w.available_balance;
--   -- global and league_total should match
-- ============================================================

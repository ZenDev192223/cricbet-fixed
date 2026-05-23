-- ============================================================
-- MIGRATION 008: Fix admin league wallet adjust
-- ============================================================
-- BUG: AdminUsers was doing a direct .update() on league_members
--      but the table only has a SELECT policy for admins — no UPDATE
--      policy. The call returned no error but changed nothing.
--
-- FIX: A SECURITY DEFINER function that bypasses RLS, mirrors
--      the same pattern as admin_adjust_wallet for global wallets.
-- ============================================================

CREATE OR REPLACE FUNCTION admin_adjust_league_wallet(
  p_admin_id   UUID,
  p_user_id    UUID,
  p_league_id  UUID,
  p_amount     NUMERIC,
  p_type       TEXT,    -- 'credit' | 'debit'
  p_reason     TEXT
)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_member   league_members%ROWTYPE;
  v_new_bal  NUMERIC;
BEGIN
  -- Verify caller is admin/superadmin
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

  UPDATE league_members SET
    credits    = v_new_bal,
    updated_at = now()
  WHERE user_id = p_user_id AND league_id = p_league_id;

  -- Transaction record
  INSERT INTO transactions (user_id, type, amount, balance_before, balance_after, note)
  VALUES (
    p_user_id,
    CASE WHEN p_type = 'credit' THEN 'admin_credit' ELSE 'admin_debit' END::transaction_type,
    p_amount,
    v_member.credits,
    v_new_bal,
    format('[League] %s', p_reason)
  );

  -- Audit log
  INSERT INTO admin_logs (admin_id, action, target_type, target_id, old_value, new_value)
  VALUES (
    p_admin_id,
    'league_wallet_' || p_type,
    'user',
    p_user_id,
    jsonb_build_object('league_credits', v_member.credits, 'league_id', p_league_id),
    jsonb_build_object('league_credits', v_new_bal, 'reason', p_reason, 'league_id', p_league_id)
  );

  RETURN jsonb_build_object('success', true, 'new_balance', v_new_bal);
END;
$$;

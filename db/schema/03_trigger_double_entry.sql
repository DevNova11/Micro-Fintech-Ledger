-- ============================================================================
-- 03_trigger_double_entry.sql — debit = credit invariant enforcement
--
-- Design (Review 1, slide 20 — "Math Check Trigger"):
--   "Runs a database check before saving; if debits do not equal credits,
--    the entire transfer cancels automatically."
--
-- Implementation: a DEFERRABLE CONSTRAINT TRIGGER, fired AFTER INSERT on
-- entry_lines, checked at COMMIT time (not per-row). This lets the transfer
-- procedure insert the debit leg and the credit leg as two separate
-- statements inside one transaction — the invariant is only evaluated once,
-- after both legs exist, rather than failing on the first (unbalanced)
-- insert. This directly addresses research gap #5 (connecting algebraic/REA
-- double-entry theory to concrete trigger logic).
-- ============================================================================

CREATE OR REPLACE FUNCTION fn_check_double_entry_balance()
RETURNS TRIGGER AS $$
DECLARE
    v_transaction_id BIGINT;
    v_debit_total    NUMERIC(18,4);
    v_credit_total   NUMERIC(18,4);
BEGIN
    v_transaction_id := NEW.transaction_id;

    SELECT
        COALESCE(SUM(amount) FILTER (WHERE direction = 'DEBIT'), 0),
        COALESCE(SUM(amount) FILTER (WHERE direction = 'CREDIT'), 0)
    INTO v_debit_total, v_credit_total
    FROM entry_lines
    WHERE transaction_id = v_transaction_id;

    IF v_debit_total <> v_credit_total THEN
        RAISE EXCEPTION
            'Double-entry invariant violated for transaction_id=%: debits=% credits=% (difference=%)',
            v_transaction_id, v_debit_total, v_credit_total, (v_debit_total - v_credit_total)
            USING ERRCODE = 'check_violation';
    END IF;

    RETURN NULL; -- return value ignored for AFTER triggers
END;
$$ LANGUAGE plpgsql;

-- DEFERRABLE INITIALLY DEFERRED: the check runs once at COMMIT, after every
-- statement in the transaction has run — not after each individual INSERT.
CREATE CONSTRAINT TRIGGER trg_check_double_entry_balance
    AFTER INSERT ON entry_lines
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW
    EXECUTE FUNCTION fn_check_double_entry_balance();

-- debit = credit invariant, checked at COMMIT (deferred constraint trigger)

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

    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

-- DEFERRABLE INITIALLY DEFERRED: fires once at COMMIT, not per insert
CREATE CONSTRAINT TRIGGER trg_check_double_entry_balance
    AFTER INSERT ON entry_lines
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW
    EXECUTE FUNCTION fn_check_double_entry_balance();

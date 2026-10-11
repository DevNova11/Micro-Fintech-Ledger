-- append-only enforcement: block UPDATE/DELETE on ledger tables

CREATE OR REPLACE FUNCTION fn_block_mutation()
RETURNS TRIGGER AS $$
BEGIN
    RAISE EXCEPTION
        'Table % is append-only: % is not permitted (pk context: %)',
        TG_TABLE_NAME, TG_OP, TG_ARGV[0]
        USING ERRCODE = 'insufficient_privilege';
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_entry_lines_immutable
    BEFORE UPDATE OR DELETE ON entry_lines
    FOR EACH ROW
    EXECUTE FUNCTION fn_block_mutation('entry_line_id');

CREATE TRIGGER trg_audit_merkle_log_immutable
    BEFORE UPDATE OR DELETE ON audit_merkle_log
    FOR EACH ROW
    EXECUTE FUNCTION fn_block_mutation('log_id');

-- transactions: DELETE always blocked; UPDATE blocked once terminal
CREATE OR REPLACE FUNCTION fn_block_transaction_mutation()
RETURNS TRIGGER AS $$
BEGIN
    IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION
            'transactions is append-only: DELETE is never permitted (transaction_id=%)',
            OLD.transaction_id
            USING ERRCODE = 'insufficient_privilege';
    END IF;

    IF OLD.status IN ('COMMITTED', 'ROLLED_BACK') THEN
        RAISE EXCEPTION
            'transaction_id=% is in terminal status % and cannot be modified further',
            OLD.transaction_id, OLD.status
            USING ERRCODE = 'insufficient_privilege';
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_transactions_immutable_after_terminal
    BEFORE UPDATE OR DELETE ON transactions
    FOR EACH ROW
    EXECUTE FUNCTION fn_block_transaction_mutation();

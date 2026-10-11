-- ============================================================================
-- 04_trigger_immutability.sql — append-only enforcement on ledger tables
--
-- Design (Review 1, slide 20 — "No Edits or Deletions"):
--   "Special database triggers instantly reject any UPDATE or DELETE
--    commands on ledger entries."
--
-- entry_lines and audit_merkle_log are fully immutable: once a row exists,
-- it can never be changed or removed by any client, including a superuser
-- session (short of disabling the trigger itself, which is logged as DDL).
--
-- transactions is a special case: its header legitimately transitions
-- PENDING -> COMMITTED or PENDING -> ROLLED_BACK, and settled_at is set at
-- that time. So transactions is immutable only once it reaches a terminal
-- status (COMMITTED or ROLLED_BACK); DELETE is blocked unconditionally.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- Generic "fully immutable" trigger function — reused by entry_lines and
-- audit_merkle_log.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_block_mutation()
RETURNS TRIGGER AS $$
BEGIN
    RAISE EXCEPTION
        'Table % is append-only: % is not permitted (attempted on row with primary key context: %)',
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

-- ----------------------------------------------------------------------------
-- transactions: block DELETE always; block UPDATE once status is terminal.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_block_transaction_mutation()
RETURNS TRIGGER AS $$
BEGIN
    IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION
            'transactions is append-only: DELETE is never permitted (transaction_id=%)',
            OLD.transaction_id
            USING ERRCODE = 'insufficient_privilege';
    END IF;

    -- TG_OP = 'UPDATE' from here on.
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

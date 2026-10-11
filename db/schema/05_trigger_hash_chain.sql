-- ============================================================================
-- 05_trigger_hash_chain.sql — SHA-256 hash-chained audit trail
--
-- Design (Review 1, slide 16/20 — "Chained Security Hashes"):
--   "Upon insertion, an active database trigger calculates a SHA-256 hash
--    chaining the previous entry state and saves the record into
--    AUDIT_MERKLE_LOG."
--
-- This is the relational substitute for blockchain-style tamper-evidence
-- (research gap #2): each new audit row's hash is a function of its own
-- entry_line data AND the previous audit row's hash, so altering any past
-- row breaks every hash computed after it — independently re-computable
-- and verifiable by anyone with read access, not just enforced by the
-- immutability trigger.
--
-- Concurrency note: entry_lines are inserted by many concurrent transfer
-- transactions. Because the hash chain is a single global sequence, two
-- concurrent inserts must not read the same "previous hash" and both chain
-- off it. We serialize chain appends with a transaction-scoped advisory
-- lock (pg_advisory_xact_lock) — cheaper than locking the whole table, and
-- automatically released at COMMIT/ROLLBACK.
-- ============================================================================

CREATE OR REPLACE FUNCTION fn_append_audit_hash()
RETURNS TRIGGER AS $$
DECLARE
    v_prev_hash   CHAR(64);
    v_payload     TEXT;
    v_entry_hash  CHAR(64);
    -- Arbitrary fixed key identifying "the audit hash chain" lock domain.
    c_chain_lock_key CONSTANT BIGINT := 918273645;
BEGIN
    -- Serialize against every other concurrent append to this chain.
    PERFORM pg_advisory_xact_lock(c_chain_lock_key);

    SELECT entry_hash INTO v_prev_hash
    FROM audit_merkle_log
    ORDER BY log_id DESC
    LIMIT 1;

    -- Canonical payload: every field that must be tamper-evident, pipe-
    -- delimited. Order and field set must stay stable — changing this
    -- later breaks verifiability of the historical chain.
    v_payload := NEW.entry_line_id || '|' || NEW.transaction_id || '|' ||
                 NEW.account_id || '|' || NEW.direction || '|' ||
                 NEW.currency_code || '|' || NEW.amount || '|' ||
                 NEW.created_at || '|' || COALESCE(v_prev_hash, 'GENESIS');

    v_entry_hash := encode(digest(v_payload, 'sha256'), 'hex');

    INSERT INTO audit_merkle_log (entry_line_id, entry_hash, prev_hash)
    VALUES (NEW.entry_line_id, v_entry_hash, v_prev_hash);

    RETURN NULL; -- AFTER trigger, return value ignored
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_entry_lines_hash_chain
    AFTER INSERT ON entry_lines
    FOR EACH ROW
    EXECUTE FUNCTION fn_append_audit_hash();

-- ----------------------------------------------------------------------------
-- Verification helper: walk the whole chain and confirm every row's stored
-- hash matches a fresh recomputation. Returns the first broken log_id, or
-- NULL if the chain is intact. Used by the test harness and by
-- reconciliation_runs.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_verify_audit_chain()
RETURNS BIGINT AS $$
DECLARE
    rec              RECORD;
    v_expected_prev  CHAR(64) := NULL;
    v_recomputed     CHAR(64);
    v_payload        TEXT;
    v_entry          RECORD;
BEGIN
    FOR rec IN SELECT * FROM audit_merkle_log ORDER BY log_id ASC LOOP
        IF rec.prev_hash IS DISTINCT FROM v_expected_prev THEN
            RETURN rec.log_id; -- chain link broken
        END IF;

        SELECT * INTO v_entry FROM entry_lines WHERE entry_line_id = rec.entry_line_id;

        v_payload := v_entry.entry_line_id || '|' || v_entry.transaction_id || '|' ||
                     v_entry.account_id || '|' || v_entry.direction || '|' ||
                     v_entry.currency_code || '|' || v_entry.amount || '|' ||
                     v_entry.created_at || '|' || COALESCE(rec.prev_hash, 'GENESIS');

        v_recomputed := encode(digest(v_payload, 'sha256'), 'hex');

        IF v_recomputed <> rec.entry_hash THEN
            RETURN rec.log_id; -- hash mismatch: tampering detected
        END IF;

        v_expected_prev := rec.entry_hash;
    END LOOP;

    RETURN NULL; -- chain fully verified, intact
END;
$$ LANGUAGE plpgsql;

-- SHA-256 hash-chained audit trail on entry_lines insert

CREATE OR REPLACE FUNCTION fn_append_audit_hash()
RETURNS TRIGGER AS $$
DECLARE
    v_prev_hash   CHAR(64);
    v_payload     TEXT;
    v_entry_hash  CHAR(64);
    c_chain_lock_key CONSTANT BIGINT := 918273645; -- advisory lock: serialize chain appends
BEGIN
    PERFORM pg_advisory_xact_lock(c_chain_lock_key);

    SELECT entry_hash INTO v_prev_hash
    FROM audit_merkle_log
    ORDER BY log_id DESC
    LIMIT 1;

    v_payload := NEW.entry_line_id || '|' || NEW.transaction_id || '|' ||
                 NEW.account_id || '|' || NEW.direction || '|' ||
                 NEW.currency_code || '|' || NEW.amount || '|' ||
                 NEW.created_at || '|' || COALESCE(v_prev_hash, 'GENESIS');

    v_entry_hash := encode(digest(v_payload, 'sha256'), 'hex');

    INSERT INTO audit_merkle_log (entry_line_id, entry_hash, prev_hash)
    VALUES (NEW.entry_line_id, v_entry_hash, v_prev_hash);

    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_entry_lines_hash_chain
    AFTER INSERT ON entry_lines
    FOR EACH ROW
    EXECUTE FUNCTION fn_append_audit_hash();

-- verify chain integrity; returns first broken log_id or NULL
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
            RETURN rec.log_id;
        END IF;

        SELECT * INTO v_entry FROM entry_lines WHERE entry_line_id = rec.entry_line_id;

        v_payload := v_entry.entry_line_id || '|' || v_entry.transaction_id || '|' ||
                     v_entry.account_id || '|' || v_entry.direction || '|' ||
                     v_entry.currency_code || '|' || v_entry.amount || '|' ||
                     v_entry.created_at || '|' || COALESCE(rec.prev_hash, 'GENESIS');

        v_recomputed := encode(digest(v_payload, 'sha256'), 'hex');

        IF v_recomputed <> rec.entry_hash THEN
            RETURN rec.log_id;
        END IF;

        v_expected_prev := rec.entry_hash;
    END LOOP;

    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

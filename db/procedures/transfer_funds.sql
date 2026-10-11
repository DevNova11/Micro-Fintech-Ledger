-- ============================================================================
-- transfer_funds.sql — the core settlement procedure
--
-- Implements the 7-step flow from Review 1 (slides 15-16, 19-20):
--   1. Idempotency check against api_clients / idempotency_keys
--   2. Fixed-order row-level locking on accounts (lower ID first), logged
--      to concurrency_lock_log
--   3. Transaction header registered in transactions (status PENDING)
--   4. Debit + credit legs inserted into entry_lines
--   5. Debit=credit invariant checked automatically at COMMIT (trigger 03)
--   6. SHA-256 hash chain appended automatically on each insert (trigger 05)
--   7. Transaction header finalized to COMMITTED
--
-- Adaptation note: the design text describes locking (step 2) happening
-- before the transaction header is created (step 3). Because
-- concurrency_lock_log.transaction_id is a NOT NULL foreign key (so every
-- lock entry is always traceable to a transaction — no orphan lock
-- records), this procedure creates the header first, then locks and logs
-- immediately after. Since the whole procedure runs as a single atomic
-- database transaction, this reordering has no observable effect on
-- correctness or isolation — it only satisfies referential integrity.
--
-- Failure semantics (insufficient funds, self-transfer, imbalance): this
-- procedure raises an exception and the ENTIRE call rolls back, including
-- the transaction header — no PENDING/FAILED row is left behind. This
-- mirrors the documented behavior for the debit=credit check ("Unbalanced:
-- the database engine triggers an immediate rollback") and keeps the
-- ledger's append-only property simple: a row exists if and only if the
-- transfer actually happened.
-- ============================================================================

-- A transfer above this amount is flagged in risk_alerts as a simple
-- large-value check. This specific threshold/mechanism is an added
-- implementation detail (to make use of the RISK_ALERTS table drawn in
-- the ERD) rather than a figure given in the Review 1 slides — call it
-- out as such if asked in review.
CREATE OR REPLACE FUNCTION transfer_funds(
    p_client_id        BIGINT,
    p_idempotency_key   VARCHAR(128),
    p_from_account_id  BIGINT,
    p_to_account_id    BIGINT,
    p_amount           NUMERIC(18,4),
    p_currency_code    CHAR(3),
    p_settlement_type  VARCHAR(16) DEFAULT 'RTGS'
)
RETURNS BIGINT AS $$
DECLARE
    v_existing_txn_id   BIGINT;
    v_transaction_id    BIGINT;
    v_lower_account_id  BIGINT;
    v_higher_account_id BIGINT;
    v_from_balance      NUMERIC(18,4);
    c_large_value_threshold CONSTANT NUMERIC(18,4) := 100000.0000;
BEGIN
    -- --------------------------------------------------------------
    -- Guard clauses
    -- --------------------------------------------------------------
    IF p_from_account_id = p_to_account_id THEN
        RAISE EXCEPTION 'Cannot transfer to the same account (account_id=%)', p_from_account_id;
    END IF;

    IF p_amount <= 0 THEN
        RAISE EXCEPTION 'Transfer amount must be positive, got %', p_amount;
    END IF;

    -- --------------------------------------------------------------
    -- Step 1: Idempotency check
    -- --------------------------------------------------------------
    SELECT transaction_id INTO v_existing_txn_id
    FROM idempotency_keys
    WHERE client_id = p_client_id AND idempotency_key = p_idempotency_key;

    IF FOUND AND v_existing_txn_id IS NOT NULL THEN
        -- Replay of an already-completed request: return the same
        -- transaction_id, do NOT move money again.
        RETURN v_existing_txn_id;
    END IF;

    IF NOT FOUND THEN
        -- Reserve the key now, before doing any work, so a concurrent
        -- duplicate request racing in fails on the UNIQUE constraint
        -- (client_id, idempotency_key) instead of double-executing.
        INSERT INTO idempotency_keys (client_id, idempotency_key)
        VALUES (p_client_id, p_idempotency_key);
    END IF;

    -- --------------------------------------------------------------
    -- Step 3 (header created first — see adaptation note above)
    -- --------------------------------------------------------------
    INSERT INTO transactions (settlement_type, status, currency_code)
    VALUES (p_settlement_type, 'PENDING', p_currency_code)
    RETURNING transaction_id INTO v_transaction_id;

    UPDATE idempotency_keys
    SET transaction_id = v_transaction_id
    WHERE client_id = p_client_id AND idempotency_key = p_idempotency_key;

    -- --------------------------------------------------------------
    -- Step 2: fixed-order locking (lower account_id first) to prevent
    -- deadlocks between two transfers that touch the same pair of
    -- accounts in opposite order.
    -- --------------------------------------------------------------
    v_lower_account_id  := LEAST(p_from_account_id, p_to_account_id);
    v_higher_account_id := GREATEST(p_from_account_id, p_to_account_id);

    PERFORM 1 FROM accounts WHERE account_id = v_lower_account_id FOR UPDATE;
    INSERT INTO concurrency_lock_log (transaction_id, account_id, lock_order)
    VALUES (v_transaction_id, v_lower_account_id, 1);

    PERFORM 1 FROM accounts WHERE account_id = v_higher_account_id FOR UPDATE;
    INSERT INTO concurrency_lock_log (transaction_id, account_id, lock_order)
    VALUES (v_transaction_id, v_higher_account_id, 2);

    -- --------------------------------------------------------------
    -- Sufficient-funds check (both accounts are now locked, so this
    -- read is safe from concurrent modification).
    -- --------------------------------------------------------------
    SELECT cached_balance INTO v_from_balance
    FROM accounts WHERE account_id = p_from_account_id;

    IF v_from_balance < p_amount THEN
        RAISE EXCEPTION
            'Insufficient funds in account_id=%: balance=% requested=%',
            p_from_account_id, v_from_balance, p_amount;
    END IF;

    -- --------------------------------------------------------------
    -- Step 4: double-entry legs
    -- --------------------------------------------------------------
    INSERT INTO entry_lines (transaction_id, account_id, direction, currency_code, amount)
    VALUES (v_transaction_id, p_from_account_id, 'DEBIT', p_currency_code, p_amount);

    INSERT INTO entry_lines (transaction_id, account_id, direction, currency_code, amount)
    VALUES (v_transaction_id, p_to_account_id, 'CREDIT', p_currency_code, p_amount);

    -- Maintain the cached running balance (source of truth remains
    -- SUM(entry_lines); this is a read-optimization only).
    UPDATE accounts SET cached_balance = cached_balance - p_amount WHERE account_id = p_from_account_id;
    UPDATE accounts SET cached_balance = cached_balance + p_amount WHERE account_id = p_to_account_id;

    -- Simple large-value risk flag (see function-level comment).
    IF p_amount >= c_large_value_threshold THEN
        INSERT INTO risk_alerts (transaction_id, alert_type, severity, details)
        VALUES (v_transaction_id, 'LARGE_VALUE_TRANSFER', 'MEDIUM',
                format('Transfer of %s %s exceeds large-value threshold of %s', p_amount, p_currency_code, c_large_value_threshold));
    END IF;

    -- --------------------------------------------------------------
    -- Step 7: finalize. Steps 5 (balance invariant) and 6 (hash chain)
    -- have already run as triggers on the entry_lines inserts above;
    -- the balance invariant itself is checked at COMMIT (deferred).
    -- --------------------------------------------------------------
    UPDATE transactions
    SET status = 'COMMITTED', settled_at = now()
    WHERE transaction_id = v_transaction_id;

    -- Release the locks explicitly in concurrency_lock_log bookkeeping
    -- (the actual row locks are released at COMMIT regardless).
    UPDATE concurrency_lock_log
    SET released_at = now()
    WHERE transaction_id = v_transaction_id;

    RETURN v_transaction_id;
END;
$$ LANGUAGE plpgsql;

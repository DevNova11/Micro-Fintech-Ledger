-- transfer_funds(): moves money between two accounts in one database transaction.
-- Steps: validate, idempotency check, create PENDING transaction, lock both
-- accounts (lower id first), check funds, write DEBIT/CREDIT lines and balances,
-- mark COMMITTED. The double-entry check and hash chain run as triggers.
-- Any failure rolls back everything, including the transaction row.

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
    c_large_value_threshold CONSTANT NUMERIC(18,4) := 100000.0000; -- risk alert at or above this
BEGIN
    IF p_from_account_id = p_to_account_id THEN
        RAISE EXCEPTION 'Cannot transfer to the same account (account_id=%)', p_from_account_id;
    END IF;

    IF p_amount <= 0 THEN
        RAISE EXCEPTION 'Transfer amount must be positive, got %', p_amount;
    END IF;

    SELECT transaction_id INTO v_existing_txn_id
    FROM idempotency_keys
    WHERE client_id = p_client_id AND idempotency_key = p_idempotency_key;

    IF FOUND AND v_existing_txn_id IS NOT NULL THEN
        RETURN v_existing_txn_id;
    END IF;

    IF NOT FOUND THEN
        INSERT INTO idempotency_keys (client_id, idempotency_key)
        VALUES (p_client_id, p_idempotency_key);
    END IF;

    -- created before the locks so the lock log can reference it
    INSERT INTO transactions (settlement_type, status, currency_code)
    VALUES (p_settlement_type, 'PENDING', p_currency_code)
    RETURNING transaction_id INTO v_transaction_id;

    UPDATE idempotency_keys
    SET transaction_id = v_transaction_id
    WHERE client_id = p_client_id AND idempotency_key = p_idempotency_key;

    -- fixed lock order (lower account_id first) prevents circular waits
    v_lower_account_id  := LEAST(p_from_account_id, p_to_account_id);
    v_higher_account_id := GREATEST(p_from_account_id, p_to_account_id);

    PERFORM 1 FROM accounts WHERE account_id = v_lower_account_id FOR UPDATE;
    INSERT INTO concurrency_lock_log (transaction_id, account_id, lock_order)
    VALUES (v_transaction_id, v_lower_account_id, 1);

    PERFORM 1 FROM accounts WHERE account_id = v_higher_account_id FOR UPDATE;
    INSERT INTO concurrency_lock_log (transaction_id, account_id, lock_order)
    VALUES (v_transaction_id, v_higher_account_id, 2);

    -- balance is read only after both locks are held
    SELECT cached_balance INTO v_from_balance
    FROM accounts WHERE account_id = p_from_account_id;

    IF v_from_balance < p_amount THEN
        RAISE EXCEPTION
            'Insufficient funds in account_id=%: balance=% requested=%',
            p_from_account_id, v_from_balance, p_amount;
    END IF;

    INSERT INTO entry_lines (transaction_id, account_id, direction, currency_code, amount)
    VALUES (v_transaction_id, p_from_account_id, 'DEBIT', p_currency_code, p_amount);

    INSERT INTO entry_lines (transaction_id, account_id, direction, currency_code, amount)
    VALUES (v_transaction_id, p_to_account_id, 'CREDIT', p_currency_code, p_amount);

    UPDATE accounts SET cached_balance = cached_balance - p_amount WHERE account_id = p_from_account_id;
    UPDATE accounts SET cached_balance = cached_balance + p_amount WHERE account_id = p_to_account_id;

    IF p_amount >= c_large_value_threshold THEN
        INSERT INTO risk_alerts (transaction_id, alert_type, severity, details)
        VALUES (v_transaction_id, 'LARGE_VALUE_TRANSFER', 'MEDIUM',
                format('Transfer of %s %s exceeds large-value threshold of %s', p_amount, p_currency_code, c_large_value_threshold));
    END IF;

    UPDATE transactions
    SET status = 'COMMITTED', settled_at = now()
    WHERE transaction_id = v_transaction_id;

    UPDATE concurrency_lock_log
    SET released_at = now()
    WHERE transaction_id = v_transaction_id;

    RETURN v_transaction_id;
END;
$$ LANGUAGE plpgsql;

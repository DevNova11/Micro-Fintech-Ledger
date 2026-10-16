-- naive_transfer_funds(): same as transfer_funds() but WITHOUT the fixed lock order.
-- It locks the sender first and the receiver second, whatever their ids are.
-- Only used by the benchmark, to show how many deadlocks that causes.
-- Not meant for real use.

CREATE OR REPLACE FUNCTION naive_transfer_funds(
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
    v_existing_txn_id BIGINT;
    v_transaction_id  BIGINT;
    v_from_balance    NUMERIC(18,4);
BEGIN
    IF p_from_account_id = p_to_account_id THEN
        RAISE EXCEPTION 'Cannot transfer to the same account (account_id=%)', p_from_account_id;
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

    INSERT INTO transactions (settlement_type, status, currency_code)
    VALUES (p_settlement_type, 'PENDING', p_currency_code)
    RETURNING transaction_id INTO v_transaction_id;

    UPDATE idempotency_keys SET transaction_id = v_transaction_id
    WHERE client_id = p_client_id AND idempotency_key = p_idempotency_key;

    -- no sorting here on purpose, this is the thing being tested
    PERFORM 1 FROM accounts WHERE account_id = p_from_account_id FOR UPDATE;
    INSERT INTO concurrency_lock_log (transaction_id, account_id, lock_order) VALUES (v_transaction_id, p_from_account_id, 1);

    PERFORM 1 FROM accounts WHERE account_id = p_to_account_id FOR UPDATE;
    INSERT INTO concurrency_lock_log (transaction_id, account_id, lock_order) VALUES (v_transaction_id, p_to_account_id, 2);

    SELECT cached_balance INTO v_from_balance FROM accounts WHERE account_id = p_from_account_id;
    IF v_from_balance < p_amount THEN
        RAISE EXCEPTION 'Insufficient funds in account_id=%: balance=% requested=%', p_from_account_id, v_from_balance, p_amount;
    END IF;

    INSERT INTO entry_lines (transaction_id, account_id, direction, currency_code, amount)
    VALUES (v_transaction_id, p_from_account_id, 'DEBIT', p_currency_code, p_amount);
    INSERT INTO entry_lines (transaction_id, account_id, direction, currency_code, amount)
    VALUES (v_transaction_id, p_to_account_id, 'CREDIT', p_currency_code, p_amount);

    UPDATE accounts SET cached_balance = cached_balance - p_amount WHERE account_id = p_from_account_id;
    UPDATE accounts SET cached_balance = cached_balance + p_amount WHERE account_id = p_to_account_id;

    UPDATE transactions SET status = 'COMMITTED', settled_at = now() WHERE transaction_id = v_transaction_id;
    UPDATE concurrency_lock_log SET released_at = now() WHERE transaction_id = v_transaction_id;

    RETURN v_transaction_id;
END;
$$ LANGUAGE plpgsql;

-- transfer_funds() end-to-end test

INSERT INTO currencies (currency_code, currency_name) VALUES ('INR', 'Indian Rupee');
INSERT INTO institutions (institution_name, swift_bic, country_code) VALUES ('Test Bank', 'TESTINBBXXX', 'IN');
INSERT INTO account_holder (institution_id, full_name, kyc_status) VALUES (1, 'Alice', 'VERIFIED'), (1, 'Bob', 'VERIFIED');

-- opening balance: direct seed fixture, not routed through entry_lines;
-- everything after this moves through transfer_funds() only
INSERT INTO accounts (account_holder_id, institution_id, currency_code, account_number, cached_balance)
VALUES (1, 1, 'INR', 'ACC-ALICE-001', 200000.00), (2, 1, 'INR', 'ACC-BOB-001', 500.00);
INSERT INTO api_clients (institution_id, client_name, api_key_hash) VALUES (1, 'Test Mobile App', repeat('a', 64));

\echo '--- A: normal transfer Alice -> Bob, 100.00 ---'
SELECT transfer_funds(1, 'req-001', 1, 2, 100.00, 'INR') AS transaction_id;
SELECT account_id, cached_balance FROM accounts ORDER BY account_id;

\echo '--- B: idempotent replay, same key -> same transaction_id, no balance change ---'
SELECT transfer_funds(1, 'req-001', 1, 2, 100.00, 'INR') AS transaction_id_replay;
SELECT account_id, cached_balance FROM accounts ORDER BY account_id;

\echo '--- C: insufficient funds -> rejected ---'
SELECT transfer_funds(1, 'req-002', 2, 1, 999999.00, 'INR') AS should_fail;

\echo '--- D: self-transfer -> rejected ---'
SELECT transfer_funds(1, 'req-003', 1, 1, 10.00, 'INR') AS should_fail;

\echo '--- E: large-value transfer -> risk_alerts row ---'
SELECT transfer_funds(1, 'req-004', 1, 2, 150000.00, 'INR') AS large_txn_id;
SELECT * FROM risk_alerts;

\echo '--- F: lock log + audit chain ---'
SELECT transaction_id, account_id, lock_order FROM concurrency_lock_log ORDER BY transaction_id, lock_order;
SELECT fn_verify_audit_chain() AS broken_at_log_id; -- expect NULL
SELECT count(*) AS total_entry_lines, count(*) FILTER (WHERE direction='DEBIT') AS debits, count(*) FILTER (WHERE direction='CREDIT') AS credits FROM entry_lines;

\echo '--- G: cached_balance == opening_balance + net(entry_lines) ---'
WITH opening AS (
    SELECT 1::BIGINT AS account_id, 200000.00::NUMERIC(18,4) AS opening_balance
    UNION ALL SELECT 2, 500.00
)
SELECT a.account_id, a.cached_balance,
       o.opening_balance + COALESCE(SUM(CASE WHEN el.direction='CREDIT' THEN el.amount WHEN el.direction='DEBIT' THEN -el.amount END), 0) AS expected_balance,
       a.cached_balance = (o.opening_balance + COALESCE(SUM(CASE WHEN el.direction='CREDIT' THEN el.amount WHEN el.direction='DEBIT' THEN -el.amount END), 0)) AS matches
FROM accounts a
JOIN opening o ON o.account_id = a.account_id
LEFT JOIN entry_lines el ON el.account_id = a.account_id
GROUP BY a.account_id, a.cached_balance, o.opening_balance
ORDER BY a.account_id;

-- trigger smoke test: seed, then exercise each trigger's pass/fail path

BEGIN;
INSERT INTO currencies (currency_code, currency_name) VALUES ('INR', 'Indian Rupee');
INSERT INTO institutions (institution_name, swift_bic, country_code) VALUES ('Test Bank', 'TESTINBBXXX', 'IN');
INSERT INTO account_holder (institution_id, full_name, kyc_status)
VALUES (1, 'Alice', 'VERIFIED'), (1, 'Bob', 'VERIFIED');
INSERT INTO accounts (account_holder_id, institution_id, currency_code, account_number)
VALUES (1, 1, 'INR', 'ACC-ALICE-001'), (2, 1, 'INR', 'ACC-BOB-001');
COMMIT;

-- test 1: balanced transfer -> succeeds
BEGIN;
INSERT INTO transactions (settlement_type, status, currency_code) VALUES ('RTGS', 'PENDING', 'INR');
INSERT INTO entry_lines (transaction_id, account_id, direction, currency_code, amount)
VALUES (1, 1, 'DEBIT', 'INR', 100.00);
INSERT INTO entry_lines (transaction_id, account_id, direction, currency_code, amount)
VALUES (1, 2, 'CREDIT', 'INR', 100.00);
UPDATE transactions SET status = 'COMMITTED', settled_at = now() WHERE transaction_id = 1;
COMMIT;
\echo 'TEST 1 PASSED: balanced transfer committed'

-- test 2: unbalanced -> rejected at commit
BEGIN;
INSERT INTO transactions (settlement_type, status, currency_code) VALUES ('RTGS', 'PENDING', 'INR');
INSERT INTO entry_lines (transaction_id, account_id, direction, currency_code, amount)
VALUES (2, 1, 'DEBIT', 'INR', 50.00);
INSERT INTO entry_lines (transaction_id, account_id, direction, currency_code, amount)
VALUES (2, 2, 'CREDIT', 'INR', 49.00);
COMMIT;

-- test 3: UPDATE on entry_lines -> rejected
BEGIN;
UPDATE entry_lines SET amount = 999.00 WHERE entry_line_id = 1;
COMMIT;

-- test 4: DELETE on entry_lines -> rejected
BEGIN;
DELETE FROM entry_lines WHERE entry_line_id = 1;
COMMIT;

-- test 5: UPDATE on COMMITTED transaction -> rejected
BEGIN;
UPDATE transactions SET settlement_type = 'NET' WHERE transaction_id = 1;
COMMIT;

-- test 6: audit chain intact
SELECT fn_verify_audit_chain() AS broken_at_log_id; -- expect NULL

SELECT log_id, entry_line_id, left(prev_hash, 8) AS prev_hash_prefix, left(entry_hash, 8) AS entry_hash_prefix
FROM audit_merkle_log ORDER BY log_id;

-- Quick smoke test: seed minimal data, then exercise each trigger's
-- pass/fail path. Not the full concurrency harness (that's Python) — this
-- just proves the trigger logic itself is correct before we build on it.

BEGIN;

INSERT INTO currencies (currency_code, currency_name) VALUES ('INR', 'Indian Rupee');
INSERT INTO institutions (institution_name, swift_bic, country_code) VALUES ('Test Bank', 'TESTINBBXXX', 'IN');

INSERT INTO account_holder (institution_id, full_name, kyc_status)
VALUES (1, 'Alice', 'VERIFIED'), (1, 'Bob', 'VERIFIED');

INSERT INTO accounts (account_holder_id, institution_id, currency_code, account_number)
VALUES (1, 1, 'INR', 'ACC-ALICE-001'), (2, 1, 'INR', 'ACC-BOB-001');

COMMIT;

-- -----------------------------------------------------------------
-- Test 1: balanced transfer should succeed.
-- -----------------------------------------------------------------
BEGIN;
INSERT INTO transactions (settlement_type, status, currency_code) VALUES ('RTGS', 'PENDING', 'INR');
INSERT INTO entry_lines (transaction_id, account_id, direction, currency_code, amount)
VALUES (1, 1, 'DEBIT', 'INR', 100.00);
INSERT INTO entry_lines (transaction_id, account_id, direction, currency_code, amount)
VALUES (1, 2, 'CREDIT', 'INR', 100.00);
UPDATE transactions SET status = 'COMMITTED', settled_at = now() WHERE transaction_id = 1;
COMMIT;
\echo 'TEST 1 PASSED: balanced transfer committed'

-- -----------------------------------------------------------------
-- Test 2: unbalanced transfer should be rejected at COMMIT.
-- -----------------------------------------------------------------
BEGIN;
INSERT INTO transactions (settlement_type, status, currency_code) VALUES ('RTGS', 'PENDING', 'INR');
INSERT INTO entry_lines (transaction_id, account_id, direction, currency_code, amount)
VALUES (2, 1, 'DEBIT', 'INR', 50.00);
INSERT INTO entry_lines (transaction_id, account_id, direction, currency_code, amount)
VALUES (2, 2, 'CREDIT', 'INR', 49.00); -- deliberately unbalanced
COMMIT; -- should raise an exception here (deferred constraint fires now)

-- -----------------------------------------------------------------
-- Test 3: UPDATE on entry_lines should be rejected unconditionally.
-- -----------------------------------------------------------------
BEGIN;
UPDATE entry_lines SET amount = 999.00 WHERE entry_line_id = 1;
COMMIT;

-- -----------------------------------------------------------------
-- Test 4: DELETE on entry_lines should be rejected unconditionally.
-- -----------------------------------------------------------------
BEGIN;
DELETE FROM entry_lines WHERE entry_line_id = 1;
COMMIT;

-- -----------------------------------------------------------------
-- Test 5: UPDATE on a COMMITTED transaction should be rejected.
-- -----------------------------------------------------------------
BEGIN;
UPDATE transactions SET settlement_type = 'NET' WHERE transaction_id = 1;
COMMIT;

-- -----------------------------------------------------------------
-- Test 6: audit hash chain should verify as intact.
-- -----------------------------------------------------------------
SELECT fn_verify_audit_chain() AS broken_at_log_id; -- expect NULL

SELECT log_id, entry_line_id, left(prev_hash, 8) AS prev_hash_prefix, left(entry_hash, 8) AS entry_hash_prefix
FROM audit_merkle_log ORDER BY log_id;

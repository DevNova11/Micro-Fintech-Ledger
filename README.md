# Micro-Fintech-Ledger

Database project in SEM 3 — Decentralized Micro-FinTech Ledger & Cleared Settlement Core.

A relational, PostgreSQL-native alternative to blockchain settlement for single-institution fintech: double-entry accounting enforced by triggers, multi-granularity row locking for concurrency, and SHA-256 hash-chained audit logging for tamper-evidence — without distributed consensus overhead.

## Layout

```
db/
  schema/
    01_extensions.sql          pgcrypto
    02_tables.sql               15-relation schema (matches the Chen ER diagram)
    03_trigger_double_entry.sql debit = credit invariant (deferred constraint trigger)
    04_trigger_immutability.sql append-only enforcement on ledger tables
    05_trigger_hash_chain.sql   SHA-256 hash chain + verification function
  procedures/
    transfer_funds.sql          the 7-step settlement flow
    naive_transfer_funds.sql    comparison-only variant (no fixed lock order)
tests/
  smoke_test.sql                trigger pass/fail scenarios
  procedure_test.sql            transfer_funds() end-to-end scenarios
  concurrency_harness.py        empirical benchmark (3 experiments)
  results/                      JSON output from harness runs
docs/
  benchmark_results.md          summarized findings for the report
```

## Setup

Requires PostgreSQL 16+.

```bash
createdb fintech_ledger
psql -d fintech_ledger \
  -f db/schema/01_extensions.sql \
  -f db/schema/02_tables.sql \
  -f db/schema/03_trigger_double_entry.sql \
  -f db/schema/04_trigger_immutability.sql \
  -f db/schema/05_trigger_hash_chain.sql \
  -f db/procedures/transfer_funds.sql \
  -f db/procedures/naive_transfer_funds.sql
```

## Running the tests

```bash
psql -d fintech_ledger -f tests/smoke_test.sql
psql -d fintech_ledger -f tests/procedure_test.sql
```

## Running the concurrency benchmark

```bash
pip install --break-system-packages psycopg2-binary
python3 tests/concurrency_harness.py --dsn "dbname=fintech_ledger host=127.0.0.1 user=<user> password=<pass>"
```

Runs three experiments: correctness under high contention (READ COMMITTED vs SERIALIZABLE), throughput/latency vs isolation level, and deadlock rate (fixed lock order vs naive order). Writes a JSON summary to `tests/results/`. See `docs/benchmark_results.md` for a prior run's findings.

## Using transfer_funds()

```sql
SELECT transfer_funds(
    p_client_id        => 1,
    p_idempotency_key   => 'unique-request-id',
    p_from_account_id  => 101,
    p_to_account_id    => 202,
    p_amount           => 500.00,
    p_currency_code    => 'INR'
);
```

Calling it twice with the same `p_idempotency_key` returns the same `transaction_id` without moving money twice.

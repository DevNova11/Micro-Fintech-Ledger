# Benchmark results

Run: `tests/results/20261011_062539.json`. PostgreSQL 16, single instance, 20 threads, 25 transfers/thread (500 total per condition unless noted). Raw JSON has full latency/error breakdowns.

## Experiment 1 — correctness under contention (research gap #1)

5 accounts, 20 threads, 500 attempted transfers.

| Isolation | Committed | Throughput | p50 | p99 | Money conserved | Chain intact |
|---|---|---|---|---|---|---|
| READ COMMITTED | 500/500 | 457.8 txn/s | 9.5ms | 230.8ms | yes | yes |
| SERIALIZABLE | 209/500 | 144.7 txn/s | 19.3ms | 79.8ms | yes | yes |

Both isolation levels preserve correctness (no lost updates, no broken hash chain) — because `transfer_funds()` takes explicit `SELECT ... FOR UPDATE` locks regardless of isolation level. SERIALIZABLE adds Postgres's own conflict detection on top of that, which aborts ~58% of attempts under this contention level even after 5 retries each.

## Experiment 2 — throughput/latency, low contention

80 accounts, 20 threads, 500 attempted transfers.

| Isolation | Committed | Throughput | p50 | p99 |
|---|---|---|---|---|
| READ COMMITTED | 500/500 | 530.7 txn/s | 21.8ms | 99.1ms |
| SERIALIZABLE | 189/500 | 120.2 txn/s | 18.5ms | 89.3ms |

Same pattern with less contention: SERIALIZABLE's failure rate stays high (~62%) even when the account pool is large enough that true conflicts should be rarer — most of this is Postgres's SSI being conservative, not genuine lost-update risk (which the row locks already prevent).

## Experiment 3 — deadlock rate: fixed lock order vs naive

5 accounts, 20 threads, READ COMMITTED. `fixed_order` = `transfer_funds()`; `naive_order` = `naive_transfer_funds()` (locks in request order instead of sorted order).

| Procedure | Txns/thread | Committed | Deadlocks | Retries used | Throughput |
|---|---|---|---|---|---|
| fixed_order | 25 | 500/500 | 0 | 0 | 460.9 txn/s |
| naive_order | 8 | 129/160 | 31 | 453 | 0.81 txn/s |

**~568x throughput difference from lock ordering alone.** naive_order needed an average of ~2.8 retries per attempted transfer just to eventually succeed, and still had 31 deadlocks exhaust their retry budget outright. fixed_order needed zero retries across 500 transfers.

## Takeaway for research gap #1

Isolation level choice (READ COMMITTED vs SERIALIZABLE) is not what's protecting this ledger from lost updates — explicit row-level locking is. Given that, SERIALIZABLE is pure overhead for this workload: lower throughput, lower success rate, no additional correctness benefit. The actual trade-off worth making for micro-transaction workloads is READ COMMITTED + mandatory row locking in application/procedure code, not a blanket SERIALIZABLE default.

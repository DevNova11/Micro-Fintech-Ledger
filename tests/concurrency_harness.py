#!/usr/bin/env python3
# concurrency_harness.py -- empirical concurrency/correctness benchmark
#
# exp 1: correctness under contention, READ COMMITTED vs SERIALIZABLE
# exp 2: throughput/latency, READ COMMITTED vs SERIALIZABLE, low contention
# exp 3: deadlock rate, fixed lock order vs naive order
#
# usage:
#   python3 concurrency_harness.py --dsn "dbname=fintech_ledger_test"

import argparse
import json
import os
import random
import statistics
import threading
import time
import uuid
from dataclasses import dataclass, field
from datetime import datetime, timezone

import psycopg2
import psycopg2.errors

SERIALIZATION_FAILURE = "40001"
DEADLOCK_DETECTED = "40P01"


@dataclass
class RunResult:
    latencies_ms: list = field(default_factory=list)
    committed: int = 0
    insufficient_funds: int = 0
    deadlocks: int = 0
    serialization_failures: int = 0
    other_errors: int = 0
    retries_used: int = 0
    wall_clock_s: float = 0.0


def seed_accounts(dsn: str, n_accounts: int, opening_balance: str = "1000000.0000"):
    # reset + seed clean test accounts
    conn = psycopg2.connect(dsn)
    conn.autocommit = True
    cur = conn.cursor()

    cur.execute("TRUNCATE risk_alerts, concurrency_lock_log, audit_merkle_log, "
                "entry_lines, idempotency_keys, transactions, accounts, "
                "account_holder, api_clients RESTART IDENTITY CASCADE;")

    cur.execute("INSERT INTO currencies (currency_code, currency_name) "
                "VALUES ('INR','Indian Rupee') ON CONFLICT DO NOTHING;")
    cur.execute("SELECT institution_id FROM institutions LIMIT 1;")
    row = cur.fetchone()
    if row:
        institution_id = row[0]
    else:
        cur.execute("INSERT INTO institutions (institution_name, swift_bic, country_code) "
                    "VALUES ('Load Test Bank','LOADTSTBXXX','IN') RETURNING institution_id;")
        institution_id = cur.fetchone()[0]

    cur.execute("INSERT INTO api_clients (institution_id, client_name, api_key_hash) "
                "VALUES (%s, 'Harness Client', repeat('b', 64)) RETURNING client_id;",
                (institution_id,))
    client_id = cur.fetchone()[0]

    account_ids = []
    for i in range(n_accounts):
        cur.execute("INSERT INTO account_holder (institution_id, full_name, kyc_status) "
                    "VALUES (%s, %s, 'VERIFIED') RETURNING account_holder_id;",
                    (institution_id, f"Holder {i}"))
        holder_id = cur.fetchone()[0]

        cur.execute("INSERT INTO accounts (account_holder_id, institution_id, currency_code, "
                    "account_number, cached_balance) VALUES (%s, %s, 'INR', %s, %s) "
                    "RETURNING account_id;",
                    (holder_id, institution_id, f"ACC-LOAD-{i:05d}", opening_balance))
        account_ids.append(cur.fetchone()[0])

    cur.close()
    conn.close()
    return client_id, account_ids, opening_balance


def worker(dsn, client_id, account_ids, n_txns, isolation_level, proc_name, result: RunResult,
           lock: threading.Lock, max_retries: int = 5):
    # same idempotency key across retries of one logical transfer
    conn = psycopg2.connect(dsn)
    conn.autocommit = False
    cur = conn.cursor()

    for _ in range(n_txns):
        a, b = random.sample(account_ids, 2)
        amount = f"{random.uniform(1, 50):.4f}"
        key = str(uuid.uuid4())

        start = time.perf_counter()
        for attempt in range(max_retries + 1):
            try:
                cur.execute(f"SET TRANSACTION ISOLATION LEVEL {isolation_level};")
                cur.execute(
                    f"SELECT {proc_name}(%s, %s, %s, %s, %s, 'INR');",
                    (client_id, key, a, b, amount),
                )
                conn.commit()
                elapsed_ms = (time.perf_counter() - start) * 1000
                with lock:
                    result.latencies_ms.append(elapsed_ms)
                    result.committed += 1
                    result.retries_used += attempt
                break
            except psycopg2.Error as e:
                conn.rollback()
                sqlstate = e.pgcode
                is_retryable = sqlstate in (DEADLOCK_DETECTED, SERIALIZATION_FAILURE)
                if is_retryable and attempt < max_retries:
                    with lock:
                        result.retries_used += 1
                    continue
                with lock:
                    if sqlstate == DEADLOCK_DETECTED:
                        result.deadlocks += 1
                    elif sqlstate == SERIALIZATION_FAILURE:
                        result.serialization_failures += 1
                    elif "Insufficient funds" in str(e):
                        result.insufficient_funds += 1
                    else:
                        result.other_errors += 1
                break
            except Exception:
                conn.rollback()
                with lock:
                    result.other_errors += 1
                break

    cur.close()
    conn.close()


def run_workload(dsn, client_id, account_ids, n_threads, n_txns_per_thread, isolation_level, proc_name="transfer_funds"):
    result = RunResult()
    lock = threading.Lock()
    threads = []

    start = time.perf_counter()
    for _ in range(n_threads):
        t = threading.Thread(
            target=worker,
            args=(dsn, client_id, account_ids, n_txns_per_thread, isolation_level, proc_name, result, lock),
        )
        threads.append(t)
        t.start()
    for t in threads:
        t.join()
    result.wall_clock_s = time.perf_counter() - start

    return result


def percentile(data, p):
    if not data:
        return None
    data = sorted(data)
    k = (len(data) - 1) * (p / 100)
    f, c = int(k), min(int(k) + 1, len(data) - 1)
    if f == c:
        return data[f]
    return data[f] + (data[c] - data[f]) * (k - f)


def summarize(label, result: RunResult, n_threads, n_txns_per_thread):
    total_attempted = n_threads * n_txns_per_thread
    throughput = result.committed / result.wall_clock_s if result.wall_clock_s > 0 else 0
    return {
        "label": label,
        "attempted": total_attempted,
        "committed": result.committed,
        "insufficient_funds": result.insufficient_funds,
        "deadlocks": result.deadlocks,
        "serialization_failures": result.serialization_failures,
        "other_errors": result.other_errors,
        "retries_used": result.retries_used,
        "wall_clock_s": round(result.wall_clock_s, 3),
        "throughput_txn_per_s": round(throughput, 2),
        "latency_ms_p50": round(percentile(result.latencies_ms, 50), 3) if result.latencies_ms else None,
        "latency_ms_p95": round(percentile(result.latencies_ms, 95), 3) if result.latencies_ms else None,
        "latency_ms_p99": round(percentile(result.latencies_ms, 99), 3) if result.latencies_ms else None,
        "latency_ms_mean": round(statistics.mean(result.latencies_ms), 3) if result.latencies_ms else None,
    }


def verify_ledger_integrity(dsn, account_ids, opening_balance):
    # no money created/destroyed; cached_balance == opening + net(entry_lines)
    conn = psycopg2.connect(dsn)
    cur = conn.cursor()

    cur.execute("SELECT fn_verify_audit_chain();")
    broken_at = cur.fetchone()[0]

    cur.execute("""
        SELECT a.account_id, a.cached_balance,
               %s + COALESCE(SUM(CASE WHEN el.direction='CREDIT' THEN el.amount
                                       WHEN el.direction='DEBIT' THEN -el.amount END), 0)
        FROM accounts a
        LEFT JOIN entry_lines el ON el.account_id = a.account_id
        WHERE a.account_id = ANY(%s)
        GROUP BY a.account_id, a.cached_balance;
    """, (opening_balance, account_ids))

    mismatches = []
    total_cached = 0
    for account_id, cached_balance, expected_balance in cur.fetchall():
        total_cached += cached_balance
        if cached_balance != expected_balance:
            mismatches.append((account_id, str(cached_balance), str(expected_balance)))

    expected_total = float(opening_balance) * len(account_ids)

    cur.close()
    conn.close()

    return {
        "audit_chain_intact": broken_at is None,
        "broken_at_log_id": broken_at,
        "balance_mismatches": mismatches,
        "total_system_balance": float(total_cached),
        "expected_total_balance": expected_total,
        "money_conserved": abs(float(total_cached) - expected_total) < 0.0001,
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dsn", default="dbname=fintech_ledger_test")
    ap.add_argument("--accounts-small", type=int, default=5)
    ap.add_argument("--accounts-large", type=int, default=50)
    ap.add_argument("--threads", type=int, default=16)
    ap.add_argument("--txns-per-thread", type=int, default=50)
    ap.add_argument("--naive-txns-per-thread", type=int, default=10,
                     help="naive_transfer_funds is deliberately pathological under contention; keep this small")
    ap.add_argument("--opening-balance", default="1000000.0000")
    args = ap.parse_args()

    safe_config = dict(vars(args))
    safe_config["dsn"] = "[redacted]"  # never persist connection credentials in results
    report = {"run_at": datetime.now(timezone.utc).isoformat(), "config": safe_config, "experiments": {}}

    print("=" * 78)
    print("EXPERIMENT 1: correctness under contention")
    print("=" * 78)
    exp1 = {}
    for isolation in ["READ COMMITTED", "SERIALIZABLE"]:
        client_id, account_ids = seed_accounts(args.dsn, args.accounts_small, args.opening_balance)[:2]
        result = run_workload(args.dsn, client_id, account_ids, args.threads, args.txns_per_thread, isolation)
        integrity = verify_ledger_integrity(args.dsn, account_ids, args.opening_balance)
        summary = summarize(isolation, result, args.threads, args.txns_per_thread)
        summary["integrity"] = integrity
        exp1[isolation] = summary
        print(f"\n[{isolation}] accounts={args.accounts_small}")
        print(f"  committed={summary['committed']}/{summary['attempted']}  "
              f"deadlocks={summary['deadlocks']}  serialization_failures={summary['serialization_failures']}  "
              f"insufficient_funds={summary['insufficient_funds']}")
        print(f"  throughput={summary['throughput_txn_per_s']} txn/s  "
              f"p50={summary['latency_ms_p50']}ms  p95={summary['latency_ms_p95']}ms  p99={summary['latency_ms_p99']}ms")
        print(f"  money_conserved={integrity['money_conserved']}  "
              f"balance_mismatches={len(integrity['balance_mismatches'])}  "
              f"audit_chain_intact={integrity['audit_chain_intact']}")
    report["experiments"]["1_correctness_under_contention"] = exp1

    print("\n" + "=" * 78)
    print("EXPERIMENT 2: throughput/latency vs isolation level")
    print("=" * 78)
    exp2 = {}
    for isolation in ["READ COMMITTED", "SERIALIZABLE"]:
        client_id, account_ids = seed_accounts(args.dsn, args.accounts_large, args.opening_balance)[:2]
        result = run_workload(args.dsn, client_id, account_ids, args.threads, args.txns_per_thread, isolation)
        summary = summarize(isolation, result, args.threads, args.txns_per_thread)
        exp2[isolation] = summary
        print(f"\n[{isolation}] accounts={args.accounts_large}")
        print(f"  committed={summary['committed']}/{summary['attempted']}  "
              f"deadlocks={summary['deadlocks']}  serialization_failures={summary['serialization_failures']}")
        print(f"  throughput={summary['throughput_txn_per_s']} txn/s  "
              f"p50={summary['latency_ms_p50']}ms  p95={summary['latency_ms_p95']}ms  p99={summary['latency_ms_p99']}ms")
    report["experiments"]["2_throughput_vs_isolation"] = exp2

    print("\n" + "=" * 78)
    print("EXPERIMENT 3: deadlock rate -- fixed order vs naive")
    print("=" * 78)
    exp3 = {}
    for proc_name, label in [("transfer_funds", "fixed_order"), ("naive_transfer_funds", "naive_order")]:
        n_txns = args.txns_per_thread if proc_name == "transfer_funds" else args.naive_txns_per_thread
        client_id, account_ids = seed_accounts(args.dsn, args.accounts_small, args.opening_balance)[:2]
        result = run_workload(args.dsn, client_id, account_ids, args.threads, n_txns,
                              "READ COMMITTED", proc_name=proc_name)
        summary = summarize(label, result, args.threads, n_txns)
        exp3[label] = summary
        print(f"\n[{label}] procedure={proc_name}  accounts={args.accounts_small}")
        print(f"  committed={summary['committed']}/{summary['attempted']}  deadlocks={summary['deadlocks']}  retries={summary['retries_used']}")
        print(f"  throughput={summary['throughput_txn_per_s']} txn/s")
    report["experiments"]["3_deadlock_fixed_vs_naive"] = exp3

    os.makedirs("tests/results", exist_ok=True)
    out_path = f"tests/results/{datetime.now().strftime('%Y%m%d_%H%M%S')}.json"
    with open(out_path, "w") as f:
        json.dump(report, f, indent=2, default=str)
    print(f"\nresults written to {out_path}")


if __name__ == "__main__":
    main()

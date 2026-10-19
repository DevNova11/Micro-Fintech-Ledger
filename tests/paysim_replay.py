#!/usr/bin/env python3
# Replays the first N PaySim rows (Lopez-Rojas et al., 2016) through transfer_funds()
# from many threads, under READ COMMITTED and SERIALIZABLE. One ledger account per
# sender/receiver name, so contention follows the dataset instead of random pairs.
# Run: python3 tests/paysim_replay.py --csv "<path>/paysim dataset.csv" \
#          --dsn "dbname=fintech_ledger host=localhost user=postgres password=..." \
#          --rows 20000 --threads 20

import argparse
import csv
import json
import os
import sys
import threading
import time
import uuid
from collections import Counter
from datetime import datetime, timezone

import psycopg2
import psycopg2.errors
from psycopg2.extras import execute_values

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from concurrency_harness import (  # noqa: E402
    DEADLOCK_DETECTED, SERIALIZATION_FAILURE, RunResult, summarize,
)

OPENING_BALANCE = "100000000000.0000"  # huge on purpose, so nobody ever runs out of money


def load_rows(path, n_rows, skip, types):
    rows, skipped = [], Counter()
    with open(path, newline="", encoding="utf-8") as f:
        reader = csv.DictReader(f)
        needed = {"type", "amount", "nameOrig", "nameDest"}
        if not needed.issubset(reader.fieldnames or []):
            raise SystemExit(f"CSV is missing columns {needed - set(reader.fieldnames or [])}")
        seen = 0
        for r in reader:
            seen += 1
            if seen <= skip:
                continue
            if types and r["type"] not in types:
                skipped["type_filtered"] += 1
                continue
            amount = float(r["amount"])
            if amount <= 0:
                skipped["non_positive_amount"] += 1
                continue
            if r["nameOrig"] == r["nameDest"]:
                skipped["self_transfer"] += 1
                continue
            rows.append((r["nameOrig"], r["nameDest"], f"{amount:.4f}", r["type"]))
            if len(rows) >= n_rows:
                break
    return rows, dict(skipped)


def contention_profile(rows):
    touches = Counter()
    for orig, dest, _, _ in rows:
        touches[orig] += 1
        touches[dest] += 1
    counts = sorted(touches.values(), reverse=True)
    total = sum(counts)
    top1pct = max(1, len(counts) // 100)
    return {
        "distinct_accounts": len(counts),
        "transfers": len(rows),
        "max_transfers_on_one_account": counts[0],
        "share_of_postings_on_top_1pct_accounts": round(sum(counts[:top1pct]) / total, 4),
        "accounts_touched_once": sum(1 for c in counts if c == 1),
    }


def seed_ledger(dsn, names):
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
        inst = row[0]
    else:
        cur.execute("INSERT INTO institutions (institution_name, swift_bic, country_code) "
                    "VALUES ('PaySim Replay Bank','PAYSIMBXXXX','IN') RETURNING institution_id;")
        inst = cur.fetchone()[0]
    cur.execute("INSERT INTO api_clients (institution_id, client_name, api_key_hash) "
                "VALUES (%s,'PaySim Replay',repeat('c',64)) RETURNING client_id;", (inst,))
    client_id = cur.fetchone()[0]

    holder_ids = []
    for i in range(0, len(names), 5000):
        chunk = names[i:i + 5000]
        res = execute_values(cur,
            "INSERT INTO account_holder (institution_id, full_name, kyc_status) VALUES %s "
            "RETURNING account_holder_id",
            [(inst, n, "VERIFIED") for n in chunk], fetch=True)
        holder_ids.extend(r[0] for r in res)

    account_ids = []
    for i in range(0, len(names), 5000):
        res = execute_values(cur,
            "INSERT INTO accounts (account_holder_id, institution_id, currency_code, "
            "account_number, cached_balance) VALUES %s RETURNING account_id",
            [(holder_ids[i + j], inst, "INR", f"PS-{n}", OPENING_BALANCE)
             for j, n in enumerate(names[i:i + 5000])], fetch=True)
        account_ids.extend(r[0] for r in res)
    cur.close()
    conn.close()
    return client_id, dict(zip(names, account_ids))


def worker(dsn, client_id, transfers, cursor, isolation, result, lock, max_retries=5):
    conn = psycopg2.connect(dsn)
    conn.autocommit = False
    cur = conn.cursor()
    while True:
        with lock:
            i = cursor[0]
            cursor[0] += 1
        if i >= len(transfers):
            break
        a, b, amount = transfers[i]
        key = str(uuid.uuid4())
        start = time.perf_counter()
        for attempt in range(max_retries + 1):
            try:
                cur.execute(f"SET TRANSACTION ISOLATION LEVEL {isolation};")
                cur.execute("SELECT transfer_funds(%s,%s,%s,%s,%s,'INR');",
                            (client_id, key, a, b, amount))
                conn.commit()
                ms = (time.perf_counter() - start) * 1000
                with lock:
                    result.latencies_ms.append(ms)
                    result.committed += 1
                    result.retries_used += attempt
                break
            except psycopg2.Error as e:
                conn.rollback()
                retryable = e.pgcode in (DEADLOCK_DETECTED, SERIALIZATION_FAILURE)
                if retryable and attempt < max_retries:
                    continue
                with lock:
                    result.retries_used += attempt
                    if e.pgcode == DEADLOCK_DETECTED:
                        result.deadlocks += 1
                    elif e.pgcode == SERIALIZATION_FAILURE:
                        result.serialization_failures += 1
                    elif "Insufficient funds" in str(e):
                        result.insufficient_funds += 1
                    else:
                        result.other_errors += 1
                break
    cur.close()
    conn.close()


def verify(dsn, n_accounts):
    conn = psycopg2.connect(dsn)
    cur = conn.cursor()
    cur.execute("SELECT fn_verify_audit_chain();")
    broken = cur.fetchone()[0]
    cur.execute("""
        WITH net AS (
          SELECT account_id,
                 SUM(CASE WHEN direction='CREDIT' THEN amount ELSE -amount END) AS n
          FROM entry_lines GROUP BY account_id)
        SELECT COUNT(*) FILTER (WHERE a.cached_balance <> %s::numeric + COALESCE(net.n,0)),
               SUM(a.cached_balance) = %s::numeric * %s
        FROM accounts a LEFT JOIN net ON net.account_id = a.account_id;
    """, (OPENING_BALANCE, OPENING_BALANCE, n_accounts))
    mismatches, conserved = cur.fetchone()
    cur.close()
    conn.close()
    return {"audit_chain_intact": broken is None, "broken_at_log_id": broken,
            "balance_mismatches": mismatches, "money_conserved": bool(conserved)}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--csv", required=True)
    ap.add_argument("--dsn", default="dbname=fintech_ledger")
    ap.add_argument("--rows", type=int, default=20000, help="transfers to replay")
    ap.add_argument("--skip", type=int, default=0, help="CSV rows to skip first")
    ap.add_argument("--threads", type=int, default=20)
    ap.add_argument("--types", default="", help="comma list, e.g. TRANSFER,CASH_OUT (default: all)")
    args = ap.parse_args()

    types = {t.strip() for t in args.types.split(",") if t.strip()}
    print(f"reading up to {args.rows} rows from {args.csv} ...")
    rows, skipped = load_rows(args.csv, args.rows, args.skip, types)
    profile = contention_profile(rows)
    print("contention profile:", json.dumps(profile))
    print("skipped rows:", skipped)

    names = sorted({n for r in rows for n in (r[0], r[1])})
    report = {"run_at": datetime.now(timezone.utc).isoformat(),
              "config": {"rows": len(rows), "skip": args.skip, "threads": args.threads,
                         "types": sorted(types) or "all", "csv": os.path.basename(args.csv)},
              "contention_profile": profile, "skipped_rows": skipped, "runs": {}}

    for isolation in ["READ COMMITTED", "SERIALIZABLE"]:
        client_id, idmap = seed_ledger(args.dsn, names)
        transfers = [(idmap[o], idmap[d], amt) for o, d, amt, _ in rows]
        result, lock, cursor = RunResult(), threading.Lock(), [0]
        t0 = time.perf_counter()
        threads = [threading.Thread(target=worker, args=(args.dsn, client_id, transfers, cursor,
                                                          isolation, result, lock))
                   for _ in range(args.threads)]
        for t in threads: t.start()
        for t in threads: t.join()
        result.wall_clock_s = time.perf_counter() - t0
        s = summarize(isolation, result, 1, len(transfers))
        s["integrity"] = verify(args.dsn, len(names))
        report["runs"][isolation] = s
        print(f"\n[{isolation}] committed={s['committed']}/{s['attempted']} "
              f"serialization_failures={s['serialization_failures']} deadlocks={s['deadlocks']} "
              f"retries={s['retries_used']}")
        print(f"  throughput={s['throughput_txn_per_s']} txn/s  p50={s['latency_ms_p50']}ms "
              f"p99={s['latency_ms_p99']}ms  integrity={s['integrity']}")

    os.makedirs("tests/results", exist_ok=True)
    out = f"tests/results/paysim_{datetime.now().strftime('%Y%m%d_%H%M%S')}.json"
    with open(out, "w") as f:
        json.dump(report, f, indent=2, default=str)
    print(f"\nresults written to {out}")


if __name__ == "__main__":
    main()

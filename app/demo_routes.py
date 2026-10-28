"""Extra demo endpoints: tamper/restore, unbalanced transfer, concurrency burst,
lock log, reconciliation and transaction detail.

server.py calls register(app, get_conn, row_to_dict).
"""

import threading
import time
import uuid

import psycopg2
from flask import jsonify, request

TAMPER_DELTA = 1  # amount added to the tampered posting

_state_lock = threading.Lock()
_tamper = {}    # {"entry_line_id": int, "delta": int} while a posting is tampered
_baseline = {}  # {"at": str, "accounts": {account_id: (cached, net)}}


def _db_message(exc):
    diag = getattr(exc, "diag", None)
    return diag.message_primary if diag and diag.message_primary else str(exc)


def register(app, get_conn, row_to_dict, invalidate_audit):

    # ---- tamper / restore -------------------------------------------------

    @app.route("/api/demo/tamper", methods=["POST"])
    def demo_tamper():
        """Edit the newest posting with the append-only trigger switched off (the
        privileged-attacker scenario from the report)."""
        with _state_lock:
            if _tamper:
                return jsonify({"ok": False, "error": "A posting is already tampered. Restore it first."}), 400
        conn = get_conn()
        conn.autocommit = False
        try:
            with conn.cursor() as cur:
                cur.execute("SELECT entry_line_id, amount, direction FROM entry_lines ORDER BY entry_line_id DESC LIMIT 1")
                row = cur.fetchone()
                if not row:
                    return jsonify({"ok": False, "error": "No postings yet. Make a transfer first."}), 400
                line_id, amount, direction = row
                cur.execute("ALTER TABLE entry_lines DISABLE TRIGGER trg_entry_lines_immutable")
                cur.execute("UPDATE entry_lines SET amount = amount + %s WHERE entry_line_id = %s", (TAMPER_DELTA, line_id))
                cur.execute("ALTER TABLE entry_lines ENABLE TRIGGER trg_entry_lines_immutable")
            conn.commit()
        except psycopg2.Error as exc:
            conn.rollback()
            return jsonify({"ok": False, "error": _db_message(exc)}), 400
        finally:
            conn.close()
        with _state_lock:
            _tamper.update(entry_line_id=line_id, delta=TAMPER_DELTA)
        invalidate_audit()
        return jsonify({"ok": True, "entry_line_id": line_id, "direction": direction,
                        "old_amount": float(amount), "new_amount": float(amount) + TAMPER_DELTA})

    @app.route("/api/demo/restore", methods=["POST"])
    def demo_restore():
        with _state_lock:
            info = dict(_tamper)
        if not info:
            return jsonify({"ok": False, "error": "Nothing to restore."}), 400
        conn = get_conn()
        conn.autocommit = False
        try:
            with conn.cursor() as cur:
                cur.execute("ALTER TABLE entry_lines DISABLE TRIGGER trg_entry_lines_immutable")
                cur.execute("UPDATE entry_lines SET amount = amount - %s WHERE entry_line_id = %s",
                            (info["delta"], info["entry_line_id"]))
                cur.execute("ALTER TABLE entry_lines ENABLE TRIGGER trg_entry_lines_immutable")
            conn.commit()
        except psycopg2.Error as exc:
            conn.rollback()
            return jsonify({"ok": False, "error": _db_message(exc)}), 400
        finally:
            conn.close()
        with _state_lock:
            _tamper.clear()
        invalidate_audit()
        return jsonify({"ok": True, "entry_line_id": info["entry_line_id"]})

    @app.route("/api/demo/tamper-state")
    def demo_tamper_state():
        with _state_lock:
            return jsonify({"tampered": bool(_tamper), **_tamper})

    # ---- unbalanced transfer ----------------------------------------------

    @app.route("/api/demo/unbalanced", methods=["POST"])
    def demo_unbalanced():
        """Insert a debit of 50.00 and a credit of 49.00, then COMMIT. The deferred
        double-entry trigger must reject it and roll everything back."""
        conn = get_conn()
        conn.autocommit = False
        try:
            with conn.cursor() as cur:
                cur.execute("SELECT account_id, currency_code FROM accounts ORDER BY account_id LIMIT 2")
                accts = cur.fetchall()
                if len(accts) < 2:
                    return jsonify({"ok": False, "error": "Need at least two accounts."}), 400
                (a, ccy), (b, _) = accts
                cur.execute("INSERT INTO transactions (settlement_type, status, currency_code) "
                            "VALUES ('RTGS', 'PENDING', %s) RETURNING transaction_id", (ccy,))
                txn = cur.fetchone()[0]
                cur.execute("INSERT INTO entry_lines (transaction_id, account_id, direction, currency_code, amount) "
                            "VALUES (%s, %s, 'DEBIT', %s, 50.00)", (txn, a, ccy))
                cur.execute("INSERT INTO entry_lines (transaction_id, account_id, direction, currency_code, amount) "
                            "VALUES (%s, %s, 'CREDIT', %s, 49.00)", (txn, b, ccy))
            conn.commit()  # the deferred trigger fires here
            return jsonify({"ok": False, "error": "Unexpected: the unbalanced transfer was accepted."}), 500
        except psycopg2.Error as exc:
            conn.rollback()
            return jsonify({"ok": True, "rejected": True, "message": _db_message(exc)})
        finally:
            conn.close()

    # ---- concurrency burst ------------------------------------------------

    @app.route("/api/demo/burst", methods=["POST"])
    def demo_burst():
        """Fire N concurrent transfers in both directions between two accounts and
        check that the combined balance did not change (no lost updates)."""
        body = request.get_json(silent=True) or {}
        try:
            a = int(body["account_a"])
            b = int(body["account_b"])
            client_id = int(body["client_id"])
            count = max(2, min(int(body.get("count", 20)), 50))
            amount = str(body.get("amount", "1.00"))
        except (KeyError, ValueError, TypeError) as exc:
            return jsonify({"ok": False, "error": f"Invalid request: {exc}"}), 400
        if a == b:
            return jsonify({"ok": False, "error": "Pick two different accounts."}), 400

        conn = get_conn()
        try:
            with conn.cursor() as cur:
                cur.execute("SELECT account_id, cached_balance, currency_code FROM accounts "
                            "WHERE account_id IN (%s, %s)", (a, b))
                before = {r[0]: float(r[1]) for r in cur.fetchall()}
                cur.execute("SELECT currency_code FROM accounts WHERE account_id = %s", (a,))
                ccy = cur.fetchone()[0]
        finally:
            conn.close()
        if len(before) != 2:
            return jsonify({"ok": False, "error": "Unknown account."}), 400

        results = []
        res_lock = threading.Lock()
        start = threading.Barrier(count)

        def worker(i):
            src, dst = (a, b) if i % 2 == 0 else (b, a)
            c = get_conn()
            try:
                start.wait(timeout=10)
                with c.cursor() as cur:
                    cur.execute("SELECT transfer_funds(%s, %s, %s, %s, %s, %s)",
                                (client_id, "burst-" + uuid.uuid4().hex, src, dst, amount, ccy))
                outcome = "committed"
            except Exception as exc:  # noqa: BLE001 - report any failure to the page
                outcome = _db_message(exc)
            finally:
                c.close()
            with res_lock:
                results.append(outcome)

        t0 = time.time()
        threads = [threading.Thread(target=worker, args=(i,)) for i in range(count)]
        for t in threads:
            t.start()
        for t in threads:
            t.join()
        elapsed = time.time() - t0

        conn = get_conn()
        try:
            with conn.cursor() as cur:
                cur.execute("SELECT account_id, cached_balance FROM accounts WHERE account_id IN (%s, %s)", (a, b))
                after = {r[0]: float(r[1]) for r in cur.fetchall()}
        finally:
            conn.close()

        committed = results.count("committed")
        errors = sorted({r for r in results if r != "committed"})
        total_before, total_after = sum(before.values()), sum(after.values())
        return jsonify({
            "ok": True, "attempted": count, "committed": committed, "failed": count - committed,
            "errors": errors, "elapsed_s": round(elapsed, 3),
            "total_before": total_before, "total_after": total_after,
            "money_conserved": abs(total_before - total_after) < 1e-6,
            "balances_before": before, "balances_after": after,
        })

    # ---- lock log ---------------------------------------------------------

    @app.route("/api/lock-log")
    def lock_log():
        conn = get_conn()
        try:
            with conn.cursor() as cur:
                cur.execute(
                    """
                    SELECT l.transaction_id,
                           max(l.account_id) FILTER (WHERE l.lock_order = 1) AS first_id,
                           max(l.account_id) FILTER (WHERE l.lock_order = 2) AS second_id,
                           max(a.account_number) FILTER (WHERE l.lock_order = 1) AS first_account,
                           max(a.account_number) FILTER (WHERE l.lock_order = 2) AS second_account
                    FROM concurrency_lock_log l
                    JOIN accounts a ON a.account_id = l.account_id
                    WHERE l.transaction_id IN (SELECT DISTINCT transaction_id FROM
                              (SELECT transaction_id FROM concurrency_lock_log ORDER BY lock_id DESC LIMIT 40) x)
                    GROUP BY l.transaction_id
                    ORDER BY l.transaction_id DESC
                    LIMIT 20
                    """
                )
                rows = []
                for r in cur.fetchall():
                    d = row_to_dict(cur, r)
                    d["lower_first"] = d["first_id"] is not None and d["second_id"] is not None and d["first_id"] < d["second_id"]
                    rows.append(d)
            return jsonify(rows)
        finally:
            conn.close()

    # ---- reconciliation: cached balance vs ledger -------------------------

    def _snapshot(cur):
        cur.execute(
            """
            SELECT a.account_id, a.account_number, a.cached_balance,
                   COALESCE(SUM(CASE e.direction WHEN 'CREDIT' THEN e.amount ELSE -e.amount END), 0) AS net
            FROM accounts a
            LEFT JOIN entry_lines e ON e.account_id = a.account_id
            GROUP BY a.account_id, a.account_number, a.cached_balance
            ORDER BY a.account_id
            """
        )
        return cur.fetchall()

    @app.route("/api/reconcile", methods=["GET", "POST"])
    def reconcile():
        """Compare each cached balance with the ledger. The opening balance is not stored,
        so the check is against a baseline taken earlier: cached must equal
        baseline cached + (net of entry lines since the baseline). POST resets the baseline."""
        conn = get_conn()
        try:
            with conn.cursor() as cur:
                snap = _snapshot(cur)
        finally:
            conn.close()
        now_accounts = {r[0]: (float(r[2]), float(r[3])) for r in snap}
        with _state_lock:
            if request.method == "POST" or not _baseline:
                _baseline.clear()
                _baseline.update(at=time.strftime("%H:%M:%S"), accounts=now_accounts)
            base = _baseline["accounts"]
            base_at = _baseline["at"]

        rows, mismatches = [], 0
        for account_id, number, cached, net in snap:
            cached, net = float(cached), float(net)
            if account_id in base:
                b_cached, b_net = base[account_id]
                expected = b_cached + (net - b_net)
                ok = abs(expected - cached) < 0.00005
            else:  # account created after the baseline
                expected, ok = cached, True
            if not ok:
                mismatches += 1
            rows.append({"account_id": account_id, "account_number": number, "cached_balance": cached,
                         "expected_balance": round(expected, 4), "ok": ok})
        # show every mismatch first, then fill up to 50 rows
        shown = [r for r in rows if not r["ok"]] + [r for r in rows if r["ok"]]
        return jsonify({"baseline_at": base_at, "accounts_checked": len(rows),
                        "mismatches": mismatches, "rows": shown[:50]})

    # ---- one transaction in detail ----------------------------------------

    @app.route("/api/transactions/<int:txn_id>")
    def transaction_detail(txn_id):
        conn = get_conn()
        try:
            with conn.cursor() as cur:
                cur.execute("SELECT transaction_id, settlement_type, status, currency_code, initiated_at, settled_at "
                            "FROM transactions WHERE transaction_id = %s", (txn_id,))
                row = cur.fetchone()
                if not row:
                    return jsonify({"error": "Transaction not found"}), 404
                txn = row_to_dict(cur, row)
                cur.execute(
                    """
                    SELECT e.entry_line_id, a.account_number, e.direction, e.amount,
                           m.log_id, m.entry_hash, m.prev_hash
                    FROM entry_lines e
                    JOIN accounts a ON a.account_id = e.account_id
                    LEFT JOIN audit_merkle_log m ON m.entry_line_id = e.entry_line_id
                    WHERE e.transaction_id = %s ORDER BY e.entry_line_id
                    """, (txn_id,))
                lines = [row_to_dict(cur, r) for r in cur.fetchall()]
                cur.execute("SELECT l.lock_order, a.account_number, l.acquired_at, l.released_at "
                            "FROM concurrency_lock_log l JOIN accounts a ON a.account_id = l.account_id "
                            "WHERE l.transaction_id = %s ORDER BY l.lock_order", (txn_id,))
                locks = [row_to_dict(cur, r) for r in cur.fetchall()]
                cur.execute("SELECT alert_type, severity, status, details FROM risk_alerts "
                            "WHERE transaction_id = %s ORDER BY alert_id", (txn_id,))
                alerts = [row_to_dict(cur, r) for r in cur.fetchall()]
            return jsonify({"transaction": txn, "lines": lines, "locks": locks, "alerts": alerts})
        finally:
            conn.close()

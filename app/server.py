"""Demo web app: Flask UI and API over the ledger schema and transfer_funds().

Run: pip install -r requirements.txt && python server.py, then open http://127.0.0.1:5050
Connection settings come from PGHOST, PGPORT, PGDATABASE, PGUSER, PGPASSWORD.
"""

import os
import uuid
from decimal import Decimal

import psycopg2
import psycopg2.extras
from flask import Flask, jsonify, render_template, request

app = Flask(__name__)

DB_CONFIG = {
    "host": os.environ.get("PGHOST", "localhost"),
    "port": os.environ.get("PGPORT", "5432"),
    "dbname": os.environ.get("PGDATABASE", "fintech_ledger"),
    "user": os.environ.get("PGUSER", "postgres"),
    "password": os.environ.get("PGPASSWORD", "newpassword123"),
}


def get_conn():
    conn = psycopg2.connect(**DB_CONFIG)
    conn.autocommit = True
    return conn


def to_jsonable(value):
    """Decimal is not JSON-serializable; convert to float."""
    if isinstance(value, Decimal):
        return float(value)
    return value


def row_to_dict(cur, row):
    return {desc[0]: to_jsonable(val) for desc, val in zip(cur.description, row)}


@app.route("/")
def index():
    return render_template("index.html")


@app.route("/api/health")
def health():
    try:
        conn = get_conn()
        conn.close()
        return jsonify({"ok": True, "database": DB_CONFIG["dbname"]})
    except Exception as exc:
        return jsonify({"ok": False, "error": str(exc)}), 500


@app.route("/api/accounts")
def list_accounts():
    conn = get_conn()
    try:
        with conn.cursor() as cur:
            cur.execute(
                """
                SELECT a.account_id, a.account_number, h.full_name AS holder_name,
                       a.currency_code, a.account_type, a.status, a.cached_balance
                FROM accounts a
                JOIN account_holder h ON h.account_holder_id = a.account_holder_id
                ORDER BY a.account_id
                """
            )
            rows = [row_to_dict(cur, r) for r in cur.fetchall()]
        return jsonify(rows)
    finally:
        conn.close()


@app.route("/api/clients")
def list_clients():
    conn = get_conn()
    try:
        with conn.cursor() as cur:
            cur.execute(
                "SELECT client_id, client_name, status FROM api_clients ORDER BY client_id"
            )
            rows = [row_to_dict(cur, r) for r in cur.fetchall()]
        return jsonify(rows)
    finally:
        conn.close()


@app.route("/api/transactions")
def list_transactions():
    limit = request.args.get("limit", default=20, type=int)
    conn = get_conn()
    try:
        with conn.cursor() as cur:
            cur.execute(
                """
                SELECT t.transaction_id, t.settlement_type, t.status, t.currency_code,
                       t.initiated_at, t.settled_at,
                       deb.account_number AS debit_account, deb_el.amount AS debit_amount,
                       cred.account_number AS credit_account
                FROM transactions t
                JOIN entry_lines deb_el ON deb_el.transaction_id = t.transaction_id AND deb_el.direction = 'DEBIT'
                JOIN accounts deb ON deb.account_id = deb_el.account_id
                JOIN entry_lines cred_el ON cred_el.transaction_id = t.transaction_id AND cred_el.direction = 'CREDIT'
                JOIN accounts cred ON cred.account_id = cred_el.account_id
                ORDER BY t.transaction_id DESC
                LIMIT %s
                """,
                (limit,),
            )
            rows = [row_to_dict(cur, r) for r in cur.fetchall()]
        return jsonify(rows)
    finally:
        conn.close()


@app.route("/api/risk-alerts")
def list_risk_alerts():
    conn = get_conn()
    try:
        with conn.cursor() as cur:
            cur.execute(
                """
                SELECT alert_id, transaction_id, alert_type, severity, status, detected_at, details
                FROM risk_alerts
                ORDER BY alert_id DESC
                LIMIT 20
                """
            )
            rows = [row_to_dict(cur, r) for r in cur.fetchall()]
        return jsonify(rows)
    finally:
        conn.close()


@app.route("/api/audit")
def audit_status():
    conn = get_conn()
    try:
        with conn.cursor() as cur:
            cur.execute("SELECT fn_verify_audit_chain() AS broken_at_log_id")
            broken_at = cur.fetchone()[0]
            cur.execute("SELECT count(*) FROM audit_merkle_log")
            log_count = cur.fetchone()[0]
        return jsonify({"intact": broken_at is None, "broken_at_log_id": broken_at, "log_rows": log_count})
    finally:
        conn.close()


@app.route("/api/transfer", methods=["POST"])
def transfer():
    body = request.get_json(force=True)
    try:
        client_id = int(body["client_id"])
        from_account_id = int(body["from_account_id"])
        to_account_id = int(body["to_account_id"])
        amount = str(Decimal(str(body["amount"])))
        currency_code = body.get("currency_code", "INR")
        idempotency_key = body.get("idempotency_key") or str(uuid.uuid4())
    except (KeyError, ValueError, TypeError) as exc:
        return jsonify({"ok": False, "error": f"Invalid request: {exc}"}), 400

    conn = get_conn()
    try:
        with conn.cursor() as cur:
            cur.execute(
                "SELECT transfer_funds(%s, %s, %s, %s, %s, %s)",
                (client_id, idempotency_key, from_account_id, to_account_id, amount, currency_code),
            )
            transaction_id = cur.fetchone()[0]
        return jsonify({"ok": True, "transaction_id": transaction_id, "idempotency_key": idempotency_key})
    except psycopg2.Error as exc:
        # surface the database's message (insufficient funds, self-transfer, ...)
        msg = exc.diag.message_primary if exc.diag and exc.diag.message_primary else str(exc)
        return jsonify({"ok": False, "error": msg}), 400
    finally:
        conn.close()


@app.route("/api/seed-demo", methods=["POST"])
def seed_demo():
    """Add the demo accounts if the database has none."""
    conn = get_conn()
    try:
        with conn.cursor() as cur:
            cur.execute("SELECT count(*) FROM accounts")
            if cur.fetchone()[0] > 0:
                return jsonify({"ok": False, "error": "Accounts already exist — seed skipped."}), 400

            cur.execute(
                "INSERT INTO currencies (currency_code, currency_name) VALUES ('INR', 'Indian Rupee') "
                "ON CONFLICT DO NOTHING"
            )
            cur.execute(
                "INSERT INTO institutions (institution_name, swift_bic, country_code) "
                "VALUES ('Demo Bank', 'DEMOINBBXXX', 'IN') RETURNING institution_id"
            )
            institution_id = cur.fetchone()[0]

            cur.execute(
                "INSERT INTO account_holder (institution_id, full_name, kyc_status) "
                "VALUES (%s, 'Alice Demo', 'VERIFIED'), (%s, 'Bob Demo', 'VERIFIED'), (%s, 'Carla Demo', 'VERIFIED') "
                "RETURNING account_holder_id",
                (institution_id, institution_id, institution_id),
            )
            holder_ids = [r[0] for r in cur.fetchall()]

            cur.execute(
                "INSERT INTO accounts (account_holder_id, institution_id, currency_code, account_number, cached_balance) "
                "VALUES (%s, %s, 'INR', 'DEMO-ALICE-001', 200000.00), "
                "(%s, %s, 'INR', 'DEMO-BOB-001', 5000.00), "
                "(%s, %s, 'INR', 'DEMO-CARLA-001', 50000.00)",
                (holder_ids[0], institution_id, holder_ids[1], institution_id, holder_ids[2], institution_id),
            )

            cur.execute(
                "INSERT INTO api_clients (institution_id, client_name, api_key_hash) "
                "VALUES (%s, 'Demo Web App', %s) RETURNING client_id",
                (institution_id, "d" * 64),
            )
            client_id = cur.fetchone()[0]

        return jsonify({"ok": True, "client_id": client_id})
    except psycopg2.Error as exc:
        return jsonify({"ok": False, "error": str(exc)}), 500
    finally:
        conn.close()


if __name__ == "__main__":
    app.run(host="127.0.0.1", port=5050, debug=True)

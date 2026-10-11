-- ============================================================================
-- Decentralized Micro-FinTech Ledger & Cleared Settlement Core
-- 02_tables.sql — core 15-relation schema
--
-- Maps directly to the Chen-notation ER diagram (Review 1, slide 14).
-- Each table's header comment names the ER relationship(s) it participates
-- in, so the mapping from diagram -> schema is traceable for the viva.
--
-- Conventions:
--   * Surrogate PKs are BIGINT GENERATED ALWAYS AS IDENTITY (fast, ordered,
--     sufficient for a single-institution settlement core).
--   * All monetary amounts are NUMERIC(18,4) — exact decimal, no float
--     rounding error, 4 decimal places covers sub-cent/micro-transaction use.
--   * All timestamps are TIMESTAMPTZ (store in UTC, display in local tz).
--   * Hashes (SHA-256) are stored as CHAR(64) hex digests.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- CURRENCIES
-- ER relationships: Relationship (1:N to ACCOUNTS), DENOMINATES (1:N to
--   TRANSACTIONS), QUOTED_AS_BASE / QUOTED_AS_TARGET (1:N to EXCHANGE_RATES)
-- ----------------------------------------------------------------------------
CREATE TABLE currencies (
    currency_code   CHAR(3)      PRIMARY KEY,         -- ISO 4217, e.g. 'INR'
    currency_name   VARCHAR(64)  NOT NULL,
    minor_unit      SMALLINT     NOT NULL DEFAULT 2,   -- decimal places in normal use (e.g. 2 for INR paise)
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT now()
);

-- ----------------------------------------------------------------------------
-- INSTITUTIONS
-- ER relationships: UNBOARDS (1:N to ACCOUNT_HOLDER), MAINTAINS (1:N to ACCOUNTS)
-- ----------------------------------------------------------------------------
CREATE TABLE institutions (
    institution_id  BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    institution_name VARCHAR(128) NOT NULL,
    swift_bic       VARCHAR(11),
    country_code    CHAR(2)      NOT NULL,
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT now()
);

-- ----------------------------------------------------------------------------
-- ACCOUNT_HOLDER
-- ER relationships: UNBOARDS (N side, from INSTITUTIONS), REGISTERS (N side,
--   from API_CLIENTS), OWNS (1:N to ACCOUNTS)
-- ----------------------------------------------------------------------------
CREATE TABLE account_holder (
    account_holder_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    institution_id  BIGINT       NOT NULL REFERENCES institutions(institution_id),
    full_name       VARCHAR(128) NOT NULL,
    kyc_status      VARCHAR(16)  NOT NULL DEFAULT 'PENDING'
                        CHECK (kyc_status IN ('PENDING', 'VERIFIED', 'REJECTED')),
    email           VARCHAR(128),
    phone           VARCHAR(32),
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT now()
);

CREATE INDEX idx_account_holder_institution ON account_holder(institution_id);

-- ----------------------------------------------------------------------------
-- API_CLIENTS
-- ER relationships: ISSUES (1:N to IDEMPOTENCY_KEYS), REGISTERS (1 side,
--   to ACCOUNT_HOLDER)
-- ----------------------------------------------------------------------------
CREATE TABLE api_clients (
    client_id       BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    institution_id  BIGINT       NOT NULL REFERENCES institutions(institution_id),
    client_name     VARCHAR(128) NOT NULL,
    api_key_hash    CHAR(64)     NOT NULL UNIQUE,      -- SHA-256 of the issued API key; never store the raw key
    status          VARCHAR(16)  NOT NULL DEFAULT 'ACTIVE'
                        CHECK (status IN ('ACTIVE', 'SUSPENDED', 'REVOKED')),
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT now()
);

-- ----------------------------------------------------------------------------
-- ACCOUNTS
-- ER relationships: OWNS (N side, from ACCOUNT_HOLDER), MAINTAINS (N side,
--   from INSTITUTIONS), Relationship (N side, to CURRENCIES), POSTS (1:N to
--   ENTRY_LINES), LOCKED_DURING / VERIFIES (1:N to CONCURRENCY_LOCK_LOG)
-- ----------------------------------------------------------------------------
CREATE TABLE accounts (
    account_id      BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    account_holder_id BIGINT     NOT NULL REFERENCES account_holder(account_holder_id),
    institution_id  BIGINT       NOT NULL REFERENCES institutions(institution_id),
    currency_code   CHAR(3)      NOT NULL REFERENCES currencies(currency_code),
    account_number  VARCHAR(34)  NOT NULL UNIQUE,      -- IBAN-length ceiling
    account_type    VARCHAR(16)  NOT NULL DEFAULT 'SAVINGS'
                        CHECK (account_type IN ('SAVINGS', 'CURRENT', 'SETTLEMENT')),
    status          VARCHAR(16)  NOT NULL DEFAULT 'ACTIVE'
                        CHECK (status IN ('ACTIVE', 'FROZEN', 'CLOSED')),
    -- Running balance is a derived/cached value, maintained only by the
    -- transfer procedure — never written directly. Source of truth is
    -- always SUM(entry_lines) for the account.
    cached_balance  NUMERIC(18,4) NOT NULL DEFAULT 0,
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT now()
);

CREATE INDEX idx_accounts_holder ON accounts(account_holder_id);
CREATE INDEX idx_accounts_institution ON accounts(institution_id);

-- ----------------------------------------------------------------------------
-- EXCHANGE_RATES
-- ER relationships: QUOTED_AS_BASE (N side, from CURRENCIES),
--   QUOTED_AS_TARGET (N side, from CURRENCIES)
-- ----------------------------------------------------------------------------
CREATE TABLE exchange_rates (
    rate_id         BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    base_currency_code   CHAR(3) NOT NULL REFERENCES currencies(currency_code),
    target_currency_code CHAR(3) NOT NULL REFERENCES currencies(currency_code),
    rate            NUMERIC(18,8) NOT NULL CHECK (rate > 0),
    effective_at    TIMESTAMPTZ  NOT NULL DEFAULT now(),
    CONSTRAINT chk_distinct_currencies CHECK (base_currency_code <> target_currency_code)
);

CREATE INDEX idx_exchange_rates_pair_time ON exchange_rates(base_currency_code, target_currency_code, effective_at DESC);

-- ----------------------------------------------------------------------------
-- SETTLEMENTS_BATCH
-- ER relationships: CLEARS_IN (1 side, from TRANSACTIONS), ANCHORS_TO
--   (1:N to MERKLE_BATCH_ROOTS)
-- ----------------------------------------------------------------------------
CREATE TABLE settlements_batch (
    batch_id        BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    batch_type      VARCHAR(16)  NOT NULL DEFAULT 'NET'
                        CHECK (batch_type IN ('NET', 'RTGS_SWEEP')),
    status          VARCHAR(16)  NOT NULL DEFAULT 'OPEN'
                        CHECK (status IN ('OPEN', 'CLEARING', 'CLOSED')),
    opened_at       TIMESTAMPTZ  NOT NULL DEFAULT now(),
    closed_at       TIMESTAMPTZ
);

-- ----------------------------------------------------------------------------
-- TRANSACTIONS
-- ER relationships: DEDUPLICATES (N side, from IDEMPOTENCY_KEYS), TRIGGERS
--   (1:N to RISK_ALERTS), CONTAINS (1:N to ENTRY_LINES), DENOMINATES (N
--   side, from CURRENCIES), CLEARS_IN (N side, to SETTLEMENTS_BATCH),
--   VERIFIES (1:N to RECONCILIATION_RUNS)
--
-- This is the transaction HEADER only — no money movement lives here.
-- Money movement lives exclusively in entry_lines (double-entry core).
-- ----------------------------------------------------------------------------
CREATE TABLE transactions (
    transaction_id  BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    settlement_type VARCHAR(16)  NOT NULL DEFAULT 'RTGS'
                        CHECK (settlement_type IN ('RTGS', 'NET', 'INTERNAL')),
    status          VARCHAR(16)  NOT NULL DEFAULT 'PENDING'
                        CHECK (status IN ('PENDING', 'COMMITTED', 'ROLLED_BACK')),
    currency_code   CHAR(3)      NOT NULL REFERENCES currencies(currency_code),
    batch_id        BIGINT       REFERENCES settlements_batch(batch_id),
    initiated_at    TIMESTAMPTZ  NOT NULL DEFAULT now(),
    settled_at      TIMESTAMPTZ
);

CREATE INDEX idx_transactions_batch ON transactions(batch_id);
CREATE INDEX idx_transactions_status ON transactions(status);

-- ----------------------------------------------------------------------------
-- ENTRY_LINES  (the double-entry core)
-- ER relationships: CONTAINS (N side, from TRANSACTIONS), POSTS (N side,
--   from ACCOUNTS), HASHED_AS (1:1 to AUDIT_MERKLE_LOG)
--
-- Append-only by policy (enforced by trigger in 03_triggers.sql, not here).
-- ----------------------------------------------------------------------------
CREATE TABLE entry_lines (
    entry_line_id   BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    transaction_id  BIGINT       NOT NULL REFERENCES transactions(transaction_id),
    account_id      BIGINT       NOT NULL REFERENCES accounts(account_id),
    direction       VARCHAR(6)   NOT NULL CHECK (direction IN ('DEBIT', 'CREDIT')),
    currency_code   CHAR(3)      NOT NULL REFERENCES currencies(currency_code),
    amount          NUMERIC(18,4) NOT NULL CHECK (amount > 0),
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT now()
);

CREATE INDEX idx_entry_lines_transaction ON entry_lines(transaction_id);
CREATE INDEX idx_entry_lines_account ON entry_lines(account_id);

-- ----------------------------------------------------------------------------
-- IDEMPOTENCY_KEYS
-- ER relationships: ISSUES (N side, from API_CLIENTS), DEDUPLICATES (1:1
--   to TRANSACTIONS)
-- ----------------------------------------------------------------------------
CREATE TABLE idempotency_keys (
    idempotency_key_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    client_id       BIGINT       NOT NULL REFERENCES api_clients(client_id),
    idempotency_key VARCHAR(128) NOT NULL,
    transaction_id  BIGINT       REFERENCES transactions(transaction_id),
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
    expires_at      TIMESTAMPTZ  NOT NULL DEFAULT (now() + INTERVAL '24 hours'),
    CONSTRAINT uq_client_idempotency_key UNIQUE (client_id, idempotency_key)
);

-- ----------------------------------------------------------------------------
-- RISK_ALERTS
-- ER relationships: TRIGGERS (N side, from TRANSACTIONS)
-- ----------------------------------------------------------------------------
CREATE TABLE risk_alerts (
    alert_id        BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    transaction_id  BIGINT       NOT NULL REFERENCES transactions(transaction_id),
    alert_type      VARCHAR(32)  NOT NULL,
    severity        VARCHAR(16)  NOT NULL DEFAULT 'LOW'
                        CHECK (severity IN ('LOW', 'MEDIUM', 'HIGH', 'CRITICAL')),
    status          VARCHAR(16)  NOT NULL DEFAULT 'OPEN'
                        CHECK (status IN ('OPEN', 'REVIEWED', 'DISMISSED')),
    detected_at     TIMESTAMPTZ  NOT NULL DEFAULT now(),
    details         TEXT
);

CREATE INDEX idx_risk_alerts_transaction ON risk_alerts(transaction_id);

-- ----------------------------------------------------------------------------
-- AUDIT_MERKLE_LOG
-- ER relationships: HASHED_AS (N side, from ENTRY_LINES — technically each
--   entry_line hashes to exactly one log row, enforced by UNIQUE below)
--
-- Append-only, hash-chained. Populated exclusively by the AFTER INSERT
-- trigger on entry_lines (see 03_triggers.sql) — never written directly.
-- ----------------------------------------------------------------------------
CREATE TABLE audit_merkle_log (
    log_id          BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    entry_line_id   BIGINT       NOT NULL UNIQUE REFERENCES entry_lines(entry_line_id),
    entry_hash      CHAR(64)     NOT NULL,            -- SHA-256(this row's data || prev_hash)
    prev_hash       CHAR(64),                         -- NULL only for the very first row (genesis)
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT now()
);

CREATE INDEX idx_audit_merkle_log_created ON audit_merkle_log(created_at);

-- ----------------------------------------------------------------------------
-- CONCURRENCY_LOCK_LOG
-- ER relationships: LOCKED_DURING / VERIFIES (N side, from ACCOUNTS)
--
-- Written by the transfer procedure BEFORE it takes each SELECT ... FOR
-- UPDATE lock, in fixed lock_order, so the sequence is independently
-- auditable (research gap #3's lightweight deadlock-avoidance evidence).
-- ----------------------------------------------------------------------------
CREATE TABLE concurrency_lock_log (
    lock_id         BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    transaction_id  BIGINT       NOT NULL REFERENCES transactions(transaction_id),
    account_id      BIGINT       NOT NULL REFERENCES accounts(account_id),
    lock_order      SMALLINT     NOT NULL,            -- 1 = locked first (lower account_id)
    acquired_at     TIMESTAMPTZ  NOT NULL DEFAULT now(),
    released_at     TIMESTAMPTZ
);

CREATE INDEX idx_concurrency_lock_log_transaction ON concurrency_lock_log(transaction_id);
CREATE INDEX idx_concurrency_lock_log_account ON concurrency_lock_log(account_id);

-- ----------------------------------------------------------------------------
-- RECONCILIATION_RUNS
-- ER relationships: VERIFIES (N side, from TRANSACTIONS)
-- ----------------------------------------------------------------------------
CREATE TABLE reconciliation_runs (
    run_id          BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    transaction_id  BIGINT       REFERENCES transactions(transaction_id),
    run_at          TIMESTAMPTZ  NOT NULL DEFAULT now(),
    status          VARCHAR(16)  NOT NULL DEFAULT 'CLEAN'
                        CHECK (status IN ('CLEAN', 'DISCREPANCY')),
    discrepancy_amount NUMERIC(18,4) NOT NULL DEFAULT 0
);

CREATE INDEX idx_reconciliation_runs_transaction ON reconciliation_runs(transaction_id);

-- ----------------------------------------------------------------------------
-- MERKLE_BATCH_ROOTS
-- ER relationships: ANCHORS_TO (N side, from SETTLEMENTS_BATCH)
-- ----------------------------------------------------------------------------
CREATE TABLE merkle_batch_roots (
    root_id         BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    batch_id        BIGINT       NOT NULL REFERENCES settlements_batch(batch_id),
    merkle_root_hash CHAR(64)    NOT NULL,
    computed_at     TIMESTAMPTZ  NOT NULL DEFAULT now()
);

CREATE INDEX idx_merkle_batch_roots_batch ON merkle_batch_roots(batch_id);

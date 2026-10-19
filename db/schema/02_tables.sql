-- 15-relation schema (matches the Chen ER diagram)

CREATE TABLE currencies (
    currency_code   CHAR(3)      PRIMARY KEY,
    currency_name   VARCHAR(64)  NOT NULL,
    minor_unit      SMALLINT     NOT NULL DEFAULT 2,
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT now()
);

CREATE TABLE institutions (
    institution_id  BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    institution_name VARCHAR(128) NOT NULL,
    swift_bic       VARCHAR(11),
    country_code    CHAR(2)      NOT NULL,
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT now()
);

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

CREATE TABLE api_clients (
    client_id       BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    institution_id  BIGINT       NOT NULL REFERENCES institutions(institution_id),
    client_name     VARCHAR(128) NOT NULL,
    api_key_hash    CHAR(64)     NOT NULL UNIQUE,
    status          VARCHAR(16)  NOT NULL DEFAULT 'ACTIVE'
                        CHECK (status IN ('ACTIVE', 'SUSPENDED', 'REVOKED')),
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT now()
);

CREATE TABLE accounts (
    account_id      BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    account_holder_id BIGINT     NOT NULL REFERENCES account_holder(account_holder_id),
    institution_id  BIGINT       NOT NULL REFERENCES institutions(institution_id),
    currency_code   CHAR(3)      NOT NULL REFERENCES currencies(currency_code),
    account_number  VARCHAR(34)  NOT NULL UNIQUE,
    account_type    VARCHAR(16)  NOT NULL DEFAULT 'SAVINGS'
                        CHECK (account_type IN ('SAVINGS', 'CURRENT', 'SETTLEMENT')),
    status          VARCHAR(16)  NOT NULL DEFAULT 'ACTIVE'
                        CHECK (status IN ('ACTIVE', 'FROZEN', 'CLOSED')),
    -- cached; source of truth is SUM(entry_lines)
    cached_balance  NUMERIC(18,4) NOT NULL DEFAULT 0,
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT now()
);

CREATE INDEX idx_accounts_holder ON accounts(account_holder_id);
CREATE INDEX idx_accounts_institution ON accounts(institution_id);

CREATE TABLE exchange_rates (
    rate_id         BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    base_currency_code   CHAR(3) NOT NULL REFERENCES currencies(currency_code),
    target_currency_code CHAR(3) NOT NULL REFERENCES currencies(currency_code),
    rate            NUMERIC(18,8) NOT NULL CHECK (rate > 0),
    effective_at    TIMESTAMPTZ  NOT NULL DEFAULT now(),
    CONSTRAINT chk_distinct_currencies CHECK (base_currency_code <> target_currency_code)
);

CREATE INDEX idx_exchange_rates_pair_time ON exchange_rates(base_currency_code, target_currency_code, effective_at DESC);

CREATE TABLE settlements_batch (
    batch_id        BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    batch_type      VARCHAR(16)  NOT NULL DEFAULT 'NET'
                        CHECK (batch_type IN ('NET', 'RTGS_SWEEP')),
    status          VARCHAR(16)  NOT NULL DEFAULT 'OPEN'
                        CHECK (status IN ('OPEN', 'CLEARING', 'CLOSED')),
    opened_at       TIMESTAMPTZ  NOT NULL DEFAULT now(),
    closed_at       TIMESTAMPTZ
);

-- transactions (header only; money moves via entry_lines)
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

-- entry_lines (double-entry core, append-only)
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

CREATE TABLE idempotency_keys (
    idempotency_key_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    client_id       BIGINT       NOT NULL REFERENCES api_clients(client_id),
    idempotency_key VARCHAR(128) NOT NULL,
    transaction_id  BIGINT       REFERENCES transactions(transaction_id),
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
    expires_at      TIMESTAMPTZ  NOT NULL DEFAULT (now() + INTERVAL '24 hours'),
    CONSTRAINT uq_client_idempotency_key UNIQUE (client_id, idempotency_key)
);

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

-- audit_merkle_log (append-only, hash-chained; written only by trigger)
CREATE TABLE audit_merkle_log (
    log_id          BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    entry_line_id   BIGINT       NOT NULL UNIQUE REFERENCES entry_lines(entry_line_id),
    entry_hash      CHAR(64)     NOT NULL,
    prev_hash       CHAR(64),
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT now()
);

CREATE INDEX idx_audit_merkle_log_created ON audit_merkle_log(created_at);

CREATE TABLE concurrency_lock_log (
    lock_id         BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    transaction_id  BIGINT       NOT NULL REFERENCES transactions(transaction_id),
    account_id      BIGINT       NOT NULL REFERENCES accounts(account_id),
    lock_order      SMALLINT     NOT NULL,
    acquired_at     TIMESTAMPTZ  NOT NULL DEFAULT now(),
    released_at     TIMESTAMPTZ
);

CREATE INDEX idx_concurrency_lock_log_transaction ON concurrency_lock_log(transaction_id);
CREATE INDEX idx_concurrency_lock_log_account ON concurrency_lock_log(account_id);

CREATE TABLE reconciliation_runs (
    run_id          BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    transaction_id  BIGINT       REFERENCES transactions(transaction_id),
    run_at          TIMESTAMPTZ  NOT NULL DEFAULT now(),
    status          VARCHAR(16)  NOT NULL DEFAULT 'CLEAN'
                        CHECK (status IN ('CLEAN', 'DISCREPANCY')),
    discrepancy_amount NUMERIC(18,4) NOT NULL DEFAULT 0
);

CREATE INDEX idx_reconciliation_runs_transaction ON reconciliation_runs(transaction_id);

CREATE TABLE merkle_batch_roots (
    root_id         BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    batch_id        BIGINT       NOT NULL REFERENCES settlements_batch(batch_id),
    merkle_root_hash CHAR(64)    NOT NULL,
    computed_at     TIMESTAMPTZ  NOT NULL DEFAULT now()
);

CREATE INDEX idx_merkle_batch_roots_batch ON merkle_batch_roots(batch_id);

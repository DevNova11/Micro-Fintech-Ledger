-- ============================================================================
-- Decentralized Micro-FinTech Ledger & Cleared Settlement Core
-- 01_extensions.sql — required PostgreSQL extensions
-- ============================================================================

-- pgcrypto gives us gen_random_uuid() for surrogate keys and digest() as a
-- fallback SHA-256 implementation if we ever need it outside PL/pgSQL.
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- =============================================================================
-- PHASE 15: employee_sessions — refresh-token storage for the employee
-- portal's own login, mirroring `sessions` (users) exactly but scoped to
-- `employees` — kept as a separate table rather than reusing `sessions`
-- because employees are a deliberately separate identity space from users
-- throughout this schema (see employees/employee_permissions comments in
-- 001_init_schema.sql), and `sessions.user_id` is FK'd to `users(id)`.
-- Purely additive: no existing table/column is altered.
-- =============================================================================

CREATE TABLE IF NOT EXISTS employee_sessions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  employee_id UUID NOT NULL REFERENCES employees(id) ON DELETE CASCADE,
  refresh_token_hash CHAR(64) NOT NULL,
  issued_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  expires_at TIMESTAMPTZ NOT NULL,
  revoked_at TIMESTAMPTZ NULL,
  user_agent TEXT NULL,
  ip_address INET NULL,
  CONSTRAINT uq_employee_sessions_refresh_token_hash UNIQUE (refresh_token_hash)
);
CREATE INDEX IF NOT EXISTS idx_employee_sessions_employee ON employee_sessions (employee_id);
CREATE INDEX IF NOT EXISTS idx_employee_sessions_expires ON employee_sessions (expires_at);

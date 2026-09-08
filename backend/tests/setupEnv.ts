// Populates required environment variables with safe dummy values before
// any test imports src/config/env.ts (which validates process.env eagerly
// at module load). Tests never talk to a real database or Google — the
// pg pool and google-auth-library are mocked per-test.
process.env.NODE_ENV = process.env.NODE_ENV ?? 'test';
process.env.PG_USER = process.env.PG_USER ?? 'test_user';
process.env.PG_PASSWORD = process.env.PG_PASSWORD ?? 'test_password';
process.env.PG_DATABASE = process.env.PG_DATABASE ?? 'test_db';
process.env.GOOGLE_OAUTH_CLIENT_ID = process.env.GOOGLE_OAUTH_CLIENT_ID ?? 'test-client-id.apps.googleusercontent.com';
process.env.JWT_ACCESS_SECRET = process.env.JWT_ACCESS_SECRET ?? 'test-access-secret-needs-32-chars-minimum';
process.env.JWT_REFRESH_SECRET = process.env.JWT_REFRESH_SECRET ?? 'test-refresh-secret-needs-32-chars-minimum';
process.env.EMPLOYEE_JWT_ACCESS_SECRET =
  process.env.EMPLOYEE_JWT_ACCESS_SECRET ?? 'test-employee-access-secret-needs-32-chars-min';
process.env.EMPLOYEE_JWT_REFRESH_SECRET =
  process.env.EMPLOYEE_JWT_REFRESH_SECRET ?? 'test-employee-refresh-secret-needs-32-chars-min';
process.env.MINIO_ACCESS_KEY = process.env.MINIO_ACCESS_KEY ?? 'test_minio_access_key';
process.env.MINIO_SECRET_KEY = process.env.MINIO_SECRET_KEY ?? 'test_minio_secret_key';

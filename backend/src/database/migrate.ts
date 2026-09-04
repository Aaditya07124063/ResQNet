import fs from 'node:fs';
import path from 'node:path';
import { Client } from 'pg';
import { env } from '../config/env';
import { logger } from '../utils/logger';

// Minimal, dependency-free migration runner: applies each .sql file in
// src/database/migrations/ (sorted by filename, hence the NNN_ prefix)
// exactly once, tracked in schema_migrations. Intended for manual/CI use
// (`npm run migrate`) — never invoked automatically by the app at boot, so
// a bad migration can't take down a running deployment.
const MIGRATIONS_DIR = path.join(__dirname, 'migrations');

async function main(): Promise<void> {
  const client = new Client({
    host: env.PG_HOST,
    port: env.PG_PORT,
    user: env.PG_USER,
    password: env.PG_PASSWORD,
    database: env.PG_DATABASE,
    ssl: env.PG_SSL ? { rejectUnauthorized: true } : undefined,
  });
  await client.connect();

  await client.query(`
    CREATE TABLE IF NOT EXISTS schema_migrations (
      filename VARCHAR(255) PRIMARY KEY,
      applied_at TIMESTAMPTZ NOT NULL DEFAULT now()
    );
  `);

  const { rows: appliedRows } = await client.query<{ filename: string }>(
    'SELECT filename FROM schema_migrations',
  );
  const applied = new Set(appliedRows.map((r) => r.filename));

  const files = fs
    .readdirSync(MIGRATIONS_DIR)
    .filter((f) => f.endsWith('.sql'))
    .sort();

  for (const file of files) {
    if (applied.has(file)) {
      logger.info({ file }, 'Migration already applied, skipping');
      continue;
    }
    const sql = fs.readFileSync(path.join(MIGRATIONS_DIR, file), 'utf8');
    logger.info({ file }, 'Applying migration');
    await client.query(sql);
    await client.query('INSERT INTO schema_migrations (filename) VALUES ($1)', [file]);
    logger.info({ file }, 'Migration applied');
  }

  await client.end();
}

main().catch((err) => {
  logger.error({ err }, 'Migration failed');
  process.exit(1);
});

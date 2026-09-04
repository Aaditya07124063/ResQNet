import { Pool, type PoolClient } from 'pg';
import { env } from '../config/env';

export const pool = new Pool({
  host: env.PG_HOST,
  port: env.PG_PORT,
  user: env.PG_USER,
  password: env.PG_PASSWORD,
  database: env.PG_DATABASE,
  max: env.PG_POOL_MAX,
  ssl: env.PG_SSL ? { rejectUnauthorized: true } : undefined,
});

// Runs `work` inside a transaction: BEGIN, then COMMIT on success or
// ROLLBACK on any thrown error. Use for any multi-statement write (e.g.
// creating a group + its owner membership row together).
export async function withTransaction<T>(work: (client: PoolClient) => Promise<T>): Promise<T> {
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    const result = await work(client);
    await client.query('COMMIT');
    return result;
  } catch (err) {
    await client.query('ROLLBACK');
    throw err;
  } finally {
    client.release();
  }
}

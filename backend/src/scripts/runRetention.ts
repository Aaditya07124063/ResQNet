import { pool } from '../database/pool';
import { runRetention } from '../services/retention/retentionJob';

// One retention run from the command line (host scheduler, or manually).
//   npm run retention:run -- --dry-run      counts what is eligible, changes nothing
//   npm run retention:run:prod              (inside the api container)
// Prints only counts. Exit code 1 when any category failed.

async function main(): Promise<void> {
  const dryRun = process.argv.includes('--dry-run');
  const report = await runRetention({ dryRun });
  process.stdout.write(`${JSON.stringify(report, null, 2)}\n`);
  await pool.end();
  process.exit(report.ok ? 0 : 1);
}

main().catch(async (err: unknown) => {
  process.stderr.write(`Retention run failed: ${(err as { code?: string }).code ?? 'error'}\n`);
  await pool.end().catch(() => undefined);
  process.exit(1);
});

import { env } from '../../config/env';
import { logger } from '../../utils/logger';
import { runRetention } from './retentionJob';

/**
 * Optional in-process schedule (RETENTION_SCHEDULE_MINUTES). Off by
 * default: run `npm run retention:run:prod` from the host scheduler instead.
 * Safe with several API instances — the job's advisory lock lets only one
 * run at a time.
 */
export function startRetentionSchedule(): (() => void) | null {
  const minutes = env.RETENTION_SCHEDULE_MINUTES;
  if (!minutes) return null;
  let running = false;
  const tick = () => {
    if (running) return;
    running = true;
    runRetention()
      .then((report) => {
        if (!report.ok) logger.error({ job: 'retention' }, 'Scheduled retention run finished with failures');
      })
      .catch((err: unknown) => logger.error({ job: 'retention', errorCode: (err as { code?: string }).code }, 'Scheduled retention run failed'))
      .finally(() => {
        running = false;
      });
  };
  const timer = setInterval(tick, minutes * 60_000);
  timer.unref();
  logger.info({ job: 'retention', everyMinutes: minutes }, 'Retention schedule started');
  return () => clearInterval(timer);
}

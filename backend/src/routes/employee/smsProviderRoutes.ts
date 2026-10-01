import { Router } from 'express';
import { z } from 'zod';
import { asyncHandler } from '../../utils/asyncHandler';
import { requireEmployeeAuth } from '../../middleware/employeeAuthMiddleware';
import { requirePermission } from '../../middleware/rbac';
import { validateBody } from '../../middleware/validate';
import { smsProviderTestRateLimiter } from '../../middleware/rateLimiter';
import {
  createSmsProvider,
  disableSmsProvider,
  listSmsProviders,
  testSmsProvider,
  updateSmsProvider,
} from '../../services/smsProviderAdminService';
import { recordAuditEvent } from '../../services/auditLogService';
import { normalizePhoneNumber } from '../../utils/phoneNumber';
import { HttpError } from '../../utils/httpError';

export const smsProviderRouter = Router();

// SMS_PROVIDER_MANAGE is its own grant (not SETTINGS_MANAGE): these routes
// handle third-party credentials and can trigger billed sends. Enforced
// here server-side; the Flutter portal only mirrors it for UX.
const SMS_PROVIDER_MANAGE = 'SMS_PROVIDER_MANAGE';

// Credential/configuration values are bounded strings (or, for
// configuration only, booleans/numbers/null) — never nested objects.
const settingValue = z.union([z.string().max(4096), z.number(), z.boolean(), z.null()]);
const settingsRecord = z.record(z.string().max(64), settingValue);

const createSchema = z.object({
  providerType: z.string().trim().min(1).max(40),
  displayName: z.string().trim().min(1).max(120),
  enabled: z.boolean().optional(),
  priority: z.number().int().min(0).max(100_000).optional(),
  credentials: z.record(z.string().max(64), z.string().max(4096)),
  configuration: settingsRecord.default({}),
});

const updateSchema = z
  .object({
    displayName: z.string().trim().min(1).max(120).optional(),
    enabled: z.boolean().optional(),
    priority: z.number().int().min(0).max(100_000).optional(),
    credentials: z.record(z.string().max(64), z.string().max(4096).nullable()).optional(),
    configuration: settingsRecord.optional(),
  })
  .refine((value) => Object.values(value).some((v) => v !== undefined), 'At least one update is required');

const testSchema = z.object({ phoneNumber: z.string().trim().min(6).max(20) });

function providerId(raw: string | undefined): string {
  const parsed = z.string().uuid().safeParse(raw);
  if (!parsed.success) throw HttpError.notFound('SMS provider not found');
  return parsed.data;
}

smsProviderRouter.use(requireEmployeeAuth, requirePermission(SMS_PROVIDER_MANAGE));

smsProviderRouter.get(
  '/',
  asyncHandler(async (_req, res) => {
    res.json(await listSmsProviders());
  }),
);

smsProviderRouter.post(
  '/',
  validateBody(createSchema),
  asyncHandler(async (req, res) => {
    const provider = await createSmsProvider(req.body);
    await recordAuditEvent({
      actorEmployeeId: req.authEmployee!.id,
      action: 'sms_provider.create',
      resourceType: 'sms_provider',
      resourceId: provider.id,
      outcome: 'success',
      ipAddress: req.ip,
      metadata: { providerType: provider.providerType, enabled: provider.enabled, priority: provider.priority },
    });
    res.status(201).json({ provider });
  }),
);

smsProviderRouter.patch(
  '/:id',
  validateBody(updateSchema),
  asyncHandler(async (req, res) => {
    const id = providerId(req.params.id);
    const body = req.body as z.infer<typeof updateSchema>;
    const provider = await updateSmsProvider(id, {
      ...body,
      credentials: body.credentials as Record<string, unknown> | undefined,
    });
    await recordAuditEvent({
      actorEmployeeId: req.authEmployee!.id,
      action: 'sms_provider.update',
      resourceType: 'sms_provider',
      resourceId: provider.id,
      outcome: 'success',
      ipAddress: req.ip,
      // Which fields changed, never their values.
      metadata: {
        changed: Object.keys(body),
        credentialFields: Object.keys(body.credentials ?? {}),
        enabled: provider.enabled,
        priority: provider.priority,
      },
    });
    res.json({ provider });
  }),
);

smsProviderRouter.delete(
  '/:id',
  asyncHandler(async (req, res) => {
    const id = providerId(req.params.id);
    await disableSmsProvider(id);
    await recordAuditEvent({
      actorEmployeeId: req.authEmployee!.id,
      action: 'sms_provider.disable',
      resourceType: 'sms_provider',
      resourceId: id,
      outcome: 'success',
      ipAddress: req.ip,
    });
    res.status(204).send();
  }),
);

smsProviderRouter.post(
  '/:id/test',
  smsProviderTestRateLimiter,
  validateBody(testSchema),
  asyncHandler(async (req, res) => {
    const id = providerId(req.params.id);
    const phone = normalizePhoneNumber((req.body as z.infer<typeof testSchema>).phoneNumber);
    if (!phone) throw HttpError.badRequest('Phone number is not valid');
    const result = await testSmsProvider(id, phone);
    await recordAuditEvent({
      actorEmployeeId: req.authEmployee!.id,
      action: 'sms_provider.test',
      resourceType: 'sms_provider',
      resourceId: id,
      outcome: result.status === 'success' ? 'success' : 'error',
      ipAddress: req.ip,
      metadata: { failure: result.failure ?? null },
    });
    res.json({ result });
  }),
);

import { z } from 'zod';

export const employeeLoginSchema = z.object({
  email: z.string().trim().email().max(320),
  password: z.string().min(1).max(256),
});

// No existing password policy exists anywhere in this codebase (Google/
// phone sign-in never involved a password) — a length-only minimum is
// applied here as current standard practice (NIST 800-63B: length matters
// more than forced complexity), not an invented business rule.
export const createEmployeeSchema = z.object({
  email: z.string().trim().email().max(320),
  password: z.string().min(12).max(256),
  displayName: z.string().trim().min(1).max(120),
  role: z.enum(['super_admin', 'admin', 'employee']),
});

// `permission` has no CHECK constraint in the schema (employee_permissions
// is explicitly "not a hardcoded enum switch" per its own doc comment) —
// validated here only against what the column itself allows (VARCHAR(60)),
// same reasoning as reportSchemas.ts's `reason` field.
export const grantPermissionSchema = z.object({
  permission: z.string().trim().min(1).max(60),
});

export const upsertSettingSchema = z.object({
  value: z.unknown().refine((v) => v !== undefined, 'value is required'),
  description: z
    .string()
    .trim()
    .max(500)
    .nullable()
    .optional()
    .transform((v) => (v ? v : null)),
});

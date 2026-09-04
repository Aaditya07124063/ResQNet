import { z } from 'zod';

const nullableTrimmedString = (max: number) =>
  z
    .string()
    .trim()
    .max(max)
    .nullable()
    .optional()
    .transform((v) => (v === '' ? null : v ?? null));

export const profileUpdateSchema = z.object({
  fatherName: nullableTrimmedString(120),
  age: z.number().int().min(0).max(150).nullable().optional(),
  address: nullableTrimmedString(300),
  bloodGroup: z
    .enum(['A+', 'A-', 'B+', 'B-', 'AB+', 'AB-', 'O+', 'O-'])
    .nullable()
    .optional(),
  allergies: nullableTrimmedString(2000),
  medications: nullableTrimmedString(2000),
  emergencyContact: nullableTrimmedString(120),
  country: nullableTrimmedString(80),
  state: nullableTrimmedString(80),
  city: nullableTrimmedString(80),
  profilePictureVisibility: z.enum(['private', 'contacts_only', 'groups_only', 'public']).optional(),
});

// E.164-ish: leading +, then 8-15 digits. Loose on purpose — real carrier
// validation belongs to the SMS provider system (Phase 8), not here.
const phoneNumberSchema = z
  .string()
  .trim()
  .regex(/^\+?[1-9]\d{7,14}$/, 'Must be a valid phone number, e.g. +15551234567');

export const trustedContactSchema = z.object({
  name: z.string().trim().min(1).max(120),
  phoneNumber: phoneNumberSchema,
  relationship: z.string().trim().max(60).nullable().optional().transform((v) => v ?? null),
});

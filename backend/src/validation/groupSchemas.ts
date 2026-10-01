import { z } from 'zod';

export const GROUP_KINDS = ['general', 'family', 'trekking', 'friends', 'rescue_team', 'organization', 'emergency'] as const;

export const createGroupSchema = z.object({
  name: z.string().trim().min(1).max(120),
  description: z.string().trim().max(500).optional(),
  kind: z.enum(GROUP_KINDS).default('general'),
});

export const addGroupMemberSchema = z.object({
  userId: z.string().uuid(),
});

export const updateGroupMemberSchema = z.object({
  role: z.enum(['admin', 'member']),
});

export const transferGroupOwnershipSchema = z.object({
  userId: z.string().uuid(),
});

export type CreateGroupInput = z.infer<typeof createGroupSchema>;

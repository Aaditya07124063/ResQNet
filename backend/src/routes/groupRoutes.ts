import { Router } from 'express';
import { asyncHandler } from '../utils/asyncHandler';
import { requireAuth } from '../middleware/authMiddleware';
import { validateBody } from '../middleware/validate';
import { conversationRateLimiter } from '../middleware/rateLimiter';
import { z } from 'zod';
import { HttpError } from '../utils/httpError';
import {
  addGroupMemberSchema,
  createGroupSchema,
  transferGroupOwnershipSchema,
  updateGroupMemberSchema,
} from '../validation/groupSchemas';
import {
  addGroupMember,
  createGroup,
  getGroup,
  listGroupsForUser,
  removeGroupMember,
  setGroupMemberRole,
  transferGroupOwnership,
} from '../services/groupService';
import { recordAuditEvent } from '../services/auditLogService';

export const groupRouter = Router();

const uuidParam = z.string().uuid();
function requireUuidParam(value: string | undefined): string {
  const result = uuidParam.safeParse(value);
  if (!result.success) throw HttpError.badRequest('Invalid id');
  return result.data;
}

// Group chat itself uses the existing /conversations/:conversationId/messages
// routes (each group has one conversation) — only membership lives here.

groupRouter.post(
  '/',
  requireAuth,
  conversationRateLimiter,
  validateBody(createGroupSchema),
  asyncHandler(async (req, res) => {
    const group = await createGroup(req.authUser!.id, req.body);
    await recordAuditEvent({
      actorUserId: req.authUser!.id,
      action: 'group.create',
      resourceType: 'group',
      resourceId: group.id,
      outcome: 'success',
      ipAddress: req.ip,
    });
    res.status(201).json({ group });
  }),
);

groupRouter.get(
  '/',
  requireAuth,
  asyncHandler(async (req, res) => {
    res.json({ groups: await listGroupsForUser(req.authUser!.id) });
  }),
);

groupRouter.get(
  '/:id',
  requireAuth,
  asyncHandler(async (req, res) => {
    res.json({ group: await getGroup(req.authUser!.id, requireUuidParam(req.params.id)) });
  }),
);

groupRouter.post(
  '/:id/members',
  requireAuth,
  conversationRateLimiter,
  validateBody(addGroupMemberSchema),
  asyncHandler(async (req, res) => {
    const groupId = requireUuidParam(req.params.id);
    await addGroupMember(req.authUser!.id, groupId, req.body.userId);
    await recordAuditEvent({
      actorUserId: req.authUser!.id,
      action: 'group.member_add',
      resourceType: 'group',
      resourceId: groupId,
      outcome: 'success',
      ipAddress: req.ip,
      metadata: { memberUserId: req.body.userId },
    });
    res.status(204).send();
  }),
);

groupRouter.patch(
  '/:id/members/:userId',
  requireAuth,
  validateBody(updateGroupMemberSchema),
  asyncHandler(async (req, res) => {
    const groupId = requireUuidParam(req.params.id);
    const userId = requireUuidParam(req.params.userId);
    await setGroupMemberRole(req.authUser!.id, groupId, userId, req.body.role);
    await recordAuditEvent({
      actorUserId: req.authUser!.id,
      action: 'group.member_role',
      resourceType: 'group',
      resourceId: groupId,
      outcome: 'success',
      ipAddress: req.ip,
      metadata: { memberUserId: userId, role: req.body.role },
    });
    res.status(204).send();
  }),
);

groupRouter.post(
  '/:id/owner',
  requireAuth,
  validateBody(transferGroupOwnershipSchema),
  asyncHandler(async (req, res) => {
    const groupId = requireUuidParam(req.params.id);
    await transferGroupOwnership(req.authUser!.id, groupId, req.body.userId);
    await recordAuditEvent({
      actorUserId: req.authUser!.id,
      action: 'group.owner_transfer',
      resourceType: 'group',
      resourceId: groupId,
      outcome: 'success',
      ipAddress: req.ip,
      metadata: { newOwnerUserId: req.body.userId },
    });
    res.status(204).send();
  }),
);

// Removing yourself is "leave group".
groupRouter.delete(
  '/:id/members/:userId',
  requireAuth,
  asyncHandler(async (req, res) => {
    const groupId = requireUuidParam(req.params.id);
    const userId = requireUuidParam(req.params.userId);
    await removeGroupMember(req.authUser!.id, groupId, userId);
    await recordAuditEvent({
      actorUserId: req.authUser!.id,
      action: userId === req.authUser!.id ? 'group.leave' : 'group.member_remove',
      resourceType: 'group',
      resourceId: groupId,
      outcome: 'success',
      ipAddress: req.ip,
      metadata: { memberUserId: userId },
    });
    res.status(204).send();
  }),
);

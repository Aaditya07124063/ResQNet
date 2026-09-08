import { Router } from 'express';
import { z } from 'zod';
import { asyncHandler } from '../utils/asyncHandler';
import { HttpError } from '../utils/httpError';
import { requireAuth } from '../middleware/authMiddleware';
import { conversationRateLimiter, messageRateLimiter } from '../middleware/rateLimiter';
import { validateBody } from '../middleware/validate';
import {
  createConversationSchema,
  listMessagesQuerySchema,
  markConversationReadSchema,
  sendMessageSchema,
  updateMessageStatusSchema,
} from '../validation/communicationSchemas';
import {
  findOrCreateDirectConversation,
  listConversationsForUser,
  requireParticipant,
} from '../services/conversationService';
import { listMessages, markConversationRead, sendMessage, updateMessageStatus } from '../services/messageService';

export const conversationRouter = Router();

const uuidParam = z.string().uuid();

function requireUuidParam(value: string | undefined): string {
  const result = uuidParam.safeParse(value);
  if (!result.success) throw HttpError.badRequest('Invalid id');
  return result.data;
}

// Every route below operates only on conversations req.authUser.id is
// actually a participant of — requireParticipant (or the services it
// backs) enforces this on every read and write, never trusting the
// conversationId path param alone (IDOR protection, Section 7/30).

conversationRouter.post(
  '/',
  requireAuth,
  conversationRateLimiter,
  validateBody(createConversationSchema),
  asyncHandler(async (req, res) => {
    const conversationId = await findOrCreateDirectConversation(req.authUser!.id, req.body.participantUserId);
    res.status(201).json({ conversationId });
  }),
);

conversationRouter.get(
  '/',
  requireAuth,
  asyncHandler(async (req, res) => {
    const conversations = await listConversationsForUser(req.authUser!.id);
    res.json({ conversations });
  }),
);

conversationRouter.get(
  '/:id/messages',
  requireAuth,
  asyncHandler(async (req, res) => {
    const conversationId = requireUuidParam(req.params.id);
    const query = listMessagesQuerySchema.safeParse(req.query);
    if (!query.success) throw HttpError.badRequest('Invalid query parameters', query.error.flatten());
    const messages = await listMessages(conversationId, req.authUser!.id, query.data);
    res.json({ messages });
  }),
);

conversationRouter.post(
  '/:id/messages',
  requireAuth,
  messageRateLimiter,
  validateBody(sendMessageSchema),
  asyncHandler(async (req, res) => {
    const conversationId = requireUuidParam(req.params.id);
    const message = await sendMessage(conversationId, req.authUser!.id, req.body);
    res.status(201).json({ message });
  }),
);

conversationRouter.post(
  '/:id/messages/:messageId/status',
  requireAuth,
  messageRateLimiter,
  validateBody(updateMessageStatusSchema),
  asyncHandler(async (req, res) => {
    const conversationId = requireUuidParam(req.params.id);
    const messageId = requireUuidParam(req.params.messageId);
    await updateMessageStatus(conversationId, req.authUser!.id, messageId, req.body.status);
    res.status(204).end();
  }),
);

conversationRouter.post(
  '/:id/read',
  requireAuth,
  messageRateLimiter,
  validateBody(markConversationReadSchema),
  asyncHandler(async (req, res) => {
    const conversationId = requireUuidParam(req.params.id);
    await markConversationRead(conversationId, req.authUser!.id, req.body.upToMessageId);
    res.status(204).end();
  }),
);

// Explicit membership-check endpoint — lets the Flutter client verify it
// can open a conversation (e.g. reached via a deep link) before rendering
// the chat screen, without that check being a side effect of some other
// call.
conversationRouter.get(
  '/:id',
  requireAuth,
  asyncHandler(async (req, res) => {
    const conversationId = requireUuidParam(req.params.id);
    await requireParticipant(conversationId, req.authUser!.id);
    res.json({ conversationId });
  }),
);

import { z } from 'zod';

export const createConversationSchema = z.object({
  participantUserId: z.string().uuid(),
});
export type CreateConversationInput = z.infer<typeof createConversationSchema>;

// A discriminated union keeps a text message from ever carrying
// coordinates and a location message from ever carrying a body — the same
// invariant the database's chk_messages_type_payload CHECK enforces,
// caught here first as a clean 400 instead of a DB constraint-violation
// 500 (same reasoning as sosSchemas.ts's eventSource comment).
const baseMessageFields = {
  clientMessageId: z.string().uuid(),
  clientCreatedAt: z.coerce.date(),
};

// Deliberately NOT .strict() — matches sosSchemas.ts's own convention of
// silently ignoring extra/irrelevant client-supplied fields (e.g. a
// spoofed senderId) rather than rejecting the whole request over them.
// A text message sent with a stray latitude/longitude is ignored the same
// way, not treated as malformed — the server-persisted row is still
// unambiguously text-only either way, since only the matched branch's
// fields (body, not latitude/longitude) ever reach sendMessage's input.
export const sendMessageSchema = z.discriminatedUnion('messageType', [
  z.object({
    messageType: z.literal('text'),
    body: z.string().trim().min(1).max(4000),
    ...baseMessageFields,
  }),
  z.object({
    messageType: z.literal('location'),
    latitude: z.number().min(-90).max(90),
    longitude: z.number().min(-180).max(180),
    locationAccuracyM: z.number().nonnegative().nullable().optional().transform((v) => v ?? null),
    ...baseMessageFields,
  }),
]);
export type SendMessageInput = z.infer<typeof sendMessageSchema>;

export const listMessagesQuerySchema = z.object({
  // Cursor = the server_received_at ISO timestamp of the oldest message
  // already loaded by the client — "give me messages strictly before
  // this", so pagination is stable even as new messages keep arriving at
  // the head of the conversation.
  before: z.coerce.date().optional(),
  limit: z.coerce.number().int().min(1).max(100).default(50),
});
export type ListMessagesQuery = z.infer<typeof listMessagesQuerySchema>;

export const updateMessageStatusSchema = z.object({
  status: z.enum(['delivered', 'read']),
});
export type UpdateMessageStatusInput = z.infer<typeof updateMessageStatusSchema>;

export const markConversationReadSchema = z.object({
  upToMessageId: z.string().uuid(),
});
export type MarkConversationReadInput = z.infer<typeof markConversationReadSchema>;

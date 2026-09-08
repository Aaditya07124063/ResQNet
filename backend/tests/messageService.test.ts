jest.mock('../src/database/pool', () => ({
  pool: { query: jest.fn() },
  withTransaction: jest.fn(),
}));
jest.mock('../src/websocket/wsServer', () => ({
  broadcastToUser: jest.fn(),
}));
jest.mock('../src/services/conversationService', () => ({
  requireParticipant: jest.fn(),
  getOtherParticipantIds: jest.fn(),
}));

import { pool, withTransaction } from '../src/database/pool';
import { broadcastToUser } from '../src/websocket/wsServer';
import { getOtherParticipantIds, requireParticipant } from '../src/services/conversationService';
import { listMessages, markConversationRead, sendMessage, updateMessageStatus } from '../src/services/messageService';

const mockPoolQuery = pool.query as jest.Mock;
const mockWithTransaction = withTransaction as jest.Mock;
const mockBroadcastToUser = broadcastToUser as jest.Mock;
const mockRequireParticipant = requireParticipant as jest.Mock;
const mockGetOtherParticipantIds = getOtherParticipantIds as jest.Mock;

const CONVERSATION_ID = 'conv-1';
const SENDER_ID = 'sender-1';
const RECIPIENT_ID = 'recipient-1';

function fakeTextMessageRow(overrides: Record<string, unknown> = {}) {
  return {
    id: 'msg-1',
    conversation_id: CONVERSATION_ID,
    sender_user_id: SENDER_ID,
    client_message_id: 'client-msg-1',
    message_type: 'text',
    body: 'hello',
    attachment_object_key: null,
    latitude: null,
    longitude: null,
    location_accuracy_m: null,
    client_created_at: new Date('2026-01-01T00:00:00Z'),
    server_received_at: new Date('2026-01-01T00:00:01Z'),
    edited_at: null,
    deleted_at: null,
    ...overrides,
  };
}

const TEXT_INPUT = {
  messageType: 'text' as const,
  body: 'hello',
  clientMessageId: 'client-msg-1',
  clientCreatedAt: new Date('2026-01-01T00:00:00Z'),
};

beforeEach(() => {
  jest.clearAllMocks();
  mockRequireParticipant.mockResolvedValue(undefined);
  mockGetOtherParticipantIds.mockResolvedValue([RECIPIENT_ID]);
});

describe('sendMessage', () => {
  it('checks conversation membership before doing anything else', async () => {
    const { HttpError } = jest.requireActual('../src/utils/httpError');
    mockRequireParticipant.mockRejectedValueOnce(HttpError.notFound('Conversation not found'));

    await expect(sendMessage(CONVERSATION_ID, 'not-a-participant', TEXT_INPUT)).rejects.toMatchObject({
      status: 404,
    });
    expect(mockWithTransaction).not.toHaveBeenCalled();
  });

  it('persists a text message and fans out recipient rows to every OTHER current participant', async () => {
    const txQuery = jest
      .fn()
      .mockResolvedValueOnce({ rows: [fakeTextMessageRow()] }) // INSERT messages
      .mockResolvedValueOnce({ rows: [{ user_id: RECIPIENT_ID }] }) // other participants (tx-scoped)
      .mockResolvedValueOnce({ rows: [] }) // INSERT message_recipients
      .mockResolvedValueOnce({ rows: [] }); // INSERT message_status
    mockWithTransaction.mockImplementationOnce(async (work: (c: { query: typeof txQuery }) => unknown) =>
      work({ query: txQuery }),
    );

    const message = await sendMessage(CONVERSATION_ID, SENDER_ID, TEXT_INPUT);

    expect(message.id).toBe('msg-1');
    expect(message.body).toBe('hello');
    expect(txQuery.mock.calls[2][0]).toMatch(/INSERT INTO message_recipients/);
    expect(txQuery.mock.calls[2][1]).toEqual(['msg-1', RECIPIENT_ID]);
    expect(txQuery.mock.calls[3][0]).toMatch(/INSERT INTO message_status/);
    expect(txQuery.mock.calls[3][1]).toEqual(['msg-1', RECIPIENT_ID, 'sent']);
  });

  it('is idempotent on (conversation_id, client_message_id) — a retried send resolves to the SAME message, not a duplicate', async () => {
    mockWithTransaction.mockRejectedValueOnce(
      Object.assign(new Error('duplicate key value violates unique constraint "uq_messages_conversation_client_id"'), {
        code: '23505',
      }),
    );
    mockPoolQuery.mockResolvedValueOnce({ rows: [fakeTextMessageRow()] }); // the re-fetch by (conversation_id, client_message_id)

    const message = await sendMessage(CONVERSATION_ID, SENDER_ID, TEXT_INPUT);

    expect(message.id).toBe('msg-1');
  });

  it('does not re-fan-out or re-broadcast on an idempotent retry (nothing new happened)', async () => {
    mockWithTransaction.mockRejectedValueOnce(Object.assign(new Error('duplicate'), { code: '23505' }));
    mockPoolQuery.mockResolvedValueOnce({ rows: [fakeTextMessageRow()] });

    await sendMessage(CONVERSATION_ID, SENDER_ID, TEXT_INPUT);

    expect(mockBroadcastToUser).not.toHaveBeenCalled();
  });

  it('refuses (never leaks) when a client_message_id collision belongs to a DIFFERENT sender', async () => {
    mockWithTransaction.mockRejectedValueOnce(Object.assign(new Error('duplicate'), { code: '23505' }));
    mockPoolQuery.mockResolvedValueOnce({ rows: [fakeTextMessageRow({ sender_user_id: 'someone-else' })] });

    await expect(sendMessage(CONVERSATION_ID, SENDER_ID, TEXT_INPUT)).rejects.toMatchObject({ status: 409 });
  });

  it('broadcasts message_created and conversation_updated to every other participant, and conversation_updated back to the sender\'s other devices', async () => {
    const txQuery = jest
      .fn()
      .mockResolvedValueOnce({ rows: [fakeTextMessageRow()] })
      .mockResolvedValueOnce({ rows: [{ user_id: RECIPIENT_ID }] })
      .mockResolvedValueOnce({ rows: [] })
      .mockResolvedValueOnce({ rows: [] });
    mockWithTransaction.mockImplementationOnce(async (work: (c: { query: typeof txQuery }) => unknown) =>
      work({ query: txQuery }),
    );

    await sendMessage(CONVERSATION_ID, SENDER_ID, TEXT_INPUT);

    const recipientCalls = mockBroadcastToUser.mock.calls.filter((c) => c[0] === RECIPIENT_ID);
    expect(recipientCalls.map((c) => c[1].type)).toEqual(
      expect.arrayContaining(['message_created', 'conversation_updated']),
    );
    const senderCalls = mockBroadcastToUser.mock.calls.filter((c) => c[0] === SENDER_ID);
    expect(senderCalls).toHaveLength(1);
    expect(senderCalls[0][1].type).toBe('conversation_updated');
  });

  it('never broadcasts message_created to the sender themselves', async () => {
    const txQuery = jest
      .fn()
      .mockResolvedValueOnce({ rows: [fakeTextMessageRow()] })
      .mockResolvedValueOnce({ rows: [{ user_id: RECIPIENT_ID }] })
      .mockResolvedValueOnce({ rows: [] })
      .mockResolvedValueOnce({ rows: [] });
    mockWithTransaction.mockImplementationOnce(async (work: (c: { query: typeof txQuery }) => unknown) =>
      work({ query: txQuery }),
    );

    await sendMessage(CONVERSATION_ID, SENDER_ID, TEXT_INPUT);

    const senderCalls = mockBroadcastToUser.mock.calls.filter((c) => c[0] === SENDER_ID);
    expect(senderCalls.every((c) => c[1].type !== 'message_created')).toBe(true);
  });

  it('persists a location message with coordinates, not a body', async () => {
    const locationRow = fakeTextMessageRow({
      message_type: 'location',
      body: null,
      latitude: '27.717200',
      longitude: '85.324000',
      location_accuracy_m: '10.00',
    });
    const txQuery = jest
      .fn()
      .mockResolvedValueOnce({ rows: [locationRow] })
      .mockResolvedValueOnce({ rows: [] });
    mockWithTransaction.mockImplementationOnce(async (work: (c: { query: typeof txQuery }) => unknown) =>
      work({ query: txQuery }),
    );
    mockGetOtherParticipantIds.mockResolvedValueOnce([]);

    const message = await sendMessage(CONVERSATION_ID, SENDER_ID, {
      messageType: 'location',
      latitude: 27.7172,
      longitude: 85.324,
      locationAccuracyM: 10,
      clientMessageId: 'client-msg-2',
      clientCreatedAt: new Date('2026-01-01T00:00:00Z'),
    });

    expect(message.messageType).toBe('location');
    expect(message.body).toBeNull();
    expect(message.latitude).toBe(27.7172);
    expect(message.longitude).toBe(85.324);
  });
});

describe('listMessages', () => {
  it('checks conversation membership (IDOR protection) before returning anything', async () => {
    const { HttpError } = jest.requireActual('../src/utils/httpError');
    mockRequireParticipant.mockRejectedValueOnce(HttpError.notFound('Conversation not found'));

    await expect(listMessages(CONVERSATION_ID, 'not-a-participant', { limit: 50 })).rejects.toMatchObject({
      status: 404,
    });
    expect(mockPoolQuery).not.toHaveBeenCalled();
  });

  it('paginates with a cursor (before) when given one', async () => {
    mockPoolQuery.mockResolvedValueOnce({ rows: [fakeTextMessageRow()] });
    const before = new Date('2026-01-01T00:00:05Z');

    await listMessages(CONVERSATION_ID, SENDER_ID, { before, limit: 10 });

    expect(mockPoolQuery.mock.calls[0][0]).toMatch(/server_received_at < \$2/);
    expect(mockPoolQuery.mock.calls[0][1]).toEqual([CONVERSATION_ID, before, 10]);
  });

  it('omits the cursor condition on the first page', async () => {
    mockPoolQuery.mockResolvedValueOnce({ rows: [] });

    await listMessages(CONVERSATION_ID, SENDER_ID, { limit: 50 });

    expect(mockPoolQuery.mock.calls[0][0]).not.toMatch(/server_received_at </);
    expect(mockPoolQuery.mock.calls[0][1]).toEqual([CONVERSATION_ID, 50]);
  });

  it('never returns soft-deleted messages', async () => {
    mockPoolQuery.mockResolvedValueOnce({ rows: [] });
    await listMessages(CONVERSATION_ID, SENDER_ID, { limit: 50 });
    expect(mockPoolQuery.mock.calls[0][0]).toMatch(/deleted_at IS NULL/);
  });
});

describe('updateMessageStatus', () => {
  it('checks conversation membership first', async () => {
    const { HttpError } = jest.requireActual('../src/utils/httpError');
    mockRequireParticipant.mockRejectedValueOnce(HttpError.notFound('Conversation not found'));

    await expect(updateMessageStatus(CONVERSATION_ID, 'not-a-participant', 'msg-1', 'read')).rejects.toMatchObject({
      status: 404,
    });
  });

  it('404s (IDOR-safe) when the caller is not that message\'s recipient', async () => {
    mockPoolQuery.mockResolvedValueOnce({ rows: [] });
    await expect(updateMessageStatus(CONVERSATION_ID, 'attacker', 'msg-1', 'read')).rejects.toMatchObject({
      status: 404,
    });
  });

  it('updates status and notifies the SENDER (not the caller/recipient themselves)', async () => {
    mockPoolQuery.mockResolvedValueOnce({ rows: [{ sender_user_id: SENDER_ID, status: 'delivered' }] });

    await updateMessageStatus(CONVERSATION_ID, RECIPIENT_ID, 'msg-1', 'delivered');

    expect(mockBroadcastToUser).toHaveBeenCalledTimes(1);
    expect(mockBroadcastToUser.mock.calls[0][0]).toBe(SENDER_ID);
    expect(mockBroadcastToUser.mock.calls[0][1]).toMatchObject({
      type: 'message_delivered',
      conversationId: CONVERSATION_ID,
      messageId: 'msg-1',
      readerUserId: RECIPIENT_ID,
    });
  });

  it('broadcasts message_read (not message_delivered) for a read update', async () => {
    mockPoolQuery.mockResolvedValueOnce({ rows: [{ sender_user_id: SENDER_ID, status: 'read' }] });

    await updateMessageStatus(CONVERSATION_ID, RECIPIENT_ID, 'msg-1', 'read');

    expect(mockBroadcastToUser.mock.calls[0][1].type).toBe('message_read');
  });

  it('never regresses read back to delivered (the UPDATE\'s own WHERE guard)', async () => {
    mockPoolQuery.mockResolvedValueOnce({ rows: [] }); // guard clause excluded the row -> no match
    await expect(updateMessageStatus(CONVERSATION_ID, RECIPIENT_ID, 'msg-1', 'delivered')).rejects.toMatchObject({
      status: 404,
    });
    expect(mockPoolQuery.mock.calls[0][0]).toMatch(/ms\.status != 'read' OR \$1 = 'read'/);
  });
});

describe('markConversationRead', () => {
  it('checks conversation membership first', async () => {
    const { HttpError } = jest.requireActual('../src/utils/httpError');
    mockRequireParticipant.mockRejectedValueOnce(HttpError.notFound('Conversation not found'));

    await expect(markConversationRead(CONVERSATION_ID, 'not-a-participant', 'msg-1')).rejects.toMatchObject({
      status: 404,
    });
  });

  it('404s when the cutoff message does not exist in this conversation', async () => {
    mockPoolQuery.mockResolvedValueOnce({ rows: [] });
    await expect(markConversationRead(CONVERSATION_ID, RECIPIENT_ID, 'nonexistent')).rejects.toMatchObject({
      status: 404,
    });
  });

  it('marks everything up to the cutoff read, then broadcasts one aggregated event per other participant', async () => {
    mockPoolQuery
      .mockResolvedValueOnce({
        rows: [{ server_received_at: new Date('2026-01-01T00:00:05Z'), sender_user_id: SENDER_ID }],
      })
      .mockResolvedValueOnce({ rows: [] }); // the bulk UPDATE
    mockGetOtherParticipantIds.mockResolvedValueOnce([SENDER_ID]);

    await markConversationRead(CONVERSATION_ID, RECIPIENT_ID, 'msg-5');

    expect(mockPoolQuery.mock.calls[1][0]).toMatch(/UPDATE message_status/);
    expect(mockBroadcastToUser).toHaveBeenCalledTimes(1);
    expect(mockBroadcastToUser.mock.calls[0]).toEqual([
      SENDER_ID,
      { type: 'message_read', conversationId: CONVERSATION_ID, upToMessageId: 'msg-5', readerUserId: RECIPIENT_ID },
    ]);
  });
});

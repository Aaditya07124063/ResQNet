jest.mock('../src/database/pool', () => ({
  pool: { query: jest.fn() },
  withTransaction: jest.fn(),
}));

import { pool, withTransaction } from '../src/database/pool';
import {
  findOrCreateDirectConversation,
  getOtherParticipantIds,
  listConversationsForUser,
  requireParticipant,
} from '../src/services/conversationService';

const mockPoolQuery = pool.query as jest.Mock;
const mockWithTransaction = withTransaction as jest.Mock;

beforeEach(() => {
  jest.clearAllMocks();
});

describe('findOrCreateDirectConversation', () => {
  it('rejects starting a conversation with yourself', async () => {
    await expect(findOrCreateDirectConversation('user-1', 'user-1')).rejects.toMatchObject({ status: 400 });
  });

  it('sorts the pair (a < b) regardless of caller/other order, so the same two users always map to one row', async () => {
    const client = {
      query: jest
        .fn()
        .mockResolvedValueOnce({ rows: [{ id: 'conv-1' }] }), // existing-lookup hit
    };
    mockWithTransaction.mockImplementation(async (work: (c: typeof client) => unknown) => work(client));

    await findOrCreateDirectConversation('user-b', 'user-a');

    expect(client.query.mock.calls[0][1]).toEqual(['user-a', 'user-b']); // sorted
  });

  it('returns the existing conversation id when the pair already has one', async () => {
    const client = { query: jest.fn().mockResolvedValueOnce({ rows: [{ id: 'existing-conv' }] }) };
    mockWithTransaction.mockImplementation(async (work: (c: typeof client) => unknown) => work(client));

    const id = await findOrCreateDirectConversation('user-a', 'user-b');

    expect(id).toBe('existing-conv');
    expect(client.query).toHaveBeenCalledTimes(1); // no INSERT attempted
  });

  it('creates a new conversation + both participants when none exists yet', async () => {
    const client = {
      query: jest
        .fn()
        .mockResolvedValueOnce({ rows: [] }) // no existing row
        .mockResolvedValueOnce({ rows: [{ id: 'new-conv' }] }) // INSERT ... RETURNING id
        .mockResolvedValueOnce({ rows: [] }), // participants insert
    };
    mockWithTransaction.mockImplementation(async (work: (c: typeof client) => unknown) => work(client));

    const id = await findOrCreateDirectConversation('user-a', 'user-b');

    expect(id).toBe('new-conv');
    expect(client.query.mock.calls[1][0]).toMatch(/INSERT INTO conversations/);
    expect(client.query.mock.calls[2][0]).toMatch(/INSERT INTO conversation_participants/);
    expect(client.query.mock.calls[2][1]).toEqual(['new-conv', 'user-a', 'user-b']);
  });

  it('resolves via a re-fetch when it loses a concurrent-insert race (ON CONFLICT returns no row)', async () => {
    const client = {
      query: jest
        .fn()
        .mockResolvedValueOnce({ rows: [] }) // no existing row (yet)
        .mockResolvedValueOnce({ rows: [] }) // INSERT ... ON CONFLICT DO NOTHING -> no row (lost the race)
        .mockResolvedValueOnce({ rows: [{ id: 'winner-conv' }] }) // re-fetch finds the winner's row
        .mockResolvedValueOnce({ rows: [] }), // participants insert (idempotent ON CONFLICT DO NOTHING)
    };
    mockWithTransaction.mockImplementation(async (work: (c: typeof client) => unknown) => work(client));

    const id = await findOrCreateDirectConversation('user-a', 'user-b');

    expect(id).toBe('winner-conv');
  });
});

describe('requireParticipant', () => {
  it('resolves silently when the user is a participant', async () => {
    mockPoolQuery.mockResolvedValueOnce({ rows: [{}] });
    await expect(requireParticipant('conv-1', 'user-1')).resolves.toBeUndefined();
  });

  it('throws 404 (never 403 — ownership-scoping convention) when the user is not a participant', async () => {
    mockPoolQuery.mockResolvedValueOnce({ rows: [] });
    await expect(requireParticipant('conv-1', 'attacker')).rejects.toMatchObject({ status: 404 });
  });
});

describe('getOtherParticipantIds', () => {
  it('excludes the given user id from the result', async () => {
    mockPoolQuery.mockResolvedValueOnce({ rows: [{ user_id: 'user-2' }] });
    const ids = await getOtherParticipantIds('conv-1', 'user-1');
    expect(ids).toEqual(['user-2']);
    expect(mockPoolQuery.mock.calls[0][1]).toEqual(['conv-1', 'user-1']);
  });
});

describe('listConversationsForUser', () => {
  it('maps rows into the ConversationSummary shape', async () => {
    mockPoolQuery.mockResolvedValueOnce({
      rows: [
        {
          id: 'conv-1',
          type: 'direct',
          other_user_id: 'user-2',
          other_display_name: 'Friend',
          last_message_id: 'msg-1',
          last_message_type: 'text',
          last_message_body: 'hi',
          last_message_sender_id: 'user-2',
          last_message_created_at: new Date('2026-01-01T00:00:00Z'),
          unread_count: '3',
          updated_at: new Date('2026-01-01T00:00:00Z'),
        },
      ],
    });

    const result = await listConversationsForUser('user-1');

    expect(result).toEqual([
      {
        id: 'conv-1',
        type: 'direct',
        otherParticipant: { id: 'user-2', displayName: 'Friend' },
        lastMessage: {
          id: 'msg-1',
          messageType: 'text',
          body: 'hi',
          senderUserId: 'user-2',
          createdAt: '2026-01-01T00:00:00.000Z',
        },
        unreadCount: 3,
        updatedAt: '2026-01-01T00:00:00.000Z',
      },
    ]);
  });

  it('handles a conversation with no messages yet (nulls throughout)', async () => {
    mockPoolQuery.mockResolvedValueOnce({
      rows: [
        {
          id: 'conv-1',
          type: 'direct',
          other_user_id: 'user-2',
          other_display_name: null,
          last_message_id: null,
          last_message_type: null,
          last_message_body: null,
          last_message_sender_id: null,
          last_message_created_at: null,
          unread_count: '0',
          updated_at: new Date('2026-01-01T00:00:00Z'),
        },
      ],
    });

    const result = await listConversationsForUser('user-1');

    expect(result[0]!.lastMessage).toBeNull();
    expect(result[0]!.unreadCount).toBe(0);
  });

  it('scopes the query to the given user id', async () => {
    mockPoolQuery.mockResolvedValueOnce({ rows: [] });
    await listConversationsForUser('user-1');
    expect(mockPoolQuery.mock.calls[0][1]).toEqual(['user-1']);
  });
});

import request from 'supertest';

jest.mock('../src/services/sessionService', () => ({
  verifyAccessToken: jest.fn(),
}));
jest.mock('../src/services/userService', () => ({
  getUserById: jest.fn(),
  findOrCreateUserByGoogleSubject: jest.fn(),
  touchLastLogin: jest.fn(),
}));
jest.mock('../src/services/conversationService', () => ({
  findOrCreateDirectConversation: jest.fn(),
  listConversationsForUser: jest.fn(),
  requireParticipant: jest.fn(),
}));
jest.mock('../src/services/messageService', () => ({
  sendMessage: jest.fn(),
  listMessages: jest.fn(),
  updateMessageStatus: jest.fn(),
  markConversationRead: jest.fn(),
}));

import { createApp } from '../src/app';
import { verifyAccessToken } from '../src/services/sessionService';
import { getUserById } from '../src/services/userService';
import {
  findOrCreateDirectConversation,
  listConversationsForUser,
  requireParticipant,
} from '../src/services/conversationService';
import { listMessages, markConversationRead, sendMessage, updateMessageStatus } from '../src/services/messageService';
import type { AuthenticatedUser } from '../src/models/User';

const app = createApp();

const USER_ID = '11111111-1111-1111-1111-111111111111';
const OTHER_USER_ID = '22222222-2222-2222-2222-222222222222';
const CONVERSATION_ID = '33333333-3333-3333-3333-333333333333';
const MESSAGE_ID = '44444444-4444-4444-4444-444444444444';

const authedUser: AuthenticatedUser = {
  id: USER_ID,
  googleSubject: 'g-1',
  email: 'user@example.com',
  emailVerified: true,
  phoneNumber: null,
  phoneVerified: false,
  displayName: 'User',
  accountStatus: 'active',
};

let nextTestUserSuffix = 1;
function freshAuthedUser(): AuthenticatedUser {
  const suffix = String(nextTestUserSuffix++).padStart(12, '0');
  return { ...authedUser, id: `88888888-8888-8888-8888-${suffix}` };
}

function authenticateAs(user: AuthenticatedUser) {
  (verifyAccessToken as jest.Mock).mockReturnValue(user.id);
  (getUserById as jest.Mock).mockResolvedValue(user);
}

beforeEach(() => {
  jest.clearAllMocks();
});

describe('POST /api/v1/conversations', () => {
  it('denies an unauthenticated request', async () => {
    const res = await request(app).post('/api/v1/conversations').send({ participantUserId: OTHER_USER_ID });
    expect(res.status).toBe(401);
    expect(findOrCreateDirectConversation).not.toHaveBeenCalled();
  });

  it('rejects a non-UUID participantUserId', async () => {
    authenticateAs(freshAuthedUser());
    const res = await request(app)
      .post('/api/v1/conversations')
      .set('Authorization', 'Bearer t')
      .send({ participantUserId: 'not-a-uuid' });
    expect(res.status).toBe(400);
    expect(findOrCreateDirectConversation).not.toHaveBeenCalled();
  });

  it('derives the caller identity from the session, never a client-supplied field', async () => {
    const user = freshAuthedUser();
    authenticateAs(user);
    (findOrCreateDirectConversation as jest.Mock).mockResolvedValue(CONVERSATION_ID);

    await request(app)
      .post('/api/v1/conversations')
      .set('Authorization', 'Bearer t')
      .send({ participantUserId: OTHER_USER_ID });

    expect((findOrCreateDirectConversation as jest.Mock).mock.calls[0]).toEqual([user.id, OTHER_USER_ID]);
  });

  it('returns 201 with the conversation id', async () => {
    authenticateAs(freshAuthedUser());
    (findOrCreateDirectConversation as jest.Mock).mockResolvedValue(CONVERSATION_ID);

    const res = await request(app)
      .post('/api/v1/conversations')
      .set('Authorization', 'Bearer t')
      .send({ participantUserId: OTHER_USER_ID });

    expect(res.status).toBe(201);
    expect(res.body.conversationId).toBe(CONVERSATION_ID);
  });
});

// conversationRateLimiter's underlying mechanism (express-rate-limit
// wired correctly, 429 on exceeding max) is already proven end-to-end by
// sosRoutes.test.ts's equivalent test for sosRateLimiter — not repeated
// here to avoid also exhausting this file's single shared `app` instance's
// IP-keyed defaultRateLimiter budget (100/window, mounted ahead of every
// route in app.ts) alongside the messageRateLimiter storm test below.

describe('GET /api/v1/conversations', () => {
  it('denies an unauthenticated request', async () => {
    const res = await request(app).get('/api/v1/conversations');
    expect(res.status).toBe(401);
  });

  it('returns the authenticated user\'s own conversations only', async () => {
    const user = freshAuthedUser();
    authenticateAs(user);
    (listConversationsForUser as jest.Mock).mockResolvedValue([]);

    const res = await request(app).get('/api/v1/conversations').set('Authorization', 'Bearer t');

    expect(res.status).toBe(200);
    expect((listConversationsForUser as jest.Mock).mock.calls[0][0]).toBe(user.id);
  });
});

describe('GET /api/v1/conversations/:id', () => {
  it('denies an unauthenticated request', async () => {
    const res = await request(app).get(`/api/v1/conversations/${CONVERSATION_ID}`);
    expect(res.status).toBe(401);
  });

  it('404s (via the service\'s own IDOR check) when the caller is not a participant', async () => {
    authenticateAs(freshAuthedUser());
    const { HttpError } = jest.requireActual('../src/utils/httpError');
    (requireParticipant as jest.Mock).mockRejectedValue(HttpError.notFound('Conversation not found'));

    const res = await request(app)
      .get(`/api/v1/conversations/${CONVERSATION_ID}`)
      .set('Authorization', 'Bearer t');

    expect(res.status).toBe(404);
  });
});

describe('GET /api/v1/conversations/:id/messages', () => {
  it('denies an unauthenticated request', async () => {
    const res = await request(app).get(`/api/v1/conversations/${CONVERSATION_ID}/messages`);
    expect(res.status).toBe(401);
  });

  it('rejects an out-of-range limit', async () => {
    authenticateAs(freshAuthedUser());
    const res = await request(app)
      .get(`/api/v1/conversations/${CONVERSATION_ID}/messages?limit=500`)
      .set('Authorization', 'Bearer t');
    expect(res.status).toBe(400);
    expect(listMessages).not.toHaveBeenCalled();
  });

  it('passes the parsed query through to the service, scoped to the caller', async () => {
    const user = freshAuthedUser();
    authenticateAs(user);
    (listMessages as jest.Mock).mockResolvedValue([]);

    await request(app)
      .get(`/api/v1/conversations/${CONVERSATION_ID}/messages?limit=10`)
      .set('Authorization', 'Bearer t');

    expect((listMessages as jest.Mock).mock.calls[0][0]).toBe(CONVERSATION_ID);
    expect((listMessages as jest.Mock).mock.calls[0][1]).toBe(user.id);
    expect((listMessages as jest.Mock).mock.calls[0][2]).toMatchObject({ limit: 10 });
  });

  it('404s when the caller is not a participant (IDOR protection surfaced from the service)', async () => {
    authenticateAs(freshAuthedUser());
    const { HttpError } = jest.requireActual('../src/utils/httpError');
    (listMessages as jest.Mock).mockRejectedValue(HttpError.notFound('Conversation not found'));

    const res = await request(app)
      .get(`/api/v1/conversations/${CONVERSATION_ID}/messages`)
      .set('Authorization', 'Bearer t');

    expect(res.status).toBe(404);
  });
});

describe('POST /api/v1/conversations/:id/messages', () => {
  const TEXT_BODY = {
    messageType: 'text',
    body: 'hello',
    clientMessageId: MESSAGE_ID,
    clientCreatedAt: '2026-01-01T00:00:00.000Z',
  };

  it('denies an unauthenticated request', async () => {
    const res = await request(app).post(`/api/v1/conversations/${CONVERSATION_ID}/messages`).send(TEXT_BODY);
    expect(res.status).toBe(401);
    expect(sendMessage).not.toHaveBeenCalled();
  });

  it('rejects a text message with an empty body', async () => {
    authenticateAs(freshAuthedUser());
    const res = await request(app)
      .post(`/api/v1/conversations/${CONVERSATION_ID}/messages`)
      .set('Authorization', 'Bearer t')
      .send({ ...TEXT_BODY, body: '' });
    expect(res.status).toBe(400);
    expect(sendMessage).not.toHaveBeenCalled();
  });

  it('rejects a text message over the 4000-char limit', async () => {
    authenticateAs(freshAuthedUser());
    const res = await request(app)
      .post(`/api/v1/conversations/${CONVERSATION_ID}/messages`)
      .set('Authorization', 'Bearer t')
      .send({ ...TEXT_BODY, body: 'x'.repeat(4001) });
    expect(res.status).toBe(400);
    expect(sendMessage).not.toHaveBeenCalled();
  });

  it('rejects a location message missing coordinates', async () => {
    authenticateAs(freshAuthedUser());
    const res = await request(app)
      .post(`/api/v1/conversations/${CONVERSATION_ID}/messages`)
      .set('Authorization', 'Bearer t')
      .send({ messageType: 'location', clientMessageId: MESSAGE_ID, clientCreatedAt: '2026-01-01T00:00:00.000Z' });
    expect(res.status).toBe(400);
    expect(sendMessage).not.toHaveBeenCalled();
  });

  it('ignores stray coordinates on a text message rather than persisting them (matches sosSchemas.ts\'s "ignore extra client fields" convention)', async () => {
    authenticateAs(freshAuthedUser());
    (sendMessage as jest.Mock).mockResolvedValue({ id: 'm-1' });

    await request(app)
      .post(`/api/v1/conversations/${CONVERSATION_ID}/messages`)
      .set('Authorization', 'Bearer t')
      .send({ ...TEXT_BODY, latitude: 1, longitude: 1 });

    expect((sendMessage as jest.Mock).mock.calls[0][2]).not.toHaveProperty('latitude');
    expect((sendMessage as jest.Mock).mock.calls[0][2]).not.toHaveProperty('longitude');
  });

  it('derives sender identity from the session, ignoring any client-supplied senderId', async () => {
    const user = freshAuthedUser();
    authenticateAs(user);
    (sendMessage as jest.Mock).mockResolvedValue({ id: 'm-1' });

    await request(app)
      .post(`/api/v1/conversations/${CONVERSATION_ID}/messages`)
      .set('Authorization', 'Bearer t')
      .send({ ...TEXT_BODY, senderId: 'attacker-controlled-id' });

    expect((sendMessage as jest.Mock).mock.calls[0][0]).toBe(CONVERSATION_ID);
    expect((sendMessage as jest.Mock).mock.calls[0][1]).toBe(user.id);
    expect((sendMessage as jest.Mock).mock.calls[0][2]).not.toHaveProperty('senderId');
  });

  it('sends a valid text message and returns 201', async () => {
    authenticateAs(freshAuthedUser());
    (sendMessage as jest.Mock).mockResolvedValue({ id: 'm-1', body: 'hello' });

    const res = await request(app)
      .post(`/api/v1/conversations/${CONVERSATION_ID}/messages`)
      .set('Authorization', 'Bearer t')
      .send(TEXT_BODY);

    expect(res.status).toBe(201);
    expect(res.body.message.id).toBe('m-1');
  });

  it('sends a valid location message', async () => {
    authenticateAs(freshAuthedUser());
    (sendMessage as jest.Mock).mockResolvedValue({ id: 'm-2', messageType: 'location' });

    const res = await request(app)
      .post(`/api/v1/conversations/${CONVERSATION_ID}/messages`)
      .set('Authorization', 'Bearer t')
      .send({
        messageType: 'location',
        latitude: 27.7,
        longitude: 85.3,
        clientMessageId: MESSAGE_ID,
        clientCreatedAt: '2026-01-01T00:00:00.000Z',
      });

    expect(res.status).toBe(201);
    expect((sendMessage as jest.Mock).mock.calls[0][2]).toMatchObject({ messageType: 'location', latitude: 27.7 });
  });

  it('404s when the caller is not a participant', async () => {
    authenticateAs(freshAuthedUser());
    const { HttpError } = jest.requireActual('../src/utils/httpError');
    (sendMessage as jest.Mock).mockRejectedValue(HttpError.notFound('Conversation not found'));

    const res = await request(app)
      .post(`/api/v1/conversations/${CONVERSATION_ID}/messages`)
      .set('Authorization', 'Bearer t')
      .send(TEXT_BODY);

    expect(res.status).toBe(404);
  });

  it('rate-limits repeated message sends from the same user', async () => {
    const user: AuthenticatedUser = { ...authedUser, id: '66666666-6666-6666-6666-666666666666' };
    authenticateAs(user);
    (sendMessage as jest.Mock).mockResolvedValue({ id: 'm-1' });

    // MESSAGE_RATE_LIMIT_MAX defaults to 60/window.
    let lastStatus = 0;
    for (let i = 0; i < 61; i++) {
      const res = await request(app)
        .post(`/api/v1/conversations/${CONVERSATION_ID}/messages`)
        .set('Authorization', 'Bearer t')
        .send({ ...TEXT_BODY, clientMessageId: `66666666-6666-6666-6666-66666666${String(i).padStart(4, '0')}` });
      lastStatus = res.status;
    }
    expect(lastStatus).toBe(429);
  });
});

describe('POST /api/v1/conversations/:id/messages/:messageId/status', () => {
  it('denies an unauthenticated request', async () => {
    const res = await request(app)
      .post(`/api/v1/conversations/${CONVERSATION_ID}/messages/${MESSAGE_ID}/status`)
      .send({ status: 'delivered' });
    expect(res.status).toBe(401);
  });

  it('rejects an invalid status value', async () => {
    authenticateAs(freshAuthedUser());
    const res = await request(app)
      .post(`/api/v1/conversations/${CONVERSATION_ID}/messages/${MESSAGE_ID}/status`)
      .set('Authorization', 'Bearer t')
      .send({ status: 'sent' }); // 'sent' is the server-assigned initial state, not a client-chosen transition
    expect(res.status).toBe(400);
    expect(updateMessageStatus).not.toHaveBeenCalled();
  });

  it('updates status for a valid request, scoped to the caller as the recipient', async () => {
    const user = freshAuthedUser();
    authenticateAs(user);
    (updateMessageStatus as jest.Mock).mockResolvedValue(undefined);

    const res = await request(app)
      .post(`/api/v1/conversations/${CONVERSATION_ID}/messages/${MESSAGE_ID}/status`)
      .set('Authorization', 'Bearer t')
      .send({ status: 'read' });

    expect(res.status).toBe(204);
    expect((updateMessageStatus as jest.Mock).mock.calls[0]).toEqual([CONVERSATION_ID, user.id, MESSAGE_ID, 'read']);
  });

  it('404s when the caller is not the message\'s recipient (IDOR protection)', async () => {
    authenticateAs(freshAuthedUser());
    const { HttpError } = jest.requireActual('../src/utils/httpError');
    (updateMessageStatus as jest.Mock).mockRejectedValue(HttpError.notFound('Message not found'));

    const res = await request(app)
      .post(`/api/v1/conversations/${CONVERSATION_ID}/messages/${MESSAGE_ID}/status`)
      .set('Authorization', 'Bearer t')
      .send({ status: 'delivered' });

    expect(res.status).toBe(404);
  });
});

describe('POST /api/v1/conversations/:id/read', () => {
  it('denies an unauthenticated request', async () => {
    const res = await request(app)
      .post(`/api/v1/conversations/${CONVERSATION_ID}/read`)
      .send({ upToMessageId: MESSAGE_ID });
    expect(res.status).toBe(401);
  });

  it('rejects a non-UUID upToMessageId', async () => {
    authenticateAs(freshAuthedUser());
    const res = await request(app)
      .post(`/api/v1/conversations/${CONVERSATION_ID}/read`)
      .set('Authorization', 'Bearer t')
      .send({ upToMessageId: 'not-a-uuid' });
    expect(res.status).toBe(400);
    expect(markConversationRead).not.toHaveBeenCalled();
  });

  it('marks read for a valid request', async () => {
    const user = freshAuthedUser();
    authenticateAs(user);
    (markConversationRead as jest.Mock).mockResolvedValue(undefined);

    const res = await request(app)
      .post(`/api/v1/conversations/${CONVERSATION_ID}/read`)
      .set('Authorization', 'Bearer t')
      .send({ upToMessageId: MESSAGE_ID });

    expect(res.status).toBe(204);
    expect((markConversationRead as jest.Mock).mock.calls[0]).toEqual([CONVERSATION_ID, user.id, MESSAGE_ID]);
  });
});

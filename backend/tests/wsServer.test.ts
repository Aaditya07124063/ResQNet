import { createServer, type Server } from 'node:http';
import type { AddressInfo } from 'node:net';
import WebSocket from 'ws';

jest.mock('../src/services/sessionService', () => ({
  verifyAccessToken: jest.fn(),
}));
jest.mock('../src/services/userService', () => ({
  getUserById: jest.fn(),
}));

import { attachWebSocketServer, broadcastToUser, resetUpgradeRateLimiterForTests } from '../src/websocket/wsServer';
import { verifyAccessToken } from '../src/services/sessionService';
import { getUserById } from '../src/services/userService';
import type { AuthenticatedUser } from '../src/models/User';

const mockVerifyAccessToken = verifyAccessToken as jest.Mock;
const mockGetUserById = getUserById as jest.Mock;

function userFixture(id: string): AuthenticatedUser {
  return {
    id,
    googleSubject: `g-${id}`,
    email: `${id}@example.com`,
    emailVerified: true,
    phoneNumber: null,
    phoneVerified: false,
    displayName: id,
    accountStatus: 'active',
  };
}

/** Authenticates every upgrade as `user`, regardless of the token supplied
 * (individual tests that need to test rejection override this). */
function authenticateEveryUpgradeAs(user: AuthenticatedUser) {
  mockVerifyAccessToken.mockReturnValue(user.id);
  mockGetUserById.mockResolvedValue(user);
}

let httpServer: Server;
let wsUrl: string;
const openSockets: WebSocket[] = [];

beforeEach(async () => {
  // Every test in this file connects from the same loopback address, so
  // the in-memory upgrade rate limiter (keyed by address) would otherwise
  // accumulate across tests and eventually start rejecting unrelated
  // later tests' connections — reset before each test, not just the one
  // that specifically exercises the limit.
  resetUpgradeRateLimiterForTests();
  httpServer = createServer();
  attachWebSocketServer(httpServer);
  await new Promise<void>((resolve) => httpServer.listen(0, '127.0.0.1', resolve));
  const { port } = httpServer.address() as AddressInfo;
  wsUrl = `ws://127.0.0.1:${port}/ws`;
});

afterEach(async () => {
  for (const ws of openSockets.splice(0)) {
    ws.terminate();
  }
  await new Promise<void>((resolve) => httpServer.close(() => resolve()));
});

function connect(opts: { headers?: Record<string, string>; query?: string } = {}): WebSocket {
  const url = opts.query ? `${wsUrl}?${opts.query}` : wsUrl;
  const ws = new WebSocket(url, { headers: opts.headers });
  // A rejected/never-established connection still emits 'error' once
  // torn down in afterEach — an unhandled 'error' event crashes the
  // process, and every test in this file that exercises rejection
  // legitimately produces exactly this. Swallowed here, not per-test.
  ws.on('error', () => {});
  openSockets.push(ws);
  return ws;
}

function waitFor(ws: WebSocket, event: 'open' | 'close' | 'unexpected-response'): Promise<unknown> {
  return new Promise((resolve) => ws.once(event, resolve));
}

describe('WebSocket authentication', () => {
  it('accepts a connection with a valid Bearer token', async () => {
    authenticateEveryUpgradeAs(userFixture('user-1'));
    const ws = connect({ headers: { Authorization: 'Bearer good-token' } });
    await waitFor(ws, 'open');
    expect(ws.readyState).toBe(WebSocket.OPEN);
  });

  it('accepts a connection authenticated via the access_token query param fallback', async () => {
    authenticateEveryUpgradeAs(userFixture('user-1'));
    const ws = connect({ query: 'access_token=good-token' });
    await waitFor(ws, 'open');
    expect(ws.readyState).toBe(WebSocket.OPEN);
  });

  it('rejects a connection with no token at all', async () => {
    const ws = connect();
    await waitFor(ws, 'unexpected-response');
    expect(ws.readyState).not.toBe(WebSocket.OPEN);
  });

  it('rejects a connection with an invalid/expired token', async () => {
    mockVerifyAccessToken.mockImplementation(() => {
      throw Object.assign(new Error('jwt expired'), { status: 401 });
    });
    const ws = connect({ headers: { Authorization: 'Bearer expired-token' } });
    await waitFor(ws, 'unexpected-response');
    expect(ws.readyState).not.toBe(WebSocket.OPEN);
  });

  it('rejects a connection for a suspended account', async () => {
    mockVerifyAccessToken.mockReturnValue('user-1');
    mockGetUserById.mockResolvedValue({ ...userFixture('user-1'), accountStatus: 'suspended' });
    const ws = connect({ headers: { Authorization: 'Bearer good-token' } });
    await waitFor(ws, 'unexpected-response');
    expect(ws.readyState).not.toBe(WebSocket.OPEN);
  });

  it('destroys the raw socket for an upgrade to any path other than WS_PATH', async () => {
    authenticateEveryUpgradeAs(userFixture('user-1'));
    const ws = new WebSocket(wsUrl.replace('/ws', '/not-ws'));
    openSockets.push(ws);
    const result = await new Promise<'open' | 'error'>((resolve) => {
      ws.once('open', () => resolve('open'));
      ws.once('error', () => resolve('error'));
    });
    expect(result).toBe('error');
  });
});

describe('broadcastToUser', () => {
  it('delivers a payload only to sockets authenticated as that exact user, never to another user\'s socket', async () => {
    authenticateEveryUpgradeAs(userFixture('user-a'));
    const wsA = connect({ headers: { Authorization: 'Bearer token-a' } });
    await waitFor(wsA, 'open');

    authenticateEveryUpgradeAs(userFixture('user-b'));
    const wsB = connect({ headers: { Authorization: 'Bearer token-b' } });
    await waitFor(wsB, 'open');

    const messagesToA: string[] = [];
    const messagesToB: string[] = [];
    wsA.on('message', (data) => messagesToA.push(data.toString()));
    wsB.on('message', (data) => messagesToB.push(data.toString()));

    broadcastToUser('user-a', { type: 'sos_created', event: { id: 'event-1' } });
    await new Promise((resolve) => setTimeout(resolve, 50));

    expect(messagesToA).toHaveLength(1);
    expect(JSON.parse(messagesToA[0]!)).toMatchObject({ type: 'sos_created' });
    expect(messagesToB).toHaveLength(0); // never leaked to the other user
  });

  it('delivers to ALL of a user\'s connected devices (multi-device)', async () => {
    authenticateEveryUpgradeAs(userFixture('user-a'));
    const device1 = connect({ headers: { Authorization: 'Bearer token-a' } });
    const device2 = connect({ headers: { Authorization: 'Bearer token-a' } });
    await Promise.all([waitFor(device1, 'open'), waitFor(device2, 'open')]);

    const received: string[] = [];
    device1.on('message', (d) => received.push(d.toString()));
    device2.on('message', (d) => received.push(d.toString()));

    broadcastToUser('user-a', { type: 'sos_status_updated', event: { id: 'event-1' } });
    await new Promise((resolve) => setTimeout(resolve, 50));

    expect(received).toHaveLength(2);
  });

  it('is a no-op (does not throw) when the user has no connected sockets', () => {
    expect(() => broadcastToUser('nobody-connected', { type: 'sos_created', event: {} })).not.toThrow();
  });

  it('stops delivering to a device after it disconnects, but keeps delivering to the user\'s other devices', async () => {
    authenticateEveryUpgradeAs(userFixture('user-a'));
    const device1 = connect({ headers: { Authorization: 'Bearer token-a' } });
    const device2 = connect({ headers: { Authorization: 'Bearer token-a' } });
    await Promise.all([waitFor(device1, 'open'), waitFor(device2, 'open')]);

    device1.close();
    await waitFor(device1, 'close');
    await new Promise((resolve) => setTimeout(resolve, 20)); // let the server's own 'close' handler run

    const received: string[] = [];
    device2.on('message', (d) => received.push(d.toString()));

    broadcastToUser('user-a', { type: 'sos_created', event: { id: 'event-1' } });
    await new Promise((resolve) => setTimeout(resolve, 50));

    expect(received).toHaveLength(1);
  });
});

describe('payload size limit (Phase 19 security audit)', () => {
  it('terminates a connection that sends a message larger than the configured maxPayload', async () => {
    authenticateEveryUpgradeAs(userFixture('user-1'));
    const ws = connect({ headers: { Authorization: 'Bearer good-token' } });
    await waitFor(ws, 'open');

    const oversized = 'x'.repeat(20 * 1024); // > the 16KB maxPayload
    const closed = new Promise<void>((resolve) => ws.once('close', () => resolve()));
    ws.send(oversized);

    await closed;
    expect(ws.readyState).not.toBe(WebSocket.OPEN);
  });
});

describe('upgrade rate limiting (Phase 19 security audit)', () => {
  it('rejects further upgrade attempts from the same address after the configured budget', async () => {
    authenticateEveryUpgradeAs(userFixture('user-1'));

    let lastResult: 'open' | 'unexpected-response' = 'open';
    // UPGRADE_RATE_LIMIT_MAX defaults to 30/window; the 31st attempt from
    // the same address in the same window must be rejected.
    for (let i = 0; i < 31; i++) {
      const ws = connect({ headers: { Authorization: 'Bearer good-token' } });
      lastResult = await new Promise((resolve) => {
        ws.once('open', () => resolve('open'));
        ws.once('unexpected-response', () => resolve('unexpected-response'));
      });
    }

    expect(lastResult).toBe('unexpected-response');
  }, 10_000);
});

describe('malformed inbound messages', () => {
  it('does not crash the connection when the client sends non-JSON data', async () => {
    authenticateEveryUpgradeAs(userFixture('user-1'));
    const ws = connect({ headers: { Authorization: 'Bearer good-token' } });
    await waitFor(ws, 'open');

    ws.send('this is not json {{{');
    await new Promise((resolve) => setTimeout(resolve, 30));

    expect(ws.readyState).toBe(WebSocket.OPEN); // still alive, not dropped
  });

  it('does not crash the connection when the client sends an unrecognized JSON message shape', async () => {
    authenticateEveryUpgradeAs(userFixture('user-1'));
    const ws = connect({ headers: { Authorization: 'Bearer good-token' } });
    await waitFor(ws, 'open');

    ws.send(JSON.stringify({ type: 'subscribe_someone_elses_data', targetUserId: 'someone-else' }));
    await new Promise((resolve) => setTimeout(resolve, 30));

    expect(ws.readyState).toBe(WebSocket.OPEN); // ignored, not acted on — no inbound protocol is defined
  });
});

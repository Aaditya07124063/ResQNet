const mockInitializeApp = jest.fn();
const mockCert = jest.fn((sa: unknown) => sa);
const mockGetMessaging = jest.fn();

jest.mock('firebase-admin/app', () => ({
  initializeApp: mockInitializeApp,
  cert: mockCert,
}));
jest.mock('firebase-admin/messaging', () => ({
  getMessaging: mockGetMessaging,
}));

const ORIGINAL_ENV_VALUE = process.env.FIREBASE_SERVICE_ACCOUNT_JSON;

async function freshImport() {
  jest.resetModules();
  return import('../src/services/fcm');
}

afterEach(() => {
  process.env.FIREBASE_SERVICE_ACCOUNT_JSON = ORIGINAL_ENV_VALUE;
  jest.clearAllMocks();
});

describe('sendMulticast — no configuration', () => {
  it('returns [] immediately for an empty token list, without touching firebase-admin at all', async () => {
    delete process.env.FIREBASE_SERVICE_ACCOUNT_JSON;
    const { sendMulticast } = await freshImport();
    const result = await sendMulticast([], { title: 't', body: 'b' });
    expect(result).toEqual([]);
    expect(mockInitializeApp).not.toHaveBeenCalled();
  });

  it('reports every token as a non-removable failure when FIREBASE_SERVICE_ACCOUNT_JSON is absent (never fabricates success)', async () => {
    delete process.env.FIREBASE_SERVICE_ACCOUNT_JSON;
    const { sendMulticast } = await freshImport();
    const result = await sendMulticast(['token-1', 'token-2'], { title: 't', body: 'b' });
    expect(result).toEqual([
      { token: 'token-1', success: false, shouldRemoveToken: false },
      { token: 'token-2', success: false, shouldRemoveToken: false },
    ]);
    expect(mockGetMessaging).not.toHaveBeenCalled();
  });

  it('degrades to the same safe no-op when the configured JSON is malformed, rather than throwing', async () => {
    process.env.FIREBASE_SERVICE_ACCOUNT_JSON = 'not valid json {{{';
    const { sendMulticast } = await freshImport();
    const result = await sendMulticast(['token-1'], { title: 't', body: 'b' });
    expect(result).toEqual([{ token: 'token-1', success: false, shouldRemoveToken: false }]);
  });
});

describe('sendMulticast — configured', () => {
  beforeEach(() => {
    process.env.FIREBASE_SERVICE_ACCOUNT_JSON = JSON.stringify({
      projectId: 'test-project',
      clientEmail: 'test@example.com',
      privateKey: 'fake-key-not-a-real-secret',
    });
  });

  it('initializes exactly once even across multiple sendMulticast calls', async () => {
    mockInitializeApp.mockReturnValue({ name: 'fake-app' });
    mockGetMessaging.mockReturnValue({
      sendEachForMulticast: jest.fn().mockResolvedValue({ responses: [{ success: true }] }),
    });
    const { sendMulticast } = await freshImport();
    await sendMulticast(['t1'], { title: 't', body: 'b' });
    await sendMulticast(['t2'], { title: 't', body: 'b' });
    expect(mockInitializeApp).toHaveBeenCalledTimes(1);
  });

  it('maps a successful per-token response through', async () => {
    mockInitializeApp.mockReturnValue({ name: 'fake-app' });
    mockGetMessaging.mockReturnValue({
      sendEachForMulticast: jest.fn().mockResolvedValue({ responses: [{ success: true }] }),
    });
    const { sendMulticast } = await freshImport();
    const result = await sendMulticast(['token-1'], { title: 't', body: 'b' });
    expect(result).toEqual([{ token: 'token-1', success: true, shouldRemoveToken: false }]);
  });

  it('flags an unregistered-token failure for removal, but not other failure codes', async () => {
    mockInitializeApp.mockReturnValue({ name: 'fake-app' });
    mockGetMessaging.mockReturnValue({
      sendEachForMulticast: jest.fn().mockResolvedValue({
        responses: [
          { success: false, error: { code: 'messaging/registration-token-not-registered' } },
          { success: false, error: { code: 'messaging/internal-error' } },
        ],
      }),
    });
    const { sendMulticast } = await freshImport();
    const result = await sendMulticast(['dead-token', 'transient-fail-token'], { title: 't', body: 'b' });
    expect(result).toEqual([
      { token: 'dead-token', success: false, shouldRemoveToken: true },
      { token: 'transient-fail-token', success: false, shouldRemoveToken: false },
    ]);
  });

  it('chunks more than 500 tokens into multiple calls', async () => {
    mockInitializeApp.mockReturnValue({ name: 'fake-app' });
    const sendEachForMulticast = jest
      .fn()
      .mockResolvedValueOnce({ responses: Array(500).fill({ success: true }) })
      .mockResolvedValueOnce({ responses: Array(10).fill({ success: true }) });
    mockGetMessaging.mockReturnValue({ sendEachForMulticast });
    const { sendMulticast } = await freshImport();
    const tokens = Array.from({ length: 510 }, (_, i) => `token-${i}`);
    const result = await sendMulticast(tokens, { title: 't', body: 'b' });
    expect(sendEachForMulticast).toHaveBeenCalledTimes(2);
    expect(sendEachForMulticast.mock.calls[0][0].tokens).toHaveLength(500);
    expect(sendEachForMulticast.mock.calls[1][0].tokens).toHaveLength(10);
    expect(result).toHaveLength(510);
  });

  it('a thrown provider error for one batch is reported as failure for that batch, never thrown to the caller', async () => {
    mockInitializeApp.mockReturnValue({ name: 'fake-app' });
    mockGetMessaging.mockReturnValue({
      sendEachForMulticast: jest.fn().mockRejectedValue(new Error('FCM outage')),
    });
    const { sendMulticast } = await freshImport();
    const result = await sendMulticast(['token-1', 'token-2'], { title: 't', body: 'b' });
    expect(result).toEqual([
      { token: 'token-1', success: false, shouldRemoveToken: false },
      { token: 'token-2', success: false, shouldRemoveToken: false },
    ]);
  });

  it('never puts notification content into the raw credential string (sanity: JSON.parse input is the env var, not fabricated)', async () => {
    mockInitializeApp.mockReturnValue({ name: 'fake-app' });
    mockGetMessaging.mockReturnValue({
      sendEachForMulticast: jest.fn().mockResolvedValue({ responses: [{ success: true }] }),
    });
    const { sendMulticast } = await freshImport();
    await sendMulticast(['token-1'], { title: 't', body: 'b' });
    expect(mockCert).toHaveBeenCalledWith(
      expect.objectContaining({ projectId: 'test-project', clientEmail: 'test@example.com' }),
    );
  });
});

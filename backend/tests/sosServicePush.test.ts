jest.mock('../src/database/pool', () => ({
  pool: { query: jest.fn() },
  withTransaction: jest.fn(),
}));
jest.mock('../src/websocket/wsServer', () => ({
  broadcastToUser: jest.fn(),
}));
jest.mock('../src/services/userService', () => ({
  getUserById: jest.fn(),
}));
jest.mock('../src/services/pushNotificationService', () => ({
  notifyUsersDevices: jest.fn(),
}));
jest.mock('../src/services/nearbyAlertService', () => ({
  findNearbyEligibleUsers: jest.fn(),
  approximateDistanceLabel: jest.requireActual('../src/services/nearbyAlertService').approximateDistanceLabel,
}));

import { pool, withTransaction } from '../src/database/pool';
import { broadcastToUser } from '../src/websocket/wsServer';
import { getUserById } from '../src/services/userService';
import { notifyUsersDevices } from '../src/services/pushNotificationService';
import { findNearbyEligibleUsers } from '../src/services/nearbyAlertService';
import { createSosEvent } from '../src/services/sosService';

const mockPoolQuery = pool.query as jest.Mock;
const mockWithTransaction = withTransaction as jest.Mock;
const mockBroadcastToUser = broadcastToUser as jest.Mock;
const mockGetUserById = getUserById as jest.Mock;
const mockNotifyUsersDevices = notifyUsersDevices as jest.Mock;
const mockFindNearbyEligibleUsers = findNearbyEligibleUsers as jest.Mock;

function fakeSosEventRow(overrides: Record<string, unknown> = {}) {
  return {
    id: 'event-1',
    event_id: 'client-event-1',
    user_id: 'user-1',
    event_source: 'manual',
    category: 'medical',
    message: 'need help',
    latitude: '12.345600',
    longitude: '77.654300',
    location_accuracy_m: '15.50',
    status: 'open',
    client_created_at: new Date('2026-01-01T00:00:00Z'),
    server_received_at: new Date('2026-01-01T00:00:01Z'),
    resolved_at: null,
    ...overrides,
  };
}

const INPUT = {
  eventId: 'client-event-1',
  eventSource: 'manual' as const,
  category: 'medical',
  message: 'need help',
  latitude: 12.3456,
  longitude: 77.6543,
  locationAccuracyM: 15.5,
  clientCreatedAt: new Date('2026-01-01T00:00:00Z'),
};

/** No trusted contacts, unless a test overrides it. */
function mockNoTrustedContacts() {
  mockWithTransaction.mockImplementationOnce(async (work: (client: { query: jest.Mock }) => unknown) =>
    work({ query: jest.fn().mockResolvedValue({ rows: [] }) }),
  );
}

beforeEach(() => {
  jest.clearAllMocks();
  mockGetUserById.mockResolvedValue({ id: 'user-1', displayName: 'Reporter Name' });
  mockNotifyUsersDevices.mockResolvedValue(new Map());
  // No nearby-eligible users unless a test in the nearby describe block
  // below overrides this — keeps every OTHER test in this file (trusted
  // contacts) from also having to reason about the nearby fan-out path
  // fakeSosEventRow's lat/lng would otherwise trigger.
  mockFindNearbyEligibleUsers.mockResolvedValue([]);
});

describe('createSosEvent — nearby ResQNet user push (replaces the old unscoped broadcast)', () => {
  function mockOneNearbyUser(distanceM = 800) {
    mockFindNearbyEligibleUsers.mockResolvedValueOnce([{ userId: 'nearby-user-1', distanceM }]);
    // fanOutToNearbyUsers's own INSERT ... RETURNING id for the sos_recipients row.
    mockPoolQuery.mockResolvedValueOnce({ rows: [{ id: 'nearby-recipient-1' }] });
  }

  it('does not call the old unscoped-broadcast function at all — it no longer exists on this path', async () => {
    mockPoolQuery.mockResolvedValueOnce({ rows: [fakeSosEventRow()] });
    mockNoTrustedContacts();

    await createSosEvent('user-1', INPUT);

    // findNearbyEligibleUsers IS the replacement — called once, scoped by
    // the event's own coordinates, not "every other active user".
    expect(mockFindNearbyEligibleUsers).toHaveBeenCalledTimes(1);
    expect(mockFindNearbyEligibleUsers).toHaveBeenCalledWith('user-1', 12.3456, 77.6543);
  });

  it('does not call findNearbyEligibleUsers at all when the event has no coordinates', async () => {
    mockPoolQuery.mockResolvedValueOnce({
      rows: [fakeSosEventRow({ latitude: null, longitude: null })],
    });
    mockNoTrustedContacts();

    await createSosEvent('user-1', INPUT);

    expect(mockFindNearbyEligibleUsers).not.toHaveBeenCalled();
  });

  it('sends a minimal push (category + approximate distance) to a nearby user — never the reporter\'s name, message, or exact coordinates', async () => {
    mockPoolQuery
      .mockResolvedValueOnce({ rows: [fakeSosEventRow()] })
      .mockResolvedValueOnce({ rows: [{ id: 'nearby-recipient-1' }] }) // fanOutToNearbyUsers insert
      .mockResolvedValueOnce({ rows: [] }); // sos_recipients status UPDATE
    mockNoTrustedContacts();
    mockFindNearbyEligibleUsers.mockResolvedValueOnce([{ userId: 'nearby-user-1', distanceM: 800 }]);
    mockNotifyUsersDevices.mockResolvedValueOnce(new Map([['nearby-user-1', 'sent']]));

    await createSosEvent('user-1', INPUT);

    expect(mockNotifyUsersDevices).toHaveBeenCalledTimes(1);
    expect(mockNotifyUsersDevices.mock.calls[0][0]).toEqual(['nearby-user-1']);
    const content = mockNotifyUsersDevices.mock.calls[0][1];
    expect(content.title).toBe('🚨 Emergency nearby');
    expect(content.body).toContain('medical');
    expect(content.body).toContain('Within 1 km');
    expect(content.body).not.toContain('Reporter Name');
    expect(content.body).not.toContain('need help');
    expect(content.data).toEqual({ sosEventId: 'event-1', category: 'medical' });
    expect(content.data.latitude).toBeUndefined();
    expect(content.data.longitude).toBeUndefined();
  });

  it('sends each nearby recipient THEIR OWN distance, not another recipient\'s', async () => {
    mockPoolQuery
      .mockResolvedValueOnce({ rows: [fakeSosEventRow()] })
      .mockResolvedValueOnce({ rows: [{ id: 'nearby-recipient-1' }] })
      .mockResolvedValueOnce({ rows: [{ id: 'nearby-recipient-2' }] })
      .mockResolvedValueOnce({ rows: [] })
      .mockResolvedValueOnce({ rows: [] });
    mockNoTrustedContacts();
    mockFindNearbyEligibleUsers.mockResolvedValueOnce([
      { userId: 'close-user', distanceM: 100 },
      { userId: 'far-user', distanceM: 4_500 },
    ]);
    mockNotifyUsersDevices
      .mockResolvedValueOnce(new Map([['close-user', 'sent']]))
      .mockResolvedValueOnce(new Map([['far-user', 'sent']]));

    await createSosEvent('user-1', INPUT);

    expect(mockNotifyUsersDevices).toHaveBeenCalledTimes(2);
    expect(mockNotifyUsersDevices.mock.calls[0][0]).toEqual(['close-user']);
    expect(mockNotifyUsersDevices.mock.calls[0][1].body).toContain('Very close by');
    expect(mockNotifyUsersDevices.mock.calls[1][0]).toEqual(['far-user']);
    expect(mockNotifyUsersDevices.mock.calls[1][1].body).toContain('Within 5 km');
  });

  it('broadcasts a targeted nearby_sos_created WebSocket event to the nearby recipient only, with the same minimal payload', async () => {
    mockPoolQuery
      .mockResolvedValueOnce({ rows: [fakeSosEventRow()] })
      .mockResolvedValueOnce({ rows: [{ id: 'nearby-recipient-1' }] })
      .mockResolvedValueOnce({ rows: [] });
    mockNoTrustedContacts();
    mockFindNearbyEligibleUsers.mockResolvedValueOnce([{ userId: 'nearby-user-1', distanceM: 800 }]);
    mockNotifyUsersDevices.mockResolvedValueOnce(new Map([['nearby-user-1', 'sent']]));

    await createSosEvent('user-1', INPUT);

    // Once for the reporter's own sos_created self-delivery, once for the
    // nearby recipient's nearby_sos_created — never a third, blind call.
    expect(mockBroadcastToUser).toHaveBeenCalledTimes(2);
    const nearbyCall = mockBroadcastToUser.mock.calls.find((c) => c[0] === 'nearby-user-1');
    expect(nearbyCall![1]).toMatchObject({
      type: 'nearby_sos_created',
      sosEventId: 'event-1',
      category: 'medical',
      approximateDistance: 'Within 1 km',
    });
    expect(nearbyCall![1]).not.toHaveProperty('latitude');
    expect(nearbyCall![1]).not.toHaveProperty('longitude');
  });

  it('does not call notifyUsersDevices at all when no one is nearby', async () => {
    mockPoolQuery.mockResolvedValueOnce({ rows: [fakeSosEventRow()] });
    mockNoTrustedContacts();

    await createSosEvent('user-1', INPUT);

    expect(mockNotifyUsersDevices).not.toHaveBeenCalled();
  });

  it('still returns the created event even if nearby discovery itself throws', async () => {
    mockPoolQuery.mockResolvedValueOnce({ rows: [fakeSosEventRow()] });
    mockNoTrustedContacts();
    mockFindNearbyEligibleUsers.mockRejectedValueOnce(new Error('DB outage'));

    const result = await createSosEvent('user-1', INPUT);

    expect(result.id).toBe('event-1');
  });

  it('still returns the created event even if the nearby push step throws', async () => {
    mockPoolQuery.mockResolvedValueOnce({ rows: [fakeSosEventRow()] });
    mockNoTrustedContacts();
    mockOneNearbyUser(); // queues its own sos_recipients insert result
    mockNotifyUsersDevices.mockRejectedValueOnce(new Error('FCM outage'));

    const result = await createSosEvent('user-1', INPUT);

    expect(result.id).toBe('event-1');
  });

  it('does not fan out to nearby users at all on an idempotent retry (nothing changed, no spurious notification)', async () => {
    mockPoolQuery
      .mockRejectedValueOnce(Object.assign(new Error('duplicate'), { code: '23505' }))
      .mockResolvedValueOnce({ rows: [fakeSosEventRow()] });

    await createSosEvent('user-1', INPUT);

    expect(mockFindNearbyEligibleUsers).not.toHaveBeenCalled();
  });
});

describe('createSosEvent — targeted push to trusted contacts who are ResQNet users', () => {
  function mockOneTrustedContactWhoIsAUser() {
    const clientQuery = jest
      .fn()
      .mockResolvedValueOnce({ rows: [{ contact_user_id: 'contact-user-1', phone_number: '+10000000001' }] })
      .mockResolvedValueOnce({ rows: [] }) // SMS insert
      .mockResolvedValueOnce({ rows: [{ id: 'push-recipient-1' }] }); // push insert, RETURNING id
    mockWithTransaction.mockImplementationOnce(async (work: (client: { query: jest.Mock }) => unknown) =>
      work({ query: clientQuery }),
    );
  }

  it('does not call notifyUsersDevices at all when no trusted contact is a ResQNet user', async () => {
    mockPoolQuery.mockResolvedValueOnce({ rows: [fakeSosEventRow()] });
    mockNoTrustedContacts();

    await createSosEvent('user-1', INPUT);

    expect(mockNotifyUsersDevices).not.toHaveBeenCalled();
  });

  it('pushes to trusted-contact users only (never the general broadcast content), and updates their sos_recipients row to "sent"', async () => {
    mockPoolQuery.mockResolvedValueOnce({ rows: [fakeSosEventRow()] }).mockResolvedValueOnce({ rows: [] }); // the sos_recipients UPDATE below
    mockOneTrustedContactWhoIsAUser();
    mockNotifyUsersDevices.mockResolvedValueOnce(new Map([['contact-user-1', 'sent']]));

    await createSosEvent('user-1', INPUT);

    expect(mockNotifyUsersDevices.mock.calls[0][0]).toEqual(['contact-user-1']);
    const targetedContent = mockNotifyUsersDevices.mock.calls[0][1];
    expect(targetedContent.title).toContain('needs you');
    // The last pool.query call is the sos_recipients status UPDATE.
    const lastCall = mockPoolQuery.mock.calls[mockPoolQuery.mock.calls.length - 1];
    expect(lastCall[0]).toMatch(/UPDATE sos_recipients\s+SET status/);
    expect(lastCall[1]).toEqual(['sent', 'sent', 'push-recipient-1']);
  });

  it('updates the row to "failed" when the outcome is failed', async () => {
    mockPoolQuery.mockResolvedValueOnce({ rows: [fakeSosEventRow()] }).mockResolvedValueOnce({ rows: [] });
    mockOneTrustedContactWhoIsAUser();
    mockNotifyUsersDevices.mockResolvedValueOnce(new Map([['contact-user-1', 'failed']]));

    await createSosEvent('user-1', INPUT);

    const lastCall = mockPoolQuery.mock.calls[mockPoolQuery.mock.calls.length - 1];
    expect(lastCall[1]).toEqual(['failed', 'failed', 'push-recipient-1']);
  });

  it('leaves the row untouched (still "pending") when the contact has no registered device — no UPDATE call at all', async () => {
    mockPoolQuery.mockResolvedValueOnce({ rows: [fakeSosEventRow()] });
    mockOneTrustedContactWhoIsAUser();
    mockNotifyUsersDevices.mockResolvedValueOnce(new Map([['contact-user-1', 'no_device']]));

    await createSosEvent('user-1', INPUT);

    expect(mockPoolQuery.mock.calls.some((c) => /UPDATE sos_recipients/.test(c[0]))).toBe(false);
  });

  it('still returns the created event even if the targeted push step throws', async () => {
    mockPoolQuery.mockResolvedValueOnce({ rows: [fakeSosEventRow()] });
    mockOneTrustedContactWhoIsAUser();
    mockNotifyUsersDevices.mockRejectedValueOnce(new Error('FCM outage'));

    const result = await createSosEvent('user-1', INPUT);

    expect(result.id).toBe('event-1');
  });
});

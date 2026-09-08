import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:resqnet/core/models/emergency_outbox_entry.dart';
import 'package:resqnet/core/services/emergency_outbox_store.dart';

EmergencyOutboxEntry fakeEntry({
  String eventId = 'event-1',
  OutboxEntryState state = OutboxEntryState.created,
  DateTime? createdAt,
}) =>
    EmergencyOutboxEntry(
      eventId: eventId,
      eventSource: 'manual',
      category: 'medical',
      message: 'help',
      latitude: 12.3456,
      longitude: 77.6543,
      createdAt: createdAt ?? DateTime.now(),
      state: state,
    );

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('upsert / loadAll / get', () {
    test('a new entry round-trips through persistence intact', () async {
      await EmergencyOutboxStore.instance.upsert(fakeEntry());
      final loaded = await EmergencyOutboxStore.instance.get('event-1');
      expect(loaded, isNotNull);
      expect(loaded!.category, 'medical');
      expect(loaded.latitude, 12.3456);
    });

    test('re-upserting the same eventId replaces it rather than duplicating', () async {
      await EmergencyOutboxStore.instance.upsert(fakeEntry());
      await EmergencyOutboxStore.instance.upsert(fakeEntry(state: OutboxEntryState.serverAccepted));
      final all = await EmergencyOutboxStore.instance.loadAll();
      expect(all.where((e) => e.eventId == 'event-1'), hasLength(1));
      expect(all.first.state, OutboxEntryState.serverAccepted);
    });

    test('survives being "reloaded" — simulates an app restart by hitting the store fresh', () async {
      await EmergencyOutboxStore.instance.upsert(fakeEntry(eventId: 'restart-test'));
      // No in-memory state is held anywhere in EmergencyOutboxStore itself
      // (every call re-reads SharedPreferences) — this test exists to
      // make that explicit, not to exercise anything special.
      final reloaded = await EmergencyOutboxStore.instance.get('restart-test');
      expect(reloaded, isNotNull);
    });

    test('get() returns null for an unknown eventId', () async {
      final result = await EmergencyOutboxStore.instance.get('does-not-exist');
      expect(result, isNull);
    });
  });

  group('loadPending', () {
    test('excludes terminal-state entries', () async {
      await EmergencyOutboxStore.instance.upsert(fakeEntry(eventId: 'pending-1', state: OutboxEntryState.queued));
      await EmergencyOutboxStore.instance.upsert(fakeEntry(eventId: 'done-1', state: OutboxEntryState.serverAccepted));
      await EmergencyOutboxStore.instance.upsert(fakeEntry(eventId: 'failed-1', state: OutboxEntryState.failed));
      await EmergencyOutboxStore.instance.upsert(fakeEntry(eventId: 'expired-1', state: OutboxEntryState.expired));

      final pending = await EmergencyOutboxStore.instance.loadPending();

      expect(pending.map((e) => e.eventId), ['pending-1']);
    });
  });

  group('pruneTerminal', () {
    test('removes old terminal entries but keeps recent ones and all non-terminal ones', () async {
      final old = DateTime.now().subtract(const Duration(days: 30));
      await EmergencyOutboxStore.instance.upsert(fakeEntry(eventId: 'old-done', state: OutboxEntryState.serverAccepted, createdAt: old));
      await EmergencyOutboxStore.instance.upsert(fakeEntry(eventId: 'recent-done', state: OutboxEntryState.serverAccepted));
      await EmergencyOutboxStore.instance.upsert(fakeEntry(eventId: 'still-pending', state: OutboxEntryState.queued, createdAt: old));

      await EmergencyOutboxStore.instance.pruneTerminal(olderThan: const Duration(days: 7));

      final remaining = (await EmergencyOutboxStore.instance.loadAll()).map((e) => e.eventId).toSet();
      expect(remaining, {'recent-done', 'still-pending'});
    });
  });

  group('processed-id dedup ledger', () {
    test('hasProcessed is false for an unseen id', () async {
      expect(await EmergencyOutboxStore.instance.hasProcessed('never-seen'), false);
    });

    test('markProcessed then hasProcessed round-trips true', () async {
      await EmergencyOutboxStore.instance.markProcessed('seen-1');
      expect(await EmergencyOutboxStore.instance.hasProcessed('seen-1'), true);
    });

    test('persists across a fresh read (no in-memory-only state)', () async {
      await EmergencyOutboxStore.instance.markProcessed('seen-2');
      // A second, independent call re-reads SharedPreferences each time —
      // there is no cache to accidentally rely on here.
      expect(await EmergencyOutboxStore.instance.hasProcessed('seen-2'), true);
      expect(await EmergencyOutboxStore.instance.hasProcessed('seen-2'), true);
    });

    test('bounded: exceeding maxProcessedIds evicts the oldest entries first', () async {
      // Use a small local loop bounded well under the real max but prove
      // the eviction/ordering logic itself using the real constant via
      // repeated inserts, checking the OLDEST is gone once the cap is
      // exceeded (marking one extra beyond the cap).
      for (var i = 0; i < EmergencyOutboxStore.maxProcessedIds; i++) {
        await EmergencyOutboxStore.instance.markProcessed('bulk-$i');
      }
      // The very first one should still be present (cap not yet exceeded).
      expect(await EmergencyOutboxStore.instance.hasProcessed('bulk-0'), true);

      await EmergencyOutboxStore.instance.markProcessed('bulk-overflow');

      // Oldest entry evicted to make room for the newest.
      expect(await EmergencyOutboxStore.instance.hasProcessed('bulk-0'), false);
      expect(await EmergencyOutboxStore.instance.hasProcessed('bulk-overflow'), true);
    }, timeout: const Timeout(Duration(seconds: 30)));
  });
}

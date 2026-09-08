import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/emergency_outbox_entry.dart';

/// Durable local persistence for emergency events in flight — the
/// concrete answer to Phase 6's "do not rely on RAM" requirement.
///
/// Uses SharedPreferences (JSON-encoded), the exact same mechanism
/// CommunicationService already uses for its own pending-message outbox
/// — not a new local database engine. This is an appropriate choice for
/// the actual data volume involved (a handful of concurrent emergency
/// events per device, not a chat history), matching this project's
/// existing "reuse the established pattern" precedent rather than
/// introducing sqlite/Hive/ObjectBox for a workload that doesn't need it.
///
/// Never persists anything secret: an [EmergencyOutboxEntry] contains
/// event content, a signed envelope (public material — the signature is
/// not exportable-private-key data, see origin_envelope.dart), and
/// transport bookkeeping. No JWT, no private key, no refresh token ever
/// passes through this store.
class EmergencyOutboxStore {
  /// [keyPrefix] exists ONLY so tests can construct multiple,
  /// independently-persisted instances within one process (e.g. to
  /// simulate several separate devices sharing a single test's mocked
  /// SharedPreferences backend — see test/mesh_multi_device_test.dart).
  /// Production code always uses [instance] (empty prefix, i.e. the
  /// exact same SharedPreferences keys this class has always used) —
  /// there is genuinely only one outbox on a real device, since one
  /// running app process IS one device.
  EmergencyOutboxStore({@visibleForTesting String keyPrefix = ''})
      : _outboxKey = '${keyPrefix}resqnet_emergency_outbox_v1',
        _processedIdsKey = '${keyPrefix}resqnet_emergency_processed_ids_v1';

  static final EmergencyOutboxStore instance = EmergencyOutboxStore();

  final String _outboxKey;
  final String _processedIdsKey;

  /// Hard cap on how many processed-message records are retained — a
  /// flood of distinct fake event/message ids must not grow this
  /// structure without bound (Section 12/21: bounded storage, never
  /// unbounded). Old entries are evicted oldest-first once this is hit,
  /// independent of their own TTL.
  static const int maxProcessedIds = 1000;

  /// How long a processed-id record is kept even if never evicted by the
  /// count cap — longer than OriginEnvelopeService.defaultTtl (24h) so a
  /// duplicate arriving right at an event's own expiry boundary is still
  /// caught as a dup, not double-processed.
  static const Duration processedIdRetention = Duration(hours: 48);

  // --- Outbox (locally-originated events) ---

  /// Always returns a fresh, growable list — callers such as [upsert]
  /// mutate the result in place before saving, so this must never return
  /// a `const []`/unmodifiable list even on the "nothing persisted yet"
  /// path.
  Future<List<EmergencyOutboxEntry>> loadAll() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_outboxKey);
    if (raw == null) return <EmergencyOutboxEntry>[];
    try {
      final list = jsonDecode(raw) as List;
      return list.map((e) => EmergencyOutboxEntry.fromJson(e as Map<String, dynamic>)).toList();
    } catch (_) {
      return <EmergencyOutboxEntry>[];
    }
  }

  Future<void> _saveAll(List<EmergencyOutboxEntry> entries) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_outboxKey, jsonEncode(entries.map((e) => e.toJson()).toList()));
  }

  /// Inserts a new entry or replaces an existing one with the same
  /// eventId — upsert semantics, so re-persisting an entry after a state
  /// change never creates a duplicate row.
  Future<void> upsert(EmergencyOutboxEntry entry) async {
    final all = await loadAll();
    final idx = all.indexWhere((e) => e.eventId == entry.eventId);
    if (idx == -1) {
      all.add(entry);
    } else {
      all[idx] = entry;
    }
    await _saveAll(all);
  }

  Future<EmergencyOutboxEntry?> get(String eventId) async {
    final all = await loadAll();
    for (final e in all) {
      if (e.eventId == eventId) return e;
    }
    return null;
  }

  /// Entries not yet in a terminal state — what the sync coordinator and
  /// mesh transport actually need to act on.
  Future<List<EmergencyOutboxEntry>> loadPending() async {
    final all = await loadAll();
    return all.where((e) => !e.isTerminal).toList();
  }

  /// Removes entries that reached a terminal state long enough ago that
  /// there's no remaining reason to keep them locally (data retention —
  /// Section 42: relay/local storage must not grow forever). Kept for a
  /// while after reaching a terminal state so the user's own SOS history
  /// UI can still show "delivered"/"failed" for a recent event.
  Future<void> pruneTerminal({Duration olderThan = const Duration(days: 7)}) async {
    final all = await loadAll();
    final cutoff = DateTime.now().subtract(olderThan);
    final kept = all.where((e) => !e.isTerminal || e.createdAt.isAfter(cutoff)).toList();
    if (kept.length != all.length) {
      await _saveAll(kept);
    }
  }

  // --- Processed-message dedup (inbox side) ---

  /// True if [id] (an eventId or mesh messageId) has already been seen
  /// and processed by this device — persisted, not just an in-memory
  /// Set, so a restart doesn't forget what's already been relayed/shown
  /// and cause it to be re-processed or re-forwarded (Section 13:
  /// "Persist deduplication state. Do not rely only on RAM.").
  Future<bool> hasProcessed(String id) async {
    final map = await _loadProcessedIds();
    return map.containsKey(id);
  }

  /// Records [id] as processed. Evicts the oldest entries once
  /// [maxProcessedIds] is exceeded, and always drops anything older than
  /// [processedIdRetention] — bounded storage, matching Section 12's
  /// relay-queue requirement even though this structure isn't the relay
  /// queue itself (MeshService's own relay path uses this same store).
  Future<void> markProcessed(String id) async {
    final map = await _loadProcessedIds();
    map[id] = DateTime.now();
    _evictStaleAndExcess(map);
    await _saveProcessedIds(map);
  }

  void _evictStaleAndExcess(Map<String, DateTime> map) {
    final cutoff = DateTime.now().subtract(processedIdRetention);
    map.removeWhere((_, seenAt) => seenAt.isBefore(cutoff));
    if (map.length > maxProcessedIds) {
      final sortedByAge = map.entries.toList()..sort((a, b) => a.value.compareTo(b.value));
      final toRemove = sortedByAge.length - maxProcessedIds;
      for (var i = 0; i < toRemove; i++) {
        map.remove(sortedByAge[i].key);
      }
    }
  }

  Future<Map<String, DateTime>> _loadProcessedIds() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_processedIdsKey);
    if (raw == null) return {};
    try {
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      return decoded.map((k, v) => MapEntry(k, DateTime.parse(v as String)));
    } catch (_) {
      return {};
    }
  }

  Future<void> _saveProcessedIds(Map<String, DateTime> map) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_processedIdsKey, jsonEncode(map.map((k, v) => MapEntry(k, v.toIso8601String()))));
  }
}

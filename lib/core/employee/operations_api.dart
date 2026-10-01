import 'employee_api_client.dart';

// Typed access to the backend's operations endpoints (/api/v1/employee/…).
// Every call goes through [EmployeeApiClient], so the employee session,
// token refresh and error mapping are the same as the rest of the portal.
// The backend enforces every permission; nothing here is a security check.

const sosMonitorPermission = 'SOS_MONITOR';
const sosRespondPermission = 'SOS_RESPOND';
const sosAssignPermission = 'SOS_ASSIGN';
const auditLogViewPermission = 'AUDIT_LOG_VIEW';
const retentionHoldManagePermission = 'RETENTION_HOLD_MANAGE';
const officialAlertPublishPermission = 'OFFICIAL_ALERT_PUBLISH';
const partnerAlertPublishPermission = 'PARTNER_ALERT_PUBLISH';
const systemAlertPublishPermission = 'SYSTEM_ALERT_PUBLISH';

/// Portal-issuable source types and the permission each needs.
const alertPublishPermissionFor = {
  'official': officialAlertPublishPermission,
  'verified_partner': partnerAlertPublishPermission,
  'resqnet_system': systemAlertPublishPermission,
};

String? _string(Object? v) => v is String ? v : null;
double? _double(Object? v) => v is num ? v.toDouble() : null;
DateTime? _time(Object? v) => v is String ? DateTime.tryParse(v)?.toLocal() : null;

class IncidentSummary {
  const IncidentSummary({
    required this.id,
    required this.eventId,
    required this.category,
    required this.eventSource,
    required this.opsStatus,
    required this.civilianState,
    required this.originVerificationState,
    required this.assignedEmployeeId,
    required this.latitude,
    required this.longitude,
    required this.receivedAt,
    this.sensitiveRemoved = false,
  });

  final String id;
  final String eventId;
  final String category;
  final String eventSource;
  final String opsStatus;
  final String civilianState;
  final String originVerificationState;
  final String? assignedEmployeeId;

  /// Approximate (≈1 km) in the queue.
  final double? latitude;
  final double? longitude;
  final DateTime receivedAt;

  /// Message and location removed under the retention policy.
  final bool sensitiveRemoved;

  factory IncidentSummary.fromJson(Map<String, dynamic> json) => IncidentSummary(
        id: json['id'] as String,
        eventId: _string(json['eventId']) ?? '',
        category: _string(json['category']) ?? 'unknown',
        eventSource: _string(json['eventSource']) ?? 'unknown',
        opsStatus: _string(json['opsStatus']) ?? 'reported',
        civilianState: _string(json['civilianState']) ?? 'active',
        originVerificationState: _string(json['originVerificationState']) ?? 'unknown',
        assignedEmployeeId: _string(json['assignedEmployeeId']),
        latitude: _double(json['approximateLatitude']),
        longitude: _double(json['approximateLongitude']),
        receivedAt: _time(json['receivedAt']) ?? DateTime.fromMillisecondsSinceEpoch(0),
        sensitiveRemoved: json['sensitiveRemoved'] == true,
      );
}

class IncidentPage {
  const IncidentPage(this.incidents, this.nextCursor);
  final List<IncidentSummary> incidents;
  final String? nextCursor;
}

class TimelineEntry {
  const TimelineEntry({
    required this.action,
    required this.employeeId,
    required this.actorRole,
    required this.previousState,
    required this.newState,
    required this.assignedEmployeeId,
    required this.note,
    required this.noteHidden,
    required this.at,
    this.noteRemoved = false,
  });

  final String action;
  final String? employeeId;
  final String? actorRole;
  final String? previousState;
  final String? newState;
  final String? assignedEmployeeId;
  final String? note;
  final bool noteHidden;
  final DateTime at;

  /// Note text removed under the retention policy.
  final bool noteRemoved;

  /// Entries written by the person in distress (or their device), not staff.
  bool get isCivilian => action == 'civilian_state';

  factory TimelineEntry.fromJson(Map<String, dynamic> json) => TimelineEntry(
        action: _string(json['action']) ?? 'unknown',
        employeeId: _string(json['employeeId']),
        actorRole: _string(json['actorRole']),
        previousState: _string(json['previousState']),
        newState: _string(json['newState']),
        assignedEmployeeId: _string(json['assignedEmployeeId']),
        note: _string(json['note']),
        noteHidden: json['noteHidden'] == true,
        at: _time(json['at']) ?? DateTime.fromMillisecondsSinceEpoch(0),
        noteRemoved: json['noteRemoved'] == true,
      );
}

class IncidentDetail {
  const IncidentDetail({
    required this.summary,
    required this.includesSensitiveDetails,
    required this.message,
    required this.latitude,
    required this.longitude,
    required this.locationAccuracyM,
    required this.reporterName,
    required this.reporterPhone,
    required this.hasReporterAccount,
    required this.timeline,
    this.lifecycle = const IncidentLifecycle(),
  });

  final IncidentSummary summary;
  final IncidentLifecycle lifecycle;

  /// False: location is approximate; phone, SOS message and note text are withheld by the server.
  final bool includesSensitiveDetails;
  final String? message;
  final double? latitude;
  final double? longitude;
  final double? locationAccuracyM;
  final String? reporterName;
  final String? reporterPhone;
  final bool hasReporterAccount;
  final List<TimelineEntry> timeline;

  factory IncidentDetail.fromJson(Map<String, dynamic> json) {
    final reporter = json['reporter'];
    return IncidentDetail(
      summary: IncidentSummary.fromJson({
        ...json,
        'approximateLatitude': json['latitude'],
        'approximateLongitude': json['longitude'],
      }),
      includesSensitiveDetails: json['includesSensitiveDetails'] == true,
      message: _string(json['message']),
      latitude: _double(json['latitude']),
      longitude: _double(json['longitude']),
      locationAccuracyM: _double(json['locationAccuracyM']),
      reporterName: reporter is Map ? _string(reporter['displayName']) : null,
      reporterPhone: reporter is Map ? _string(reporter['phoneNumber']) : null,
      hasReporterAccount: reporter is Map,
      timeline: ((json['timeline'] as List?) ?? const [])
          .map((e) => TimelineEntry.fromJson(e as Map<String, dynamic>))
          .toList(),
      lifecycle: IncidentLifecycle.fromJson((json['lifecycle'] as Map?)?.cast<String, dynamic>() ?? const {}),
    );
  }
}

/// Retention state of an incident record (server-side lifecycle).
class IncidentLifecycle {
  const IncidentLifecycle({this.closedAt, this.sensitiveRedactedAt, this.deidentifiedAt, this.holdSince, this.holdReason});

  final DateTime? closedAt;
  final DateTime? sensitiveRedactedAt;
  final DateTime? deidentifiedAt;
  final DateTime? holdSince;
  final String? holdReason;

  bool get onHold => holdSince != null;

  factory IncidentLifecycle.fromJson(Map<String, dynamic> json) {
    final hold = json['retentionHold'];
    return IncidentLifecycle(
      closedAt: _time(json['closedAt']),
      sensitiveRedactedAt: _time(json['sensitiveRedactedAt']),
      deidentifiedAt: _time(json['deidentifiedAt']),
      holdSince: hold is Map ? _time(hold['since']) : null,
      holdReason: hold is Map ? _string(hold['reason']) : null,
    );
  }
}

class IncidentCounts {
  const IncidentCounts({
    required this.generatedAt,
    required this.byResponderState,
    required this.openButCivilianSafe,
    required this.openButCivilianCancelled,
    required this.oldestUnacknowledgedAt,
  });

  final DateTime generatedAt;
  final Map<String, int> byResponderState;
  final int openButCivilianSafe;
  final int openButCivilianCancelled;
  final DateTime? oldestUnacknowledgedAt;

  int count(String state) => byResponderState[state] ?? 0;
  int get open => byResponderState.entries
      .where((e) => e.key != 'resolved' && e.key != 'stood_down')
      .fold(0, (sum, e) => sum + e.value);

  factory IncidentCounts.fromJson(Map<String, dynamic> json) => IncidentCounts(
        generatedAt: _time(json['generatedAt']) ?? DateTime.now(),
        byResponderState:
            ((json['byResponderState'] as Map?) ?? const {}).map((k, v) => MapEntry(k as String, (v as num).toInt())),
        openButCivilianSafe: (json['openButCivilianSafe'] as num?)?.toInt() ?? 0,
        openButCivilianCancelled: (json['openButCivilianCancelled'] as num?)?.toInt() ?? 0,
        oldestUnacknowledgedAt: _time(json['oldestUnacknowledgedAt']),
      );
}

class EligibleResponder {
  const EligibleResponder(
      {required this.id, required this.displayName, required this.role, required this.openAssignments});
  final String id;
  final String displayName;
  final String role;
  final int openAssignments;

  factory EligibleResponder.fromJson(Map<String, dynamic> json) => EligibleResponder(
        id: json['id'] as String,
        displayName: _string(json['displayName']) ?? 'Employee',
        role: _string(json['role']) ?? 'employee',
        openAssignments: (json['openAssignments'] as num?)?.toInt() ?? 0,
      );
}

class StaffAlert {
  const StaffAlert({
    required this.id,
    required this.sourceType,
    required this.sourceName,
    required this.sourceUrl,
    required this.retrievedAt,
    required this.category,
    required this.severity,
    required this.status,
    required this.title,
    required this.body,
    required this.latitude,
    required this.longitude,
    required this.radiusKm,
    required this.areaNames,
    required this.issuedAt,
    required this.expiresAt,
    required this.updatedAt,
  });

  final String id;
  final String sourceType;
  final String sourceName;
  final String? sourceUrl;

  /// Set when ingested from an external feed; null when issued in the portal.
  final DateTime? retrievedAt;
  final String category;
  final String severity;
  final String status;
  final String title;
  final String body;
  final double? latitude;
  final double? longitude;
  final double? radiusKm;
  final List<String> areaNames;
  final DateTime? issuedAt;
  final DateTime? expiresAt;
  final DateTime? updatedAt;

  factory StaffAlert.fromJson(Map<String, dynamic> json) {
    final area = (json['area'] as Map?) ?? const {};
    return StaffAlert(
      id: json['id'] as String,
      sourceType: _string(json['sourceType']) ?? 'community',
      sourceName: _string(json['sourceName']) ?? '',
      sourceUrl: _string(json['sourceUrl']),
      retrievedAt: _time(json['retrievedAt']),
      category: _string(json['category']) ?? 'other',
      severity: _string(json['severity']) ?? 'info',
      status: _string(json['status']) ?? 'active',
      title: _string(json['title']) ?? '',
      body: _string(json['body']) ?? '',
      latitude: _double(area['latitude']),
      longitude: _double(area['longitude']),
      radiusKm: _double(area['radiusKm']),
      areaNames: [area['municipality'], area['district'], area['province']].whereType<String>().toList(),
      issuedAt: _time(json['issuedAt']),
      expiresAt: _time(json['expiresAt']),
      updatedAt: _time(json['updatedAt']),
    );
  }
}

class DisasterSourceStatus {
  const DisasterSourceStatus({required this.registered, required this.scheduledIngestion, required this.observed});

  final List<Map<String, dynamic>> registered;
  final bool scheduledIngestion;
  final List<Map<String, dynamic>> observed;

  factory DisasterSourceStatus.fromJson(Map<String, dynamic> json) => DisasterSourceStatus(
        registered: ((json['registered'] as List?) ?? const []).cast<Map<String, dynamic>>(),
        scheduledIngestion: json['scheduledIngestion'] == true,
        observed: ((json['observed'] as List?) ?? const []).cast<Map<String, dynamic>>(),
      );
}

class AuditEntry {
  const AuditEntry({
    required this.id,
    required this.at,
    required this.actorKind,
    required this.actorName,
    required this.actorRole,
    required this.actorId,
    required this.action,
    required this.resourceType,
    required this.resourceId,
    required this.outcome,
    required this.metadata,
  });

  final String id;
  final DateTime at;
  final String actorKind;
  final String? actorName;
  final String? actorRole;
  final String? actorId;
  final String action;
  final String resourceType;
  final String? resourceId;
  final String outcome;
  final Map<String, dynamic> metadata;

  factory AuditEntry.fromJson(Map<String, dynamic> json) {
    final actor = (json['actor'] as Map?) ?? const {};
    return AuditEntry(
      id: json['id'] as String,
      at: _time(json['at']) ?? DateTime.fromMillisecondsSinceEpoch(0),
      actorKind: _string(actor['kind']) ?? 'system',
      actorName: _string(actor['displayName']),
      actorRole: _string(actor['role']),
      actorId: _string(actor['id']),
      action: _string(json['action']) ?? '',
      resourceType: _string(json['resourceType']) ?? '',
      resourceId: _string(json['resourceId']),
      outcome: _string(json['outcome']) ?? 'success',
      metadata: json['metadata'] is Map<String, dynamic> ? json['metadata'] as Map<String, dynamic> : const {},
    );
  }
}

class AuditPage {
  const AuditPage(this.entries, this.nextBefore);
  final List<AuditEntry> entries;
  final String? nextBefore;
}

class OperationsApi {
  OperationsApi({EmployeeApiClient? client}) : _client = client;

  final EmployeeApiClient? _client;
  EmployeeApiClient get _api => _client ?? EmployeeApiClient.instance;

  static String _withQuery(String path, Map<String, String?> query) {
    final params = {
      for (final e in query.entries)
        if (e.value != null && e.value!.isNotEmpty) e.key: e.value!,
    };
    return params.isEmpty ? path : '$path?${Uri(queryParameters: params).query}';
  }

  Future<IncidentPage> listIncidents({
    String scope = 'active',
    String? opsStatus,
    String? civilianState,
    String? assignee,
    String? cursor,
    int limit = 50,
  }) async {
    final json = await _api.get(_withQuery('/incidents', {
      'scope': scope,
      'opsStatus': opsStatus,
      'civilianState': civilianState,
      'assignee': assignee,
      'cursor': cursor,
      'limit': '$limit',
    }));
    return IncidentPage(
      ((json['incidents'] as List?) ?? const [])
          .map((e) => IncidentSummary.fromJson(e as Map<String, dynamic>))
          .toList(),
      _string(json['nextCursor']),
    );
  }

  Future<IncidentCounts> incidentCounts() async =>
      IncidentCounts.fromJson((await _api.get('/incidents/summary'))['counts'] as Map<String, dynamic>);

  Future<IncidentDetail> incident(String id) async =>
      IncidentDetail.fromJson((await _api.get('/incidents/$id'))['incident'] as Map<String, dynamic>);

  Future<List<EligibleResponder>> responders() async =>
      ((await _api.get('/incidents/responders'))['responders'] as List)
          .map((e) => EligibleResponder.fromJson(e as Map<String, dynamic>))
          .toList();

  /// Returns the new responder state. The backend validates the transition.
  Future<String> recordUpdate(String incidentId, String action, {String? note, String? assignedEmployeeId}) async {
    final json = await _api.post('/incidents/$incidentId/updates', body: {
      'action': action,
      if (note != null && note.trim().isNotEmpty) 'note': note.trim(),
      if (assignedEmployeeId != null) 'assignedEmployeeId': assignedEmployeeId,
    });
    return _string(json['opsStatus']) ?? action;
  }

  /// Places ([reason] required) or lifts a retention hold. RETENTION_HOLD_MANAGE.
  Future<void> setRetentionHold(String incidentId, {required bool hold, String? reason}) async {
    await _api.post('/incidents/$incidentId/retention-hold', body: {'hold': hold, if (hold) 'reason': reason});
  }

  Future<List<StaffAlert>> alerts() async => ((await _api.get('/alerts'))['alerts'] as List)
      .map((e) => StaffAlert.fromJson(e as Map<String, dynamic>))
      .toList();

  Future<StaffAlert> createAlert(Map<String, dynamic> body) async =>
      StaffAlert.fromJson((await _api.post('/alerts', body: body))['alert'] as Map<String, dynamic>);

  Future<StaffAlert> updateAlert(String id, Map<String, dynamic> body) async =>
      StaffAlert.fromJson((await _api.patch('/alerts/$id', body: body))['alert'] as Map<String, dynamic>);

  Future<DisasterSourceStatus> disasterSources() async =>
      DisasterSourceStatus.fromJson((await _api.get('/alerts/sources'))['sources'] as Map<String, dynamic>);

  Future<AuditPage> auditLogs(
      {String? resourceType,
      String? resourceId,
      String? actionPrefix,
      String? outcome,
      String? before,
      int limit = 50}) async {
    final json = await _api.get(_withQuery('/audit-logs', {
      'resourceType': resourceType,
      'resourceId': resourceId,
      'actionPrefix': actionPrefix,
      'outcome': outcome,
      'before': before,
      'limit': '$limit',
    }));
    return AuditPage(
      ((json['entries'] as List?) ?? const []).map((e) => AuditEntry.fromJson(e as Map<String, dynamic>)).toList(),
      _string(json['nextBefore']),
    );
  }
}

import 'employee_api_client.dart';

/// Permission required by every /employee/sms-providers endpoint.
const smsProviderManagePermission = 'SMS_PROVIDER_MANAGE';

class SmsProviderField {
  const SmsProviderField({
    required this.key,
    required this.label,
    required this.required,
    required this.secret,
    this.help,
    this.options = const [],
  });

  final String key;
  final String label;
  final bool required;
  final bool secret;
  final String? help;
  final List<String> options;

  factory SmsProviderField.fromJson(Map<String, dynamic> json) => SmsProviderField(
        key: json['key'] as String,
        label: json['label'] as String? ?? json['key'] as String,
        required: json['required'] as bool? ?? false,
        secret: json['secret'] as bool? ?? false,
        help: json['help'] as String?,
        options: ((json['options'] as List?) ?? const []).cast<String>(),
      );
}

/// One entry of the backend's provider catalog (what can be configured).
class SmsProviderType {
  const SmsProviderType({
    required this.providerType,
    required this.displayName,
    required this.available,
    required this.coverage,
    required this.notes,
    required this.docsUrl,
    required this.credentialFields,
    required this.configurationFields,
  });

  final String providerType;
  final String displayName;
  final bool available;
  final String coverage;
  final String notes;
  final String docsUrl;
  final List<SmsProviderField> credentialFields;
  final List<SmsProviderField> configurationFields;

  static List<SmsProviderField> _fields(Object? raw) =>
      ((raw as List?) ?? const []).map((f) => SmsProviderField.fromJson(f as Map<String, dynamic>)).toList();

  factory SmsProviderType.fromJson(Map<String, dynamic> json) => SmsProviderType(
        providerType: json['providerType'] as String,
        displayName: json['displayName'] as String? ?? json['providerType'] as String,
        available: json['available'] as bool? ?? false,
        coverage: json['coverage'] as String? ?? '',
        notes: json['notes'] as String? ?? '',
        docsUrl: json['docsUrl'] as String? ?? '',
        credentialFields: _fields(json['credentialFields']),
        configurationFields: _fields(json['configurationFields']),
      );
}

/// A configured sms_providers row. Credentials are write-only: the API only
/// reports which credential fields are set, never their values.
class ConfiguredSmsProvider {
  const ConfiguredSmsProvider({
    required this.id,
    required this.providerType,
    required this.displayName,
    required this.enabled,
    required this.priority,
    required this.available,
    required this.configuration,
    required this.configuredCredentialFields,
    required this.credentialsReadable,
    this.lastTestedAt,
    this.lastTestStatus,
  });

  final String id;
  final String providerType;
  final String displayName;
  final bool enabled;
  final int priority;
  final bool available;
  final Map<String, dynamic> configuration;
  final Set<String> configuredCredentialFields;
  final bool credentialsReadable;
  final DateTime? lastTestedAt;
  final String? lastTestStatus;

  factory ConfiguredSmsProvider.fromJson(Map<String, dynamic> json) => ConfiguredSmsProvider(
        id: json['id'] as String,
        providerType: json['providerType'] as String,
        displayName: json['displayName'] as String? ?? json['providerType'] as String,
        enabled: json['enabled'] as bool? ?? false,
        priority: (json['priority'] as num?)?.toInt() ?? 100,
        available: json['available'] as bool? ?? false,
        configuration: Map<String, dynamic>.from((json['configuration'] as Map?) ?? const {}),
        configuredCredentialFields: ((json['configuredCredentialFields'] as List?) ?? const []).cast<String>().toSet(),
        credentialsReadable: json['credentialsReadable'] as bool? ?? true,
        lastTestedAt: DateTime.tryParse(json['lastTestedAt'] as String? ?? ''),
        lastTestStatus: json['lastTestStatus'] as String?,
      );
}

class SmsProviderOverview {
  const SmsProviderOverview({required this.catalog, required this.providers});

  final List<SmsProviderType> catalog;

  /// Sorted in fallback order (ascending priority), as returned by the API.
  final List<ConfiguredSmsProvider> providers;

  SmsProviderType? typeOf(String providerType) {
    for (final type in catalog) {
      if (type.providerType == providerType) return type;
    }
    return null;
  }

  /// Providers that will actually be tried for an OTP, in order.
  List<ConfiguredSmsProvider> get fallbackOrder => providers.where((p) => p.enabled && p.available).toList();
}

class SmsProviderTestResult {
  const SmsProviderTestResult({required this.success, required this.message, this.failure, this.providerCode});

  final bool success;
  final String message;
  final String? failure;
  final String? providerCode;

  factory SmsProviderTestResult.fromJson(Map<String, dynamic> json) => SmsProviderTestResult(
        success: json['status'] == 'success',
        message: json['message'] as String? ?? '',
        failure: json['failure'] as String?,
        providerCode: json['providerCode'] as String?,
      );
}

/// Calls the /employee/sms-providers API.
class SmsProviderAdminService {
  SmsProviderAdminService({EmployeeApiClient? client}) : _client = client;

  final EmployeeApiClient? _client;
  EmployeeApiClient get _api => _client ?? EmployeeApiClient.instance;

  Future<SmsProviderOverview> load() async {
    final result = await _api.get('/sms-providers');
    return SmsProviderOverview(
      catalog: ((result['catalog'] as List?) ?? const [])
          .map((e) => SmsProviderType.fromJson(e as Map<String, dynamic>))
          .toList(),
      providers: ((result['providers'] as List?) ?? const [])
          .map((e) => ConfiguredSmsProvider.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }

  Future<ConfiguredSmsProvider> create({
    required String providerType,
    required String displayName,
    required bool enabled,
    required int priority,
    required Map<String, String> credentials,
    required Map<String, String> configuration,
  }) async {
    final result = await _api.post('/sms-providers', body: {
      'providerType': providerType,
      'displayName': displayName,
      'enabled': enabled,
      'priority': priority,
      'credentials': credentials,
      'configuration': configuration,
    });
    return ConfiguredSmsProvider.fromJson(result['provider'] as Map<String, dynamic>);
  }

  /// Blank secret values are dropped before sending, so the server keeps
  /// the stored secret; blank configuration values are sent as null, which
  /// clears that optional setting.
  Future<ConfiguredSmsProvider> update(
    String id, {
    String? displayName,
    bool? enabled,
    int? priority,
    Map<String, String>? credentials,
    Map<String, String>? configuration,
  }) async {
    final body = <String, dynamic>{
      if (displayName != null) 'displayName': displayName,
      if (enabled != null) 'enabled': enabled,
      if (priority != null) 'priority': priority,
    };
    final changedSecrets = {
      for (final entry in (credentials ?? const <String, String>{}).entries)
        if (entry.value.trim().isNotEmpty) entry.key: entry.value.trim(),
    };
    if (changedSecrets.isNotEmpty) body['credentials'] = changedSecrets;
    if (configuration != null) {
      body['configuration'] = {
        for (final entry in configuration.entries) entry.key: entry.value.trim().isEmpty ? null : entry.value.trim(),
      };
    }
    final result = await _api.patch('/sms-providers/$id', body: body);
    return ConfiguredSmsProvider.fromJson(result['provider'] as Map<String, dynamic>);
  }

  Future<void> disable(String id) => _api.delete('/sms-providers/$id');

  Future<SmsProviderTestResult> test(String id, String phoneNumber) async {
    final result = await _api.post('/sms-providers/$id/test', body: {'phoneNumber': phoneNumber});
    return SmsProviderTestResult.fromJson(result['result'] as Map<String, dynamic>);
  }
}

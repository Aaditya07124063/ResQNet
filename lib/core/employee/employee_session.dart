import 'package:flutter/foundation.dart';
import '../network/api_exception.dart';
import 'employee_api_client.dart';
import 'employee_token_storage.dart';

/// A signed-in employee, as returned by GET /employee/me.
class EmployeeProfile {
  const EmployeeProfile({required this.id, required this.email, required this.displayName, required this.role});

  final String id;
  final String email;
  final String displayName;
  final String role;

  bool get isSuperAdmin => role == 'super_admin';

  factory EmployeeProfile.fromJson(Map<String, dynamic> json) => EmployeeProfile(
        id: json['id'] as String,
        email: json['email'] as String? ?? '',
        displayName: json['displayName'] as String? ?? json['email'] as String? ?? 'Employee',
        role: json['role'] as String? ?? 'employee',
      );
}

enum EmployeeSessionStatus { unknown, signedOut, signedIn, offline }

/// Employee-portal session state. Entirely separate from the civilian
/// [AuthService]/[BackendSession]: it is only restored when the portal is
/// opened, and its tokens live in [EmployeeTokenStorage].
///
/// Permission checks here only decide what the UI shows — the backend
/// enforces every permission itself.
class EmployeeSession extends ChangeNotifier {
  EmployeeSession({EmployeeApiClient? client}) : _client = client;

  final EmployeeApiClient? _client;
  EmployeeApiClient get _api => _client ?? EmployeeApiClient.instance;

  EmployeeSessionStatus status = EmployeeSessionStatus.unknown;
  EmployeeProfile? employee;
  Set<String> permissions = const {};
  bool busy = false;

  /// Why the employee was signed out without asking (e.g. an expired or
  /// revoked session), shown on the sign-in form. Cleared on sign-in.
  String? signedOutReason;

  bool get isSignedIn => status == EmployeeSessionStatus.signedIn && employee != null;

  bool can(String permission) => employee != null && (employee!.isSuperAdmin || permissions.contains(permission));

  /// Loads the current employee if a stored session exists. Makes no
  /// network request when no employee has ever signed in on this device.
  Future<void> restore() async {
    if (busy) return;
    if (await EmployeeTokenStorage.instance.readRefreshToken() == null) {
      _signedOut();
      return;
    }
    busy = true;
    notifyListeners();
    try {
      await _loadMe();
    } on ApiException catch (e) {
      if (e.isNetworkError) {
        status = EmployeeSessionStatus.offline;
      } else {
        await EmployeeTokenStorage.instance.clear();
        _clearIdentity();
        status = EmployeeSessionStatus.signedOut;
      }
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  /// Throws [ApiException] on failure so the login form can show it.
  Future<void> login(String email, String password) async {
    busy = true;
    notifyListeners();
    try {
      final result = await _api.post('/auth/login', body: {'email': email, 'password': password}, auth: false);
      final session = result['session'] as Map<String, dynamic>;
      await EmployeeTokenStorage.instance.save(
        accessToken: session['accessToken'] as String,
        refreshToken: session['refreshToken'] as String,
      );
      await _loadMe();
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  /// Called when a request is still rejected with 401 after the client's
  /// refresh attempt: the session has expired or was revoked.
  Future<void> expire() async {
    await EmployeeTokenStorage.instance.clear();
    _signedOut();
    signedOutReason = 'Your staff session has ended. Please sign in again.';
    notifyListeners();
  }

  Future<void> logout() async {
    final refreshToken = await EmployeeTokenStorage.instance.readRefreshToken();
    if (refreshToken != null) {
      try {
        await _api.postNoContent('/auth/logout', body: {'refreshToken': refreshToken});
      } on ApiException {
        // Local sign-out always completes; the server-side refresh token
        // then simply expires.
      }
    }
    await EmployeeTokenStorage.instance.clear();
    _signedOut();
  }

  Future<void> _loadMe() async {
    final me = await _api.get('/me');
    employee = EmployeeProfile.fromJson(me['employee'] as Map<String, dynamic>);
    permissions = ((me['permissions'] as List?) ?? const [])
        .map((entry) => (entry as Map<String, dynamic>)['permission'] as String)
        .toSet();
    status = EmployeeSessionStatus.signedIn;
    signedOutReason = null;
  }

  void _clearIdentity() {
    employee = null;
    permissions = const {};
  }

  void _signedOut() {
    _clearIdentity();
    status = EmployeeSessionStatus.signedOut;
    notifyListeners();
  }
}

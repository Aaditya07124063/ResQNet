import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/constants/app_colors.dart';
import '../../core/employee/employee_session.dart';
import '../../core/network/api_exception.dart';
import '../operations/operations_shell.dart';

/// Entry point for responder/staff tools. Uses the separate employee
/// session (never the civilian sign-in) and only shows tools the employee
/// is permitted to use; the backend enforces the same permissions.
class EmployeePortalScreen extends StatefulWidget {
  const EmployeePortalScreen({super.key});

  @override
  State<EmployeePortalScreen> createState() => _EmployeePortalScreenState();
}

class _EmployeePortalScreenState extends State<EmployeePortalScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final session = context.read<EmployeeSession>();
      if (session.status != EmployeeSessionStatus.signedIn) session.restore();
    });
  }

  @override
  Widget build(BuildContext context) {
    final session = context.watch<EmployeeSession>();
    // Signed in: the operations shell brings its own navigation and scaffold.
    if (session.status == EmployeeSessionStatus.signedIn && session.employee != null) {
      return const OperationsShell();
    }
    return Scaffold(
      backgroundColor: AppColors.backgroundDark,
      appBar: AppBar(
        backgroundColor: AppColors.surfaceDark,
        foregroundColor: AppColors.textPrimary,
        title: const Text('ResQNet Operations'),
      ),
      body: SafeArea(child: _body(session)),
    );
  }

  Widget _body(EmployeeSession session) {
    switch (session.status) {
      case EmployeeSessionStatus.unknown:
        return const Center(child: CircularProgressIndicator());
      case EmployeeSessionStatus.offline:
        return _OfflineNotice(onRetry: session.busy ? null : session.restore);
      case EmployeeSessionStatus.signedOut:
        return const EmployeeLoginForm();
      case EmployeeSessionStatus.signedIn:
        return const SizedBox.shrink(); // handled in build()
    }
  }
}

class _OfflineNotice extends StatelessWidget {
  const _OfflineNotice({required this.onRetry});

  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cloud_off, size: 48, color: AppColors.textSecondary),
            const SizedBox(height: 12),
            Text(
              'The responder portal needs a connection to the ResQNet server. '
              'Emergency features on this device keep working offline.',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.textSecondary),
            ),
            const SizedBox(height: 16),
            OutlinedButton.icon(onPressed: onRetry, icon: const Icon(Icons.refresh), label: const Text('Retry')),
          ],
        ),
      ),
    );
  }
}

class EmployeeLoginForm extends StatefulWidget {
  const EmployeeLoginForm({super.key});

  @override
  State<EmployeeLoginForm> createState() => _EmployeeLoginFormState();
}

class _EmployeeLoginFormState extends State<EmployeeLoginForm> {
  final _formKey = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _password = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _error = null);
    try {
      await context.read<EmployeeSession>().login(_email.text.trim(), _password.text);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.isNetworkError
            ? 'Could not reach the ResQNet server. Check your connection.'
            : e.statusCode == 429
                ? 'Too many sign-in attempts. Please wait a minute.'
                : e.isUnauthorized
                    ? 'Invalid email or password.'
                    : e.message;
      });
    } finally {
      _password.clear();
    }
  }

  @override
  Widget build(BuildContext context) {
    final busy = context.watch<EmployeeSession>().busy;
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        const Icon(Icons.shield_outlined, size: 56, color: AppColors.emergencyRed),
        const SizedBox(height: 12),
        Text(
          'Staff sign-in',
          textAlign: TextAlign.center,
          style: TextStyle(color: AppColors.textPrimary, fontSize: 22, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 6),
        Text(
          'For ResQNet responders and administrators. Civilians do not need an account here.',
          textAlign: TextAlign.center,
          style: TextStyle(color: AppColors.textSecondary),
        ),
        if (context.watch<EmployeeSession>().signedOutReason case final reason?) ...[
          const SizedBox(height: 12),
          Semantics(
            liveRegion: true,
            child: Text(
              reason,
              key: const Key('employee-signed-out-reason'),
              textAlign: TextAlign.center,
              style: const TextStyle(color: AppColors.emergencyYellow),
            ),
          ),
        ],
        const SizedBox(height: 24),
        Form(
          key: _formKey,
          child: AutofillGroup(
            child: Column(
              children: [
                TextFormField(
                  key: const Key('employee-email'),
                  controller: _email,
                  keyboardType: TextInputType.emailAddress,
                  autofillHints: const [AutofillHints.username],
                  decoration: const InputDecoration(labelText: 'Work email', border: OutlineInputBorder()),
                  validator: (v) => (v == null || !v.contains('@')) ? 'Enter your work email' : null,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  key: const Key('employee-password'),
                  controller: _password,
                  obscureText: true,
                  autofillHints: const [AutofillHints.password],
                  decoration: const InputDecoration(labelText: 'Password', border: OutlineInputBorder()),
                  validator: (v) => (v == null || v.isEmpty) ? 'Enter your password' : null,
                  onFieldSubmitted: (_) => busy ? null : _submit(),
                ),
              ],
            ),
          ),
        ),
        if (_error != null) ...[
          const SizedBox(height: 12),
          Text(_error!, style: const TextStyle(color: AppColors.emergencyRed)),
        ],
        const SizedBox(height: 20),
        SizedBox(
          height: 48,
          child: ElevatedButton(
            onPressed: busy ? null : _submit,
            style: ElevatedButton.styleFrom(backgroundColor: AppColors.emergencyRed, foregroundColor: Colors.white),
            child: busy
                ? const SizedBox(
                    width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : const Text('Sign in'),
          ),
        ),
      ],
    );
  }
}

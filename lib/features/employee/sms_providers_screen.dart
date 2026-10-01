import 'package:flutter/material.dart';
import '../../core/constants/app_colors.dart';
import '../../core/employee/sms_provider_admin.dart';
import '../../core/network/api_exception.dart';
import 'sms_provider_form_screen.dart';

/// Lists configured SMS providers in fallback order and lets an employee
/// with SMS_PROVIDER_MANAGE add, edit, enable/disable, and test them.
class SmsProvidersScreen extends StatefulWidget {
  const SmsProvidersScreen({super.key, this.service});

  final SmsProviderAdminService? service;

  @override
  State<SmsProvidersScreen> createState() => _SmsProvidersScreenState();
}

class _SmsProvidersScreenState extends State<SmsProvidersScreen> {
  late final SmsProviderAdminService _service = widget.service ?? SmsProviderAdminService();
  SmsProviderOverview? _overview;
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final overview = await _service.load();
      if (mounted) setState(() => _overview = overview);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = describeApiError(e));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _snack(String message) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _openForm(SmsProviderType type, [ConfiguredSmsProvider? existing]) async {
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => SmsProviderFormScreen(type: type, existing: existing, service: _service)),
    );
    if (saved == true) await _load();
  }

  Future<void> _chooseProviderType() async {
    final overview = _overview;
    if (overview == null) return;
    final type = await showModalBottomSheet<SmsProviderType>(
      context: context,
      backgroundColor: AppColors.surfaceDark,
      isScrollControlled: true,
      builder: (sheetContext) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Text('Add SMS provider',
                  style: TextStyle(color: AppColors.textPrimary, fontSize: 18, fontWeight: FontWeight.bold)),
            ),
            for (final type in overview.catalog)
              ListTile(
                key: Key('catalog-${type.providerType}'),
                enabled: type.available,
                title: Text(type.displayName, style: TextStyle(color: AppColors.textPrimary)),
                subtitle: Text(
                  type.available ? type.coverage : 'Coming soon — ${type.notes}',
                  style: TextStyle(color: AppColors.textSecondary, fontSize: 12),
                ),
                trailing: type.available ? const Icon(Icons.add) : const Icon(Icons.schedule),
                onTap: type.available ? () => Navigator.pop(sheetContext, type) : null,
              ),
          ],
        ),
      ),
    );
    if (type != null) await _openForm(type);
  }

  Future<void> _setEnabled(ConfiguredSmsProvider provider, bool enabled) async {
    try {
      if (enabled) {
        await _service.update(provider.id, enabled: true);
      } else {
        await _service.disable(provider.id);
      }
      await _load();
    } on ApiException catch (e) {
      _snack(describeApiError(e));
    }
  }

  Future<void> _test(ConfiguredSmsProvider provider) async {
    await showDialog<void>(
      context: context,
      builder: (_) => _TestProviderDialog(provider: provider, service: _service),
    );
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.backgroundDark,
      appBar: AppBar(
        backgroundColor: AppColors.surfaceDark,
        foregroundColor: AppColors.textPrimary,
        title: const Text('SMS delivery providers'),
      ),
      floatingActionButton: _overview == null
          ? null
          : FloatingActionButton.extended(
              key: const Key('add-provider'),
              backgroundColor: AppColors.emergencyRed,
              foregroundColor: Colors.white,
              onPressed: _chooseProviderType,
              icon: const Icon(Icons.add),
              label: const Text('Add provider'),
            ),
      body: _content(),
    );
  }

  Widget _content() {
    if (_loading && _overview == null) return const Center(child: CircularProgressIndicator());
    if (_error != null && _overview == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(_error!, textAlign: TextAlign.center, style: TextStyle(color: AppColors.textSecondary)),
            const SizedBox(height: 12),
            OutlinedButton.icon(onPressed: _load, icon: const Icon(Icons.refresh), label: const Text('Retry')),
          ]),
        ),
      );
    }
    final overview = _overview!;
    final order = overview.fallbackOrder;
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
        children: [
          Card(
            color: AppColors.cardDark,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Delivery order', style: TextStyle(color: AppColors.textPrimary, fontWeight: FontWeight.bold)),
                const SizedBox(height: 6),
                Text(
                  order.isEmpty
                      ? 'No provider is enabled. Phone sign-in codes cannot be delivered until one is enabled.'
                      : 'Verification codes are sent through ${order.first.displayName} first. If a provider is '
                          'unavailable, does not serve the destination country, or rejects its own credentials, '
                          'the same code is retried through the next enabled provider (lower priority number first).',
                  style: TextStyle(color: order.isEmpty ? AppColors.emergencyRed : AppColors.textSecondary),
                ),
              ]),
            ),
          ),
          const SizedBox(height: 12),
          if (overview.providers.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 32),
              child: Text('No SMS providers configured yet.',
                  textAlign: TextAlign.center, style: TextStyle(color: AppColors.textSecondary)),
            ),
          for (final provider in overview.providers)
            _ProviderCard(
              provider: provider,
              type: overview.typeOf(provider.providerType),
              position: order.indexWhere((p) => p.id == provider.id),
              onEdit: () {
                final type = overview.typeOf(provider.providerType);
                if (type != null) _openForm(type, provider);
              },
              onToggle: (enabled) => _setEnabled(provider, enabled),
              onTest: () => _test(provider),
            ),
        ],
      ),
    );
  }
}

String describeApiError(ApiException e) {
  if (e.isNetworkError) return 'Could not reach the ResQNet server. Check your connection and try again.';
  if (e.statusCode == 401) return 'Your staff session has expired. Please sign in again.';
  if (e.statusCode == 403) return 'You do not have permission to manage SMS providers.';
  if (e.statusCode == 429) return 'Too many requests. Please wait before trying again.';
  return e.message;
}

class _ProviderCard extends StatelessWidget {
  const _ProviderCard({
    required this.provider,
    required this.type,
    required this.position,
    required this.onEdit,
    required this.onToggle,
    required this.onTest,
  });

  final ConfiguredSmsProvider provider;
  final SmsProviderType? type;
  final int position;
  final VoidCallback onEdit;
  final ValueChanged<bool> onToggle;
  final VoidCallback onTest;

  @override
  Widget build(BuildContext context) {
    final (label, color) = !provider.available
        ? ('Not available', AppColors.textSecondary)
        : !provider.enabled
            ? ('Disabled', AppColors.textSecondary)
            : position == 0
                ? ('Primary', AppColors.safeGreen)
                : ('Fallback $position', AppColors.accentBlue);
    return Card(
      key: Key('provider-${provider.id}'),
      color: AppColors.cardDark,
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(
              child: Text(provider.displayName,
                  style: TextStyle(color: AppColors.textPrimary, fontSize: 16, fontWeight: FontWeight.w600)),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(label, style: TextStyle(color: color, fontSize: 12)),
            ),
            Switch(
              value: provider.enabled,
              onChanged: provider.available || provider.enabled ? onToggle : null,
            ),
          ]),
          Text(
            '${type?.displayName ?? provider.providerType} · priority ${provider.priority}',
            style: TextStyle(color: AppColors.textSecondary, fontSize: 12),
          ),
          const SizedBox(height: 4),
          Text(_testSummary(), style: TextStyle(color: _testColor(), fontSize: 12)),
          if (!provider.credentialsReadable)
            const Padding(
              padding: EdgeInsets.only(top: 4),
              child: Text('Stored credentials cannot be read. Re-enter them.',
                  style: TextStyle(color: AppColors.emergencyRed, fontSize: 12)),
            ),
          Row(mainAxisAlignment: MainAxisAlignment.end, children: [
            TextButton.icon(
              onPressed: provider.available ? onTest : null,
              icon: const Icon(Icons.send_outlined, size: 18),
              label: const Text('Test'),
            ),
            TextButton.icon(
              onPressed: type == null ? null : onEdit,
              icon: const Icon(Icons.edit_outlined, size: 18),
              label: const Text('Configure'),
            ),
          ]),
        ]),
      ),
    );
  }

  String _testSummary() {
    final status = provider.lastTestStatus;
    if (status == null || provider.lastTestedAt == null) return 'Not tested yet';
    final when = provider.lastTestedAt!.toLocal().toString().substring(0, 16);
    if (status == 'success') return 'Last test succeeded · $when';
    return 'Last test failed (${status.replaceFirst('failed_', '')}) · $when';
  }

  Color _testColor() {
    final status = provider.lastTestStatus;
    if (status == null) return AppColors.textSecondary;
    return status == 'success' ? AppColors.safeGreen : AppColors.emergencyOrange;
  }
}

class _TestProviderDialog extends StatefulWidget {
  const _TestProviderDialog({required this.provider, required this.service});

  final ConfiguredSmsProvider provider;
  final SmsProviderAdminService service;

  @override
  State<_TestProviderDialog> createState() => _TestProviderDialogState();
}

class _TestProviderDialogState extends State<_TestProviderDialog> {
  final _phone = TextEditingController();
  bool _sending = false;
  SmsProviderTestResult? _result;
  String? _error;

  @override
  void dispose() {
    _phone.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    if (_phone.text.trim().length < 6) {
      setState(() => _error = 'Enter a phone number to receive the test message');
      return;
    }
    setState(() {
      _sending = true;
      _error = null;
      _result = null;
    });
    try {
      final result = await widget.service.test(widget.provider.id, _phone.text.trim());
      if (mounted) setState(() => _result = result);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = describeApiError(e));
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final result = _result;
    return AlertDialog(
      backgroundColor: AppColors.surfaceDark,
      title: Text('Test ${widget.provider.displayName}', style: TextStyle(color: AppColors.textPrimary)),
      content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(
          'Sends one real SMS through this provider only (no fallback). It contains no verification code '
          'and may be billed by the provider.',
          style: TextStyle(color: AppColors.textSecondary, fontSize: 13),
        ),
        const SizedBox(height: 12),
        TextField(
          key: const Key('test-phone'),
          controller: _phone,
          keyboardType: TextInputType.phone,
          decoration: const InputDecoration(labelText: 'Phone number', hintText: '+977 98XXXXXXXX'),
        ),
        if (_error != null) ...[
          const SizedBox(height: 8),
          Text(_error!, style: const TextStyle(color: AppColors.emergencyRed)),
        ],
        if (result != null) ...[
          const SizedBox(height: 12),
          Row(children: [
            Icon(result.success ? Icons.check_circle : Icons.error_outline,
                color: result.success ? AppColors.safeGreen : AppColors.emergencyOrange),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                result.providerCode == null ? result.message : '${result.message} (code ${result.providerCode})',
                style: TextStyle(color: AppColors.textPrimary),
              ),
            ),
          ]),
        ],
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
        ElevatedButton(
          key: const Key('send-test'),
          onPressed: _sending ? null : _send,
          child: _sending
              ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('Send test'),
        ),
      ],
    );
  }
}

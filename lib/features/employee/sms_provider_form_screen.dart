import 'package:flutter/material.dart';
import '../../core/constants/app_colors.dart';
import '../../core/employee/sms_provider_admin.dart';
import '../../core/network/api_exception.dart';
import 'sms_providers_screen.dart' show describeApiError;

/// Create or edit one SMS provider. Stored secrets are never shown: when
/// editing, a secret field left blank keeps the stored value, and typing a
/// new value replaces it.
class SmsProviderFormScreen extends StatefulWidget {
  const SmsProviderFormScreen({super.key, required this.type, this.existing, required this.service});

  final SmsProviderType type;
  final ConfiguredSmsProvider? existing;
  final SmsProviderAdminService service;

  @override
  State<SmsProviderFormScreen> createState() => _SmsProviderFormScreenState();
}

class _SmsProviderFormScreenState extends State<SmsProviderFormScreen> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _name;
  late final TextEditingController _priority;
  late bool _enabled;
  final Map<String, TextEditingController> _secrets = {};
  final Map<String, TextEditingController> _config = {};
  final Map<String, String?> _choices = {};
  bool _saving = false;
  String? _error;

  bool get _editing => widget.existing != null;

  @override
  void initState() {
    super.initState();
    final existing = widget.existing;
    _name = TextEditingController(text: existing?.displayName ?? widget.type.displayName);
    _priority = TextEditingController(text: '${existing?.priority ?? 100}');
    _enabled = existing?.enabled ?? false;
    for (final field in widget.type.credentialFields) {
      _secrets[field.key] = TextEditingController();
    }
    for (final field in widget.type.configurationFields) {
      final current = existing?.configuration[field.key]?.toString();
      if (field.options.isNotEmpty) {
        _choices[field.key] = field.options.contains(current) ? current : null;
      } else {
        _config[field.key] = TextEditingController(text: current ?? '');
      }
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _priority.dispose();
    for (final c in [..._secrets.values, ..._config.values]) {
      c.dispose();
    }
    super.dispose();
  }

  bool _secretStored(String key) => widget.existing?.configuredCredentialFields.contains(key) ?? false;

  Map<String, String> _configurationValues() => {
        for (final e in _config.entries) e.key: e.value.text.trim(),
        for (final e in _choices.entries) e.key: e.value ?? '',
      };

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    final credentials = {for (final e in _secrets.entries) e.key: e.value.text.trim()};
    try {
      if (_editing) {
        await widget.service.update(
          widget.existing!.id,
          displayName: _name.text.trim(),
          enabled: _enabled,
          priority: int.parse(_priority.text.trim()),
          credentials: credentials,
          configuration: _configurationValues(),
        );
      } else {
        await widget.service.create(
          providerType: widget.type.providerType,
          displayName: _name.text.trim(),
          enabled: _enabled,
          priority: int.parse(_priority.text.trim()),
          credentials: credentials,
          configuration: {
            for (final e in _configurationValues().entries)
              if (e.value.isNotEmpty) e.key: e.value,
          },
        );
      }
      if (mounted) Navigator.pop(context, true);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = describeApiError(e));
    } finally {
      for (final c in _secrets.values) {
        c.clear();
      }
      if (mounted) setState(() => _saving = false);
    }
  }

  InputDecoration _decoration(SmsProviderField field, {String? hint}) => InputDecoration(
        labelText: field.required ? '${field.label} *' : field.label,
        helperText: field.help,
        helperMaxLines: 2,
        hintText: hint,
        border: const OutlineInputBorder(),
      );

  @override
  Widget build(BuildContext context) {
    final type = widget.type;
    return Scaffold(
      backgroundColor: AppColors.backgroundDark,
      appBar: AppBar(
        backgroundColor: AppColors.surfaceDark,
        foregroundColor: AppColors.textPrimary,
        title: Text(_editing ? 'Configure ${type.displayName}' : 'Add ${type.displayName}'),
      ),
      body: SafeArea(
        child: Form(
          key: _formKey,
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Text(type.coverage, style: TextStyle(color: AppColors.textSecondary)),
              if (type.notes.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(type.notes, style: TextStyle(color: AppColors.textSecondary, fontSize: 12)),
              ],
              const SizedBox(height: 16),
              TextFormField(
                key: const Key('field-displayName'),
                controller: _name,
                decoration: const InputDecoration(labelText: 'Display name *', border: OutlineInputBorder()),
                validator: (v) => (v == null || v.trim().isEmpty) ? 'Required' : null,
              ),
              const SizedBox(height: 12),
              TextFormField(
                key: const Key('field-priority'),
                controller: _priority,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'Priority *',
                  helperText: 'Lower numbers are tried first',
                  border: OutlineInputBorder(),
                ),
                validator: (v) {
                  final value = int.tryParse(v?.trim() ?? '');
                  return value == null || value < 0 || value > 100000 ? 'Enter a number from 0 to 100000' : null;
                },
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text('Enabled', style: TextStyle(color: AppColors.textPrimary)),
                subtitle:
                    Text('Include this provider in OTP delivery', style: TextStyle(color: AppColors.textSecondary)),
                value: _enabled,
                onChanged: (v) => setState(() => _enabled = v),
              ),
              const SizedBox(height: 8),
              Text('Credentials', style: TextStyle(color: AppColors.textPrimary, fontWeight: FontWeight.bold)),
              Text(
                'Stored encrypted and never displayed again.',
                style: TextStyle(color: AppColors.textSecondary, fontSize: 12),
              ),
              const SizedBox(height: 8),
              for (final field in type.credentialFields) ...[
                TextFormField(
                  key: Key('secret-${field.key}'),
                  controller: _secrets[field.key],
                  obscureText: true,
                  enableSuggestions: false,
                  autocorrect: false,
                  decoration: _decoration(
                    field,
                    hint: _secretStored(field.key) ? '•••••••• saved — leave blank to keep' : null,
                  ),
                  validator: (v) => field.required && !_secretStored(field.key) && (v == null || v.trim().isEmpty)
                      ? 'Required'
                      : null,
                ),
                const SizedBox(height: 12),
              ],
              if (type.configurationFields.isNotEmpty) ...[
                Text('Configuration', style: TextStyle(color: AppColors.textPrimary, fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
              ],
              for (final field in type.configurationFields) ...[
                if (field.options.isNotEmpty)
                  DropdownButtonFormField<String>(
                    key: Key('config-${field.key}'),
                    initialValue: _choices[field.key],
                    decoration: _decoration(field),
                    items: [
                      if (!field.required) const DropdownMenuItem<String>(value: null, child: Text('Default')),
                      for (final option in field.options) DropdownMenuItem(value: option, child: Text(option)),
                    ],
                    onChanged: (v) => setState(() => _choices[field.key] = v),
                    validator: (v) => field.required && v == null ? 'Required' : null,
                  )
                else
                  TextFormField(
                    key: Key('config-${field.key}'),
                    controller: _config[field.key],
                    decoration: _decoration(field),
                    validator: (v) => field.required && (v == null || v.trim().isEmpty) ? 'Required' : null,
                  ),
                const SizedBox(height: 12),
              ],
              if (_error != null) ...[
                Text(_error!, style: const TextStyle(color: AppColors.emergencyRed)),
                const SizedBox(height: 12),
              ],
              SizedBox(
                height: 48,
                child: ElevatedButton(
                  key: const Key('save-provider'),
                  onPressed: _saving ? null : _save,
                  style:
                      ElevatedButton.styleFrom(backgroundColor: AppColors.emergencyRed, foregroundColor: Colors.white),
                  child: _saving
                      ? const SizedBox(
                          width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                      : Text(_editing ? 'Save changes' : 'Add provider'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

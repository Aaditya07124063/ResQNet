import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import '../../core/constants/app_colors.dart';
import 'ops_theme.dart';
import '../../core/employee/employee_session.dart';
import '../../core/employee/incident_workflow.dart';
import '../../core/network/api_exception.dart';

// Shared building blocks for the operations portal. Status is always shown
// as text plus an icon — never by colour alone.

final _absolute = DateFormat('yyyy-MM-dd HH:mm:ss');

/// Absolute local time, e.g. "2026-09-28 14:05:12".
String formatTimestamp(DateTime? t) => t == null ? '—' : _absolute.format(t.toLocal());

/// Compact age, e.g. "45 s", "12 min", "3 h", "2 d".
String formatAge(DateTime t, {DateTime? now}) {
  final d = (now ?? DateTime.now()).difference(t);
  if (d.isNegative || d.inSeconds < 60) return '${d.inSeconds.clamp(0, 59)} s';
  if (d.inMinutes < 60) return '${d.inMinutes} min';
  if (d.inHours < 48) return '${d.inHours} h';
  return '${d.inDays} d';
}

String shortId(String id) => id.length > 8 ? id.substring(0, 8) : id;

/// User-facing message for a failed request.
String describeApiError(Object error) {
  if (error is! ApiException) return 'Something went wrong. Try again.';
  if (error.isNetworkError) return 'Could not reach the ResQNet server. Check the connection and retry.';
  return switch (error.statusCode) {
    401 => 'Your staff session has ended. Please sign in again.',
    403 => 'You do not have permission for this. ${error.message}',
    404 => 'Not found. It may have been removed, or the link is wrong.',
    409 => error.message,
    400 => error.message,
    429 => 'Too many requests. Wait a moment and retry.',
    _ => error.statusCode >= 500 ? 'The server had a problem (${error.statusCode}). Try again shortly.' : error.message,
  };
}

/// Ends the portal session when the server says it is no longer valid.
/// Returns true when it did.
bool handleSessionError(BuildContext context, Object error) {
  if (error is ApiException && error.isUnauthorized) {
    context.read<EmployeeSession>().expire();
    return true;
  }
  return false;
}

class StatusChip extends StatelessWidget {
  const StatusChip({super.key, required this.label, required this.icon, required this.color, this.tooltip});

  final String label;
  final IconData icon;
  final Color color;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final chip = Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.16),
        border: Border.all(color: color.withValues(alpha: 0.7)),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              label,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: OpsColors.text, fontSize: 12, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
    return tooltip == null ? chip : Tooltip(message: tooltip!, child: chip);
  }
}

class ResponderStateChip extends StatelessWidget {
  const ResponderStateChip(this.state, {super.key});
  final String state;

  @override
  Widget build(BuildContext context) {
    final (icon, color) = switch (state) {
      'reported' => (Icons.priority_high, AppColors.emergencyRed),
      'acknowledged' => (Icons.visibility_outlined, AppColors.emergencyOrange),
      'assigned' => (Icons.person_pin_circle_outlined, AppColors.emergencyYellow),
      'en_route' => (Icons.directions_run, AppColors.accentBlue),
      'arrived' => (Icons.place_outlined, AppColors.accentBlue),
      'assisting' => (Icons.medical_services_outlined, AppColors.accentBlue),
      'resolved' => (Icons.check_circle_outline, AppColors.safeGreen),
      'stood_down' => (Icons.do_not_disturb_on_outlined, OpsColors.textMuted),
      _ => (Icons.help_outline, OpsColors.textMuted),
    };
    return StatusChip(label: responderStateLabel(state), icon: icon, color: color, tooltip: 'Responder state');
  }
}

class CivilianStateChip extends StatelessWidget {
  const CivilianStateChip(this.state, {super.key});
  final String state;

  @override
  Widget build(BuildContext context) {
    final (icon, color) = switch (state) {
      'active' => (Icons.sos, AppColors.emergencyRed),
      'safe' => (Icons.verified_user_outlined, AppColors.safeGreen),
      'cancelled' => (Icons.cancel_outlined, OpsColors.textMuted),
      _ => (Icons.help_outline, OpsColors.textMuted),
    };
    return StatusChip(
        label: civilianStateLabel(state), icon: icon, color: color, tooltip: 'Reported by the person / their device');
  }
}

/// Source label for alerts. OFFICIAL only ever comes from the server's source_type.
class SourceTypeChip extends StatelessWidget {
  const SourceTypeChip(this.sourceType, {super.key});
  final String sourceType;

  static String labelFor(String type) => switch (type) {
        'official' => 'OFFICIAL',
        'verified_partner' => 'VERIFIED PARTNER',
        'international_public' => 'PUBLIC INTERNATIONAL SOURCE',
        'resqnet_system' => 'RESQNET',
        'community' => 'COMMUNITY',
        'device_sensor' => 'DEVICE SENSOR',
        _ => type.toUpperCase(),
      };

  @override
  Widget build(BuildContext context) {
    final (icon, color) = switch (sourceType) {
      'official' => (Icons.account_balance_outlined, AppColors.accentBlue),
      'verified_partner' => (Icons.handshake_outlined, AppColors.safeGreen),
      'international_public' => (Icons.public, AppColors.emergencyYellow),
      'resqnet_system' => (Icons.shield_outlined, AppColors.emergencyOrange),
      'community' => (Icons.groups_outlined, OpsColors.textMuted),
      'device_sensor' => (Icons.sensors, OpsColors.textMuted),
      _ => (Icons.help_outline, OpsColors.textMuted),
    };
    return StatusChip(label: labelFor(sourceType), icon: icon, color: color, tooltip: 'Source type');
  }
}

/// "Last refreshed" line; warns when the data is older than [staleAfter].
class RefreshedStamp extends StatelessWidget {
  const RefreshedStamp({super.key, required this.refreshedAt, this.staleAfter = const Duration(minutes: 2), this.now});

  final DateTime? refreshedAt;
  final Duration staleAfter;
  final DateTime? now;

  @override
  Widget build(BuildContext context) {
    final at = refreshedAt;
    if (at == null) return const SizedBox.shrink();
    final stale = (now ?? DateTime.now()).difference(at) > staleAfter;
    return Semantics(
      label: stale
          ? 'Data may be out of date. Last refreshed ${formatTimestamp(at)}'
          : 'Last refreshed ${formatTimestamp(at)}',
      child: ExcludeSemantics(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(stale ? Icons.warning_amber_rounded : Icons.schedule,
                size: 16, color: stale ? AppColors.emergencyYellow : OpsColors.textMuted),
            const SizedBox(width: 4),
            Text(
              stale ? 'Possibly out of date · refreshed ${formatTimestamp(at)}' : 'Refreshed ${formatTimestamp(at)}',
              key: const Key('ops-refreshed-stamp'),
              style: TextStyle(color: stale ? AppColors.emergencyYellow : OpsColors.textMuted, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}

class MessagePanel extends StatelessWidget {
  const MessagePanel({super.key, required this.icon, required this.title, this.message, this.onRetry});

  final IconData icon;
  final String title;
  final String? message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Semantics(
            liveRegion: true,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 40, color: OpsColors.textMuted),
                const SizedBox(height: 12),
                Text(title,
                    textAlign: TextAlign.center,
                    style: TextStyle(color: OpsColors.text, fontSize: 18, fontWeight: FontWeight.w600)),
                if (message != null) ...[
                  const SizedBox(height: 8),
                  Text(message!, textAlign: TextAlign.center, style: TextStyle(color: OpsColors.textMuted)),
                ],
                if (onRetry != null) ...[
                  const SizedBox(height: 16),
                  OutlinedButton.icon(onPressed: onRetry, icon: const Icon(Icons.refresh), label: const Text('Retry')),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Error panel for a failed load, with the right icon for the failure kind.
class ErrorPanel extends StatelessWidget {
  const ErrorPanel({super.key, required this.error, this.onRetry});
  final Object error;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final e = error;
    final icon = e is ApiException && e.isNetworkError
        ? Icons.cloud_off
        : e is ApiException && e.statusCode == 403
            ? Icons.lock_outline
            : Icons.error_outline;
    final title = e is ApiException && e.statusCode == 403 ? 'Not permitted' : 'Could not load';
    return MessagePanel(icon: icon, title: title, message: describeApiError(error), onRetry: onRetry);
  }
}

/// Page header: title, optional subtitle and trailing actions.
class OpsPageHeader extends StatelessWidget {
  const OpsPageHeader({super.key, required this.title, this.subtitle, this.actions = const []});

  final String title;
  final Widget? subtitle;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
      child: Wrap(
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        runSpacing: 8,
        spacing: 16,
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Semantics(
                  header: true,
                  child:
                      Text(title, style: TextStyle(color: OpsColors.text, fontSize: 22, fontWeight: FontWeight.bold))),
              if (subtitle != null) ...[const SizedBox(height: 4), subtitle!],
            ],
          ),
          Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: actions),
        ],
      ),
    );
  }
}

/// Labelled value used in detail panels.
class FieldRow extends StatelessWidget {
  const FieldRow(this.label, this.value, {super.key, this.valueWidget});
  final String label;
  final String? value;
  final Widget? valueWidget;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: MergeSemantics(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(width: 170, child: Text(label, style: TextStyle(color: OpsColors.textMuted))),
            Expanded(
              child: valueWidget ?? Text(value ?? '—', style: TextStyle(color: OpsColors.text)),
            ),
          ],
        ),
      ),
    );
  }
}

class OpsCard extends StatelessWidget {
  const OpsCard({super.key, required this.child, this.title});
  final Widget child;
  final String? title;

  @override
  Widget build(BuildContext context) {
    return Card(
      color: OpsColors.card,
      margin: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (title != null) ...[
              Semantics(
                  header: true,
                  child:
                      Text(title!, style: TextStyle(color: OpsColors.text, fontSize: 16, fontWeight: FontWeight.w600))),
              const SizedBox(height: 8),
            ],
            // Card text (IDs, timestamps) can be selected and copied as a
            // whole, without making each value a separate tiny focus stop.
            SelectionArea(child: child),
          ],
        ),
      ),
    );
  }
}

Future<bool> confirmAction(BuildContext context,
    {required String title, required String message, required String confirmLabel}) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(dialogContext, true), child: Text(confirmLabel)),
      ],
    ),
  );
  return ok == true;
}

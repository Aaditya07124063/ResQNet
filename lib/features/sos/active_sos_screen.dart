import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/constants/app_colors.dart';
import '../../core/services/sos_service.dart';
import 'active_sos_view.dart';
import 'sos_actions.dart';
import 'sos_status.dart';

/// Full detail of the user's own active SOS (also the target of an "your
/// SOS" notification tap). Shows the same live status as the Home card,
/// plus what was sent.
class ActiveSosScreen extends StatelessWidget {
  const ActiveSosScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final alert = context.watch<SosService>().activeAlert;
    return Scaffold(
      backgroundColor: AppColors.backgroundDark,
      appBar: AppBar(
        backgroundColor: AppColors.surfaceDark,
        title: Text('Your SOS', style: TextStyle(color: AppColors.textPrimary, fontWeight: FontWeight.bold)),
      ),
      body: alert == null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  'No SOS is active.',
                  style: TextStyle(color: AppColors.textSecondary, fontSize: 16),
                ),
              ),
            )
          : ActiveSosStatusBuilder(
              alert: alert,
              builder: (context, elapsed, lines) => ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  Text(
                    'SOS active for ${formatElapsed(elapsed)}',
                    style: const TextStyle(color: AppColors.emergencyRed, fontSize: 22, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Started ${alert.timestamp.toLocal().toString().substring(0, 19)}',
                    style: TextStyle(color: AppColors.textSecondary),
                  ),
                  const SizedBox(height: 16),
                  _Section(
                    title: 'What was sent',
                    children: [
                      _Field('Emergency type', alert.category.name),
                      _Field('Message', alert.message),
                    ],
                  ),
                  _Section(
                    title: 'Delivery',
                    children: [for (final line in lines) SosStatusRow(line: line)],
                  ),
                  _Section(
                    title: 'SMS',
                    children: [
                      Text(
                        'An SMS to your trusted contacts and local helplines was opened in your messaging app. '
                        'It is only sent if you pressed send there.',
                        style: TextStyle(color: AppColors.textSecondary),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  ElevatedButton.icon(
                    onPressed: () => confirmAndCancelSos(context),
                    icon: const Icon(Icons.check_circle),
                    label: const Text("I'm safe — end SOS"),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.safeGreen,
                      foregroundColor: Colors.white,
                      minimumSize: const Size.fromHeight(56),
                    ),
                  ),
                ],
              ),
            ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Card(
      color: AppColors.cardDark,
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Semantics(
              header: true,
              child: Text(title,
                  style: TextStyle(color: AppColors.textPrimary, fontWeight: FontWeight.bold, fontSize: 16)),
            ),
            const SizedBox(height: 8),
            ...children,
          ],
        ),
      ),
    );
  }
}

class _Field extends StatelessWidget {
  const _Field(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Text.rich(
        TextSpan(children: [
          TextSpan(text: '$label: ', style: TextStyle(color: AppColors.textSecondary)),
          TextSpan(text: value, style: TextStyle(color: AppColors.textPrimary)),
        ]),
      ),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import '../../core/services/location_log_service.dart';

class LocationTrailScreen extends StatelessWidget {
  const LocationTrailScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final service = context.watch<LocationLogService>();
    final fmt = DateFormat('dd MMM, hh:mm a');

    return Scaffold(
      appBar: AppBar(
        title: const Text('Location Trail (24h)'),
        actions: [
          if (service.trail.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: 'Clear trail',
              onPressed: () => service.clear(),
            ),
        ],
      ),
      body: Column(
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            color: Colors.blue.withOpacity(0.1),
            child: Text(
              'Your location is saved on this phone every 5 minutes. '
              'If the phone dies, family can charge it, open this screen, '
              'and see exactly where you were — no internet needed.',
              style: TextStyle(fontSize: 13, color: Colors.blue.shade800),
            ),
          ),
          Expanded(
            child: service.trail.isEmpty
                ? const Center(child: Text('No locations logged yet'))
                : ListView.builder(
                    itemCount: service.trail.length,
                    itemBuilder: (_, i) {
                      final e = service.trail[i];
                      final coords =
                          '${(e['lat'] as num).toStringAsFixed(5)}, ${(e['lng'] as num).toStringAsFixed(5)}';
                      return ListTile(
                        leading: Icon(
                          i == 0 ? Icons.my_location : Icons.location_on,
                          color: i == 0 ? Colors.green : Colors.grey,
                        ),
                        title: Text(coords),
                        subtitle: Text(
                          '${fmt.format(DateTime.parse(e['time']))}${i == 0 ? '  •  LATEST' : ''}',
                        ),
                        trailing: IconButton(
                          icon: const Icon(Icons.copy, size: 18),
                          onPressed: () {
                            Clipboard.setData(ClipboardData(text: coords));
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                  content: Text('Coordinates copied')),
                            );
                          },
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
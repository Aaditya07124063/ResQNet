import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';
import '../../core/models/emergency_message.dart';
import '../../core/services/mesh_service.dart';
import '../../core/services/profile_service.dart';

class MissingPersonScreen extends StatefulWidget {
  const MissingPersonScreen({super.key});

  @override
  State<MissingPersonScreen> createState() => _MissingPersonScreenState();
}

class _MissingPersonScreenState extends State<MissingPersonScreen> {
  static const prefix = 'MISSING|';

  final _nameController = TextEditingController();
  final _ageController = TextEditingController();
  final _descController = TextEditingController();
  final _lastSeenController = TextEditingController();

  @override
  void dispose() {
    _nameController.dispose();
    _ageController.dispose();
    _descController.dispose();
    _lastSeenController.dispose();
    super.dispose();
  }

  Future<void> _broadcast() async {
    if (_nameController.text.trim().isEmpty) return;

    double? lat, lng;
    try {
      final pos = await Geolocator.getLastKnownPosition();
      lat = pos?.latitude;
      lng = pos?.longitude;
    } catch (_) {}

    if (!mounted) return;
    final profile = context.read<ProfileService>();
    final reporter = profile.name.isNotEmpty ? profile.name : 'Anonymous';

    final payload = jsonEncode({
      'name': _nameController.text.trim(),
      'age': _ageController.text.trim(),
      'description': _descController.text.trim(),
      'lastSeen': _lastSeenController.text.trim(),
      'reporter': reporter,
      'time': DateTime.now().toIso8601String(),
    });

    final message = EmergencyMessage(
      id: const Uuid().v4(),
      senderId: reporter,
      senderName: reporter,
      message: '$prefix$payload',
      type: EmergencyType.rescue,
      priority: PriorityLevel.high,
      latitude: lat,
      longitude: lng,
      timestamp: DateTime.now(),
    );

    await context.read<MeshService>().broadcastMessage(message);

    if (mounted) {
      _nameController.clear();
      _ageController.clear();
      _descController.clear();
      _lastSeenController.clear();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('🔍 Missing person alert broadcast to nearby devices'),
          backgroundColor: Colors.orange,
        ),
      );
    }
  }

  List<Map<String, dynamic>> _receivedReports(MeshService mesh) {
    final reports = <Map<String, dynamic>>[];
    for (final m in mesh.messages) {
      if (m.message.startsWith(prefix)) {
        try {
          reports.add(jsonDecode(m.message.substring(prefix.length)));
        } catch (_) {}
      }
    }
    return reports;
  }

  @override
  Widget build(BuildContext context) {
    final mesh = context.watch<MeshService>();
    final reports = _receivedReports(mesh);

    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Missing Person'),
          bottom: TabBar(tabs: [
            const Tab(text: 'REPORT'),
            Tab(text: 'ALERTS (${reports.length})'),
          ]),
        ),
        body: TabBarView(
          children: [
            SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  TextField(
                    controller: _nameController,
                    decoration: const InputDecoration(
                        labelText: 'Name *', prefixIcon: Icon(Icons.person)),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _ageController,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                        labelText: 'Age', prefixIcon: Icon(Icons.cake)),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _descController,
                    maxLines: 2,
                    decoration: const InputDecoration(
                      labelText: 'Description',
                      hintText: 'Height, clothing, features...',
                      prefixIcon: Icon(Icons.description),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _lastSeenController,
                    decoration: const InputDecoration(
                      labelText: 'Last seen location',
                      hintText: 'e.g. Near bus stand, Market road',
                      prefixIcon: Icon(Icons.location_on),
                    ),
                  ),
                  const SizedBox(height: 24),
                  SizedBox(
                    width: double.infinity,
                    height: 52,
                    child: ElevatedButton.icon(
                      onPressed: _broadcast,
                      icon: const Icon(Icons.campaign, color: Colors.white),
                      label: const Text('BROADCAST ALERT',
                          style: TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold)),
                      style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.orange),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Alert is relayed device-to-device over the mesh — no internet needed.',
                    textAlign: TextAlign.center,
                    style:
                        TextStyle(fontSize: 12, color: Colors.grey.shade600),
                  ),
                ],
              ),
            ),
            reports.isEmpty
                ? const Center(child: Text('No missing person alerts nearby'))
                : ListView.builder(
                    padding: const EdgeInsets.all(12),
                    itemCount: reports.length,
                    itemBuilder: (_, i) {
                      final r = reports[i];
                      return Card(
                        margin: const EdgeInsets.only(bottom: 10),
                        child: ListTile(
                          leading: const CircleAvatar(
                            backgroundColor: Colors.orange,
                            child: Icon(Icons.person_search,
                                color: Colors.white),
                          ),
                          title: Text(
                              '${r['name']}${(r['age'] ?? '').toString().isNotEmpty ? ', ${r['age']} yrs' : ''}',
                              style: const TextStyle(
                                  fontWeight: FontWeight.bold)),
                          subtitle: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              if ((r['description'] ?? '')
                                  .toString()
                                  .isNotEmpty)
                                Text(r['description']),
                              if ((r['lastSeen'] ?? '').toString().isNotEmpty)
                                Text('Last seen: ${r['lastSeen']}'),
                              Text('Reported by: ${r['reporter'] ?? '?'}',
                                  style: const TextStyle(fontSize: 12)),
                            ],
                          ),
                          isThreeLine: true,
                        ),
                      );
                    },
                  ),
          ],
        ),
      ),
    );
  }
}
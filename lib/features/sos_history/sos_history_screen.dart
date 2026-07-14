import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../../core/constants/app_colors.dart';
import '../../core/models/emergency_message.dart';

class SosHistoryScreen extends StatelessWidget {
  const SosHistoryScreen({super.key});

  String get _uid => FirebaseAuth.instance.currentUser?.uid ?? '';

  Stream<QuerySnapshot> get _stream => FirebaseFirestore.instance
      .collection('sos_history')
      .doc(_uid)
      .collection('messages')
      .orderBy('timestamp', descending: true)
      .snapshots();

  Future<void> _delete(BuildContext context, String docId) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppColors.surfaceDark,
        title: const Text('Delete Entry',
            style: TextStyle(color: AppColors.textPrimary)),
        content: const Text('Remove this SOS from history?',
            style: TextStyle(color: AppColors.textSecondary)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel',
                style: TextStyle(color: AppColors.textSecondary)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete',
                style: TextStyle(color: AppColors.emergencyRed)),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await FirebaseFirestore.instance
          .collection('sos_history')
          .doc(_uid)
          .collection('messages')
          .doc(docId)
          .delete();
    }
  }

  Future<void> _clearAll(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppColors.surfaceDark,
        title: const Text('Clear All History',
            style: TextStyle(color: AppColors.textPrimary)),
        content: const Text('Delete all SOS history? This cannot be undone.',
            style: TextStyle(color: AppColors.textSecondary)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel',
                style: TextStyle(color: AppColors.textSecondary)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Clear All',
                style: TextStyle(color: AppColors.emergencyRed)),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      final snap = await FirebaseFirestore.instance
          .collection('sos_history')
          .doc(_uid)
          .collection('messages')
          .get();
      for (final doc in snap.docs) {
        await doc.reference.delete();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.backgroundDark,
      appBar: AppBar(
        backgroundColor: AppColors.surfaceDark,
        title: const Text('SOS History',
            style: TextStyle(
                color: AppColors.textPrimary, fontWeight: FontWeight.bold)),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: AppColors.textPrimary),
          onPressed: () => Navigator.pop(context),
        ),
        actions: [
          IconButton(
            icon:
                const Icon(Icons.delete_sweep, color: AppColors.emergencyRed),
            tooltip: 'Clear all',
            onPressed: () => _clearAll(context),
          ),
        ],
      ),
      body: StreamBuilder<QuerySnapshot>(
        stream: _stream,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(
              child:
                  CircularProgressIndicator(color: AppColors.emergencyRed),
            );
          }

          final docs = snapshot.data?.docs ?? [];

          if (docs.isEmpty) {
            return const Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.history,
                      color: AppColors.textSecondary, size: 64),
                  SizedBox(height: 16),
                  Text('No SOS history yet',
                      style: TextStyle(
                          color: AppColors.textPrimary,
                          fontSize: 18,
                          fontWeight: FontWeight.bold)),
                  SizedBox(height: 8),
                  Text('Your sent SOS alerts will appear here',
                      style: TextStyle(
                          color: AppColors.textSecondary, fontSize: 14)),
                ],
              ),
            );
          }

          return ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: docs.length,
            itemBuilder: (_, i) {
              final doc = docs[i];
              final data = doc.data() as Map<String, dynamic>;
              final msg = EmergencyMessage.fromJson(data);

              return Dismissible(
                key: Key(doc.id),
                direction: DismissDirection.endToStart,
                background: Container(
                  alignment: Alignment.centerRight,
                  padding: const EdgeInsets.only(right: 20),
                  decoration: BoxDecoration(
                    color: AppColors.emergencyRed.withOpacity(0.2),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Icon(Icons.delete,
                      color: AppColors.emergencyRed),
                ),
                confirmDismiss: (_) async {
                  await _delete(context, doc.id);
                  return false;
                },
                child: Card(
                  color: AppColors.cardDark,
                  margin: const EdgeInsets.only(bottom: 12),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                  child: Row(
                    children: [
                      Container(
                        width: 4,
                        height: 90,
                        decoration: BoxDecoration(
                          color: msg.priorityColor,
                          borderRadius: const BorderRadius.only(
                            topLeft: Radius.circular(12),
                            bottomLeft: Radius.circular(12),
                          ),
                        ),
                      ),
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Icon(msg.typeIcon,
                                      color: msg.priorityColor, size: 18),
                                  const SizedBox(width: 6),
                                  Expanded(
                                    child: Text(
                                      msg.type.name.toUpperCase(),
                                      style: TextStyle(
                                          color: msg.priorityColor,
                                          fontWeight: FontWeight.bold,
                                          fontSize: 13),
                                    ),
                                  ),
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 8, vertical: 2),
                                    decoration: BoxDecoration(
                                      color: msg.priorityColor
                                          .withOpacity(0.15),
                                      borderRadius:
                                          BorderRadius.circular(8),
                                      border: Border.all(
                                          color: msg.priorityColor
                                              .withOpacity(0.5)),
                                    ),
                                    child: Text(
                                      msg.priority.name.toUpperCase(),
                                      style: TextStyle(
                                          color: msg.priorityColor,
                                          fontSize: 10,
                                          fontWeight: FontWeight.bold),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 6),
                              Text(
                                msg.message,
                                style: const TextStyle(
                                    color: AppColors.textPrimary,
                                    fontSize: 13),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                              const SizedBox(height: 6),
                              Row(
                                children: [
                                  const Icon(Icons.access_time,
                                      size: 12,
                                      color: AppColors.textSecondary),
                                  const SizedBox(width: 4),
                                  Text(
                                    DateFormat('dd MMM yyyy  HH:mm')
                                        .format(msg.timestamp),
                                    style: const TextStyle(
                                        fontSize: 11,
                                        color: AppColors.textSecondary),
                                  ),
                                  if (msg.latitude != null) ...[
                                    const SizedBox(width: 8),
                                    const Icon(Icons.location_on,
                                        size: 12,
                                        color: AppColors.accentBlue),
                                    const SizedBox(width: 2),
                                    const Text('GPS attached',
                                        style: TextStyle(
                                            fontSize: 11,
                                            color: AppColors.accentBlue)),
                                  ],
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}
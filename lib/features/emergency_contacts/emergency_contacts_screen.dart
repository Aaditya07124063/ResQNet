import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../core/constants/app_colors.dart';
import '../../core/services/communication_service.dart';
import '../../core/services/emergency_contacts_service.dart';
import '../../core/services/trusted_contacts_service.dart';
import '../communication/chat_screen.dart';

class EmergencyContactsScreen extends StatefulWidget {
  const EmergencyContactsScreen({super.key});

  @override
  State<EmergencyContactsScreen> createState() =>
      _EmergencyContactsScreenState();
}

class _EmergencyContactsScreenState extends State<EmergencyContactsScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<EmergencyContactsService>().detectAndLoadContacts();
      context.read<TrustedContactsService>().load();
    });
  }

  Future<void> _call(String number) async {
    final uri = Uri(scheme: 'tel', path: number);
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  /// Only reachable for a trusted contact the backend has actually linked
  /// to a ResQNet account (`contactUserId` non-null) — messaging someone
  /// who isn't a ResQNet user isn't possible (Section 1: no external
  /// messaging platform), so this button never appears for them at all.
  Future<void> _messageContact(TrustedContact contact) async {
    if (contact.contactUserId == null) return;
    try {
      final conversationId = await context
          .read<CommunicationService>()
          .startConversationWith(contact.contactUserId!);
      if (!mounted) return;
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => ChatScreen(
            conversationId: conversationId,
            otherParticipantName: contact.name,
            otherParticipantId: contact.contactUserId,
          ),
        ),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not start a conversation. Please try again.')),
        );
      }
    }
  }

  Future<void> _addTrustedContact() async {
    final nameController = TextEditingController();
    final relationController = TextEditingController();
    final phoneController = TextEditingController();

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: AppColors.surfaceDark,
        title: Text('Add Trusted Contact',
            style: TextStyle(color: AppColors.textPrimary)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameController,
              style: TextStyle(color: AppColors.textPrimary),
              decoration: const InputDecoration(hintText: 'Name'),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: relationController,
              style: TextStyle(color: AppColors.textPrimary),
              decoration:
                  const InputDecoration(hintText: 'Relation (e.g. Father)'),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: phoneController,
              keyboardType: TextInputType.phone,
              style: TextStyle(color: AppColors.textPrimary),
              decoration:
                  const InputDecoration(hintText: 'Phone number, e.g. +91XXXXXXXXXX'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Add'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;
    if (nameController.text.trim().isEmpty ||
        phoneController.text.trim().isEmpty) {
      return;
    }

    await context.read<TrustedContactsService>().addContact(
          name: nameController.text.trim(),
          relation: relationController.text.trim().isEmpty
              ? 'Contact'
              : relationController.text.trim(),
          phone: phoneController.text.trim(),
        );
  }

  @override
  Widget build(BuildContext context) {
    final service = context.watch<EmergencyContactsService>();
    final trusted = context.watch<TrustedContactsService>();

    return Scaffold(
      backgroundColor: AppColors.backgroundDark,
      appBar: AppBar(
        backgroundColor: AppColors.surfaceDark,
        title: Text(
          'Emergency Contacts',
          style: TextStyle(
              color: AppColors.textPrimary, fontWeight: FontWeight.bold),
        ),
        leading: IconButton(
          icon: Icon(Icons.arrow_back, color: AppColors.textPrimary),
          onPressed: () => Navigator.pop(context),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.my_location, color: AppColors.primaryOrange),
            tooltip: 'Detect my location',
            onPressed: () => service.detectAndLoadContacts(),
          ),
        ],
      ),
      body: ListView(
        children: [
          // --- Trusted contacts (parents/relatives) ---
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'Trusted Contacts',
                    style: TextStyle(
                        color: AppColors.textPrimary,
                        fontWeight: FontWeight.bold,
                        fontSize: 16),
                  ),
                ),
                TextButton.icon(
                  onPressed: _addTrustedContact,
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('Add'),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              'Notified by SMS the moment you send an SOS — online or offline.',
              style: TextStyle(color: AppColors.textSecondary, fontSize: 12),
            ),
          ),
          const SizedBox(height: 8),
          if (trusted.contacts.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Text(
                'No trusted contacts added yet.',
                style: TextStyle(color: AppColors.textSecondary, fontSize: 13),
              ),
            )
          else
            ...trusted.contacts.map((c) => Card(
                  color: AppColors.cardDark,
                  margin:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                  child: ListTile(
                    leading: CircleAvatar(
                      backgroundColor: AppColors.accentBlue.withOpacity(0.15),
                      child: const Icon(Icons.person, color: AppColors.accentBlue),
                    ),
                    title: Text(c.name,
                        style: TextStyle(
                            color: AppColors.textPrimary,
                            fontWeight: FontWeight.bold)),
                    subtitle: Text('${c.relation} • ${c.phone}',
                        style: TextStyle(
                            color: AppColors.textSecondary, fontSize: 12)),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (c.contactUserId != null)
                          IconButton(
                            icon: Icon(Icons.chat_bubble_outline,
                                color: AppColors.connectedGreen),
                            tooltip: 'Message on ResQNet',
                            onPressed: () => _messageContact(c),
                          ),
                        IconButton(
                          icon: Icon(Icons.delete_outline,
                              color: AppColors.textSecondary),
                          onPressed: () => context
                              .read<TrustedContactsService>()
                              .removeContact(c.id),
                        ),
                      ],
                    ),
                  ),
                )),
          const Divider(height: 24, color: Colors.white12),

          // --- National hotlines (police/fire/ambulance/disaster mgmt) ---
          if (service.isLoading)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: Center(
                child: Column(
                  children: [
                    const CircularProgressIndicator(
                        color: AppColors.primaryOrange),
                    const SizedBox(height: 12),
                    Text('Detecting your location...',
                        style: TextStyle(color: AppColors.textSecondary)),
                  ],
                ),
              ),
            )
          else ...[
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              color: AppColors.cardDark,
              child: Row(
                children: [
                  const Icon(Icons.location_on,
                      color: AppColors.primaryOrange, size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      service.countryName.isNotEmpty
                          ? 'Showing hotlines for: ${service.countryName}'
                          : 'International emergency numbers',
                      style: TextStyle(
                          color: AppColors.textPrimary, fontSize: 14),
                    ),
                  ),
                ],
              ),
            ),
            Container(
              margin: const EdgeInsets.all(16),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.emergencyRed.withOpacity(0.1),
                borderRadius: BorderRadius.circular(8),
                border:
                    Border.all(color: AppColors.emergencyRed.withOpacity(0.3)),
              ),
              child: const Row(
                children: [
                  Icon(Icons.warning_amber,
                      color: AppColors.emergencyRed, size: 18),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Use these numbers only for genuine emergencies.',
                      style:
                          TextStyle(color: AppColors.emergencyRed, fontSize: 12),
                    ),
                  ),
                ],
              ),
            ),
            ...service.contacts.map((contact) => Card(
                  color: AppColors.cardDark,
                  margin:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                  child: ListTile(
                    leading: CircleAvatar(
                      backgroundColor: AppColors.emergencyRed.withOpacity(0.15),
                      child:
                          const Icon(Icons.phone, color: AppColors.emergencyRed),
                    ),
                    title: Text(
                      contact.name,
                      style: TextStyle(
                          color: AppColors.textPrimary,
                          fontWeight: FontWeight.bold),
                    ),
                    subtitle: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(contact.description,
                            style: TextStyle(
                                color: AppColors.textSecondary, fontSize: 12)),
                        Text(contact.number,
                            style: const TextStyle(
                                color: AppColors.accentBlue,
                                fontSize: 13,
                                fontWeight: FontWeight.bold)),
                      ],
                    ),
                    trailing: ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.emergencyRed,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 8),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8)),
                      ),
                      icon: const Icon(Icons.call, size: 16),
                      label: const Text('Call', style: TextStyle(fontSize: 12)),
                      onPressed: () => _call(contact.number),
                    ),
                    isThreeLine: true,
                  ),
                )),
          ],
          const SizedBox(height: 16),
        ],
      ),
    );
  }
}

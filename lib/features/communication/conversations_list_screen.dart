import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import '../../core/constants/app_colors.dart';
import '../../core/models/conversation.dart';
import '../../core/models/message.dart';
import '../../core/services/communication_service.dart';
import 'chat_screen.dart';

/// A. Conversations list (Section 16) — every conversation the signed-in
/// user participates in, most recently active first, with the other
/// participant, a last-message preview, and an unread indicator.
class ConversationsListScreen extends StatefulWidget {
  const ConversationsListScreen({super.key});

  @override
  State<ConversationsListScreen> createState() => _ConversationsListScreenState();
}

class _ConversationsListScreenState extends State<ConversationsListScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<CommunicationService>().loadConversations();
    });
  }

  String _previewText(ConversationLastMessage message) {
    if (message.messageType == MessageType.location) return '📍 Location shared';
    final body = message.body ?? '';
    return body.length > 60 ? '${body.substring(0, 60)}…' : body;
  }

  String _timeLabel(DateTime dt) {
    final now = DateTime.now();
    final isToday = now.year == dt.year && now.month == dt.month && now.day == dt.day;
    return isToday ? DateFormat.jm().format(dt) : DateFormat.MMMd().format(dt);
  }

  @override
  Widget build(BuildContext context) {
    final comms = context.watch<CommunicationService>();

    return Scaffold(
      backgroundColor: AppColors.backgroundDark,
      appBar: AppBar(
        backgroundColor: AppColors.surfaceDark,
        title: Text('Messages',
            style: TextStyle(color: AppColors.textPrimary, fontWeight: FontWeight.bold)),
        leading: IconButton(
          icon: Icon(Icons.arrow_back, color: AppColors.textPrimary),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: RefreshIndicator(
        onRefresh: () => context.read<CommunicationService>().loadConversations(),
        child: comms.loadingConversations && comms.conversations.isEmpty
            ? const Center(child: CircularProgressIndicator())
            : comms.conversations.isEmpty
                ? ListView(
                    children: [
                      SizedBox(height: MediaQuery.of(context).size.height * 0.3),
                      Icon(Icons.chat_bubble_outline, size: 48, color: AppColors.textSecondary),
                      const SizedBox(height: 12),
                      Center(
                        child: Text('No conversations yet',
                            style: TextStyle(color: AppColors.textSecondary)),
                      ),
                      const SizedBox(height: 6),
                      Center(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 32),
                          child: Text(
                            'Message a trusted contact who also uses ResQNet from Emergency Contacts.',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: AppColors.textSecondary, fontSize: 12),
                          ),
                        ),
                      ),
                    ],
                  )
                : ListView.separated(
                    itemCount: comms.conversations.length,
                    separatorBuilder: (_, __) => Divider(height: 1, color: AppColors.lowGrey.withValues(alpha: 0.2)),
                    itemBuilder: (context, index) {
                      final conversation = comms.conversations[index];
                      final name = conversation.otherParticipantName ?? 'ResQNet user';
                      final hasUnread = conversation.unreadCount > 0;
                      return ListTile(
                        leading: CircleAvatar(
                          backgroundColor: AppColors.accentBlue.withValues(alpha: 0.15),
                          child: Text(
                            name.isNotEmpty ? name[0].toUpperCase() : '?',
                            style: TextStyle(color: AppColors.accentBlue, fontWeight: FontWeight.bold),
                          ),
                        ),
                        title: Text(name,
                            style: TextStyle(
                                color: AppColors.textPrimary,
                                fontWeight: hasUnread ? FontWeight.bold : FontWeight.w500)),
                        subtitle: Text(
                          conversation.lastMessage != null
                              ? _previewText(conversation.lastMessage!)
                              : 'Say hello',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: hasUnread ? AppColors.textPrimary : AppColors.textSecondary,
                            fontWeight: hasUnread ? FontWeight.w600 : FontWeight.normal,
                          ),
                        ),
                        trailing: Column(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(_timeLabel(conversation.updatedAt),
                                style: TextStyle(color: AppColors.textSecondary, fontSize: 11)),
                            if (hasUnread) ...[
                              const SizedBox(height: 4),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                                decoration: BoxDecoration(
                                  color: AppColors.emergencyRed,
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: Text(
                                  '${conversation.unreadCount}',
                                  style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold),
                                ),
                              ),
                            ],
                          ],
                        ),
                        onTap: () => Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => ChatScreen(
                              conversationId: conversation.id,
                              otherParticipantName: name,
                              otherParticipantId: conversation.otherParticipantId,
                            ),
                          ),
                        ),
                      );
                    },
                  ),
      ),
    );
  }
}

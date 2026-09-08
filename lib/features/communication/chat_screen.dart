import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import '../../core/constants/app_colors.dart';
import '../../core/models/message.dart';
import '../../core/services/communication_service.dart';
import '../../core/services/location_service.dart';

/// B. Chat screen (Section 16) — messages, sending/delivered/read state,
/// retry state, and a composer supporting text and native location
/// messages (Section 19). This is normal ResQNet-to-ResQNet
/// communication — an SOS is never rendered here as an ordinary bubble
/// (Section 17); the emergency domain has its own screens entirely.
class ChatScreen extends StatefulWidget {
  final String conversationId;
  final String otherParticipantName;
  /// Used only to tell "mine" from "theirs" for a confirmed (server-echoed)
  /// message — in a 1:1 conversation, any sender who isn't the other
  /// participant must be the current user, with no separate "my own user
  /// id" concept needed on the client at all.
  final String? otherParticipantId;

  const ChatScreen({
    super.key,
    required this.conversationId,
    required this.otherParticipantName,
    this.otherParticipantId,
  });

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _textController = TextEditingController();
  final _scrollController = ScrollController();
  bool _sharingLocation = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final comms = context.read<CommunicationService>();
      await comms.loadMessages(widget.conversationId);
      final messages = comms.messagesFor(widget.conversationId);
      if (messages.isNotEmpty) {
        await comms.markRead(widget.conversationId, messages.last.id);
      }
    });
  }

  @override
  void dispose() {
    _textController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _sendText() {
    final text = _textController.text.trim();
    if (text.isEmpty) return;
    context.read<CommunicationService>().sendText(widget.conversationId, text);
    _textController.clear();
  }

  Future<void> _shareLocation() async {
    setState(() => _sharingLocation = true);
    try {
      final position = await context.read<LocationService>().getCurrentLocation();
      if (position == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Location is not available right now')),
          );
        }
        return;
      }
      if (!mounted) return;
      await context.read<CommunicationService>().sendLocation(
            widget.conversationId,
            latitude: position.latitude,
            longitude: position.longitude,
            accuracyM: position.accuracy,
          );
    } finally {
      if (mounted) setState(() => _sharingLocation = false);
    }
  }

  Widget _deliveryIcon(MessageDeliveryState state) {
    switch (state) {
      case MessageDeliveryState.pending:
        return SizedBox(
          width: 12,
          height: 12,
          child: CircularProgressIndicator(strokeWidth: 1.5, color: AppColors.textSecondary),
        );
      case MessageDeliveryState.failed:
        return Icon(Icons.error_outline, size: 14, color: AppColors.emergencyRed);
      case MessageDeliveryState.read:
        return Icon(Icons.done_all, size: 14, color: AppColors.accentBlue);
      case MessageDeliveryState.delivered:
        return Icon(Icons.done_all, size: 14, color: AppColors.textSecondary);
      case MessageDeliveryState.sent:
        return Icon(Icons.done, size: 14, color: AppColors.textSecondary);
    }
  }

  @override
  Widget build(BuildContext context) {
    final comms = context.watch<CommunicationService>();
    final messages = comms.messagesFor(widget.conversationId);

    return Scaffold(
      backgroundColor: AppColors.backgroundDark,
      appBar: AppBar(
        backgroundColor: AppColors.surfaceDark,
        title: Text(widget.otherParticipantName,
            style: TextStyle(color: AppColors.textPrimary, fontWeight: FontWeight.bold)),
        leading: IconButton(
          icon: Icon(Icons.arrow_back, color: AppColors.textPrimary),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: messages.isEmpty
                ? Center(
                    child: Text('No messages yet — say hello.',
                        style: TextStyle(color: AppColors.textSecondary)),
                  )
                : ListView.builder(
                    controller: _scrollController,
                    reverse: false,
                    padding: const EdgeInsets.all(12),
                    itemCount: messages.length,
                    itemBuilder: (context, index) {
                      final message = messages[index];
                      // A pending/local message has no server-confirmed
                      // sender id yet; treat it as "mine" — only the
                      // current user can have a pending outbox entry.
                      // Otherwise: in a 1:1 conversation, any confirmed
                      // sender who isn't the other participant is me.
                      final isMine = message.deliveryState == MessageDeliveryState.pending ||
                          message.deliveryState == MessageDeliveryState.failed ||
                          message.senderUserId != widget.otherParticipantId;
                      return Align(
                        alignment: isMine ? Alignment.centerRight : Alignment.centerLeft,
                        child: Container(
                          margin: const EdgeInsets.symmetric(vertical: 4),
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                          constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.75),
                          decoration: BoxDecoration(
                            color: isMine ? AppColors.emergencyRed.withValues(alpha: 0.85) : AppColors.cardDark,
                            borderRadius: BorderRadius.circular(14),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              if (message.type == MessageType.location)
                                Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(Icons.location_on,
                                        size: 16, color: isMine ? Colors.white : AppColors.accentBlue),
                                    const SizedBox(width: 6),
                                    Text(
                                      'Location: ${message.latitude!.toStringAsFixed(4)}, ${message.longitude!.toStringAsFixed(4)}',
                                      style: TextStyle(
                                          color: isMine ? Colors.white : AppColors.textPrimary, fontSize: 13),
                                    ),
                                  ],
                                )
                              else
                                Text(
                                  message.body ?? '',
                                  style: TextStyle(
                                      color: isMine ? Colors.white : AppColors.textPrimary, fontSize: 14),
                                ),
                              const SizedBox(height: 4),
                              Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    DateFormat.jm().format(message.clientCreatedAt),
                                    style: TextStyle(
                                        color: isMine ? Colors.white70 : AppColors.textSecondary, fontSize: 10),
                                  ),
                                  if (isMine) ...[
                                    const SizedBox(width: 4),
                                    _deliveryIcon(message.deliveryState),
                                  ],
                                ],
                              ),
                              if (message.deliveryState == MessageDeliveryState.failed)
                                Padding(
                                  padding: const EdgeInsets.only(top: 4),
                                  child: GestureDetector(
                                    onTap: () => comms.retryPendingSends(),
                                    child: const Text(
                                      'Tap to retry',
                                      style: TextStyle(color: Colors.white, fontSize: 11, decoration: TextDecoration.underline),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              child: Row(
                children: [
                  IconButton(
                    icon: _sharingLocation
                        ? SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.textSecondary),
                          )
                        : Icon(Icons.location_on_outlined, color: AppColors.textSecondary),
                    tooltip: 'Share location',
                    onPressed: _sharingLocation ? null : _shareLocation,
                  ),
                  Expanded(
                    child: TextField(
                      controller: _textController,
                      style: TextStyle(color: AppColors.textPrimary),
                      maxLines: 4,
                      minLines: 1,
                      decoration: InputDecoration(
                        hintText: 'Message',
                        hintStyle: TextStyle(color: AppColors.textSecondary),
                        filled: true,
                        fillColor: AppColors.cardDark,
                        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(20),
                          borderSide: BorderSide.none,
                        ),
                      ),
                      onSubmitted: (_) => _sendText(),
                    ),
                  ),
                  const SizedBox(width: 6),
                  IconButton(
                    icon: Icon(Icons.send, color: AppColors.emergencyRed),
                    onPressed: _sendText,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

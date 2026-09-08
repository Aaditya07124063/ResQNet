export interface DbConversationRow {
  id: string;
  type: 'direct' | 'group';
  group_id: string | null;
  direct_user_a_id: string | null;
  direct_user_b_id: string | null;
  created_at: Date;
}

/** A conversation summary as returned by the conversations-list endpoint —
 * includes the other participant (direct conversations only, V1's only
 * supported type) and the last message, so the Flutter list screen never
 * needs a second round-trip per row. */
export interface ConversationSummary {
  id: string;
  type: 'direct' | 'group';
  otherParticipant: { id: string; displayName: string | null } | null;
  lastMessage: {
    id: string;
    messageType: 'text' | 'location';
    body: string | null;
    senderUserId: string;
    createdAt: string;
  } | null;
  unreadCount: number;
  updatedAt: string;
}

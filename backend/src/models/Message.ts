export interface DbMessageRow {
  id: string;
  conversation_id: string;
  sender_user_id: string;
  client_message_id: string;
  message_type: 'text' | 'location';
  body: string | null;
  attachment_object_key: string | null;
  latitude: string | null;
  longitude: string | null;
  location_accuracy_m: string | null;
  client_created_at: Date;
  server_received_at: Date;
  edited_at: Date | null;
  deleted_at: Date | null;
}

export type MessageDeliveryStatus = 'sent' | 'delivered' | 'read';

/** Transport-independent message shape — this is what a message IS,
 * regardless of whether it travels over the authenticated WebSocket/HTTPS
 * path (implemented) or, in the future, a local mesh transport
 * (Bluetooth/Wi-Fi Direct — not implemented by this phase, see
 * docs/PLAN.md's mesh-compatibility note). Nothing in this shape assumes
 * an internet-connected delivery path. */
export interface Message {
  id: string;
  conversationId: string;
  senderUserId: string;
  clientMessageId: string;
  messageType: 'text' | 'location';
  body: string | null;
  latitude: number | null;
  longitude: number | null;
  locationAccuracyM: number | null;
  clientCreatedAt: string;
  serverReceivedAt: string;
}

function toNullableNumber(value: string | null): number | null {
  return value === null ? null : Number(value);
}

export function toMessage(row: DbMessageRow): Message {
  return {
    id: row.id,
    conversationId: row.conversation_id,
    senderUserId: row.sender_user_id,
    clientMessageId: row.client_message_id,
    messageType: row.message_type,
    body: row.body,
    latitude: toNullableNumber(row.latitude),
    longitude: toNullableNumber(row.longitude),
    locationAccuracyM: toNullableNumber(row.location_accuracy_m),
    clientCreatedAt: row.client_created_at.toISOString(),
    serverReceivedAt: row.server_received_at.toISOString(),
  };
}

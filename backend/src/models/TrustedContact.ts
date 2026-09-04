export interface DbTrustedContactRow {
  id: string;
  owner_user_id: string;
  contact_user_id: string | null;
  name: string;
  phone_number: string;
  relationship: string | null;
  created_at: Date;
  updated_at: Date;
}

export interface TrustedContact {
  id: string;
  ownerUserId: string;
  contactUserId: string | null;
  name: string;
  phoneNumber: string;
  relationship: string | null;
  updatedAt: string;
}

export function toTrustedContact(row: DbTrustedContactRow): TrustedContact {
  return {
    id: row.id,
    ownerUserId: row.owner_user_id,
    contactUserId: row.contact_user_id,
    name: row.name,
    phoneNumber: row.phone_number,
    relationship: row.relationship,
    updatedAt: row.updated_at.toISOString(),
  };
}

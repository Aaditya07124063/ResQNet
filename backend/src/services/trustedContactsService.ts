import { pool } from '../database/pool';
import { HttpError } from '../utils/httpError';
import { type DbTrustedContactRow, type TrustedContact, toTrustedContact } from '../models/TrustedContact';

export interface TrustedContactInput {
  name: string;
  phoneNumber: string;
  relationship: string | null;
}

// Every query here is scoped by owner_user_id — a user can only ever see
// or modify their OWN trusted contacts. That scoping is what enforces
// authorization; it is never left to the caller to check separately.

export async function listTrustedContacts(ownerUserId: string): Promise<TrustedContact[]> {
  const { rows } = await pool.query<DbTrustedContactRow>(
    'SELECT * FROM trusted_contacts WHERE owner_user_id = $1 ORDER BY created_at ASC',
    [ownerUserId],
  );
  return rows.map(toTrustedContact);
}

export async function createTrustedContact(
  ownerUserId: string,
  input: TrustedContactInput,
): Promise<TrustedContact> {
  const { rows } = await pool.query<DbTrustedContactRow>(
    `INSERT INTO trusted_contacts (owner_user_id, name, phone_number, relationship)
     VALUES ($1, $2, $3, $4)
     RETURNING *`,
    [ownerUserId, input.name, input.phoneNumber, input.relationship],
  );
  return toTrustedContact(rows[0]!);
}

export async function updateTrustedContact(
  ownerUserId: string,
  contactId: string,
  input: TrustedContactInput,
): Promise<TrustedContact> {
  const { rows } = await pool.query<DbTrustedContactRow>(
    `UPDATE trusted_contacts
     SET name = $1, phone_number = $2, relationship = $3
     WHERE id = $4 AND owner_user_id = $5
     RETURNING *`,
    [input.name, input.phoneNumber, input.relationship, contactId, ownerUserId],
  );
  const row = rows[0];
  if (!row) {
    // Same 404 whether the contact doesn't exist or belongs to someone
    // else — never reveal that a resource exists under another user.
    throw HttpError.notFound('Trusted contact not found');
  }
  return toTrustedContact(row);
}

export async function deleteTrustedContact(ownerUserId: string, contactId: string): Promise<void> {
  const { rowCount } = await pool.query(
    'DELETE FROM trusted_contacts WHERE id = $1 AND owner_user_id = $2',
    [contactId, ownerUserId],
  );
  if (!rowCount) {
    throw HttpError.notFound('Trusted contact not found');
  }
}

/**
 * Used by the `contacts_only` profile-picture visibility rule (Phase 6).
 * True if either user has linked the other as a trusted contact — checked
 * in both directions since a contact relationship may only have been
 * recorded from one side (trusted_contacts.contact_user_id is filled in
 * only when the contact is also a ResQNet user).
 */
export async function isMutualTrustedContact(userIdA: string, userIdB: string): Promise<boolean> {
  const { rows } = await pool.query<{ exists: boolean }>(
    `SELECT EXISTS (
       SELECT 1 FROM trusted_contacts
       WHERE (owner_user_id = $1 AND contact_user_id = $2)
          OR (owner_user_id = $2 AND contact_user_id = $1)
     ) AS exists`,
    [userIdA, userIdB],
  );
  return rows[0]?.exists ?? false;
}

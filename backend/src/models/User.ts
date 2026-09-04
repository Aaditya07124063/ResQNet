export interface DbUserRow {
  id: string;
  google_subject: string | null;
  email: string | null;
  email_verified: boolean;
  phone_number: string | null;
  phone_verified: boolean;
  display_name: string | null;
  account_status: 'active' | 'review_required' | 'suspended' | 'deleted';
  created_at: Date;
  updated_at: Date;
  last_login_at: Date | null;
}

/** Identity attached to `req.authUser` by requireAuth — derived from the
 * verified ResQNet session token, never from client-supplied input. */
export interface AuthenticatedUser {
  id: string;
  googleSubject: string | null;
  email: string | null;
  emailVerified: boolean;
  phoneNumber: string | null;
  phoneVerified: boolean;
  displayName: string | null;
  accountStatus: DbUserRow['account_status'];
}

export function toAuthenticatedUser(row: DbUserRow): AuthenticatedUser {
  return {
    id: row.id,
    googleSubject: row.google_subject,
    email: row.email,
    emailVerified: row.email_verified,
    phoneNumber: row.phone_number,
    phoneVerified: row.phone_verified,
    displayName: row.display_name,
    accountStatus: row.account_status,
  };
}

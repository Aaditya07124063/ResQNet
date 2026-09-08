export interface DbEmployeeRow {
  id: string;
  email: string;
  password_hash: string;
  display_name: string;
  role: 'super_admin' | 'admin' | 'employee';
  status: 'active' | 'disabled';
  created_at: Date;
  updated_at: Date;
  last_login_at: Date | null;
}

/** Identity attached to `req.authEmployee` by requireEmployeeAuth —
 * deliberately never includes `password_hash`, matching the equivalent
 * omission on `AuthenticatedUser`. */
export interface AuthenticatedEmployee {
  id: string;
  email: string;
  displayName: string;
  role: DbEmployeeRow['role'];
  status: DbEmployeeRow['status'];
  createdAt: string;
  lastLoginAt: string | null;
}

export function toAuthenticatedEmployee(row: DbEmployeeRow): AuthenticatedEmployee {
  return {
    id: row.id,
    email: row.email,
    displayName: row.display_name,
    role: row.role,
    status: row.status,
    createdAt: row.created_at.toISOString(),
    lastLoginAt: row.last_login_at ? row.last_login_at.toISOString() : null,
  };
}

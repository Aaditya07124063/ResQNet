import { pool } from '../database/pool';
import type { AuthenticatedEmployee } from '../models/Employee';

/**
 * SUPER_ADMIN implicitly has every permission and never needs a row in
 * employee_permissions (see the table's own doc comment in
 * 001_init_schema.sql) — this is the ONLY role-name-based bypass anywhere
 * in the authorization model; ADMIN/EMPLOYEE always require an explicit
 * grant, regardless of role.
 */
export async function hasPermission(employee: AuthenticatedEmployee, permission: string): Promise<boolean> {
  if (employee.role === 'super_admin') return true;
  const { rows } = await pool.query(
    'SELECT 1 FROM employee_permissions WHERE employee_id = $1 AND permission = $2 LIMIT 1',
    [employee.id, permission],
  );
  return rows.length > 0;
}

export interface GrantedPermission {
  permission: string;
  grantedAt: string;
  grantedByEmployeeId: string | null;
}

export async function listPermissions(employeeId: string): Promise<GrantedPermission[]> {
  const { rows } = await pool.query<{ permission: string; granted_at: Date; granted_by_employee_id: string | null }>(
    'SELECT permission, granted_at, granted_by_employee_id FROM employee_permissions WHERE employee_id = $1 ORDER BY permission ASC',
    [employeeId],
  );
  return rows.map((r) => ({
    permission: r.permission,
    grantedAt: r.granted_at.toISOString(),
    grantedByEmployeeId: r.granted_by_employee_id,
  }));
}

/** Idempotent — granting a permission the employee already has is a no-op,
 * not a conflict (ON CONFLICT DO NOTHING on the (employee_id, permission)
 * primary key). */
export async function grantPermission(
  employeeId: string,
  permission: string,
  grantedByEmployeeId: string,
): Promise<void> {
  await pool.query(
    `INSERT INTO employee_permissions (employee_id, permission, granted_by_employee_id)
     VALUES ($1, $2, $3)
     ON CONFLICT (employee_id, permission) DO NOTHING`,
    [employeeId, permission, grantedByEmployeeId],
  );
}

export async function revokePermission(employeeId: string, permission: string): Promise<void> {
  await pool.query('DELETE FROM employee_permissions WHERE employee_id = $1 AND permission = $2', [
    employeeId,
    permission,
  ]);
}

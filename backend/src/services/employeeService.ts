import { pool } from '../database/pool';
import { toAuthenticatedEmployee, type AuthenticatedEmployee, type DbEmployeeRow } from '../models/Employee';

export async function getEmployeeById(id: string): Promise<AuthenticatedEmployee | null> {
  const { rows } = await pool.query<DbEmployeeRow>('SELECT * FROM employees WHERE id = $1 LIMIT 1', [id]);
  return rows[0] ? toAuthenticatedEmployee(rows[0]) : null;
}

/** Includes `password_hash` — for employeeAuthService.ts's login check
 * ONLY. Every other caller must use the password-hash-free
 * `AuthenticatedEmployee` shape (getEmployeeById/listEmployees). */
export async function getEmployeeByEmailWithPasswordHash(email: string): Promise<DbEmployeeRow | null> {
  const { rows } = await pool.query<DbEmployeeRow>('SELECT * FROM employees WHERE email = $1 LIMIT 1', [email]);
  return rows[0] ?? null;
}

export async function listEmployees(): Promise<AuthenticatedEmployee[]> {
  const { rows } = await pool.query<DbEmployeeRow>('SELECT * FROM employees ORDER BY created_at ASC');
  return rows.map(toAuthenticatedEmployee);
}

export interface CreateEmployeeInput {
  email: string;
  passwordHash: string;
  displayName: string;
  role: DbEmployeeRow['role'];
}

/** Unique-violation (duplicate email) is left to the caller to map — the
 * route layer already has a consistent HttpError-mapping convention
 * (see reportService.ts/sosService.ts) that a service function shouldn't
 * duplicate. */
export async function createEmployee(input: CreateEmployeeInput): Promise<AuthenticatedEmployee> {
  const { rows } = await pool.query<DbEmployeeRow>(
    `INSERT INTO employees (email, password_hash, display_name, role)
     VALUES ($1, $2, $3, $4)
     RETURNING *`,
    [input.email, input.passwordHash, input.displayName, input.role],
  );
  return toAuthenticatedEmployee(rows[0]!);
}

export async function touchEmployeeLastLogin(employeeId: string): Promise<void> {
  await pool.query('UPDATE employees SET last_login_at = now() WHERE id = $1', [employeeId]);
}

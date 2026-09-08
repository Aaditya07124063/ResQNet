jest.mock('../src/database/pool', () => ({
  pool: { query: jest.fn() },
}));

import { pool } from '../src/database/pool';
import {
  grantPermission,
  hasPermission,
  listPermissions,
  revokePermission,
} from '../src/services/employeePermissionService';
import type { AuthenticatedEmployee } from '../src/models/Employee';

const mockedQuery = pool.query as jest.Mock;

function employee(overrides: Partial<AuthenticatedEmployee> = {}): AuthenticatedEmployee {
  return {
    id: 'employee-1',
    email: 'e@example.com',
    displayName: 'E',
    role: 'employee',
    status: 'active',
    createdAt: '2026-01-01T00:00:00.000Z',
    lastLoginAt: null,
    ...overrides,
  };
}

describe('hasPermission', () => {
  it('a super_admin has every permission implicitly, without any database query at all', async () => {
    const result = await hasPermission(employee({ role: 'super_admin' }), 'ANYTHING_AT_ALL');
    expect(result).toBe(true);
    expect(mockedQuery).not.toHaveBeenCalled();
  });

  it('an admin without an explicit grant is denied — role name alone never grants anything', async () => {
    mockedQuery.mockResolvedValueOnce({ rows: [] });
    const result = await hasPermission(employee({ role: 'admin' }), 'USER_SUSPEND');
    expect(result).toBe(false);
  });

  it('an employee with an explicit grant for exactly this permission is allowed', async () => {
    mockedQuery.mockResolvedValueOnce({ rows: [{ '?column?': 1 }] });
    const result = await hasPermission(employee({ role: 'employee' }), 'MESSAGE_REVIEW');
    expect(result).toBe(true);
    expect(mockedQuery.mock.calls[0][1]).toEqual(['employee-1', 'MESSAGE_REVIEW']);
  });

  it('a grant for a DIFFERENT permission does not satisfy this check', async () => {
    mockedQuery.mockResolvedValueOnce({ rows: [] }); // the query itself is scoped by permission string
    const result = await hasPermission(employee({ role: 'employee' }), 'USER_SUSPEND');
    expect(result).toBe(false);
  });
});

describe('grantPermission', () => {
  it('inserts with ON CONFLICT DO NOTHING (idempotent re-grant)', async () => {
    mockedQuery.mockResolvedValueOnce({ rows: [] });
    await grantPermission('employee-1', 'USER_VIEW', 'granting-employee');
    expect(mockedQuery.mock.calls[0][0]).toMatch(/ON CONFLICT \(employee_id, permission\) DO NOTHING/);
    expect(mockedQuery.mock.calls[0][1]).toEqual(['employee-1', 'USER_VIEW', 'granting-employee']);
  });
});

describe('revokePermission', () => {
  it('deletes the exact (employee_id, permission) row', async () => {
    mockedQuery.mockResolvedValueOnce({ rows: [] });
    await revokePermission('employee-1', 'USER_VIEW');
    expect(mockedQuery.mock.calls[0][0]).toMatch(/DELETE FROM employee_permissions/);
    expect(mockedQuery.mock.calls[0][1]).toEqual(['employee-1', 'USER_VIEW']);
  });
});

describe('listPermissions', () => {
  it('maps rows to the API shape', async () => {
    mockedQuery.mockResolvedValueOnce({
      rows: [
        { permission: 'USER_VIEW', granted_at: new Date('2026-01-01T00:00:00Z'), granted_by_employee_id: 'admin-1' },
      ],
    });
    const result = await listPermissions('employee-1');
    expect(result).toEqual([
      { permission: 'USER_VIEW', grantedAt: '2026-01-01T00:00:00.000Z', grantedByEmployeeId: 'admin-1' },
    ]);
  });
});

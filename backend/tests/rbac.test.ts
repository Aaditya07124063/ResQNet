import type { Request, Response } from 'express';

jest.mock('../src/services/employeePermissionService', () => ({
  hasPermission: jest.fn(),
}));

import { requirePermission } from '../src/middleware/rbac';
import { hasPermission } from '../src/services/employeePermissionService';
import type { AuthenticatedEmployee } from '../src/models/Employee';

const mockHasPermission = hasPermission as jest.Mock;

const employee: AuthenticatedEmployee = {
  id: 'employee-1',
  email: 'e@example.com',
  displayName: 'E',
  role: 'employee',
  status: 'active',
  createdAt: '2026-01-01T00:00:00.000Z',
  lastLoginAt: null,
};

function run(req: Partial<Request>, permission: string) {
  const next = jest.fn();
  requirePermission(permission)(req as Request, {} as Response, next);
  return new Promise<jest.Mock>((resolve) => setImmediate(() => resolve(next)));
}

describe('requirePermission', () => {
  it('denies (401) if requireEmployeeAuth never ran — no req.authEmployee at all', async () => {
    const next = await run({}, 'USER_VIEW');
    expect(next).toHaveBeenCalledWith(expect.objectContaining({ status: 401 }));
    expect(mockHasPermission).not.toHaveBeenCalled();
  });

  it('allows when hasPermission resolves true', async () => {
    mockHasPermission.mockResolvedValueOnce(true);
    const next = await run({ authEmployee: employee }, 'USER_VIEW');
    expect(next).toHaveBeenCalledWith(); // no error
    expect(mockHasPermission).toHaveBeenCalledWith(employee, 'USER_VIEW');
  });

  it('denies (403) when hasPermission resolves false', async () => {
    mockHasPermission.mockResolvedValueOnce(false);
    const next = await run({ authEmployee: employee }, 'USER_SUSPEND');
    expect(next).toHaveBeenCalledWith(expect.objectContaining({ status: 403 }));
  });

  it('propagates (not swallows) an unexpected error from the permission lookup', async () => {
    mockHasPermission.mockRejectedValueOnce(new Error('db down'));
    const next = await run({ authEmployee: employee }, 'USER_VIEW');
    expect(next).toHaveBeenCalledWith(expect.any(Error));
  });
});

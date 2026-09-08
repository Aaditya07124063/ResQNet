import type { Request, Response } from 'express';

jest.mock('../src/services/employeeAuthService', () => ({
  verifyEmployeeAccessToken: jest.fn(),
}));
jest.mock('../src/services/employeeService', () => ({
  getEmployeeById: jest.fn(),
}));

import { requireEmployeeAuth } from '../src/middleware/employeeAuthMiddleware';
import { verifyEmployeeAccessToken } from '../src/services/employeeAuthService';
import { getEmployeeById } from '../src/services/employeeService';
import type { AuthenticatedEmployee } from '../src/models/Employee';

const mockVerify = verifyEmployeeAccessToken as jest.Mock;
const mockGetEmployeeById = getEmployeeById as jest.Mock;

function makeReq(authorization?: string): Partial<Request> {
  return { headers: authorization ? { authorization } : {} };
}

const activeEmployee: AuthenticatedEmployee = {
  id: 'employee-1',
  email: 'e@example.com',
  displayName: 'E',
  role: 'employee',
  status: 'active',
  createdAt: '2026-01-01T00:00:00.000Z',
  lastLoginAt: null,
};

async function run(req: Partial<Request>) {
  const next = jest.fn();
  await requireEmployeeAuth(req as Request, {} as Response, next);
  return next;
}

describe('requireEmployeeAuth', () => {
  it('denies a request with no Authorization header', async () => {
    const next = await run(makeReq());
    expect(next).toHaveBeenCalledWith(expect.objectContaining({ status: 401 }));
  });

  it('denies a malformed Authorization header (not Bearer)', async () => {
    const next = await run(makeReq('Basic abc123'));
    expect(next).toHaveBeenCalledWith(expect.objectContaining({ status: 401 }));
  });

  it('denies when the token fails verification', async () => {
    mockVerify.mockImplementation(() => {
      throw Object.assign(new Error('bad token'), { status: 401 });
    });
    const next = await run(makeReq('Bearer some-invalid-token'));
    expect(next).toHaveBeenCalledWith(expect.objectContaining({ status: 401 }));
  });

  it('denies when the token is valid but the employee no longer exists', async () => {
    mockVerify.mockReturnValue('employee-1');
    mockGetEmployeeById.mockResolvedValue(null);
    const next = await run(makeReq('Bearer valid-token'));
    expect(next).toHaveBeenCalledWith(expect.objectContaining({ status: 401 }));
  });

  it('denies a disabled employee account', async () => {
    mockVerify.mockReturnValue('employee-1');
    mockGetEmployeeById.mockResolvedValue({ ...activeEmployee, status: 'disabled' });
    const next = await run(makeReq('Bearer valid-token'));
    expect(next).toHaveBeenCalledWith(expect.objectContaining({ status: 403 }));
  });

  it('allows an active employee and attaches req.authEmployee', async () => {
    mockVerify.mockReturnValue('employee-1');
    mockGetEmployeeById.mockResolvedValue(activeEmployee);
    const req = makeReq('Bearer valid-token');
    const next = await run(req);
    expect(next).toHaveBeenCalledWith(); // called with no error
    expect((req as Request).authEmployee).toEqual(activeEmployee);
  });
});

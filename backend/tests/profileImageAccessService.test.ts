jest.mock('../src/services/trustedContactsService', () => ({
  isMutualTrustedContact: jest.fn(),
}));

import { canViewProfileImage } from '../src/services/profileImageAccessService';
import { isMutualTrustedContact } from '../src/services/trustedContactsService';

const mockIsMutualTrustedContact = isMutualTrustedContact as jest.Mock;

describe('canViewProfileImage', () => {
  const OWNER = 'owner-id';
  const VIEWER = 'viewer-id';

  it('always allows the owner to view their own image, regardless of visibility', async () => {
    for (const visibility of ['private', 'public', 'contacts_only', 'groups_only'] as const) {
      await expect(canViewProfileImage(OWNER, OWNER, visibility)).resolves.toBe(true);
    }
    expect(mockIsMutualTrustedContact).not.toHaveBeenCalled();
  });

  it('denies a non-owner when visibility is private', async () => {
    await expect(canViewProfileImage(VIEWER, OWNER, 'private')).resolves.toBe(false);
  });

  it('allows any authenticated non-owner when visibility is public', async () => {
    await expect(canViewProfileImage(VIEWER, OWNER, 'public')).resolves.toBe(true);
    expect(mockIsMutualTrustedContact).not.toHaveBeenCalled();
  });

  it('allows a non-owner who IS a mutual trusted contact when visibility is contacts_only', async () => {
    mockIsMutualTrustedContact.mockResolvedValue(true);
    await expect(canViewProfileImage(VIEWER, OWNER, 'contacts_only')).resolves.toBe(true);
    expect(mockIsMutualTrustedContact).toHaveBeenCalledWith(VIEWER, OWNER);
  });

  it('denies a non-owner who is NOT a mutual trusted contact when visibility is contacts_only', async () => {
    mockIsMutualTrustedContact.mockResolvedValue(false);
    await expect(canViewProfileImage(VIEWER, OWNER, 'contacts_only')).resolves.toBe(false);
  });

  it('treats groups_only as owner-only (documented Phase 11 limitation) — denies a non-owner', async () => {
    await expect(canViewProfileImage(VIEWER, OWNER, 'groups_only')).resolves.toBe(false);
    // Must not fall back to the contacts check either — groups_only is
    // its own documented no-access-for-others case, not an alias for
    // contacts_only.
    expect(mockIsMutualTrustedContact).not.toHaveBeenCalled();
  });
});

import { isMutualTrustedContact } from './trustedContactsService';
import type { UserProfile } from '../models/Profile';

/**
 * Authorization decision for viewing a profile picture (Phase 6). This is
 * the ONLY place that decides whether a signed URL gets issued — the
 * route layer must call this before ever calling storageService, never
 * after, and never trust a client's own claim about permission.
 *
 * `groups_only` is NOT fully implemented (Phase 11 — groups — doesn't
 * exist yet). Per explicit instruction, it is treated as owner-only
 * (same as `private`) rather than silently granting broader access than
 * can actually be verified. Do not change this to real group-membership
 * checking until Phase 11's group_members data exists and is wired in.
 */
export async function canViewProfileImage(
  viewerUserId: string,
  ownerUserId: string,
  visibility: UserProfile['profilePictureVisibility'],
): Promise<boolean> {
  if (viewerUserId === ownerUserId) return true;

  switch (visibility) {
    case 'public':
      return true;
    case 'contacts_only':
      return isMutualTrustedContact(viewerUserId, ownerUserId);
    case 'private':
    case 'groups_only':
      // groups_only intentionally falls back to owner-only — see the
      // doc comment above. Do not treat this as a bug to "fix" by
      // granting access; it is the documented safe behavior.
      return false;
  }
}

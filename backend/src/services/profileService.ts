import { pool } from '../database/pool';
import { type DbUserProfileRow, type UserProfile, toUserProfile } from '../models/Profile';

export interface ProfileUpdateInput {
  fatherName?: string | null;
  age?: number | null;
  address?: string | null;
  bloodGroup?: string | null;
  allergies?: string | null;
  medications?: string | null;
  emergencyContact?: string | null;
  country?: string | null;
  state?: string | null;
  city?: string | null;
  profilePictureVisibility?: UserProfile['profilePictureVisibility'];
}

export async function getProfile(userId: string): Promise<UserProfile | null> {
  const { rows } = await pool.query<DbUserProfileRow>(
    'SELECT * FROM user_profiles WHERE user_id = $1 LIMIT 1',
    [userId],
  );
  return rows[0] ? toUserProfile(rows[0]) : null;
}

/**
 * Creates or updates the caller's own profile row. `userId` must come from
 * the authenticated session (req.authUser.id), never a client-supplied
 * field — callers enforce that at the route layer.
 */
export async function upsertProfile(userId: string, input: ProfileUpdateInput): Promise<UserProfile> {
  const { rows } = await pool.query<DbUserProfileRow>(
    `INSERT INTO user_profiles (
       user_id, father_name, age, address, blood_group, allergies,
       medications, emergency_contact, country, state, city, profile_picture_visibility
     )
     VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, COALESCE($12, 'private'))
     ON CONFLICT (user_id) DO UPDATE SET
       father_name = EXCLUDED.father_name,
       age = EXCLUDED.age,
       address = EXCLUDED.address,
       blood_group = EXCLUDED.blood_group,
       allergies = EXCLUDED.allergies,
       medications = EXCLUDED.medications,
       emergency_contact = EXCLUDED.emergency_contact,
       country = EXCLUDED.country,
       state = EXCLUDED.state,
       city = EXCLUDED.city,
       profile_picture_visibility = COALESCE(EXCLUDED.profile_picture_visibility, user_profiles.profile_picture_visibility)
     RETURNING *`,
    [
      userId,
      input.fatherName ?? null,
      input.age ?? null,
      input.address ?? null,
      input.bloodGroup ?? null,
      input.allergies ?? null,
      input.medications ?? null,
      input.emergencyContact ?? null,
      input.country ?? null,
      input.state ?? null,
      input.city ?? null,
      input.profilePictureVisibility ?? null,
    ],
  );
  return toUserProfile(rows[0]!);
}

/**
 * Sets/replaces the caller's own profile-image object key (Phase 6). Only
 * ever the MinIO key is stored — never a URL, signed or otherwise (see
 * backend/src/services/storageService.ts). Upserts the same as
 * upsertProfile() since a user may upload a photo before ever having
 * saved any other profile field.
 */
export async function setProfileImageKey(userId: string, objectKey: string): Promise<UserProfile> {
  const { rows } = await pool.query<DbUserProfileRow>(
    `INSERT INTO user_profiles (user_id, profile_image_object_key)
     VALUES ($1, $2)
     ON CONFLICT (user_id) DO UPDATE SET profile_image_object_key = EXCLUDED.profile_image_object_key
     RETURNING *`,
    [userId, objectKey],
  );
  return toUserProfile(rows[0]!);
}

export async function clearProfileImageKey(userId: string): Promise<void> {
  await pool.query('UPDATE user_profiles SET profile_image_object_key = NULL WHERE user_id = $1', [
    userId,
  ]);
}

export interface DbUserProfileRow {
  user_id: string;
  father_name: string | null;
  age: number | null;
  address: string | null;
  blood_group: string | null;
  allergies: string | null;
  medications: string | null;
  emergency_contact: string | null;
  country: string | null;
  state: string | null;
  city: string | null;
  profile_image_object_key: string | null;
  profile_picture_visibility: 'private' | 'contacts_only' | 'groups_only' | 'public';
  created_at: Date;
  updated_at: Date;
}

export interface UserProfile {
  userId: string;
  fatherName: string | null;
  age: number | null;
  address: string | null;
  bloodGroup: string | null;
  allergies: string | null;
  medications: string | null;
  emergencyContact: string | null;
  country: string | null;
  state: string | null;
  city: string | null;
  /** MinIO object key — never a public URL. Resolved to a signed URL (if
   * the requester is authorized to see it) at the API response layer,
   * once MinIO exists (Phase 6). Until then this is just the stored key. */
  profileImageObjectKey: string | null;
  profilePictureVisibility: DbUserProfileRow['profile_picture_visibility'];
  updatedAt: string;
}

export function toUserProfile(row: DbUserProfileRow): UserProfile {
  return {
    userId: row.user_id,
    fatherName: row.father_name,
    age: row.age,
    address: row.address,
    bloodGroup: row.blood_group,
    allergies: row.allergies,
    medications: row.medications,
    emergencyContact: row.emergency_contact,
    country: row.country,
    state: row.state,
    city: row.city,
    profileImageObjectKey: row.profile_image_object_key,
    profilePictureVisibility: row.profile_picture_visibility,
    updatedAt: row.updated_at.toISOString(),
  };
}

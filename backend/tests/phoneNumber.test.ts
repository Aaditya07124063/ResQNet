import { normalizePhoneNumber } from '../src/utils/phoneNumber';

describe('normalizePhoneNumber', () => {
  it('normalizes a Nepali national-format number to E.164 using the NP default region', () => {
    expect(normalizePhoneNumber('9812345678')).toBe('+9779812345678');
  });

  it('normalizes a Nepali number already carrying its country code', () => {
    expect(normalizePhoneNumber('+9779812345678')).toBe('+9779812345678');
  });

  it('normalizes an Indian number that carries its own country code regardless of the NP default region', () => {
    expect(normalizePhoneNumber('+919876543210')).toBe('+919876543210');
  });

  // Formatting-variant inputs for the SAME real number must all collapse to
  // the identical E.164 string — this is what makes rate-limiting/lookup
  // immune to spacing/punctuation-based bypass (see authSchemas.ts).
  it('collapses formatting variants (spaces, dashes) of the same number to the same E.164 value', () => {
    const variants = ['+977 98-1234-5678', '+977-981-234-5678', '+977 981 234 5678'];
    const normalized = variants.map(normalizePhoneNumber);
    expect(new Set(normalized).size).toBe(1);
    expect(normalized[0]).toBe('+9779812345678');
  });

  it('returns null for an empty string', () => {
    expect(normalizePhoneNumber('')).toBeNull();
  });

  it('returns null for non-numeric garbage', () => {
    expect(normalizePhoneNumber('not-a-phone-number')).toBeNull();
  });

  it('returns null for a too-short number', () => {
    expect(normalizePhoneNumber('123')).toBeNull();
  });

  it('returns null for an input over 32 characters', () => {
    expect(normalizePhoneNumber('9'.repeat(40))).toBeNull();
  });

  it('returns null for an implausible/invalid number shape even if digits-only', () => {
    expect(normalizePhoneNumber('0000000000')).toBeNull();
  });
});

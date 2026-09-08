export type DetectedImageType = 'jpeg' | 'png' | 'webp';

/**
 * Detects an image's real format from its magic bytes — never trust a
 * client-declared Content-Type or filename extension for this. Returns
 * null for anything that doesn't match one of the three supported
 * signatures, including a file that merely claims to be an image.
 */
export function detectImageType(buffer: Buffer): DetectedImageType | null {
  if (buffer.length >= 3 && buffer[0] === 0xff && buffer[1] === 0xd8 && buffer[2] === 0xff) {
    return 'jpeg';
  }

  const pngSignature = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];
  if (buffer.length >= pngSignature.length && pngSignature.every((byte, i) => buffer[i] === byte)) {
    return 'png';
  }

  if (
    buffer.length >= 12 &&
    buffer.subarray(0, 4).toString('ascii') === 'RIFF' &&
    buffer.subarray(8, 12).toString('ascii') === 'WEBP'
  ) {
    return 'webp';
  }

  return null;
}

export function extensionFor(type: DetectedImageType): string {
  return type === 'jpeg' ? 'jpg' : type;
}

export function contentTypeFor(type: DetectedImageType): string {
  return `image/${type}`;
}

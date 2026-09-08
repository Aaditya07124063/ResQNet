import { contentTypeFor, detectImageType, extensionFor } from '../src/utils/imageSignature';

const JPEG_MAGIC = Buffer.from([0xff, 0xd8, 0xff, 0xe0, 0x00, 0x10, 0x4a, 0x46]);
const PNG_MAGIC = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00]);
const WEBP_MAGIC = Buffer.concat([
  Buffer.from('RIFF', 'ascii'),
  Buffer.from([0x00, 0x00, 0x00, 0x00]),
  Buffer.from('WEBP', 'ascii'),
]);

describe('detectImageType', () => {
  it('detects a real JPEG by its magic bytes', () => {
    expect(detectImageType(JPEG_MAGIC)).toBe('jpeg');
  });

  it('detects a real PNG by its magic bytes', () => {
    expect(detectImageType(PNG_MAGIC)).toBe('png');
  });

  it('detects a real WEBP by its RIFF/WEBP markers', () => {
    expect(detectImageType(WEBP_MAGIC)).toBe('webp');
  });

  it('rejects a plain text file masquerading as an image', () => {
    expect(detectImageType(Buffer.from('this is not an image, just text', 'utf8'))).toBeNull();
  });

  it('rejects an empty buffer', () => {
    expect(detectImageType(Buffer.alloc(0))).toBeNull();
  });

  it('rejects a buffer with a plausible-looking but wrong-order JPEG prefix', () => {
    expect(detectImageType(Buffer.from([0xff, 0xff, 0xd8]))).toBeNull();
  });

  it('rejects a truncated buffer too short to contain any real signature', () => {
    expect(detectImageType(Buffer.from([0x89, 0x50]))).toBeNull();
  });
});

describe('extensionFor / contentTypeFor', () => {
  it('maps jpeg to the .jpg extension (not .jpeg)', () => {
    expect(extensionFor('jpeg')).toBe('jpg');
  });

  it('maps png/webp to themselves', () => {
    expect(extensionFor('png')).toBe('png');
    expect(extensionFor('webp')).toBe('webp');
  });

  it('produces a proper image/* content type for each detected type', () => {
    expect(contentTypeFor('jpeg')).toBe('image/jpeg');
    expect(contentTypeFor('png')).toBe('image/png');
    expect(contentTypeFor('webp')).toBe('image/webp');
  });
});

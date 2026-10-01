import { createHash, createHmac } from 'node:crypto';

// Minimal AWS Signature Version 4 signer
// (https://docs.aws.amazon.com/IAM/latest/UserGuide/create-signed-request.html)
// for a single JSON POST, so the AWS SMS adapter does not need the full AWS
// SDK. Only the headers passed in are signed; the caller must include
// `host` and `x-amz-date`.

function sha256Hex(data: string): string {
  return createHash('sha256').update(data, 'utf8').digest('hex');
}

function hmac(key: Buffer | string, data: string): Buffer {
  return createHmac('sha256', key).update(data, 'utf8').digest();
}

export interface SigV4Request {
  method: string;
  path: string;
  query?: string;
  headers: Record<string, string>;
  body: string;
}

export interface SigV4Credentials {
  accessKeyId: string;
  secretAccessKey: string;
}

/** Returns the Authorization header value for `request`. `amzDate` must
 * equal the request's x-amz-date header (YYYYMMDD'T'HHMMSS'Z'). */
export function signV4(
  request: SigV4Request,
  credentials: SigV4Credentials,
  region: string,
  service: string,
  amzDate: string,
): string {
  const dateStamp = amzDate.slice(0, 8);
  const headers = Object.entries(request.headers)
    .map(([name, value]) => [name.toLowerCase(), value.trim().replace(/\s+/g, ' ')] as const)
    .sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0));
  const canonicalHeaders = headers.map(([name, value]) => `${name}:${value}\n`).join('');
  const signedHeaders = headers.map(([name]) => name).join(';');

  const canonicalRequest = [
    request.method,
    request.path,
    request.query ?? '',
    canonicalHeaders,
    signedHeaders,
    sha256Hex(request.body),
  ].join('\n');

  const scope = `${dateStamp}/${region}/${service}/aws4_request`;
  const stringToSign = ['AWS4-HMAC-SHA256', amzDate, scope, sha256Hex(canonicalRequest)].join('\n');

  const kDate = hmac(`AWS4${credentials.secretAccessKey}`, dateStamp);
  const kRegion = hmac(kDate, region);
  const kService = hmac(kRegion, service);
  const kSigning = hmac(kService, 'aws4_request');
  const signature = createHmac('sha256', kSigning).update(stringToSign, 'utf8').digest('hex');

  return `AWS4-HMAC-SHA256 Credential=${credentials.accessKeyId}/${scope}, SignedHeaders=${signedHeaders}, Signature=${signature}`;
}

export function toAmzDate(date: Date): string {
  return date.toISOString().replace(/[:-]/g, '').replace(/\.\d{3}/, '');
}

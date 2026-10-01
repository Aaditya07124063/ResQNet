import { signV4, toAmzDate } from '../src/services/sms/awsSigV4';

// Vectors from the AWS Signature Version 4 test suite (get-vanilla /
// post-vanilla), which use these documented example credentials.
const credentials = { accessKeyId: 'AKIDEXAMPLE', secretAccessKey: 'wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY' };
const amzDate = '20150830T123600Z';

describe('signV4', () => {
  it('matches the AWS get-vanilla test vector', () => {
    const authorization = signV4(
      { method: 'GET', path: '/', headers: { Host: 'example.amazonaws.com', 'X-Amz-Date': amzDate }, body: '' },
      credentials,
      'us-east-1',
      'service',
      amzDate,
    );
    expect(authorization).toBe(
      'AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/service/aws4_request, ' +
        'SignedHeaders=host;x-amz-date, ' +
        'Signature=5fa00fa31553b73ebf1942676e86291e8372ff2a2260956d9b8aae1d763fbf31',
    );
  });

  it('matches the AWS post-vanilla test vector', () => {
    const authorization = signV4(
      { method: 'POST', path: '/', headers: { Host: 'example.amazonaws.com', 'X-Amz-Date': amzDate }, body: '' },
      credentials,
      'us-east-1',
      'service',
      amzDate,
    );
    expect(authorization).toMatch(/Signature=5da7c1a2acd57cee7505fc6676e4e544621c30862966e37dddb68e92efbe5d6b$/);
  });

  it('formats x-amz-date without separators or milliseconds', () => {
    expect(toAmzDate(new Date('2015-08-30T12:36:00.123Z'))).toBe(amzDate);
  });
});

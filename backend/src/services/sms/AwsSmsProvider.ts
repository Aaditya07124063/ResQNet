import type { SmsProvider } from './SmsProvider';
import { SmsProviderError, type SmsFailureKind } from './SmsProviderError';
import { classifyHttpStatus, providerFetch, readJson } from './http';
import { signV4, toAmzDate } from './awsSigV4';

// AWS End User Messaging SMS (API v2, formerly Pinpoint SMS/Voice v2),
// SendTextMessage:
// https://docs.aws.amazon.com/pinpoint/latest/apireference_smsvoicev2/API_SendTextMessage.html
// AWS recommends this API over SNS Publish for direct transactional SMS.
// Wire protocol per the AWS SDK service model (pinpoint-sms-voice-v2,
// 2022-03-31): AWS JSON 1.0, endpoint prefix and SigV4 signing name
// `sms-voice`, target prefix `PinpointSMSVoiceV2`.
//
// Credentials are an IAM access key pair stored encrypted like every other
// provider secret; the IAM principal should be limited to
// sms-voice:SendTextMessage. (Instance-role credentials would need the AWS
// SDK credential chain and are not supported by this adapter.)

export interface AwsSmsCredentials {
  access_key_id: string;
  secret_access_key: string;
}
export interface AwsSmsConfiguration {
  region: string;
  /** Phone number, sender ID, pool ID, or their ARN. */
  origination_identity?: string;
  configuration_set?: string;
  /** India DLT registration (DestinationCountryParameters). */
  in_entity_id?: string;
  in_template_id?: string;
}

/** AWS region names only (e.g. ap-south-1) — this value becomes part of the
 * request host, so it is strictly validated to prevent host injection. */
export const AWS_REGION_PATTERN = /^[a-z]{2}(-gov)?-[a-z]+-\d$/;

function classifyAwsError(type: string | undefined, status: number): SmsFailureKind {
  const name = type?.split('#').pop()?.split(':')[0];
  switch (name) {
    case 'ThrottlingException':
    case 'ServiceQuotaExceededException':
    case 'InternalServerException':
      return 'availability';
    case 'AccessDeniedException':
    case 'ResourceNotFoundException':
    case 'UnrecognizedClientException':
    case 'InvalidSignatureException':
    case 'ValidationException':
    case 'ConflictException':
      return 'configuration';
    default:
      return classifyHttpStatus(status);
  }
}

export class AwsSmsProvider implements SmsProvider {
  constructor(
    private readonly credentials: AwsSmsCredentials,
    private readonly configuration: AwsSmsConfiguration,
    private readonly now: () => Date = () => new Date(),
  ) {}

  async send(to: string, message: string): Promise<{ providerMessageId?: string }> {
    const { region } = this.configuration;
    if (!AWS_REGION_PATTERN.test(region)) throw new SmsProviderError('configuration', 'AWS region is not valid');

    const payload: Record<string, unknown> = {
      DestinationPhoneNumber: to,
      MessageBody: message,
      MessageType: 'TRANSACTIONAL',
    };
    if (this.configuration.origination_identity) payload.OriginationIdentity = this.configuration.origination_identity;
    if (this.configuration.configuration_set) payload.ConfigurationSetName = this.configuration.configuration_set;
    if (to.startsWith('+91') && this.configuration.in_entity_id && this.configuration.in_template_id) {
      payload.DestinationCountryParameters = {
        IN_ENTITY_ID: this.configuration.in_entity_id,
        IN_TEMPLATE_ID: this.configuration.in_template_id,
      };
    }

    const host = `sms-voice.${region}.amazonaws.com`;
    const body = JSON.stringify(payload);
    const amzDate = toAmzDate(this.now());
    const headers: Record<string, string> = {
      'content-type': 'application/x-amz-json-1.0',
      host,
      'x-amz-date': amzDate,
      'x-amz-target': 'PinpointSMSVoiceV2.SendTextMessage',
    };
    const authorization = signV4(
      { method: 'POST', path: '/', headers, body },
      { accessKeyId: this.credentials.access_key_id, secretAccessKey: this.credentials.secret_access_key },
      region,
      'sms-voice',
      amzDate,
    );

    // `host` is set by fetch itself from the URL; it is only needed above
    // for the signature.
    const sendHeaders = Object.fromEntries(Object.entries(headers).filter(([name]) => name !== 'host'));
    const response = await providerFetch(`https://${host}/`, {
      method: 'POST',
      headers: { ...sendHeaders, authorization },
      body,
    });
    const result = await readJson<{ MessageId?: string; __type?: string }>(response);
    if (!response.ok) {
      const errorType = response.headers.get('x-amzn-errortype') ?? result?.__type;
      throw new SmsProviderError(
        classifyAwsError(errorType, response.status),
        `AWS End User Messaging rejected request (HTTP ${response.status})`,
        errorType?.split('#').pop()?.split(':')[0],
      );
    }
    return { providerMessageId: result?.MessageId };
  }
}

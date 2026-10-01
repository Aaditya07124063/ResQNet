import '../../core/network/api_exception.dart';

// Phone sign-in is handled entirely by the ResQNet backend
// (POST /auth/phone/send-otp + verify-otp); these map its responses to
// user-facing text.

/// Matches the backend's 60-second resend cooldown (verificationService.ts).
const int backendOtpResendSeconds = 60;

/// User-facing text for a failed code request. Never includes the code or
/// raw server detail.
String describeOtpSendError(ApiException e) {
  if (e.isNetworkError) {
    return 'No internet connection. Signing in needs a connection — '
        'emergency SOS still works without one.';
  }
  switch (e.statusCode) {
    case 400:
      return 'That phone number does not look right. Check the country code and number.';
    case 429:
      return 'Please wait a minute before requesting another code.';
    default:
      return e.isServerError
          ? 'The code could not be sent right now. Try again shortly, or sign in with Google.'
          : 'The code could not be sent. Please try again.';
  }
}

/// User-facing text for a failed verification. The backend deliberately
/// returns one generic 401 for wrong, expired, reused, or unknown codes.
String describeOtpVerifyError(ApiException e) {
  if (e.isNetworkError) return 'No internet connection. Check your connection and try again.';
  switch (e.statusCode) {
    case 401:
      return 'That code is invalid or has expired. Check it, or request a new one.';
    case 403:
      return 'This account is not active.';
    case 429:
      return 'Too many attempts. Please wait before trying again.';
    default:
      return 'The code could not be checked right now. Please try again.';
  }
}

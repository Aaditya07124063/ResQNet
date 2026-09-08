import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../core/constants/app_colors.dart';
import '../../core/constants/app_routes.dart';
import '../../core/network/api_exception.dart';
import '../../core/services/app_shortcut_service.dart';
import 'auth_service.dart';
import 'otp_screen.dart';

/// Public policy pages already published for the product — reused here
/// rather than inventing in-app legal content (none exists in the app
/// itself). Kept local to this screen since it's the only place that
/// links to them today.
const _termsUrl = 'https://resqnet.co/terms/';
const _privacyUrl = 'https://resqnet.co/privacy-policy/';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});
  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _phoneCtrl = TextEditingController();
  String _selectedCountryCode = '+91';
  bool _isHuman = false;
  late final TapGestureRecognizer _termsTap;
  late final TapGestureRecognizer _privacyTap;
  late final AppShortcutService _shortcutService;
  bool _cameFromSosShortcut = false;

  // Unchanged behavior — only the on-screen presentation of each entry
  // gains a flag below (_countryFlag). Adding a new supported country
  // code is still just adding one entry here, same as before.
  final List<String> _countryCodes = ['+91', '+977'];

  static const Map<String, String> _countryFlags = {
    '+91': '🇮🇳',
    '+977': '🇳🇵',
  };

  Future<void> _sendOtp() async {
    if (!_isHuman) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please verify you are not a robot')),
      );
      return;
    }
    if (_phoneCtrl.text.length < 10) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter a valid phone number')),
      );
      return;
    }
    final auth = context.read<AuthService>();
    final phone = '$_selectedCountryCode${_phoneCtrl.text.trim()}';
    await auth.sendOtp(
      phoneNumber: phone,
      onCodeSent: () {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => OtpScreen(phoneNumber: phone),
          ),
        );
      },
      onError: (e) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e)),
        );
      },
    );
  }

  Future<void> _googleSignIn() async {
    if (!_isHuman) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please verify you are not a robot')),
      );
      return;
    }
    final auth = context.read<AuthService>();
    // Phase 4C: this now authenticates against the ResQNet backend
    // (POST /auth/google) rather than FirebaseAuth.signInWithCredential().
    // Phone login below is unchanged and still Firebase-based.
    try {
      final success = await auth.signInWithGoogleBackend();
      if (success && mounted) {
        Navigator.pushReplacementNamed(context, AppRoutes.home);
      }
      // A `false` result means the user cancelled Google's own account
      // picker — not an error, so no message is shown.
    } on ApiException catch (e) {
      if (!mounted) return;
      final message = e.isNetworkError
          ? 'Could not reach the server. Check your connection and try again.'
          : 'Sign-in failed. Please try again.';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message)),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Sign-in failed. Please try again.')),
      );
    }
  }

  Future<void> _openLegalUrl(String url) async {
    final uri = Uri.parse(url);
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not open the link.')),
      );
    }
  }

  @override
  void initState() {
    super.initState();
    _termsTap = TapGestureRecognizer()..onTap = () => _openLegalUrl(_termsUrl);
    _privacyTap = TapGestureRecognizer()..onTap = () => _openLegalUrl(_privacyUrl);

    // The "Send SOS" home-screen shortcut can launch (or resume) the app
    // before the user is signed in. HomeScreen is the only other place
    // that consumes AppShortcutService.pendingAction, and it never mounts
    // while unauthenticated — so left alone, this value would sit
    // unconsumed here and then silently fire an automatic SOS-screen
    // navigation the moment ANY later sign-in succeeds, not just one
    // prompted by the shortcut. Mirrors HomeScreen's own listener +
    // immediate-check pattern (not just an initState-only check) so a
    // second shortcut tap while already sitting on this screen — an app
    // resume, not a cold start — is caught too.
    _shortcutService = context.read<AppShortcutService>();
    _shortcutService.pendingAction.addListener(_handlePendingShortcutAction);
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _handlePendingShortcutAction(),
    );
  }

  void _handlePendingShortcutAction() {
    if (!mounted) return;
    if (_shortcutService.pendingAction.value !=
        AppShortcutService.sosActionType) {
      return;
    }
    _shortcutService.consume();
    setState(() => _cameFromSosShortcut = true);
  }

  @override
  void dispose() {
    _shortcutService.pendingAction.removeListener(
      _handlePendingShortcutAction,
    );
    _phoneCtrl.dispose();
    _termsTap.dispose();
    _privacyTap.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthService>();
    return Scaffold(
      backgroundColor: AppColors.backgroundDark,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 28),
              // Logo — the one place brand red stays as a solid fill;
              // everything else on this screen reads it as an accent,
              // not the dominant color (see below).
              Center(
                child: Container(
                  width: 72,
                  height: 72,
                  decoration: BoxDecoration(
                    color: AppColors.emergencyRed,
                    borderRadius: BorderRadius.circular(18),
                  ),
                  child: const Center(
                    child: Text('RQ',
                        style: TextStyle(
                            color: Colors.white,
                            fontSize: 28,
                            fontWeight: FontWeight.w900)),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Center(
                child: Text('ResQNet',
                    style: TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 26,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 0.2)),
              ),
              const SizedBox(height: 4),
              Center(
                child: Text('Emergency Communication Platform',
                    style: TextStyle(
                        color: AppColors.textSecondary, fontSize: 12)),
              ),
              const SizedBox(height: 40),
              if (_cameFromSosShortcut) ...[
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 10),
                  decoration: BoxDecoration(
                    color: AppColors.emergencyRed.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                        color: AppColors.emergencyRed.withValues(alpha: 0.3)),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.info_outline,
                          color: AppColors.emergencyRed, size: 18),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Sign in, then tap Send SOS again to start an alert.',
                          style: TextStyle(
                              color: AppColors.emergencyRed, fontSize: 12.5),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 20),
              ],
              Text('Sign in with phone',
                  style: TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: 18,
                      fontWeight: FontWeight.w700)),
              const SizedBox(height: 4),
              Text('We\'ll text you a one-time code.',
                  style: TextStyle(
                      color: AppColors.textSecondary, fontSize: 13)),
              const SizedBox(height: 16),
              // Phone input
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    height: 52,
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    decoration: BoxDecoration(
                      color: AppColors.cardDark,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: AppColors.lowGrey.withValues(alpha: 0.4)),
                    ),
                    child: DropdownButtonHideUnderline(
                      child: DropdownButton<String>(
                        value: _selectedCountryCode,
                        dropdownColor: AppColors.cardDark,
                        borderRadius: BorderRadius.circular(10),
                        icon: Icon(Icons.expand_more,
                            color: AppColors.textSecondary, size: 20),
                        style: TextStyle(
                            color: AppColors.textPrimary,
                            fontSize: 15,
                            fontWeight: FontWeight.w500),
                        // Country + calling code, so the selected value
                        // is unambiguous even before opening the list.
                        selectedItemBuilder: (context) => _countryCodes
                            .map((code) => Align(
                                  alignment: Alignment.centerLeft,
                                  child: Text(
                                    '${_countryFlags[code] ?? ''} $code',
                                    style: TextStyle(
                                        color: AppColors.textPrimary,
                                        fontSize: 15,
                                        fontWeight: FontWeight.w500),
                                  ),
                                ))
                            .toList(),
                        items: _countryCodes
                            .map((code) => DropdownMenuItem(
                                  value: code,
                                  child: Text(
                                    '${_countryFlags[code] ?? ''}  $code',
                                    style: TextStyle(
                                      color: AppColors.textPrimary,
                                      fontSize: 15,
                                    ),
                                  ),
                                ))
                            .toList(),
                        onChanged: (val) =>
                            setState(() => _selectedCountryCode = val!),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: SizedBox(
                      height: 52,
                      child: TextField(
                        controller: _phoneCtrl,
                        keyboardType: TextInputType.phone,
                        style: TextStyle(color: AppColors.textPrimary, fontSize: 15),
                        cursorColor: AppColors.textPrimary,
                        decoration: InputDecoration(
                          hintText: 'Phone number',
                          hintStyle: TextStyle(color: AppColors.textSecondary),
                          filled: true,
                          fillColor: AppColors.cardDark,
                          contentPadding:
                              const EdgeInsets.symmetric(horizontal: 14),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(10),
                            borderSide:
                                BorderSide(color: AppColors.lowGrey.withValues(alpha: 0.4)),
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(10),
                            borderSide:
                                BorderSide(color: AppColors.lowGrey.withValues(alpha: 0.4)),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(10),
                            borderSide: const BorderSide(
                                color: AppColors.emergencyRed, width: 1.4),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              // CAPTCHA — same "I'm not a robot" gate used by both sign-in
              // paths below; only its container styling changed.
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                decoration: BoxDecoration(
                  color: AppColors.cardDark,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: _isHuman
                        ? AppColors.safeGreen
                        : AppColors.lowGrey.withValues(alpha: 0.4),
                  ),
                ),
                child: Row(children: [
                  Checkbox(
                    value: _isHuman,
                    onChanged: (val) => setState(() => _isHuman = val!),
                    activeColor: AppColors.safeGreen,
                  ),
                  Text("I'm not a robot",
                      style: TextStyle(color: AppColors.textPrimary, fontSize: 14)),
                  const Spacer(),
                  Image.network(
                    'https://www.gstatic.com/recaptcha/api2/logo_48.png',
                    width: 28,
                    height: 28,
                    errorBuilder: (_, __, ___) => Icon(
                      Icons.security,
                      color: AppColors.textSecondary,
                    ),
                  ),
                ]),
              ),
              const SizedBox(height: 20),
              // Send OTP button — the one button that keeps a solid red
              // fill, since it's the primary action on the screen.
              SizedBox(
                width: double.infinity,
                height: 52,
                child: ElevatedButton(
                  onPressed: auth.isLoading ? null : _sendOtp,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.emergencyRed,
                    disabledBackgroundColor:
                        AppColors.emergencyRed.withValues(alpha: 0.5),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ),
                  child: auth.isLoading
                      ? const SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(
                              color: Colors.white, strokeWidth: 2.4),
                        )
                      : const Text('Send OTP',
                          style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                              color: Colors.white)),
                ),
              ),
              const SizedBox(height: 18),
              // Divider
              Row(children: [
                Expanded(child: Divider(color: AppColors.lowGrey.withValues(alpha: 0.5))),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Text('OR',
                      style: TextStyle(
                          color: AppColors.textSecondary,
                          fontSize: 12,
                          fontWeight: FontWeight.w600)),
                ),
                Expanded(child: Divider(color: AppColors.lowGrey.withValues(alpha: 0.5))),
              ]),
              const SizedBox(height: 18),
              // Google Sign-In button — a neutral, clearly-enabled-looking
              // button (never tinted red — Google's own brand guidelines
              // ask third-party apps not to recolor its mark, and doing
              // so would also fight this screen's "red = primary action"
              // hierarchy).
              SizedBox(
                width: double.infinity,
                height: 52,
                child: OutlinedButton.icon(
                  onPressed: auth.backendLoading ? null : _googleSignIn,
                  style: OutlinedButton.styleFrom(
                    backgroundColor: AppColors.cardDark,
                    disabledForegroundColor: AppColors.textSecondary,
                    side: BorderSide(color: AppColors.lowGrey.withValues(alpha: 0.6)),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ),
                  icon: auth.backendLoading
                      ? SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                              strokeWidth: 2.2, color: AppColors.textPrimary),
                        )
                      : const _GoogleGIcon(size: 20),
                  label: Text('Continue with Google',
                      style: TextStyle(
                          color: AppColors.textPrimary,
                          fontSize: 15,
                          fontWeight: FontWeight.w600)),
                ),
              ),
              const SizedBox(height: 28),
              // Terms/Privacy — real, tappable links to the actual
              // published pages (no in-app legal screens exist to reuse
              // instead). The "emergency use only" line stays plain text;
              // it isn't a link to anything.
              Center(
                child: Column(
                  children: [
                    Text.rich(
                      TextSpan(
                        style: TextStyle(
                            color: AppColors.textSecondary, fontSize: 11.5),
                        children: [
                          const TextSpan(text: 'By continuing, you agree to our '),
                          _legalLinkSpan('Terms of Service', _termsTap),
                          const TextSpan(text: ' and '),
                          _legalLinkSpan('Privacy Policy', _privacyTap),
                          const TextSpan(text: '.'),
                        ],
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'This app is for emergency use only.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          color: AppColors.textSecondary, fontSize: 11.5),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
            ],
          ),
        ),
      ),
    );
  }
}

/// A tappable legal-link span for use inside [Text.rich] — underlined and
/// in the primary text color (not a saturated link-blue, which would add
/// a fourth competing accent color to an already-considered palette) so
/// it still visibly reads as interactive without shouting for attention.
/// Using spans (rather than separate inline widgets) keeps the whole
/// sentence flowing and wrapping as one unit, so a trailing word/period
/// never gets orphaned onto its own line the way a `Wrap` of separate
/// Text widgets could.
TextSpan _legalLinkSpan(String label, TapGestureRecognizer recognizer) {
  return TextSpan(
    text: label,
    recognizer: recognizer,
    style: TextStyle(
      color: AppColors.textPrimary,
      fontWeight: FontWeight.w600,
      decoration: TextDecoration.underline,
      decorationColor: AppColors.textSecondary,
    ),
  );
}

/// A dependency-free approximation of the Google "G" mark (no bundled
/// brand asset exists in this project, and Material Icons has no actual
/// Google logo — `Icons.g_mobiledata` it replaces is a mobile-data
/// network icon, not a brand mark). Purely decorative/non-semantic; the
/// button's own text label carries the accessible name.
class _GoogleGIcon extends StatelessWidget {
  const _GoogleGIcon({required this.size});

  final double size;

  @override
  Widget build(BuildContext context) {
    return ExcludeSemantics(
      child: SizedBox(
        width: size,
        height: size,
        child: CustomPaint(painter: _GoogleGPainter()),
      ),
    );
  }
}

class _GoogleGPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2;
    final strokeWidth = size.width * 0.22;
    final rect = Rect.fromCircle(center: center, radius: radius - strokeWidth / 2);

    Paint arcPaint(Color color) => Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.butt;

    const degToRad = 3.14159265359 / 180;
    // Four arcs with a genuine ~40° open gap on the right (340° to 20°,
    // i.e. centered on 3 o'clock) — an earlier version of this had red
    // and blue meeting with zero gap, which drew a fully closed 4-color
    // wheel instead of a "G" shape; caught by visually inspecting the
    // rendered icon on a real device, not just reading the angle math.
    canvas.drawArc(rect, 270 * degToRad, 70 * degToRad, false, arcPaint(const Color(0xFFEA4335))); // red: top
    canvas.drawArc(rect, 20 * degToRad, 70 * degToRad, false, arcPaint(const Color(0xFF4285F4))); // blue: right
    canvas.drawArc(rect, 90 * degToRad, 90 * degToRad, false, arcPaint(const Color(0xFF34A853))); // green: bottom
    canvas.drawArc(rect, 180 * degToRad, 90 * degToRad, false, arcPaint(const Color(0xFFFBBC05))); // yellow: left

    // The crossbar sits inside that same gap, from the ring's center out
    // to its outer edge at mid-height — closing the gap the way the real
    // "G" does.
    final barPaint = Paint()..color = const Color(0xFF4285F4);
    final barRect = Rect.fromLTWH(
      center.dx,
      center.dy - strokeWidth / 2,
      radius - center.dx + strokeWidth / 2,
      strokeWidth,
    );
    canvas.drawRect(barRect, barPaint);
  }

  @override
  bool shouldRepaint(covariant _GoogleGPainter oldDelegate) => false;
}

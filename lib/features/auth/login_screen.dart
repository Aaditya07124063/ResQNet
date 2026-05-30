import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/constants/app_colors.dart';
import '../../core/constants/app_routes.dart';
import 'auth_service.dart';
import 'otp_screen.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});
  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _phoneCtrl = TextEditingController();
  String _selectedCountryCode = '+91';
  bool _isHuman = false;

  final List<String> _countryCodes = ['+91', '+1', '+44', '+61', '+971'];

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
    final success = await auth.signInWithGoogle();
    if (success && mounted) {
      Navigator.pushReplacementNamed(context, AppRoutes.home);
    }
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
              const SizedBox(height: 40),
              // Logo
              Center(
                child: Container(
                  width: 80,
                  height: 80,
                  decoration: BoxDecoration(
                    color: AppColors.emergencyRed,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: const Center(
                    child: Text('RQ',
                        style: TextStyle(
                            color: Colors.white,
                            fontSize: 32,
                            fontWeight: FontWeight.w900)),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              const Center(
                child: Text('ResQNet',
                    style: TextStyle(
                        color: AppColors.emergencyRed,
                        fontSize: 28,
                        fontWeight: FontWeight.bold)),
              ),
              const Center(
                child: Text('Emergency Communication Platform',
                    style: TextStyle(
                        color: AppColors.textSecondary, fontSize: 12)),
              ),
              const SizedBox(height: 48),
              const Text('Login with Phone',
                  style: TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: 18,
                      fontWeight: FontWeight.bold)),
              const SizedBox(height: 16),
              // Phone input
              Row(children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  decoration: BoxDecoration(
                    color: AppColors.cardDark,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<String>(
                      value: _selectedCountryCode,
                      dropdownColor: AppColors.cardDark,
                      style: const TextStyle(color: Colors.white),
                      items: _countryCodes
                          .map((code) => DropdownMenuItem(
                              value: code,
                              child: Text(code,
                                  style: const TextStyle(
                                      color: Colors.white))))
                          .toList(),
                      onChanged: (val) =>
                          setState(() => _selectedCountryCode = val!),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: _phoneCtrl,
                    keyboardType: TextInputType.phone,
                    style: const TextStyle(color: Colors.white),
                    decoration: InputDecoration(
                      hintText: 'Enter phone number',
                      hintStyle:
                          const TextStyle(color: AppColors.textSecondary),
                      filled: true,
                      fillColor: AppColors.cardDark,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                ),
              ]),
              const SizedBox(height: 24),
              // CAPTCHA
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: AppColors.cardDark,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: _isHuman
                        ? AppColors.safeGreen
                        : AppColors.lowGrey,
                  ),
                ),
                child: Row(children: [
                  Checkbox(
                    value: _isHuman,
                    onChanged: (val) => setState(() => _isHuman = val!),
                    activeColor: AppColors.safeGreen,
                  ),
                  const Text("I'm not a robot",
                      style: TextStyle(color: AppColors.textPrimary)),
                  const Spacer(),
                  Image.network(
                    'https://www.gstatic.com/recaptcha/api2/logo_48.png',
                    width: 32,
                    height: 32,
                    errorBuilder: (_, __, ___) => const Icon(
                      Icons.security,
                      color: AppColors.infoBlue,
                    ),
                  ),
                ]),
              ),
              const SizedBox(height: 24),
              // Send OTP button
              SizedBox(
                width: double.infinity,
                height: 52,
                child: ElevatedButton(
                  onPressed: auth.isLoading ? null : _sendOtp,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.emergencyRed,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ),
                  child: auth.isLoading
                      ? const CircularProgressIndicator(color: Colors.white)
                      : const Text('Send OTP',
                          style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                              color: Colors.white)),
                ),
              ),
              const SizedBox(height: 20),
              // Divider
              Row(children: [
                const Expanded(child: Divider(color: AppColors.lowGrey)),
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 12),
                  child: Text('OR',
                      style: TextStyle(color: AppColors.textSecondary)),
                ),
                const Expanded(child: Divider(color: AppColors.lowGrey)),
              ]),
              const SizedBox(height: 20),
              // Google Sign In button
              SizedBox(
                width: double.infinity,
                height: 52,
                child: OutlinedButton.icon(
                  onPressed: auth.isLoading ? null : _googleSignIn,
                  style: OutlinedButton.styleFrom(
                    side: const BorderSide(color: AppColors.lowGrey),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ),
                  icon: const Icon(Icons.g_mobiledata,
                      color: Colors.white, size: 28),
                  label: const Text('Continue with Google',
                      style: TextStyle(color: Colors.white, fontSize: 16)),
                ),
              ),
              const SizedBox(height: 32),
              const Center(
                child: Text(
                  'By continuing, you agree to our Terms of Service.\nThis app is for emergency use only.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      color: AppColors.textSecondary, fontSize: 11),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
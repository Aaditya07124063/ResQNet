import 'dart:io';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import '../../core/constants/app_colors.dart';
import '../../core/services/crash_detection_service.dart';
import '../../core/services/seismic_service.dart';
import '../../core/services/theme_service.dart';
import '../../features/auth/auth_service.dart';

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _fatherNameController = TextEditingController();
  final _ageController = TextEditingController();
  final _addressController = TextEditingController();
  final _emergencyContactController = TextEditingController();
  final _allergiesController = TextEditingController();
  final _medicationsController = TextEditingController();

  String _bloodGroup = 'A+';
  bool _loading = true;
  bool _saving = false;
  String? _photoUrl;
  bool _uploadingPhoto = false;

  static const List<String> _bloodGroups = [
    'A+', 'A-', 'B+', 'B-', 'AB+', 'AB-', 'O+', 'O-'
  ];

  @override
  void initState() {
    super.initState();
    _loadProfile();
  }

  @override
  void dispose() {
    _nameController.dispose();
    _fatherNameController.dispose();
    _ageController.dispose();
    _addressController.dispose();
    _emergencyContactController.dispose();
    _allergiesController.dispose();
    _medicationsController.dispose();
    super.dispose();
  }

  Future<void> _loadProfile() async {
    final auth = context.read<AuthService>();
    final uid = auth.currentUser?.uid;
    if (uid == null) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    try {
      final doc = await FirebaseFirestore.instance
          .collection('user_profiles')
          .doc(uid)
          .get()
          .timeout(const Duration(seconds: 8));
      if (doc.exists && mounted) {
        final data = doc.data()!;
        _nameController.text = data['name'] ?? '';
        _fatherNameController.text = data['fatherName'] ?? '';
        _ageController.text = data['age'] ?? '';
        _addressController.text = data['address'] ?? '';
        _emergencyContactController.text = data['emergencyContact'] ?? '';
        _allergiesController.text = data['allergies'] ?? '';
        _medicationsController.text = data['medications'] ?? '';
        setState(() {
          _bloodGroup = data['bloodGroup'] ?? 'A+';
          _photoUrl = data['photoUrl'];
        });
      }
    } catch (e) {
      debugPrint('Profile load error: $e');
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _pickAndUploadPhoto() async {
    final picker = ImagePicker();
    final picked = await picker.pickImage(
      source: ImageSource.gallery,
      maxWidth: 512,
      maxHeight: 512,
      imageQuality: 75,
    );
    if (picked == null) return;

    final auth = context.read<AuthService>();
    final uid = auth.currentUser?.uid;
    if (uid == null) return;

    setState(() => _uploadingPhoto = true);

    try {
      final file = File(picked.path);
      final ref = FirebaseStorage.instance
          .ref()
          .child('profile_pictures')
          .child('$uid.jpg');
      await ref.putFile(file);
      final url = await ref.getDownloadURL();
      await FirebaseFirestore.instance
          .collection('user_profiles')
          .doc(uid)
          .set({'photoUrl': url}, SetOptions(merge: true));
      if (mounted) setState(() => _photoUrl = url);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Profile picture updated!'),
          backgroundColor: Colors.green,
          duration: Duration(seconds: 2),
        ));
      }
    } catch (e) {
      debugPrint('Photo upload error: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Failed to upload photo. Try again.'),
          backgroundColor: Colors.red,
          duration: Duration(seconds: 2),
        ));
      }
    }
    if (mounted) setState(() => _uploadingPhoto = false);
  }

  Future<void> _saveProfile() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);

    final auth = context.read<AuthService>();
    final uid = auth.currentUser?.uid;
    if (uid == null) {
      setState(() => _saving = false);
      return;
    }

    final data = {
      'name': _nameController.text.trim(),
      'fatherName': _fatherNameController.text.trim(),
      'age': _ageController.text.trim(),
      'bloodGroup': _bloodGroup,
      'address': _addressController.text.trim(),
      'emergencyContact': _emergencyContactController.text.trim(),
      'allergies': _allergiesController.text.trim(),
      'medications': _medicationsController.text.trim(),
      'phone': auth.currentUser?.phoneNumber ?? '',
      'email': auth.currentUser?.email ?? '',
      'updatedAt': DateTime.now().toIso8601String(),
    };

    setState(() => _saving = false);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Profile saved!'),
        backgroundColor: Colors.green,
        duration: Duration(seconds: 2),
      ));
    }

    FirebaseFirestore.instance
        .collection('user_profiles')
        .doc(uid)
        .set(data, SetOptions(merge: true))
        .catchError((e) => debugPrint('Profile sync error: $e'));
  }

  Future<void> _logout() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppColors.surfaceDark,
        title: const Text('Logout',
            style: TextStyle(color: AppColors.textPrimary)),
        content: const Text('Are you sure you want to logout?',
            style: TextStyle(color: AppColors.textSecondary)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel',
                style: TextStyle(color: AppColors.textSecondary)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Logout',
                style: TextStyle(color: AppColors.emergencyRed)),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      await context.read<AuthService>().signOut();
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthService>();

    return Scaffold(
      backgroundColor: AppColors.backgroundDark,
      appBar: AppBar(
        backgroundColor: AppColors.surfaceDark,
        title: const Text('My Profile',
            style: TextStyle(
                color: AppColors.textPrimary,
                fontWeight: FontWeight.bold)),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: AppColors.textPrimary),
          onPressed: () => Navigator.pop(context),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.logout, color: AppColors.emergencyRed),
            onPressed: _logout,
            tooltip: 'Logout',
          ),
        ],
      ),
      body: _loading
          ? const Center(
              child: CircularProgressIndicator(
                  color: AppColors.emergencyRed))
          : SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Center(
                      child: Column(
                        children: [
                          GestureDetector(
                            onTap: _uploadingPhoto
                                ? null
                                : _pickAndUploadPhoto,
                            child: Stack(
                              children: [
                                CircleAvatar(
                                  radius: 48,
                                  backgroundColor: AppColors.emergencyRed,
                                  backgroundImage: _photoUrl != null
                                      ? NetworkImage(_photoUrl!)
                                      : null,
                                  child: _photoUrl == null
                                      ? Text(
                                          _nameController.text.isNotEmpty
                                              ? _nameController.text[0]
                                                  .toUpperCase()
                                              : '?',
                                          style: const TextStyle(
                                              color: Colors.white,
                                              fontSize: 32,
                                              fontWeight: FontWeight.bold),
                                        )
                                      : null,
                                ),
                                if (_uploadingPhoto)
                                  Positioned.fill(
                                    child: CircleAvatar(
                                      radius: 48,
                                      backgroundColor:
                                          Colors.black.withOpacity(0.5),
                                      child:
                                          const CircularProgressIndicator(
                                              color: Colors.white,
                                              strokeWidth: 2),
                                    ),
                                  ),
                                Positioned(
                                  bottom: 0,
                                  right: 0,
                                  child: Container(
                                    padding: const EdgeInsets.all(6),
                                    decoration: const BoxDecoration(
                                      color: AppColors.emergencyRed,
                                      shape: BoxShape.circle,
                                    ),
                                    child: const Icon(Icons.camera_alt,
                                        color: Colors.white, size: 16),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 6),
                          const Text('Tap to change photo',
                              style: TextStyle(
                                  color: AppColors.textSecondary,
                                  fontSize: 12)),
                          const SizedBox(height: 4),
                          Text(
                            auth.currentUser?.phoneNumber ??
                                auth.currentUser?.email ??
                                'No contact info',
                            style: const TextStyle(
                                color: AppColors.textSecondary,
                                fontSize: 14),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 24),
                    _sectionTitle('Personal Information'),
                    _buildField('Full Name *', _nameController,
                        icon: Icons.person, required: true),
                    _buildField("Father's Name (Optional)",
                        _fatherNameController,
                        icon: Icons.family_restroom),
                    _buildField('Age (Optional)', _ageController,
                        icon: Icons.cake,
                        keyboardType: TextInputType.number),
                    _buildField('Address (Optional)', _addressController,
                        icon: Icons.home, maxLines: 2),
                    const SizedBox(height: 16),
                    _sectionTitle('Medical Information'),
                    Container(
                      margin: const EdgeInsets.only(bottom: 12),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 4),
                      decoration: BoxDecoration(
                        color: AppColors.cardDark,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.bloodtype,
                              color: AppColors.emergencyRed, size: 20),
                          const SizedBox(width: 12),
                          const Text('Blood Group',
                              style: TextStyle(
                                  color: AppColors.textSecondary,
                                  fontSize: 13)),
                          const Spacer(),
                          DropdownButton<String>(
                            value: _bloodGroup,
                            dropdownColor: AppColors.cardDark,
                            style: const TextStyle(
                                color: AppColors.textPrimary,
                                fontWeight: FontWeight.bold),
                            underline: const SizedBox(),
                            items: _bloodGroups
                                .map((g) => DropdownMenuItem(
                                    value: g,
                                    child: Text(g,
                                        style: const TextStyle(
                                            color: AppColors.emergencyRed,
                                            fontWeight: FontWeight.bold))))
                                .toList(),
                            onChanged: (v) =>
                                setState(() => _bloodGroup = v ?? 'A+'),
                          ),
                        ],
                      ),
                    ),
                    _buildField(
                        'Allergies (Optional)', _allergiesController,
                        icon: Icons.warning_amber,
                        hint: 'e.g. Penicillin, Peanuts'),
                    _buildField(
                        'Current Medications (Optional)',
                        _medicationsController,
                        icon: Icons.medication,
                        hint: 'e.g. Aspirin 100mg',
                        maxLines: 2),
                    const SizedBox(height: 16),
                    _sectionTitle('Emergency Contact'),
                    _buildField(
                        'Contact Number (Optional)',
                        _emergencyContactController,
                        icon: Icons.phone,
                        keyboardType: TextInputType.phone,
                        hint: '+91 XXXXXXXXXX'),
                    const SizedBox(height: 16),
                    _sectionTitle('Safety Detection'),
                    Consumer<CrashDetectionService>(
                      builder: (context, crash, _) {
                        return Container(
                          margin: const EdgeInsets.only(bottom: 12),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 16, vertical: 4),
                          decoration: BoxDecoration(
                            color: AppColors.cardDark,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Row(
                            children: [
                              Icon(Icons.car_crash,
                                  color: crash.isActive
                                      ? AppColors.connectedGreen
                                      : AppColors.textSecondary,
                                  size: 20),
                              const SizedBox(width: 12),
                              const Expanded(
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.start,
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text('Crash Detection',
                                        style: TextStyle(
                                            color: AppColors.textPrimary,
                                            fontSize: 13)),
                                    Text('Auto SOS on vehicle impact',
                                        style: TextStyle(
                                            color: AppColors.textSecondary,
                                            fontSize: 11)),
                                  ],
                                ),
                              ),
                              Switch(
                                value: crash.isActive,
                                onChanged: (val) =>
                                    val ? crash.start() : crash.stop(),
                                activeColor: AppColors.connectedGreen,
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                    Consumer<SeismicService>(
                      builder: (context, seismic, _) {
                        return Container(
                          margin: const EdgeInsets.only(bottom: 12),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 16, vertical: 4),
                          decoration: BoxDecoration(
                            color: AppColors.cardDark,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Row(
                            children: [
                              Icon(Icons.crisis_alert,
                                  color: seismic.isActive
                                      ? AppColors.connectedGreen
                                      : AppColors.textSecondary,
                                  size: 20),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.start,
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    const Text('Earthquake Detection',
                                        style: TextStyle(
                                            color: AppColors.textPrimary,
                                            fontSize: 13)),
                                    Text(
                                      seismic.isActive
                                          ? (seismic.isStationary
                                              ? 'Monitoring — phone is still'
                                              : 'Active — waiting for phone to rest')
                                          : 'Detects tremors when phone is resting',
                                      style: const TextStyle(
                                          color: AppColors.textSecondary,
                                          fontSize: 11),
                                    ),
                                  ],
                                ),
                              ),
                              Switch(
                                value: seismic.isActive,
                                onChanged: (val) =>
                                    val ? seismic.start() : seismic.stop(),
                                activeColor: AppColors.connectedGreen,
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                    const SizedBox(height: 16),
                    _sectionTitle('App Theme'),
                    Consumer<ThemeService>(
                      builder: (context, themeService, _) {
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Container(
                              margin: const EdgeInsets.only(bottom: 12),
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 16, vertical: 4),
                              decoration: BoxDecoration(
                                color: AppColors.cardDark,
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Row(
                                children: [
                                  Icon(
                                    themeService.isDarkMode
                                        ? Icons.dark_mode
                                        : Icons.light_mode,
                                    color: themeService.isDarkMode
                                        ? AppColors.accentBlue
                                        : AppColors.warningAmber,
                                    size: 20,
                                  ),
                                  const SizedBox(width: 12),
                                  Text(
                                    themeService.isDarkMode
                                        ? 'Dark Mode'
                                        : 'Light Mode',
                                    style: const TextStyle(
                                        color: AppColors.textSecondary,
                                        fontSize: 13),
                                  ),
                                  const Spacer(),
                                  Switch(
                                    value: themeService.isDarkMode,
                                    onChanged: (_) =>
                                        themeService.toggleDarkMode(),
                                    activeColor: AppColors.accentBlue,
                                  ),
                                ],
                              ),
                            ),
                          ],
                        );
                      },
                    ),
                    const SizedBox(height: 32),
                    SizedBox(
                      width: double.infinity,
                      height: 52,
                      child: ElevatedButton.icon(
                        onPressed: _saving ? null : _saveProfile,
                        icon: _saving
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                    color: Colors.white, strokeWidth: 2))
                            : const Icon(Icons.save, color: Colors.white),
                        label: Text(
                          _saving ? 'Saving...' : 'Save Profile',
                          style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                              fontSize: 16),
                        ),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppColors.emergencyRed,
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12)),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                  ],
                ),
              ),
            ),
    );
  }

  Widget _sectionTitle(String title) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Text(title,
          style: const TextStyle(
              color: AppColors.textPrimary,
              fontWeight: FontWeight.bold,
              fontSize: 15)),
    );
  }

  Widget _buildField(
    String label,
    TextEditingController controller, {
    IconData? icon,
    String? hint,
    int maxLines = 1,
    TextInputType keyboardType = TextInputType.text,
    bool required = false,
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      child: TextFormField(
        controller: controller,
        maxLines: maxLines,
        keyboardType: keyboardType,
        style: const TextStyle(color: AppColors.textPrimary),
        validator: required
            ? (v) => v == null || v.trim().isEmpty ? 'Required' : null
            : null,
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          labelStyle: const TextStyle(
              color: AppColors.textSecondary, fontSize: 13),
          hintStyle: const TextStyle(
              color: AppColors.textSecondary, fontSize: 12),
          prefixIcon: icon != null
              ? Icon(icon, color: AppColors.textSecondary, size: 20)
              : null,
          filled: true,
          fillColor: AppColors.cardDark,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide.none,
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(
                color: AppColors.emergencyRed, width: 1.5),
          ),
        ),
      ),
    );
  }
}
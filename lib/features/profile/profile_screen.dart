import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import '../../core/constants/app_colors.dart';
import '../../core/data/locations.dart';
import '../../core/network/api_client.dart';
import '../../core/services/crash_detection_service.dart';
import '../../core/services/profile_service.dart';
import '../../core/services/seismic_service.dart';
import '../../core/services/sensor_recorder_service.dart';
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
  String? _country;
  String? _state;
  String? _city;
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
    final profile = context.read<ProfileService>();

    // Cache first — instant, and works with zero internet, and doesn't
    // depend on being logged in (this used to require a Firebase uid
    // before even trying the cache, so Profile went blank offline or
    // whenever the auth session hadn't restored yet).
    await profile.loadFromCache();
    if (mounted) {
      _applyToControllers(profile);
      setState(() => _loading = false);
    }

    // Then a best-effort refresh from the cloud, in case another device
    // changed something — silently keeps the cached values if offline.
    await profile.syncFromCloud();
    if (mounted) _applyToControllers(profile);
  }

  void _applyToControllers(ProfileService profile) {
    _nameController.text = profile.name;
    _fatherNameController.text = profile.fatherName;
    _ageController.text = profile.age;
    _addressController.text = profile.address;
    _emergencyContactController.text = profile.emergencyContact;
    _allergiesController.text = profile.allergies;
    _medicationsController.text = profile.medications;
    setState(() {
      _bloodGroup = profile.bloodGroup.isNotEmpty ? profile.bloodGroup : 'A+';
      _photoUrl = profile.photoUrl.isNotEmpty ? profile.photoUrl : null;
      // Only keep a saved value if it's still valid for the current
      // dropdown options — avoids crashing on stale/free-text data.
      _country =
          Locations.countries.contains(profile.country) ? profile.country : null;
      _state = Locations.statesFor(_country).contains(profile.state)
          ? profile.state
          : null;
      _city = Locations.citiesFor(_state).contains(profile.city)
          ? profile.city
          : null;
    });
  }

  /// Phase 20: uploads to the ResQNet backend's MinIO-backed storage
  /// (`PUT /api/v1/profile/image`, Phase 6) instead of Firebase Storage.
  /// Requires a backend session (Google or, once Phase 8/9 exists, phone)
  /// — gated on that rather than a Firebase uid, since a backend-Google-
  /// authenticated user has no Firebase session at all (see
  /// docs/DONE.md's Phase 20 entry).
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
    if (!await auth.isBackendSignedIn()) return;

    setState(() => _uploadingPhoto = true);

    try {
      final bytes = await File(picked.path).readAsBytes();
      await ApiClient.instance.putBytes(
        '/profile/image',
        bytes: bytes,
        contentType: 'image/jpeg',
        auth: true,
      );
      if (!mounted) return;
      final profile = context.read<ProfileService>();
      // The backend never returns a permanent URL (the object is private,
      // visibility-gated) — fetch a fresh signed one to display now.
      await profile.refreshPhotoUrl();
      if (mounted) setState(() => _photoUrl = profile.photoUrl);
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
    // No early return on a missing uid — that would skip the local cache
    // save too (this used to write straight to Firestore only, so an
    // unauthenticated/not-yet-restored session silently saved nothing at
    // all, online or offline). ProfileService.saveProfile() always caches
    // locally and only skips its own Firestore push when there's no uid.

    final data = {
      'name': _nameController.text.trim(),
      'fatherName': _fatherNameController.text.trim(),
      'age': _ageController.text.trim(),
      'bloodGroup': _bloodGroup,
      'country': _country ?? '',
      'state': _state ?? '',
      'city': _city ?? '',
      'address': _addressController.text.trim(),
      'emergencyContact': _emergencyContactController.text.trim(),
      'allergies': _allergiesController.text.trim(),
      'medications': _medicationsController.text.trim(),
      'photoUrl': _photoUrl ?? '',
      'phone': auth.currentUser?.phoneNumber ?? '',
      'email': auth.currentUser?.email ?? '',
      'updatedAt': DateTime.now().toIso8601String(),
    };

    // Saves to the local cache immediately (so it's there next time even
    // with zero internet) and pushes to Firestore in the background.
    await context.read<ProfileService>().saveProfile(data);

    setState(() => _saving = false);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Profile saved!'),
        backgroundColor: Colors.green,
        duration: Duration(seconds: 2),
      ));
    }
  }

  Future<void> _logout() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppColors.surfaceDark,
        title: Text('Logout',
            style: TextStyle(color: AppColors.textPrimary)),
        content: Text('Are you sure you want to logout?',
            style: TextStyle(color: AppColors.textSecondary)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text('Cancel',
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
        title: Text('My Profile',
            style: TextStyle(
                color: AppColors.textPrimary,
                fontWeight: FontWeight.bold)),
        leading: IconButton(
          icon: Icon(Icons.arrow_back, color: AppColors.textPrimary),
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
                          Text('Tap to change photo',
                              style: TextStyle(
                                  color: AppColors.textSecondary,
                                  fontSize: 12)),
                          const SizedBox(height: 4),
                          Text(
                            auth.currentUser?.phoneNumber ??
                                auth.currentUser?.email ??
                                'No contact info',
                            style: TextStyle(
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
                    _buildDropdown<String>(
                      label: 'Country',
                      icon: Icons.public,
                      value: _country,
                      items: Locations.countries,
                      onChanged: (v) => setState(() {
                        _country = v;
                        _state = null;
                        _city = null;
                      }),
                    ),
                    _buildDropdown<String>(
                      label: 'State',
                      icon: Icons.map,
                      value: _state,
                      items: Locations.statesFor(_country),
                      hint: _country == null ? 'Select country first' : 'Select state',
                      onChanged: _country == null
                          ? null
                          : (v) => setState(() {
                                _state = v;
                                _city = null;
                              }),
                    ),
                    _buildDropdown<String>(
                      label: 'City / Town',
                      icon: Icons.location_city,
                      value: _city,
                      items: Locations.citiesFor(_state),
                      hint: _state == null ? 'Select state first' : 'Select city/town',
                      onChanged:
                          _state == null ? null : (v) => setState(() => _city = v),
                    ),
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
                          Text('Blood Group',
                              style: TextStyle(
                                  color: AppColors.textSecondary,
                                  fontSize: 13)),
                          const Spacer(),
                          DropdownButton<String>(
                            value: _bloodGroup,
                            dropdownColor: AppColors.cardDark,
                            style: TextStyle(
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
                              Expanded(
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
                                    Text('Earthquake Detection',
                                        style: TextStyle(
                                            color: AppColors.textPrimary,
                                            fontSize: 13)),
                                    Text(
                                      seismic.isActive
                                          ? (seismic.isStationary
                                              ? 'Monitoring — phone is still'
                                              : 'Active — waiting for phone to rest')
                                          : 'Detects tremors when phone is resting',
                                      style: TextStyle(
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
                                    style: TextStyle(
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
                    const SizedBox(height: 16),
                    _sectionTitle('Developer / Data Collection'),
                    Consumer<SensorRecorderService>(
                      builder: (context, recorder, _) {
                        return Container(
                          margin: const EdgeInsets.only(bottom: 12),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 16, vertical: 12),
                          decoration: BoxDecoration(
                            color: AppColors.cardDark,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Icon(Icons.fiber_manual_record,
                                      color: recorder.isRecording
                                          ? AppColors.emergencyRed
                                          : AppColors.textSecondary,
                                      size: 14),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      recorder.isRecording
                                          ? 'Recording — ${recorder.bufferedSampleCount} samples captured'
                                          : 'Records raw accelerometer/gyro/GPS data for detector testing and replay.',
                                      style: TextStyle(
                                          color: AppColors.textSecondary,
                                          fontSize: 12),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 10),
                              SizedBox(
                                width: double.infinity,
                                child: OutlinedButton.icon(
                                  onPressed: () async {
                                    if (recorder.isRecording) {
                                      final session =
                                          await recorder.stopRecording();
                                      if (context.mounted && session != null) {
                                        ScaffoldMessenger.of(context)
                                            .showSnackBar(SnackBar(
                                          content: Text(
                                              'Saved session with ${session.samples.length} samples'),
                                        ));
                                      }
                                    } else {
                                      await recorder.startRecording();
                                    }
                                  },
                                  icon: Icon(recorder.isRecording
                                      ? Icons.stop
                                      : Icons.fiber_manual_record),
                                  label: Text(recorder.isRecording
                                      ? 'Stop Recording'
                                      : 'Start Recording'),
                                  style: OutlinedButton.styleFrom(
                                    foregroundColor: recorder.isRecording
                                        ? AppColors.emergencyRed
                                        : AppColors.connectedGreen,
                                    side: BorderSide(
                                        color: recorder.isRecording
                                            ? AppColors.emergencyRed
                                            : AppColors.connectedGreen),
                                  ),
                                ),
                              ),
                              const SizedBox(height: 4),
                              TextButton(
                                onPressed: () =>
                                    _showSessionListDialog(context, recorder),
                                child: Text('View saved sessions',
                                    style: TextStyle(
                                        color: AppColors.accentBlue)),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                    const SizedBox(height: 16),
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

  Future<void> _shareSession(
      BuildContext context, SensorRecorderService recorder, String sessionId,
      {required bool asCsv}) async {
    try {
      await (asCsv
          ? recorder.shareSessionCsv(sessionId)
          : recorder.shareSessionJson(sessionId));
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Share failed: $e')));
      }
    }
  }

  Future<void> _showSessionListDialog(
      BuildContext context, SensorRecorderService recorder) async {
    final ids = await recorder.listSavedSessionIds();
    if (!context.mounted) return;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: AppColors.surfaceDark,
        title: Text('Recorded Sessions',
            style: TextStyle(color: AppColors.textPrimary)),
        content: SizedBox(
          width: double.maxFinite,
          child: ids.isEmpty
              ? Text('No sessions recorded yet.',
                  style: TextStyle(color: AppColors.textSecondary))
              : ListView.builder(
                  shrinkWrap: true,
                  itemCount: ids.length,
                  itemBuilder: (_, i) {
                    final id = ids[i];
                    return ListTile(
                      title: Text(id,
                          style: TextStyle(
                              color: AppColors.textPrimary, fontSize: 12),
                          overflow: TextOverflow.ellipsis),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            icon: Icon(Icons.ios_share,
                                color: AppColors.accentBlue, size: 20),
                            tooltip: 'Share CSV',
                            onPressed: () => _shareSession(
                                dialogContext, recorder, id,
                                asCsv: true),
                          ),
                          IconButton(
                            icon: Icon(Icons.code,
                                color: AppColors.accentBlue, size: 20),
                            tooltip: 'Share JSON',
                            onPressed: () => _shareSession(
                                dialogContext, recorder, id,
                                asCsv: false),
                          ),
                          IconButton(
                            icon: Icon(Icons.delete_outline,
                                color: AppColors.emergencyRed, size: 20),
                            tooltip: 'Delete',
                            onPressed: () async {
                              await recorder.deleteSession(id);
                              if (dialogContext.mounted) {
                                Navigator.pop(dialogContext);
                                _showSessionListDialog(context, recorder);
                              }
                            },
                          ),
                        ],
                      ),
                    );
                  },
                ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Widget _sectionTitle(String title) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Text(title,
          style: TextStyle(
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
        style: TextStyle(color: AppColors.textPrimary),
        validator: required
            ? (v) => v == null || v.trim().isEmpty ? 'Required' : null
            : null,
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          labelStyle: TextStyle(
              color: AppColors.textSecondary, fontSize: 13),
          hintStyle: TextStyle(
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

  Widget _buildDropdown<T>({
    required String label,
    required IconData icon,
    required T? value,
    required List<T> items,
    required ValueChanged<T?>? onChanged,
    String? hint,
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      child: DropdownButtonFormField<T>(
        initialValue: value,
        items: items
            .map((item) => DropdownMenuItem<T>(
                  value: item,
                  child: Text('$item',
                      style: TextStyle(color: AppColors.textPrimary)),
                ))
            .toList(),
        onChanged: onChanged,
        dropdownColor: AppColors.cardDark,
        style: TextStyle(color: AppColors.textPrimary),
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          labelStyle: TextStyle(
              color: AppColors.textSecondary, fontSize: 13),
          hintStyle: TextStyle(
              color: AppColors.textSecondary, fontSize: 12),
          prefixIcon: Icon(icon, color: AppColors.textSecondary, size: 20),
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
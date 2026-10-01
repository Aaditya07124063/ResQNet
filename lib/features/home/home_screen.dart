import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';
import '../../core/constants/app_colors.dart';
import '../../core/constants/app_routes.dart';
import '../../core/models/emergency_message.dart';
import '../../core/services/app_shortcut_service.dart';
import '../../core/services/background_detection_service.dart';
import '../../core/services/communication_service.dart';
import '../../core/services/crash_detection_service.dart';
import '../../core/services/device_key_service.dart';
import '../../core/services/emergency_communication_service.dart';
import '../../core/services/hazard_service.dart';
import '../../core/network/websocket_client.dart';
import '../../core/services/map_cache_service.dart';
import '../../core/services/mesh_service.dart';
import '../../core/services/location_service.dart';
import '../../core/services/notification_service.dart';
import '../../core/services/profile_service.dart';
import '../../core/services/safe_zone_service.dart';
import '../../core/services/seismic_service.dart';
import '../../core/services/trusted_contacts_service.dart';
import '../../core/utils/permission_handler.dart' as perms;
import '../../core/notifications/notification_catalog.dart';
import '../../core/services/connectivity_status_service.dart';
import '../../core/services/sos_dispatch_service.dart';
import '../../core/services/sos_service.dart';
import '../permissions/permissions_screen.dart';
import '../sos/sos_actions.dart';
import 'notification_navigation.dart';
import 'widgets/sos_home_panel.dart';
import '../../features/profile/profile_screen.dart';
import '../../features/emergency_contacts/emergency_contacts_screen.dart';
import '../../features/sos_history/sos_history_screen.dart';
import '../../features/communication/conversations_list_screen.dart';
import '../../features/emergency/nearby_emergency_screen.dart';
import '../crash_countdown/crash_countdown_dialog.dart';
import '../seismic/earthquake_alert_dialog.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  bool _crashDialogOpen = false;
  bool _quakeDialogOpen = false;
  late final AppShortcutService _shortcutService;
  late final NotificationService _notifications;
  StreamSubscription? _nearbySosSubscription;
  StreamSubscription? _meshIncomingSubscription;

  /// Undo actions for every listener this screen registers on app-lifetime
  /// services, so a re-created HomeScreen (e.g. after signing out and in
  /// again) never leaves the previous instance's listeners running.
  final List<VoidCallback> _removeListeners = [];

  void _listen(Listenable service, VoidCallback listener) {
    service.addListener(listener);
    _removeListeners.add(() => service.removeListener(listener));
  }
  NotificationSpec? _detectionNotification;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _init());

    // Nearby emergency alerts (Section 14/16D): a lightweight in-app
    // banner for a `nearby_sos_created` WebSocket event, for when the app
    // is already open — the FCM push (received while backgrounded) is a
    // separate, existing delivery path that deep-links here the same way.
    _nearbySosSubscription =
        ResQNetWebSocketClient.instance.events.listen(_handleNearbySosEvent);

    // Home-screen SOS (Android App Shortcut / iOS Home Screen Quick
    // Action): HomeScreen only exists once _AuthGate (app.dart) has
    // already confirmed an authenticated session — an unauthenticated
    // launch never reaches this widget at all, it lands on LoginScreen
    // instead, which is the entire "fail safely" behavior this needs.
    // From here it's the exact same SosScreen a manual tap on the SOS
    // button already opens (below), with its own existing confirm-then-
    // 5-second-cancellable-countdown gate — nothing here sends anything
    // by itself.
    _notifications = NotificationService();
    _notifications.pendingTap.addListener(_handleNotificationTap);
    WidgetsBinding.instance.addPostFrameCallback((_) => _handleNotificationTap());

    _shortcutService = context.read<AppShortcutService>();
    _shortcutService.pendingAction.addListener(_handlePendingShortcutAction);
    // Covers a cold start via the shortcut, where the value may already
    // have been set before this listener was attached.
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
    // Same countdown as the Home button — the shortcut never sends by itself.
    startSos(context);
  }

  void _handleNotificationTap() {
    if (!mounted) return;
    final tap = _notifications.pendingTap.value;
    if (tap == null) return;
    _notifications.pendingTap.value = null;
    openNotificationDestination(context, tap);
  }

  void _handleNearbySosEvent(Map<String, dynamic> event) {
    if (!mounted || event['type'] != 'nearby_sos_created') return;
    final sosEventId = event['sosEventId'] as String?;
    if (sosEventId == null) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        backgroundColor: AppColors.emergencyRed,
        content: Text('🚨 Emergency nearby — ${event['category'] ?? 'general'}'),
        action: SnackBarAction(
          label: 'View',
          textColor: Colors.white,
          onPressed: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => NearbyEmergencyScreen(sosEventId: sosEventId)),
          ),
        ),
        duration: const Duration(seconds: 8),
      ),
    );
  }

  @override
  void dispose() {
    _shortcutService.pendingAction.removeListener(
      _handlePendingShortcutAction,
    );
    _nearbySosSubscription?.cancel();
    _meshIncomingSubscription?.cancel();
    _notifications.pendingTap.removeListener(_handleNotificationTap);
    for (final remove in _removeListeners) {
      remove();
    }
    super.dispose();
  }

  Future<void> _init() async {
    context.read<ConnectivityStatusService>().start();

    // Explain before the system prompts, once. SOS never waits on this.
    try {
      if (!await perms.permissionsExplained()) {
        if (!mounted) return;
        await showPermissionExplainer(context);
        await perms.markPermissionsExplained();
      }
      await perms.requestAllPermissions();
    } catch (e) {
      debugPrint('Permission request error: $e');
    }
    if (!mounted) return;
    _notifications.initialize().catchError(
      (e) => debugPrint('Notification init error: $e'),
    );
    // Cryptographic device identity (Phase 2): ensures a local signing
    // keypair exists and registers its public key with the backend —
    // best-effort, same non-blocking pattern as the FCM token
    // registration above, so an ordinary user normally already has a
    // registered key before they ever go offline (see
    // docs on the offline/edge case). Never throws into this init path;
    // failures are retried the next time this screen initializes.
    DeviceKeyService.instance.registerWithBackendIfNeeded().catchError(
      (e) {
        debugPrint('Device key registration error: $e');
        return false;
      },
    );
    if (!mounted) return;
    context.read<LocationService>().getCurrentLocation().then((pos) {
      // Silently keep the local map cached so it still works if the
      // user loses connectivity before they think to download it.
      if (pos != null) MapCacheService.autoCacheNearbyArea(pos);
    });
    final meshService = context.read<MeshService>();
    meshService.startMeshNetwork().catchError(
      (e) => debugPrint('Mesh start error: $e'),
    );

    // Offline alerts: an emergency received over the mesh raises a local
    // notification (deduplicated with any push for the same event).
    final gatewaySync = context.read<EmergencyCommunicationService>();
    _meshIncomingSubscription = meshService.incomingMessages.listen((message) {
      // If this phone is online, act as a gateway for the new emergency
      // now rather than waiting for the next periodic sync.
      if (message.originEnvelope != null && !message.isCancellation) {
        gatewaySync.syncPendingEvents().catchError((Object e) => debugPrint('Gateway sync error: $e'));
      }
      final target = message.cancelsEventId;
      _notifications.notifyMeshMessage(
        message,
        cancellationVerified: target != null && (meshService.cancellationFor(target)?.verified ?? false),
      );
    });

    // An SOS that was active when the app was closed stays active and keeps
    // being offered to devices that come into range.
    final sosService = context.read<SosService>();
    Future<void> resumeSos() => SosDispatchService.resumeActive(sosService, meshService)
        .catchError((Object e) => debugPrint('Resume active SOS failed: $e'));
    if (sosService.isRestored) {
      resumeSos();
    } else {
      late final VoidCallback onRestored;
      onRestored = () {
        if (!sosService.isRestored) return;
        sosService.removeListener(onRestored);
        resumeSos();
      };
      _listen(sosService, onRestored);
    }

    // ResQNet-native chat: connects the realtime WebSocket transport and
    // retries any messages that failed to send in a previous session.
    // Best-effort — a user signed in only via phone (no backend Google
    // session, Phase 4C not yet extended to phone auth) simply gets a
    // 401 on the underlying API calls, the same graceful degradation
    // SosService's own backend reporting already has.
    context.read<CommunicationService>().initialize().catchError(
      (e) => debugPrint('Communication service init error: $e'),
    );

    // Phase 8/9: reconcile any emergency events created while offline (or
    // whose online submission failed mid-flight) with the backend, and
    // keep checking periodically in case connectivity returns later
    // without any other app activity triggering a retry. Best-effort,
    // non-blocking — see EmergencyCommunicationService's own doc comment
    // on why a failed attempt here is never a fatal error.
    final emergencyCommunicationService = context.read<EmergencyCommunicationService>();
    emergencyCommunicationService.syncPendingEvents().catchError(
      (e) => debugPrint('Emergency sync error: $e'),
    );
    emergencyCommunicationService.startPeriodicSync();

    final hazardService = context.read<HazardService>();
    hazardService.load();
    final safeZoneService = context.read<SafeZoneService>();
    safeZoneService.load();
    context.read<TrustedContactsService>().load();
    // Absorb any flood/fire/etc. hazards, and any safe zones/safe routes
    // ("this way is safe") — peer-reported or relayed from an official
    // feed — that arrive over the mesh, offline or online.
    _listen(meshService, () {
      hazardService.syncFromMesh(meshService.messages);
      safeZoneService.syncFromMesh(meshService.messages);
    });

    // Keeps sensor-based detection running while ResQNet is backgrounded
    // (Android foreground service — see BackgroundDetectionService for
    // the iOS platform limits this can't get around). Best-effort: if
    // the notification permission is denied, detection still runs
    // normally while the app is in the foreground.
    BackgroundDetectionService.start().catchError(
      (e) {
        debugPrint('Background detection start error: $e');
        return false;
      },
    );

    // Vehicle crash detection
    final crashService = context.read<CrashDetectionService>();
    crashService.start();
    _listen(crashService, () {
      if (crashService.crashDetected && mounted && !_crashDialogOpen) {
        _crashDialogOpen = true;
        _showDetectionNotification('crash', crashService.confirmationCountdown.inSeconds);
        showDialog(
          context: context,
          barrierDismissible: false,
          builder: (_) => const CrashCountdownDialog(),
        ).then((_) {
          _crashDialogOpen = false;
          _dismissDetectionNotification();
        });
      }
    });

    // Earthquake (seismic P-wave) detection
    final seismicService = context.read<SeismicService>();
    seismicService.start();
    _listen(seismicService, () {
      if (seismicService.quakeDetected && mounted && !_quakeDialogOpen) {
        _quakeDialogOpen = true;
        _showDetectionNotification('earthquake', seismicService.confirmationCountdown.inSeconds);
        showDialog(
          context: context,
          barrierDismissible: false,
          builder: (_) => const EarthquakeAlertDialog(),
        ).then((_) {
          _quakeDialogOpen = false;
          _dismissDetectionNotification();
        });
      }
    });
  }

  /// The detection countdown runs even while ResQNet is in the background
  /// (foreground service); this notification is how the user finds out
  /// and gets back in to cancel it.
  void _showDetectionNotification(String detection, int seconds) {
    final spec = detectionWarningSpec(detection: detection, seconds: seconds);
    _detectionNotification = spec;
    _notifications.show(spec);
  }

  void _dismissDetectionNotification() {
    final spec = _detectionNotification;
    _detectionNotification = null;
    if (spec != null) _notifications.dismiss(spec);
  }

  Future<void> _sendImSafe() async {
    HapticFeedback.mediumImpact();
    final profile = context.read<ProfileService>();
    double? lat, lng;
    try {
      final pos = await Geolocator.getLastKnownPosition();
      lat = pos?.latitude;
      lng = pos?.longitude;
    } catch (_) {}
    if (!mounted) return;

    final name = profile.name.isNotEmpty ? profile.name : 'Someone';
    final locText = (lat != null && lng != null)
        ? ' Location: ${lat.toStringAsFixed(5)}, ${lng.toStringAsFixed(5)}'
        : '';

    final message = EmergencyMessage(
      id: const Uuid().v4(),
      senderId: name,
      senderName: name,
      message: '✅ I AM SAFE — $name is safe.$locText',
      type: EmergencyType.general,
      priority: PriorityLevel.low,
      latitude: lat,
      longitude: lng,
      timestamp: DateTime.now(),
    );
    await context.read<MeshService>().broadcastMessage(message);

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('✅ "I am safe" broadcast to nearby devices'),
          backgroundColor: Colors.green,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final mesh = context.watch<MeshService>();

    return Scaffold(
      backgroundColor: AppColors.backgroundDark,
      appBar: AppBar(
        backgroundColor: AppColors.surfaceDark,
        title: Row(
          children: [
            const Icon(Icons.emergency,
                color: AppColors.emergencyRed, size: 24),
            const SizedBox(width: 8),
            Text('ResQNet',
                style: TextStyle(
                    color: AppColors.textPrimary,
                    fontWeight: FontWeight.bold,
                    fontSize: 20)),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Profile and settings',
            icon: Icon(Icons.account_circle,
                color: AppColors.textSecondary, size: 28),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const ProfileScreen()),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SosHomePanel(),
              const SizedBox(height: 16),
              OutlinedButton.icon(
                onPressed: _sendImSafe,
                icon: const Icon(Icons.check_circle, color: AppColors.connectedGreen),
                label: const Text(
                  "I AM SAFE — tell everyone nearby",
                  style: TextStyle(color: AppColors.connectedGreen, fontWeight: FontWeight.bold),
                ),
                style: OutlinedButton.styleFrom(
                  side: const BorderSide(color: AppColors.connectedGreen),
                  minimumSize: const Size.fromHeight(52),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
              ),
              const SizedBox(height: 24),
              _ActionButton(
                icon: Icons.map,
                label: 'Emergency Map',
                subtitle: 'Hazards, safe zones, and offline maps',
                color: AppColors.accentBlue,
                onTap: () => Navigator.pushNamed(context, AppRoutes.map),
              ),
              const SizedBox(height: 12),
              _ActionButton(
                icon: Icons.hub,
                label: 'Offline Mesh',
                subtitle:
                    '${mesh.connectedCount} connected · ${mesh.discoveredDevices.length} nearby · ${mesh.messages.length} alerts',
                color: AppColors.primaryOrange,
                onTap: () => Navigator.pushNamed(context, AppRoutes.mesh),
              ),
              const SizedBox(height: 12),
              _ActionButton(
                icon: Icons.chat_bubble_outline,
                label: 'Messages',
                subtitle: 'Chat with a trusted contact on ResQNet',
                color: AppColors.connectedGreen,
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const ConversationsListScreen()),
                ),
              ),
              const SizedBox(height: 12),
              _ActionButton(
                icon: Icons.history,
                label: 'SOS History',
                subtitle: 'Your past SOS alerts, including offline ones',
                color: AppColors.accentBlue,
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const SosHistoryScreen()),
                ),
              ),
              const SizedBox(height: 12),
              _ActionButton(
                icon: Icons.contact_phone,
                label: 'Emergency Contacts',
                subtitle: 'Call local emergency services',
                color: AppColors.emergencyRed,
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const EmergencyContactsScreen()),
                ),
              ),
              const SizedBox(height: 12),
              _ActionButton(
                icon: Icons.dashboard,
                label: 'Dashboard',
                subtitle: 'All alerts received over the mesh',
                color: const Color(0xFF6A1B9A),
                onTap: () => Navigator.pushNamed(context, AppRoutes.dashboard),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final String subtitle;
  final Color color;
  final VoidCallback onTap;

  const _ActionButton({
    required this.icon,
    required this.label,
    required this.subtitle,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: '$label. $subtitle',
      excludeSemantics: true,
      child: GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppColors.cardDark,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: color.withValues(alpha: 0.3)),
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, color: color, size: 24),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label,
                      style: TextStyle(
                          color: AppColors.textPrimary,
                          fontWeight: FontWeight.bold,
                          fontSize: 15)),
                  Text(subtitle,
                      style: TextStyle(
                          color: AppColors.textSecondary, fontSize: 12)),
                ],
              ),
            ),
            Icon(Icons.chevron_right,
                color: AppColors.textSecondary),
          ],
        ),
      ),
      ),
    );
  }
}
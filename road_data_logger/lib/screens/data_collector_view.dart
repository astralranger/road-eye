import 'dart:async';
import 'dart:io';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../config/app_config.dart';
import '../models/spatial_video_report.dart';
import '../models/telemetry_payload.dart';
import '../services/api_service.dart';
import '../services/camera_service.dart';
import '../services/sensor_service.dart';
import '../services/spatial_queue_service.dart';
import '../services/spatial_security_service.dart';
import '../theme/uber_theme.dart';
import '../utils/mp4_validator.dart';
import '../utils/url_helper.dart';
import '../utils/uuid_helper.dart';
import 'account_screen.dart';
import 'map_screen.dart';

enum CaptureMode { patrolStream, spatialVideo }

class DataCollectorView extends StatefulWidget {
  final CameraDescription? camera;
  const DataCollectorView({super.key, this.camera});

  @override
  State<DataCollectorView> createState() => _DataCollectorViewState();
}

class _DataCollectorViewState extends State<DataCollectorView>
    with SingleTickerProviderStateMixin {
  final CameraService _cameraService = CameraService();
  final SensorService _sensorService = SensorService();
  final ApiService _apiService = ApiService();
  final SpatialSecurityService _spatialSecurityService = SpatialSecurityService();
  final SpatialQueueService _spatialQueueService = SpatialQueueService();

  final TextEditingController _urlCtrl = TextEditingController();

  CaptureMode _selectedMode = CaptureMode.patrolStream;
  String _targetUrl = "Not Set";
  bool _isSystemReady = false;
  bool _isStreaming = false;

  // Spatial Video state
  bool _isRecordingSpatialVideo = false;
  int _spatialRecordingSeconds = 0;
  Timer? _spatialRecordTimer;

  final ValueNotifier<String> _statusMessageNotifier = ValueNotifier<String>("Ready");
  final ValueNotifier<Color> _statusColorNotifier = ValueNotifier<Color>(UberColors.textSecondary);

  Timer? _patrolLoopTimer;
  late final AnimationController _pulseController;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 1),
    );

    _initializeSystem();
  }

  @override
  void dispose() {
    _stopStreaming(notify: false);
    _spatialRecordTimer?.cancel();
    _pulseController.dispose();
    _cameraService.dispose();
    _sensorService.dispose();
    _apiService.dispose();
    _spatialSecurityService.dispose();
    _urlCtrl.dispose();
    _statusMessageNotifier.dispose();
    _statusColorNotifier.dispose();
    super.dispose();
  }

  Future<void> _initializeSystem() async {
    await _loadTargetUrl();

    try {
      await [Permission.camera, Permission.location, Permission.microphone].request();
    } catch (e) {
      debugPrint("Permission request warning: $e");
    }

    final bool cameraOk = await _cameraService.initialize(widget.camera);
    _sensorService.start();

    if (mounted) {
      setState(() => _isSystemReady = true);

      if (!cameraOk) {
        _updateStatus("Camera Unavailable (Telemetry Mode)", UberColors.amber);
      }

      if (_targetUrl == "Not Set") {
        Future.delayed(const Duration(milliseconds: 600), () {
          if (mounted && _targetUrl == "Not Set") {
            _showUrlDialog();
          }
        });
      }
    }
  }

  Future<void> _loadTargetUrl() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString('target_url') ?? "Not Set";
    if (mounted) {
      setState(() => _targetUrl = saved);
    }
  }

  Future<void> _saveTargetUrl(String rawUrl) async {
    final sanitized = UrlHelper.sanitize(rawUrl);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('target_url', sanitized);
    if (mounted) {
      setState(() => _targetUrl = sanitized);
    }
  }

  void _showUrlDialog() {
    _urlCtrl.text = UrlHelper.toDisplayString(_targetUrl);
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        backgroundColor: UberColors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: const BorderSide(color: UberColors.border),
        ),
        title: const Text("Edge AI Node Connection", style: UberTypography.title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              "Enter the inference server endpoint (e.g. 10.0.2.2:5000 for emulator, LAN IP, or Cloudflare URL):",
              style: TextStyle(color: UberColors.textSecondary, fontSize: 13, height: 1.4),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _urlCtrl,
              autofocus: true,
              style: const TextStyle(color: UberColors.textPrimary, fontSize: 14),
              decoration: const InputDecoration(
                hintText: "10.0.2.2:5000",
                prefixIcon: Icon(Icons.lan_outlined, color: UberColors.textSecondary, size: 20),
              ),
            ),
          ],
        ),
        actionsPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        actions: [
          TextButton(
            child: const Text("CANCEL", style: TextStyle(color: UberColors.textSecondary, fontWeight: FontWeight.w600)),
            onPressed: () => Navigator.pop(context),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: UberColors.white,
              foregroundColor: UberColors.black,
              minimumSize: const Size(100, 44),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
            ),
            child: const Text("SAVE", style: TextStyle(fontWeight: FontWeight.w700)),
            onPressed: () {
              if (_urlCtrl.text.trim().isNotEmpty) {
                _saveTargetUrl(_urlCtrl.text.trim());
                Navigator.pop(context);
              }
            },
          )
        ],
      ),
    );
  }

  void _updateStatus(String message, Color color) {
    _statusMessageNotifier.value = message;
    _statusColorNotifier.value = color;
  }

  // ==========================================
  // PATROL STREAMING LOGIC
  // ==========================================

  void _toggleStreaming() {
    if (_targetUrl == "Not Set" || !UrlHelper.isValidUrl(_targetUrl)) {
      _showUrlDialog();
      return;
    }
    _isStreaming ? _stopStreaming() : _startStreaming();
  }

  void _startStreaming() {
    setState(() => _isStreaming = true);
    _pulseController.repeat(reverse: true);
    _updateStatus("Patrol Active", UberColors.green);

    _scheduleNextCapture(Duration.zero);
  }

  void _stopStreaming({bool notify = true}) {
    _patrolLoopTimer?.cancel();
    _patrolLoopTimer = null;
    _pulseController.stop();
    _isStreaming = false;
    if (notify && mounted) {
      setState(() {});
      _updateStatus("Patrol Paused", UberColors.amber);
    }
  }

  void _scheduleNextCapture(Duration delay) {
    _patrolLoopTimer?.cancel();
    if (!_isStreaming) return;

    _patrolLoopTimer = Timer(delay, () async {
      if (!_isStreaming || !mounted) return;
      await _captureAndTransmit();
      if (_isStreaming && mounted) {
        _scheduleNextCapture(const Duration(seconds: 2));
      }
    });
  }

  Future<void> _captureAndTransmit() async {
    final position = _sensorService.currentPosition;
    if (position == null) {
      _updateStatus("Waiting for GPS lock...", UberColors.amber);
      return;
    }

    if (position.accuracy > 20.0) {
      _updateStatus("GPS Accuracy Low (±${position.accuracy.toStringAsFixed(0)}m)", UberColors.amber);
      return;
    }

    final double roughness = _sensorService.getRoughnessAndReset();

    String? base64Img;
    if (_cameraService.isInitialized) {
      base64Img = await _cameraService.captureAsBase64();
    }
    base64Img ??= "";

    if (base64Img.isEmpty && _cameraService.isInitialized) {
      return;
    }

    final user = AppConfig.currentUser;

    final payload = TelemetryPayload(
      imageBase64: base64Img,
      gps: GpsData(
        lat: position.latitude,
        lon: position.longitude,
        speed: position.speed,
        heading: position.heading,
      ),
      instanceIp: _targetUrl,
      roughness: roughness,
      userId: user?.id ?? "anonymous",
      userEmail: user?.email ?? "anonymous",
    );

    final response = await _apiService.sendDetectionPayload(
      targetUrl: _targetUrl,
      payload: payload,
    );

    if (!mounted || !_isStreaming) return;

    if (response.success) {
      if (response.status == "DETECTED") {
        _updateStatus("POTHOLE DETECTED", UberColors.red);
      } else {
        _updateStatus("AI: ${response.status}", UberColors.white);
      }
    } else {
      _updateStatus("NODE: ${response.status}", UberColors.amber);
    }
  }

  // ==========================================
  // SPATIAL VIDEO RECORDING LOGIC
  // ==========================================

  Future<void> _toggleSpatialRecording() async {
    if (_isRecordingSpatialVideo) {
      await _stopSpatialRecording();
    } else {
      await _startSpatialRecording();
    }
  }

  Future<void> _startSpatialRecording() async {
    if (!_cameraService.isInitialized) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("Camera hardware not available for video recording."),
          backgroundColor: UberColors.red,
        ),
      );
      return;
    }

    try {
      final tempDir = Directory.systemTemp;
      final tempPath = '${tempDir.path}/temp_rec_${DateTime.now().millisecondsSinceEpoch}.mp4';

      // Mark recording in progress for crash recovery resilience
      await SpatialQueueService.markRecordingStarted(tempPath);

      final started = await _cameraService.startVideoRecording();
      if (!started) {
        await SpatialQueueService.markRecordingFinished();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text("Failed to start hardware video recording."),
              backgroundColor: UberColors.red,
            ),
          );
        }
        return;
      }

      await _spatialSecurityService.startSecurityTrail();

      setState(() {
        _isRecordingSpatialVideo = true;
        _spatialRecordingSeconds = 0;
      });

      _pulseController.repeat(reverse: true);
      _updateStatus("RECORDING SPATIAL BURST", UberColors.red);

      _spatialRecordTimer?.cancel();
      _spatialRecordTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
        if (!mounted) return;
        setState(() {
          _spatialRecordingSeconds++;
        });

        // Safe automatic cap at 90 seconds to prevent storage exhaustion
        if (_spatialRecordingSeconds >= 90) {
          _stopSpatialRecording();
        }
      });
    } catch (e) {
      debugPrint("startSpatialRecording error: $e");
      await SpatialQueueService.markRecordingFinished();
      setState(() => _isRecordingSpatialVideo = false);
      _pulseController.stop();
    }
  }

  Future<void> _stopSpatialRecording() async {
    if (!_isRecordingSpatialVideo) return;

    _spatialRecordTimer?.cancel();
    _spatialRecordTimer = null;

    setState(() => _isRecordingSpatialVideo = false);
    _pulseController.stop();
    _updateStatus("FINALIZING SPATIAL REPORT...", UberColors.amber);

    try {
      final XFile? videoXFile = await _cameraService.stopVideoRecording();
      if (videoXFile == null) {
        await SpatialQueueService.markRecordingFinished();
        _updateStatus("Recording Cancelled", UberColors.textSecondary);
        return;
      }

      final int durationMs = _spatialRecordingSeconds * 1000;
      final file = File(videoXFile.path);
      final int fileSizeBytes = await file.length();

      if (durationMs < 1500 || fileSizeBytes == 0) {
        await file.delete().catchError((_) => file);
        await SpatialQueueService.markRecordingFinished();
        _updateStatus("Recording discarded (burst < 1.5s)", UberColors.amber);
        return;
      }

      final user = AppConfig.currentUser;
      final String userId = user?.id ?? "anonymous_${DateTime.now().millisecondsSinceEpoch}";
      final String userEmail = user?.email ?? "anonymous@roadsense.local";

      final securityResult = await _spatialSecurityService.stopSecurityTrail(
        userId: userId,
        durationMs: durationMs,
        fileSizeBytes: fileSizeBytes,
      );

      // Persist video file in local spatial video directory with container atom validation
      final destDir = _spatialQueueService.videoDirectory;
      final reportId = UuidHelper.generateV4();
      final videoFilename = 'spatial_${DateTime.now().millisecondsSinceEpoch}.mp4';
      final targetPath = '${destDir.path}/$videoFilename';

      final bool persisted = await Mp4Validator.safelyFinalizeAndPersist(file, targetPath);
      if (!persisted) {
        await SpatialQueueService.markRecordingFinished();
        _updateStatus("Recording discarded (moov container error)", UberColors.red);
        return;
      }

      // Clear crash recovery flag
      await SpatialQueueService.markRecordingFinished();

      final report = SpatialVideoReport(
        id: reportId,
        userId: userId,
        userEmail: userEmail,
        recordedAt: DateTime.now(),
        durationMs: durationMs,
        resolution: '1280x720',
        fileSizeBytes: fileSizeBytes,
        localVideoPath: targetPath,
        videoFilename: videoFilename,
        storageStatus: 'local_only',
        checksumSha256: securityResult.checksumSha256,
        pointCount: securityResult.pointCount,
        startLat: securityResult.startLat,
        startLon: securityResult.startLon,
        endLat: securityResult.endLat,
        endLon: securityResult.endLon,
        distanceMeters: securityResult.distanceMeters,
        avgSpeedKmh: securityResult.avgSpeedKmh,
        gpsTrail: securityResult.trail,
        isTamperVerified: securityResult.isTamperVerified,
        splatStatus: 'queued',
        syncStatus: SyncStatus.pending,
      );

      await _spatialQueueService.enqueueReport(report);

      _updateStatus("Saved (${securityResult.pointCount} pts)", UberColors.green);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              "Spatial video logged! ${securityResult.pointCount} GPS pts locked. SHA-256 verified.",
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            backgroundColor: UberColors.surfaceElevated,
            duration: const Duration(seconds: 4),
            action: SnackBarAction(
              label: "VIEW",
              textColor: UberColors.white,
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const AccountScreen()),
                );
              },
            ),
          ),
        );
      }
    } catch (e) {
      debugPrint("stopSpatialRecording error: $e");
      await SpatialQueueService.markRecordingFinished();
      _updateStatus("Error saving spatial burst", UberColors.red);
    }
  }

  Future<void> _logout() async {
    _stopStreaming();
    if (_isRecordingSpatialVideo) {
      await _stopSpatialRecording();
    }
    if (AppConfig.isSupabaseInitialized) {
      await AppConfig.supabase.auth.signOut();
    }
  }

  // ==========================================
  // UI BUILD
  // ==========================================

  @override
  Widget build(BuildContext context) {
    if (!_isSystemReady) {
      return const Scaffold(
        backgroundColor: UberColors.background,
        body: Center(child: CircularProgressIndicator(color: UberColors.white)),
      );
    }

    return Scaffold(
      backgroundColor: UberColors.background,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // 1. Fullscreen Camera Viewport
          Positioned.fill(
            child: _cameraService.isInitialized
                ? CameraPreview(_cameraService.controller!)
                : Container(
                    color: UberColors.background,
                    child: Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Container(
                            width: 64,
                            height: 64,
                            decoration: BoxDecoration(
                              color: UberColors.surfaceElevated,
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(color: UberColors.border),
                            ),
                            child: const Icon(Icons.videocam_off_outlined, size: 32, color: UberColors.textSecondary),
                          ),
                          const SizedBox(height: 16),
                          const Text("Camera Off • Telemetry Mode", style: UberTypography.title),
                          const SizedBox(height: 4),
                          const Text("Accelerometer & GPS logging active", style: TextStyle(color: UberColors.textTertiary, fontSize: 12)),
                        ],
                      ),
                    ),
                  ),
          ),

          // 2. High-Contrast Vignette Gradient
          Positioned.fill(
            child: IgnorePointer(
              child: Container(
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Color(0xDD000000),
                      Colors.transparent,
                      Colors.transparent,
                      Color(0xEE000000),
                    ],
                    stops: [0.0, 0.22, 0.65, 1.0],
                  ),
                ),
              ),
            ),
          ),

          // 3. Anchored Top Navigation & Mode Switcher
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              bottom: false,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Top Navigation Header Bar
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    child: Row(
                      children: [
                        // App Badge Pill
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                          decoration: BoxDecoration(
                            color: UberColors.surface,
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(color: UberColors.border),
                          ),
                          child: Row(
                            children: [
                              Container(
                                width: 8,
                                height: 8,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: (_isStreaming || _isRecordingSpatialVideo)
                                      ? (_isRecordingSpatialVideo ? UberColors.red : UberColors.green)
                                      : UberColors.textTertiary,
                                ),
                              ),
                              const SizedBox(width: 8),
                              Text(
                                _isRecordingSpatialVideo
                                    ? "REC SPATIAL"
                                    : (_isStreaming ? "PATROL ACTIVE" : "ROAD SENSE"),
                                style: UberTypography.caption.copyWith(
                                  color: UberColors.textPrimary,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const Spacer(),

                        // Account & Spatial Reports View
                        _buildHeaderIconButton(
                          icon: Icons.person_outline_rounded,
                          tooltip: "Account & Reports",
                          onTap: () => Navigator.push(
                            context,
                            MaterialPageRoute(builder: (_) => const AccountScreen()),
                          ),
                        ),
                        const SizedBox(width: 8),

                        // Map Button
                        _buildHeaderIconButton(
                          icon: Icons.map_outlined,
                          tooltip: "Map Database",
                          onTap: () => Navigator.push(
                            context,
                            MaterialPageRoute(builder: (_) => const MapScreen()),
                          ),
                        ),
                        const SizedBox(width: 8),

                        // Settings Button
                        _buildHeaderIconButton(
                          icon: Icons.settings_outlined,
                          tooltip: "Node Configuration",
                          onTap: _showUrlDialog,
                        ),
                        const SizedBox(width: 8),

                        // Logout Button
                        _buildHeaderIconButton(
                          icon: Icons.logout,
                          tooltip: "Sign Out",
                          onTap: _logout,
                          iconColor: UberColors.red,
                        ),
                      ],
                    ),
                  ),

                  // Mode Switcher Pill Toggle
                  _buildModeSelector(),

                  // Floating HUD Telemetry Card (Speed/Vibration OR Spatial GPS Lock)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                    child: _selectedMode == CaptureMode.patrolStream
                        ? _buildPatrolHudCard()
                        : _buildSpatialHudCard(),
                  ),
                ],
              ),
            ),
          ),

          // 4. Anchored Bottom Control Sheet
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: Container(
              decoration: const BoxDecoration(
                color: UberColors.surface,
                borderRadius: BorderRadius.only(
                  topLeft: Radius.circular(20),
                  topRight: Radius.circular(20),
                ),
                border: Border(top: BorderSide(color: UberColors.border, width: 1.2)),
              ),
              child: SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Handle Bar
                      Center(
                        child: Container(
                          width: 36,
                          height: 4,
                          decoration: BoxDecoration(
                            color: UberColors.border,
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                      ),
                      const SizedBox(height: 14),

                      // Status Header Pill
                      AnimatedBuilder(
                        animation: Listenable.merge([_statusMessageNotifier, _statusColorNotifier]),
                        builder: (_, __) => Container(
                          width: double.infinity,
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                          decoration: BoxDecoration(
                            color: UberColors.surfaceElevated,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: UberColors.border),
                          ),
                          child: Row(
                            children: [
                              if (_isStreaming || _isRecordingSpatialVideo)
                                FadeTransition(
                                  opacity: _pulseController,
                                  child: Container(
                                    width: 8,
                                    height: 8,
                                    decoration: const BoxDecoration(shape: BoxShape.circle, color: UberColors.red),
                                  ),
                                )
                              else
                                Container(
                                  width: 8,
                                  height: 8,
                                  decoration: const BoxDecoration(shape: BoxShape.circle, color: UberColors.textTertiary),
                                ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                  _statusMessageNotifier.value.toUpperCase(),
                                  style: TextStyle(
                                    color: _statusColorNotifier.value,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w800,
                                    letterSpacing: 0.8,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 14),

                      // High-Density Context Info Row
                      if (_selectedMode == CaptureMode.patrolStream)
                        _buildPatrolBottomInfo()
                      else
                        _buildSpatialBottomInfo(),

                      const SizedBox(height: 18),

                      // Full-Width Uber High-Impact CTA Button
                      SizedBox(
                        width: double.infinity,
                        height: 54,
                        child: ElevatedButton(
                          onPressed: _selectedMode == CaptureMode.patrolStream
                              ? _toggleStreaming
                              : _toggleSpatialRecording,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: (_selectedMode == CaptureMode.patrolStream && _isStreaming) ||
                                    (_selectedMode == CaptureMode.spatialVideo && _isRecordingSpatialVideo)
                                ? UberColors.red
                                : UberColors.white,
                            foregroundColor: (_selectedMode == CaptureMode.patrolStream && _isStreaming) ||
                                    (_selectedMode == CaptureMode.spatialVideo && _isRecordingSpatialVideo)
                                ? UberColors.white
                                : UberColors.black,
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                            elevation: 0,
                          ),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              if (_selectedMode == CaptureMode.spatialVideo && !_isRecordingSpatialVideo) ...[
                                Container(
                                  width: 12,
                                  height: 12,
                                  decoration: const BoxDecoration(
                                    color: UberColors.red,
                                    shape: BoxShape.circle,
                                  ),
                                ),
                                const SizedBox(width: 8),
                              ],
                              Text(
                                _selectedMode == CaptureMode.patrolStream
                                    ? (_isStreaming ? "STOP PATROL" : "START PATROL")
                                    : (_isRecordingSpatialVideo
                                        ? "STOP & SAVE SPATIAL BURST"
                                        : "RECORD SPATIAL VIDEO"),
                                style: const TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: 0.8,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ==========================================
  // COMPONENT BUILDERS
  // ==========================================

  Widget _buildModeSelector() {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: UberColors.surface.withValues(alpha: 0.95),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: UberColors.border),
      ),
      child: Row(
        children: [
          Expanded(
            child: _buildModeTab(
              title: "PATROL INFERENCE",
              icon: Icons.radar,
              isSelected: _selectedMode == CaptureMode.patrolStream,
              onTap: () {
                if (_isRecordingSpatialVideo) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text("Stop spatial video recording before switching mode."),
                      backgroundColor: UberColors.amber,
                    ),
                  );
                  return;
                }
                setState(() {
                  _selectedMode = CaptureMode.patrolStream;
                  _updateStatus(
                    _isStreaming ? "Patrol Active" : "Ready",
                    _isStreaming ? UberColors.green : UberColors.textSecondary,
                  );
                });
              },
            ),
          ),
          const SizedBox(width: 4),
          Expanded(
            child: _buildModeTab(
              title: "3D SPATIAL VIDEO",
              icon: Icons.view_in_ar_rounded,
              isSelected: _selectedMode == CaptureMode.spatialVideo,
              onTap: () {
                if (_isStreaming) {
                  _stopStreaming();
                }
                setState(() {
                  _selectedMode = CaptureMode.spatialVideo;
                  _updateStatus(
                    _isRecordingSpatialVideo
                        ? "Recording Spatial Burst"
                        : "Spatial Ready (Local-First)",
                    _isRecordingSpatialVideo ? UberColors.red : UberColors.white,
                  );
                });
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildModeTab({
    required String title,
    required IconData icon,
    required bool isSelected,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(vertical: 8),
        decoration: BoxDecoration(
          color: isSelected ? UberColors.surfaceElevated : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          border: isSelected ? Border.all(color: UberColors.border) : null,
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              icon,
              size: 14,
              color: isSelected ? UberColors.white : UberColors.textTertiary,
            ),
            const SizedBox(width: 6),
            Text(
              title,
              style: TextStyle(
                color: isSelected ? UberColors.white : UberColors.textSecondary,
                fontSize: 11,
                fontWeight: isSelected ? FontWeight.w800 : FontWeight.w600,
                letterSpacing: 0.5,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPatrolHudCard() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
      decoration: BoxDecoration(
        color: UberColors.surface.withValues(alpha: 0.95),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: UberColors.border),
      ),
      child: Row(
        children: [
          // Speedometer
          Expanded(
            flex: 3,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text("SPEED", style: UberTypography.caption.copyWith(fontSize: 10)),
                const SizedBox(height: 2),
                ValueListenableBuilder<double>(
                  valueListenable: _sensorService.speedKmhNotifier,
                  builder: (_, speed, __) => Row(
                    crossAxisAlignment: CrossAxisAlignment.baseline,
                    textBaseline: TextBaseline.alphabetic,
                    children: [
                      Text(
                        speed.toStringAsFixed(0),
                        style: UberTypography.display.copyWith(fontSize: 32),
                      ),
                      const SizedBox(width: 4),
                      const Text("KM/H", style: TextStyle(color: UberColors.textSecondary, fontSize: 12, fontWeight: FontWeight.bold)),
                    ],
                  ),
                ),
              ],
            ),
          ),

          Container(width: 1, height: 36, color: UberColors.border),

          // Vibration Roughness
          Expanded(
            flex: 3,
            child: Padding(
              padding: const EdgeInsets.only(left: 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text("VIBRATION", style: UberTypography.caption.copyWith(fontSize: 10)),
                  const SizedBox(height: 2),
                  ValueListenableBuilder<double>(
                    valueListenable: _sensorService.roughnessNotifier,
                    builder: (_, roughness, __) => Row(
                      children: [
                        Container(
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: roughness > 1.5 ? UberColors.red : UberColors.green,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          roughness.toStringAsFixed(1),
                          style: UberTypography.display.copyWith(
                            fontSize: 22,
                            color: roughness > 1.5 ? UberColors.red : UberColors.textPrimary,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSpatialHudCard() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
      decoration: BoxDecoration(
        color: UberColors.surface.withValues(alpha: 0.95),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: UberColors.border),
      ),
      child: Row(
        children: [
          // Burst Timer
          Expanded(
            flex: 3,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text("RECORDING TIME", style: UberTypography.caption.copyWith(fontSize: 10)),
                const SizedBox(height: 2),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    Text(
                      "00:${_spatialRecordingSeconds.toString().padLeft(2, '0')}",
                      style: UberTypography.display.copyWith(
                        fontSize: 30,
                        color: _isRecordingSpatialVideo ? UberColors.red : UberColors.white,
                      ),
                    ),
                    const SizedBox(width: 4),
                    const Text(
                      "/ 01:30",
                      style: TextStyle(
                        color: UberColors.textTertiary,
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),

          Container(width: 1, height: 36, color: UberColors.border),

          // Security-Bound Locked GPS Points
          Expanded(
            flex: 4,
            child: Padding(
              padding: const EdgeInsets.only(left: 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text("ANTI-SPOOF GPS LOCK", style: UberTypography.caption.copyWith(fontSize: 10)),
                  const SizedBox(height: 2),
                  ValueListenableBuilder<int>(
                    valueListenable: _spatialSecurityService.pointCountNotifier,
                    builder: (_, count, __) => ValueListenableBuilder<double>(
                      valueListenable: _spatialSecurityService.latestAccuracyNotifier,
                      builder: (_, acc, __) => Row(
                        children: [
                          Container(
                            width: 8,
                            height: 8,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: _isRecordingSpatialVideo
                                  ? (acc <= 20 ? UberColors.green : UberColors.amber)
                                  : UberColors.textTertiary,
                            ),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            "$count PTS",
                            style: UberTypography.display.copyWith(
                              fontSize: 22,
                              color: _isRecordingSpatialVideo ? UberColors.white : UberColors.textSecondary,
                            ),
                          ),
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                            decoration: BoxDecoration(
                              color: UberColors.surfaceElevated,
                              borderRadius: BorderRadius.circular(4),
                              border: Border.all(color: UberColors.border),
                            ),
                            child: Text(
                              acc > 0 ? "±${acc.toStringAsFixed(0)}m" : "LOCKING",
                              style: const TextStyle(
                                color: UberColors.textSecondary,
                                fontSize: 10,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPatrolBottomInfo() {
    return Row(
      children: [
        // GPS Coords
        Expanded(
          child: ValueListenableBuilder(
            valueListenable: _sensorService.positionNotifier,
            builder: (_, pos, __) => Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text("GPS COORDINATES", style: UberTypography.caption.copyWith(fontSize: 10)),
                const SizedBox(height: 3),
                Text(
                  pos == null
                      ? "Acquiring..."
                      : "${pos.latitude.toStringAsFixed(4)}, ${pos.longitude.toStringAsFixed(4)}",
                  style: const TextStyle(color: UberColors.textPrimary, fontSize: 13, fontWeight: FontWeight.w600),
                ),
              ],
            ),
          ),
        ),

        // Node Info
        Expanded(
          child: InkWell(
            onTap: _showUrlDialog,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text("TARGET NODE", style: UberTypography.caption.copyWith(fontSize: 10)),
                const SizedBox(height: 3),
                Text(
                  _targetUrl == "Not Set" ? "Tap to configure" : UrlHelper.toDisplayString(_targetUrl),
                  style: const TextStyle(
                    color: UberColors.blue,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    decoration: TextDecoration.underline,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildSpatialBottomInfo() {
    return Row(
      children: [
        // Live GPS Fix
        Expanded(
          child: ValueListenableBuilder(
            valueListenable: _sensorService.positionNotifier,
            builder: (_, pos, __) => Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text("SPATIAL GPS TRAIL", style: UberTypography.caption.copyWith(fontSize: 10)),
                const SizedBox(height: 3),
                Text(
                  pos == null
                      ? "Acquiring Fix..."
                      : "${pos.latitude.toStringAsFixed(4)}, ${pos.longitude.toStringAsFixed(4)}",
                  style: const TextStyle(color: UberColors.textPrimary, fontSize: 13, fontWeight: FontWeight.w600),
                ),
              ],
            ),
          ),
        ),

        // Local Queue & Storage Metric
        Expanded(
          child: ValueListenableBuilder<List<SpatialVideoReport>>(
            valueListenable: _spatialQueueService.reportsNotifier,
            builder: (_, reports, __) => InkWell(
              onTap: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const AccountScreen()),
                );
              },
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text("LOCAL STORAGE QUEUE", style: UberTypography.caption.copyWith(fontSize: 10)),
                  const SizedBox(height: 3),
                  Row(
                    children: [
                      Text(
                        "${reports.length} videos • ${_spatialQueueService.formattedTotalStorage}",
                        style: const TextStyle(
                          color: UberColors.white,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(width: 4),
                      const Icon(Icons.arrow_forward_ios, size: 10, color: UberColors.textTertiary),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildHeaderIconButton({
    required IconData icon,
    required String tooltip,
    required VoidCallback onTap,
    Color iconColor = UberColors.white,
  }) {
    return Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        color: UberColors.surface,
        shape: BoxShape.circle,
        border: Border.all(color: UberColors.border),
      ),
      child: IconButton(
        icon: Icon(icon, color: iconColor, size: 18),
        tooltip: tooltip,
        padding: EdgeInsets.zero,
        onPressed: onTap,
      ),
    );
  }
}

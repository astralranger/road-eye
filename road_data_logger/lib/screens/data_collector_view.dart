import 'dart:async';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../config/app_config.dart';
import '../models/telemetry_payload.dart';
import '../services/api_service.dart';
import '../services/camera_service.dart';
import '../services/sensor_service.dart';
import '../theme/uber_theme.dart';
import '../utils/url_helper.dart';
import 'map_screen.dart';

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

  final TextEditingController _urlCtrl = TextEditingController();

  String _targetUrl = "Not Set";
  bool _isSystemReady = false;
  bool _isStreaming = false;

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
    _pulseController.dispose();
    _cameraService.dispose();
    _sensorService.dispose();
    _apiService.dispose();
    _urlCtrl.dispose();
    _statusMessageNotifier.dispose();
    _statusColorNotifier.dispose();
    super.dispose();
  }

  Future<void> _initializeSystem() async {
    await _loadTargetUrl();

    try {
      await [Permission.camera, Permission.location].request();
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

  Future<void> _logout() async {
    _stopStreaming();
    if (AppConfig.isSupabaseInitialized) {
      await AppConfig.supabase.auth.signOut();
    }
  }

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
                          const Text("Camera Off • Simulation Mode", style: UberTypography.title),
                          const SizedBox(height: 4),
                          const Text("Accelerometer & GPS telemetry logging is active", style: TextStyle(color: UberColors.textTertiary, fontSize: 12)),
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

          // 3. Anchored Top Navigation & Telemetry Card
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
                                  color: _isStreaming ? UberColors.green : UberColors.textTertiary,
                                ),
                              ),
                              const SizedBox(width: 8),
                              Text(
                                _isStreaming ? "PATROL ACTIVE" : "ROAD SENSE",
                                style: UberTypography.caption.copyWith(
                                  color: UberColors.textPrimary,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const Spacer(),

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

                  // Floating HUD Telemetry Card (Speed & Vibration)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                    child: Container(
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
                    ),
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
                              if (_isStreaming)
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

                      // High-Density Telemetry Info Row
                      Row(
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
                      ),
                      const SizedBox(height: 18),

                      // Full-Width Uber High-Impact CTA Button
                      SizedBox(
                        width: double.infinity,
                        height: 54,
                        child: ElevatedButton(
                          onPressed: _toggleStreaming,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: _isStreaming ? UberColors.red : UberColors.white,
                            foregroundColor: _isStreaming ? UberColors.white : UberColors.black,
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                            elevation: 0,
                          ),
                          child: Text(
                            _isStreaming ? "STOP PATROL" : "START PATROL",
                            style: const TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 0.8,
                            ),
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

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:ui'; // For image filter (blur)
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:geolocator/geolocator.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:http/http.dart' as http;
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);

  await dotenv.load(fileName: ".env");
  await Supabase.initialize(
    url: dotenv.env['SUPABASE_URL']!,
    anonKey: dotenv.env['SUPABASE_KEY']!,
  );

  final cameras = await availableCameras();
  runApp(MyApp(camera: cameras.first));
}

class MyApp extends StatelessWidget {
  final CameraDescription camera;
  const MyApp({super.key, required this.camera});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Road Sense Pro',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF0F172A), // Slate 900
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF38BDF8), // Sky Blue
          secondary: Color(0xFFF472B6), // Pink
          surface: Color(0xFF1E293B),
        ),
      ),
      home: DataCollectorView(camera: camera),
    );
  }
}

class DataCollectorView extends StatefulWidget {
  final CameraDescription camera;
  const DataCollectorView({super.key, required this.camera});

  @override
  State<DataCollectorView> createState() => _DataCollectorViewState();
}

class _DataCollectorViewState extends State<DataCollectorView> with TickerProviderStateMixin {
  late CameraController _controller;

  // Settings
  String _targetUrl = "Not Set";
  final TextEditingController _urlCtrl = TextEditingController();

  // State
  bool _isReady = false;
  bool _isStreaming = false;
  String _statusMessage = "Ready to Patrol";
  Color _statusColor = Colors.grey;

  // Sensor Data (Held in Memory)
  List<double> _zBuffer = [];
  double _currentRoughness = 0.0;

  // GPS State
  Position? _currentPosition;
  double _currentSpeedKmh = 0.0;

  // Streams & Timers
  StreamSubscription? _accelSub;
  StreamSubscription? _gpsSub;
  Timer? _uploadTimer;

  // Animation
  late AnimationController _pulseController;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(vsync: this, duration: const Duration(seconds: 1))..repeat(reverse: true);
    _initializeSystem();
  }

  Future<void> _initializeSystem() async {
    await _loadTargetUrl();
    await [Permission.camera, Permission.location, Permission.sensors].request();

    // 1. Camera Init
    _controller = CameraController(
        widget.camera,
        ResolutionPreset.medium, // Balanced for speed/quality
        enableAudio: false,
        imageFormatGroup: Platform.isAndroid ? ImageFormatGroup.jpeg : ImageFormatGroup.bgra8888
    );

    try {
      await _controller.initialize();

      // 2. Continuous Sensor Listeners (Non-blocking)
      _startSensors();

      setState(() => _isReady = true);

      if (_targetUrl == "Not Set") {
        Future.delayed(const Duration(milliseconds: 600), _showUrlDialog);
      }
    } catch (e) {
      setState(() => _statusMessage = "Camera Error: $e");
    }
  }

  void _startSensors() {
    // IMU
    _accelSub = userAccelerometerEvents.listen((event) {
      _zBuffer.add(event.z);
      if (_zBuffer.length > 200) _zBuffer.removeAt(0);
    });

    // HIGH ACCURACY GPS STREAM
    // We use a stream so we always have the latest coord ready for the upload timer
    const LocationSettings locationSettings = LocationSettings(
      accuracy: LocationAccuracy.bestForNavigation, // Highest possible
      distanceFilter: 2, // Update every 2 meters
    );

    _gpsSub = Geolocator.getPositionStream(locationSettings: locationSettings).listen((Position position) {
      setState(() {
        _currentPosition = position;
        _currentSpeedKmh = (position.speed * 3.6); // m/s to km/h
      });
    });
  }

  // --- SETTINGS ---
  Future<void> _loadTargetUrl() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() => _targetUrl = prefs.getString('target_url') ?? "Not Set");
  }

  Future<void> _saveTargetUrl(String url) async {
    if (!url.startsWith("http")) url = "http://$url";
    if (url.endsWith("/")) url = url.substring(0, url.length - 1);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('target_url', url);
    setState(() => _targetUrl = url);
  }

  void _showUrlDialog() {
    _urlCtrl.text = _targetUrl == "Not Set" ? "" : _targetUrl.replaceAll("http://", "");
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        backgroundColor: const Color(0xFF1E293B),
        title: const Text("Server Connection"),
        content: TextField(
          controller: _urlCtrl,
          style: const TextStyle(color: Colors.white),
          decoration: const InputDecoration(
              labelText: "Cloudflare URL or IP:5000",
              border: OutlineInputBorder(),
              prefixIcon: Icon(Icons.cloud, color: Colors.blue)
          ),
        ),
        actions: [
          TextButton(child: const Text("SAVE"), onPressed: () {
            if(_urlCtrl.text.isNotEmpty) {
              _saveTargetUrl(_urlCtrl.text.trim());
              Navigator.pop(context);
            }
          })
        ],
      ),
    );
  }

  // --- LOGIC ---
  void _toggleStreaming() {
    if (_targetUrl == "Not Set") { _showUrlDialog(); return; }
    _isStreaming ? _stopStreaming() : _startStreaming();
  }

  void _startStreaming() {
    setState(() {
      _isStreaming = true;
      _statusMessage = "Patrol Active";
      _statusColor = Colors.greenAccent;
      _zBuffer.clear();
    });

    // 3. THROTTLE UPLOAD (2 Seconds)
    // GPS is already hot, so this just grabs latest data and sends. Fast.
    _uploadTimer = Timer.periodic(const Duration(seconds: 2), (timer) async {
      await _captureAndTransmit();
    });
  }

  void _stopStreaming() {
    _uploadTimer?.cancel();
    setState(() {
      _isStreaming = false;
      _statusMessage = "Patrol Paused";
      _statusColor = Colors.amber;
    });
  }

  double _calculateRoughness() {
    if (_zBuffer.isEmpty) return 0.0;
    double mean = _zBuffer.reduce((a, b) => a + b) / _zBuffer.length;
    double variance = _zBuffer.map((x) => pow(x - mean, 2)).reduce((a, b) => a + b) / _zBuffer.length;
    double stdDev = sqrt(variance);
    _zBuffer.clear();
    return stdDev;
  }

  Future<void> _captureAndTransmit() async {
    if (!_controller.value.isInitialized || !_isStreaming || _currentPosition == null) return;

    try {
      // 1. Snapshot Data
      double roughness = _calculateRoughness();
      _currentRoughness = roughness;

      // 2. Capture Image
      XFile imageFile = await _controller.takePicture();
      List<int> bytes = await File(imageFile.path).readAsBytes();
      String base64Img = base64Encode(bytes);

      // 3. Build Payload
      Map<String, dynamic> payload = {
        "image": base64Img,
        "gps": {
          "lat": _currentPosition!.latitude,
          "lon": _currentPosition!.longitude,
          "speed": _currentPosition!.speed
        },
        "instance_ip": _targetUrl,
        "roughness": roughness
      };

      // 4. Send (Fire & Forget Logic)
      // We set a short timeout so UI doesn't hang on bad connections
      http.post(
        Uri.parse("$_targetUrl/detect"),
        headers: {"Content-Type": "application/json"},
        body: jsonEncode(payload),
      ).timeout(const Duration(seconds: 5)).then((response) {
        if (response.statusCode == 200) {
          var data = jsonDecode(response.body);
          if (mounted) {
            setState(() => _statusMessage = "AI: ${data['status'].toString().toUpperCase()}");
          }
        }
      }).catchError((e) {
        debugPrint("Upload Error: $e");
      });

      File(imageFile.path).delete();

    } catch (e) {
      debugPrint("Loop Error: $e");
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _accelSub?.cancel();
    _gpsSub?.cancel();
    _uploadTimer?.cancel();
    _pulseController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_isReady) return const Scaffold(body: Center(child: CircularProgressIndicator()));

    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: const Text("Road Sense Pro", style: TextStyle(fontWeight: FontWeight.bold)),
        centerTitle: true,
        flexibleSpace: ClipRect(
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
            child: Container(color: Colors.black.withOpacity(0.3)),
          ),
        ),
        actions: [
          IconButton(icon: const Icon(Icons.map, color: Colors.white), onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const MapScreen()))),
          IconButton(icon: const Icon(Icons.settings, color: Colors.white), onPressed: _showUrlDialog)
        ],
      ),
      body: Stack(
        fit: StackFit.expand,
        children: [
          // 1. Camera Feed
          _controller.value.isInitialized
              ? CameraPreview(_controller)
              : Container(color: Colors.black),

          // 2. Dark Gradient Overlay (For readability)
          Container(
            decoration: const BoxDecoration(
                gradient: LinearGradient(
                    begin: Alignment.topCenter, end: Alignment.bottomCenter,
                    colors: [Colors.black45, Colors.transparent, Colors.transparent, Colors.black87]
                )
            ),
          ),

          // 3. HUD - Speedometer & GPS
          Positioned(
            top: 110, left: 20,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.speed, color: Colors.cyanAccent, size: 20),
                    const SizedBox(width: 8),
                    Text(
                      "${_currentSpeedKmh.toStringAsFixed(0)} km/h",
                      style: const TextStyle(fontSize: 28, fontWeight: FontWeight.bold, color: Colors.white, fontFamily: 'monospace'),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  _currentPosition == null ? "Waiting for GPS..." :
                  "${_currentPosition!.latitude.toStringAsFixed(5)}, ${_currentPosition!.longitude.toStringAsFixed(5)}",
                  style: const TextStyle(color: Colors.white70, fontSize: 12),
                ),
              ],
            ),
          ),

          // 4. HUD - Roughness Indicator
          Positioned(
            top: 110, right: 20,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                  color: Colors.black45,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: Colors.white24)
              ),
              child: Row(
                children: [
                  Text("Vibration: ", style: TextStyle(color: Colors.grey.shade300, fontSize: 12)),
                  Text(
                    _currentRoughness.toStringAsFixed(1),
                    style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: _currentRoughness > 1.5 ? Colors.redAccent : Colors.greenAccent
                    ),
                  ),
                ],
              ),
            ),
          ),

          // 5. Bottom Control Panel (Glassmorphism)
          Positioned(
            bottom: 30, left: 20, right: 20,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(25),
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 15, sigmaY: 15),
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 20),
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.1),
                    border: Border.all(color: Colors.white24),
                  ),
                  child: Column(
                    children: [
                      // Status Text
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          if (_isStreaming)
                            FadeTransition(
                              opacity: _pulseController,
                              child: const Icon(Icons.circle, color: Colors.red, size: 12),
                            ),
                          const SizedBox(width: 8),
                          Text(
                            _statusMessage.toUpperCase(),
                            style: TextStyle(color: _statusColor, fontWeight: FontWeight.bold, letterSpacing: 1.2),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),

                      // Big Button
                      SizedBox(
                        width: double.infinity,
                        height: 55,
                        child: ElevatedButton(
                          onPressed: _toggleStreaming,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: _isStreaming ? Colors.red.shade900 : Colors.cyan.shade800,
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(30)),
                            elevation: 8,
                            shadowColor: _isStreaming ? Colors.redAccent.withOpacity(0.5) : Colors.cyan.withOpacity(0.5),
                          ),
                          child: Text(
                            _isStreaming ? "STOP PATROL" : "START PATROL",
                            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white),
                          ),
                        ),
                      ),

                      const SizedBox(height: 8),
                      Text(
                        _targetUrl,
                        style: TextStyle(color: Colors.grey.shade500, fontSize: 10),
                        overflow: TextOverflow.ellipsis,
                      )
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
}

// --- FAST MAP SCREEN (No Heatmap, Only Potholes) ---
class MapScreen extends StatefulWidget {
  const MapScreen({super.key});
  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  List<Marker> _markers = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _fetchDetections();
  }

  Future<void> _fetchDetections() async {
    try {
      // ONLY fetch actual detections. No road logs. Fast.
      final detections = await Supabase.instance.client
          .from('detections')
          .select('latitude, longitude, image_url, created_at')
          .order('created_at', ascending: false)
          .limit(50);

      List<Marker> newMarkers = [];

      for(var row in (detections as List<dynamic>)) {
        newMarkers.add(Marker(
          point: LatLng(row['latitude'], row['longitude']),
          width: 45, height: 45,
          child: GestureDetector(
            onTap: () => _showImage(row),
            child: Container(
              decoration: BoxDecoration(
                  color: Colors.red.withOpacity(0.9),
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white, width: 2),
                  boxShadow: const [BoxShadow(color: Colors.black45, blurRadius: 4)]
              ),
              child: const Icon(Icons.warning_amber_rounded, color: Colors.white, size: 28),
            ),
          ),
        ));
      }

      if(mounted) {
        setState(() {
          _markers = newMarkers;
          _isLoading = false;
        });
      }
    } catch (e) {
      debugPrint("Map Error: $e");
      setState(() => _isLoading = false);
    }
  }

  void _showImage(Map<String, dynamic> data) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: const Color(0xFF1E293B),
        title: const Text("Confirmed Pothole", style: TextStyle(color: Colors.white)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text("Detected: ${data['created_at'].substring(0,10)}", style: const TextStyle(color: Colors.grey)),
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Image.network(
                data['image_url'],
                height: 250,
                fit: BoxFit.cover,
                loadingBuilder: (_,c,p) => p == null ? c : const CircularProgressIndicator(),
                errorBuilder: (_,__,___) => const Icon(Icons.broken_image, color: Colors.white),
              ),
            ),
          ],
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text("CLOSE"))],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("Pothole Database")),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : FlutterMap(
        options: MapOptions(
          initialCenter: _markers.isNotEmpty ? _markers.first.point : const LatLng(20.59, 78.96),
          initialZoom: 14.0,
          backgroundColor: const Color(0xFF0F172A),
        ),
        children: [
          TileLayer(
            urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
            userAgentPackageName: 'com.road.sense.pro',
          ),
          MarkerLayer(markers: _markers),
        ],
      ),
    );
  }
}
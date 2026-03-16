import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:ui';
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
        scaffoldBackgroundColor: const Color(0xFF0F172A),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF38BDF8),
          secondary: Color(0xFFF472B6),
          surface: Color(0xFF1E293B),
        ),
      ),
      home: StreamBuilder<AuthState>(
        stream: Supabase.instance.client.auth.onAuthStateChange,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Scaffold(body: Center(child: CircularProgressIndicator()));
          }
          final session = snapshot.data?.session;
          if (session != null) {
            return DataCollectorView(camera: camera);
          } else {
            return const AuthScreen();
          }
        },
      ),
    );
  }
}

// --- AUTH LOGIN SCREEN ---
class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key});
  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  final _emailCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  bool _isLoading = false;
  bool _isLogin = true;

  Future<void> _submit() async {
    setState(() => _isLoading = true);
    try {
      final email = _emailCtrl.text.trim();
      final password = _passCtrl.text.trim();
      if (email.isEmpty || password.isEmpty) throw "Please fill all fields";

      if (_isLogin) {
        await Supabase.instance.client.auth.signInWithPassword(email: email, password: password);
      } else {
        await Supabase.instance.client.auth.signUp(email: email, password: password);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Account Created! You can now login.")));
          setState(() => _isLogin = true);
        }
      }
    } on AuthException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message), backgroundColor: Colors.red));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString()), backgroundColor: Colors.red));
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children:[
              const Icon(Icons.add_road, size: 80, color: Colors.blueAccent),
              const SizedBox(height: 20),
              Text(_isLogin ? "Welcome Back" : "Join Road Sense", style: const TextStyle(fontSize: 28, fontWeight: FontWeight.bold)),
              const SizedBox(height: 30),
              TextField(controller: _emailCtrl, decoration: const InputDecoration(labelText: "Email", prefixIcon: Icon(Icons.email), border: OutlineInputBorder())),
              const SizedBox(height: 16),
              TextField(controller: _passCtrl, obscureText: true, decoration: const InputDecoration(labelText: "Password", prefixIcon: Icon(Icons.lock), border: OutlineInputBorder())),
              const SizedBox(height: 24),
              SizedBox(
                width: double.infinity, height: 50,
                child: ElevatedButton(
                  onPressed: _isLoading ? null : _submit,
                  style: ElevatedButton.styleFrom(backgroundColor: Colors.blueAccent, foregroundColor: Colors.white),
                  child: _isLoading ? const CircularProgressIndicator(color: Colors.white) : Text(_isLogin ? "LOGIN" : "SIGN UP"),
                ),
              ),
              const SizedBox(height: 16),
              TextButton(onPressed: () => setState(() => _isLogin = !_isLogin), child: Text(_isLogin ? "Create an account" : "I already have an account"))
            ],
          ),
        ),
      ),
    );
  }
}

// --- MAIN COLLECTOR SCREEN ---
class DataCollectorView extends StatefulWidget {
  final CameraDescription camera;
  const DataCollectorView({super.key, required this.camera});
  @override
  State<DataCollectorView> createState() => _DataCollectorViewState();
}

class _DataCollectorViewState extends State<DataCollectorView> with TickerProviderStateMixin {
  late CameraController _controller;
  final TextEditingController _urlCtrl = TextEditingController();

  String _targetUrl = "Not Set";
  bool _isReady = false;
  bool _isStreaming = false;
  String _statusMessage = "Ready";
  Color _statusColor = Colors.grey;

  List<double> _zBuffer =[];
  double _currentRoughness = 0.0;

  Position? _currentPosition;
  double _currentSpeedKmh = 0.0;

  StreamSubscription? _accelSub;
  StreamSubscription? _gpsSub;
  Timer? _uploadTimer;
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

    _controller = CameraController(
        widget.camera,
        ResolutionPreset.medium,
        enableAudio: false,
        imageFormatGroup: Platform.isAndroid ? ImageFormatGroup.jpeg : ImageFormatGroup.bgra8888
    );

    try {
      await _controller.initialize();
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
    _accelSub = userAccelerometerEvents.listen((event) {
      _zBuffer.add(event.z);
      if (_zBuffer.length > 200) _zBuffer.removeAt(0);
    });

    const LocationSettings locationSettings = LocationSettings(
      accuracy: LocationAccuracy.bestForNavigation,
      distanceFilter: 1, // High accuracy filter
    );

    _gpsSub = Geolocator.getPositionStream(locationSettings: locationSettings).listen((Position position) {
      // Discard highly inaccurate GPS readings to prevent drift
      if (position.accuracy > 20.0) return;

      setState(() {
        _currentPosition = position;
        _currentSpeedKmh = (position.speed * 3.6);
      });
    });
  }

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
          decoration: const InputDecoration(labelText: "Cloudflare URL or IP:5000", border: OutlineInputBorder()),
        ),
        actions:[
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
    if (_currentPosition!.accuracy > 20.0) return; // Safety check

    try {
      double roughness = _calculateRoughness();
      _currentRoughness = roughness;

      XFile imageFile = await _controller.takePicture();
      List<int> bytes = await File(imageFile.path).readAsBytes();
      String base64Img = base64Encode(bytes);

      final user = Supabase.instance.client.auth.currentUser;

      Map<String, dynamic> payload = {
        "image": base64Img,
        "gps": {
          "lat": _currentPosition!.latitude,
          "lon": _currentPosition!.longitude,
          "speed": _currentPosition!.speed,
          "heading": _currentPosition!.heading
        },
        "instance_ip": _targetUrl,
        "roughness": roughness,
        "user_id": user?.id ?? "anonymous",
        "user_email": user?.email ?? "anonymous"
      };

      http.post(
        Uri.parse("$_targetUrl/detect"),
        headers: {"Content-Type": "application/json"},
        body: jsonEncode(payload),
      ).timeout(const Duration(seconds: 5)).then((response) {
        if (response.statusCode == 200) {
          var data = jsonDecode(response.body);
          if (mounted) setState(() => _statusMessage = "AI: ${data['status'].toString().toUpperCase()}");
        }
      });

      File(imageFile.path).delete();

    } catch (e) {
      debugPrint("Loop Error: $e");
    }
  }

  Future<void> _logout() async {
    _stopStreaming();
    await Supabase.instance.client.auth.signOut();
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
        title: const Text("Road Sense Pro"),
        centerTitle: true,
        flexibleSpace: ClipRect(
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
            child: Container(color: Colors.black.withOpacity(0.3)),
          ),
        ),
        actions:[
          IconButton(
            icon: const Icon(Icons.map, color: Colors.white),
            onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const MapScreen())),
          ),
          IconButton(icon: const Icon(Icons.logout, color: Colors.redAccent), onPressed: _logout),
          IconButton(icon: const Icon(Icons.settings, color: Colors.white), onPressed: _showUrlDialog)
        ],
      ),
      body: Stack(
        fit: StackFit.expand,
        children:[
          _controller.value.isInitialized ? CameraPreview(_controller) : Container(color: Colors.black),
          Container(
            decoration: const BoxDecoration(
                gradient: LinearGradient(
                    begin: Alignment.topCenter, end: Alignment.bottomCenter,
                    colors:[Colors.black45, Colors.transparent, Colors.transparent, Colors.black87]
                )
            ),
          ),
          Positioned(
            top: 110, left: 20,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children:[
                Row(
                  children:[
                    const Icon(Icons.speed, color: Colors.cyanAccent, size: 20),
                    const SizedBox(width: 8),
                    Text(
                      "${_currentSpeedKmh.toStringAsFixed(0)} km/h",
                      style: const TextStyle(fontSize: 28, fontWeight: FontWeight.bold, color: Colors.white, fontFamily: 'monospace'),
                    ),
                  ],
                ),
                Text(
                  _currentPosition == null ? "Waiting for GPS..." : "${_currentPosition!.latitude.toStringAsFixed(5)}, ${_currentPosition!.longitude.toStringAsFixed(5)}",
                  style: const TextStyle(color: Colors.white70, fontSize: 12),
                ),
                const SizedBox(height: 5),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(color: Colors.blueAccent.withOpacity(0.5), borderRadius: BorderRadius.circular(4)),
                  child: Text(
                    Supabase.instance.client.auth.currentUser?.email ?? "Unknown",
                    style: const TextStyle(fontSize: 10, color: Colors.white),
                  ),
                )
              ],
            ),
          ),
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
                children:[
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
                    children:[
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children:[
                          if (_isStreaming)
                            FadeTransition(opacity: _pulseController, child: const Icon(Icons.circle, color: Colors.red, size: 12)),
                          const SizedBox(width: 8),
                          Text(
                            _statusMessage.toUpperCase(),
                            style: TextStyle(color: _statusColor, fontWeight: FontWeight.bold, letterSpacing: 1.2),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      SizedBox(
                        width: double.infinity,
                        height: 55,
                        child: ElevatedButton(
                          onPressed: _toggleStreaming,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: _isStreaming ? Colors.red.shade900 : Colors.cyan.shade800,
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(30)),
                          ),
                          child: Text(_isStreaming ? "STOP PATROL" : "START PATROL", style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white)),
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

// --- MAP SCREEN WITH USER MANAGEMENT ---
class MapScreen extends StatefulWidget {
  const MapScreen({super.key});
  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  List<Marker> _markers =[];
  bool _isLoading = true;
  bool _showOnlyMine = false;

  @override
  void initState() {
    super.initState();
    _fetchDetections();
  }

  Future<void> _fetchDetections() async {
    setState(() => _isLoading = true);
    try {
      // 1. Setup the base query
      var query = Supabase.instance.client
          .from('detections')
          .select('id, latitude, longitude, image_url, created_at, severity, user_id');

      // 2. Apply filtering first (if needed)
      if (_showOnlyMine) {
        final userId = Supabase.instance.client.auth.currentUser!.id;
        query = query.eq('user_id', userId);
      }

      // 3. Apply Ordering and Limit last, then execute
      final detections = await query.order('created_at', ascending: false).limit(500);

      List<Marker> newMarkers =[];

      for(var row in (detections as List<dynamic>)) {
        Color markerColor = Colors.orange;
        if(row['severity'] == "Severe") markerColor = Colors.red;
        if(row['severity'] == "Minor") markerColor = Colors.green;

        newMarkers.add(Marker(
          point: LatLng(row['latitude'], row['longitude']),
          width: 30, height: 30,
          child: GestureDetector(
            onTap: () => _showImage(row),
            child: Container(
              decoration: BoxDecoration(
                  color: markerColor.withOpacity(0.9),
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white, width: 1.5),
                  boxShadow: const[BoxShadow(color: Colors.black45, blurRadius: 2)]
              ),
              child: const Icon(Icons.warning_amber_rounded, color: Colors.white, size: 16),
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

  Future<void> _deleteDetection(int id) async {
    try {
      await Supabase.instance.client.from('detections').delete().eq('id', id);
      if (mounted) {
        Navigator.pop(context);
        _fetchDetections();
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Detection Deleted")));
      }
    } catch(e) {
      debugPrint("Delete Error: $e");
    }
  }

  void _showImage(Map<String, dynamic> data) {
    bool isOwner = data['user_id'] == Supabase.instance.client.auth.currentUser?.id;

    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: const Color(0xFF1E293B),
        title: Text("Confirmed ${data['severity']} Pothole", style: const TextStyle(color: Colors.white)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children:[
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
        actions:[
          if (isOwner)
            TextButton(onPressed: () => _deleteDetection(data['id']), child: const Text("DELETE", style: TextStyle(color: Colors.red))),
          TextButton(onPressed: () => Navigator.pop(context), child: const Text("CLOSE"))
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Database"),
        actions:[
          Row(
            children:[
              const Text("Mine Only", style: TextStyle(fontSize: 12)),
              Switch(
                value: _showOnlyMine,
                activeColor: Colors.blueAccent,
                onChanged: (val) {
                  setState(() => _showOnlyMine = val);
                  _fetchDetections();
                },
              ),
            ],
          )
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : FlutterMap(
        options: MapOptions(
          initialCenter: _markers.isNotEmpty ? _markers.first.point : const LatLng(20.59, 78.96),
          initialZoom: 14.0,
          backgroundColor: const Color(0xFF0F172A),
        ),
        children:[
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
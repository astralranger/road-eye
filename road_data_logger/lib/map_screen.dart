import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

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
    _fetchPotholes();
  }

  Future<void> _fetchPotholes() async {
    try {
      // 1. Query Supabase
      final data = await Supabase.instance.client
          .from('detections')
          .select('latitude, longitude, image_url, created_at')
          .order('created_at', ascending: false) // Newest first
          .limit(100); // Limit to 100 for performance

      final List<dynamic> rows = data as List<dynamic>;

      setState(() {
        _markers = rows.map((row) {
          return Marker(
            point: LatLng(row['latitude'], row['longitude']),
            width: 40,
            height: 40,
            child: GestureDetector(
              onTap: () => _showPotholeDetails(row),
              child: const Icon(Icons.location_on, color: Colors.red, size: 40),
            ),
          );
        }).toList();
        _isLoading = false;
      });
    } catch (e) {
      debugPrint("Error fetching map data: $e");
      setState(() => _isLoading = false);
    }
  }

  void _showPotholeDetails(Map<String, dynamic> data) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("Pothole Detected"),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text("Date: ${data['created_at']}"),
            const SizedBox(height: 10),
            Image.network(
              data['image_url'],
              loadingBuilder: (ctx, child, progress) {
                if (progress == null) return child;
                return const CircularProgressIndicator();
              },
              errorBuilder: (ctx, error, stack) => const Icon(Icons.broken_image),
            ),
          ],
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("Close"))],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("Live Pothole Map")),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : FlutterMap(
        options: MapOptions(
          // Center on the first pothole, or a default location
          initialCenter: _markers.isNotEmpty
              ? _markers.first.point
              : const LatLng(19.0760, 72.8777), // Mumbai default
          initialZoom: 13.0,
        ),
        children: [
          TileLayer(
            urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
            userAgentPackageName: 'com.example.road_logger',
          ),
          MarkerLayer(markers: _markers),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        child: const Icon(Icons.refresh),
        onPressed: _fetchPotholes,
      ),
    );
  }
}
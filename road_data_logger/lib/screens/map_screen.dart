import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:geolocator/geolocator.dart';
import '../config/app_config.dart';
import '../models/detection_record.dart';
import '../theme/uber_theme.dart';

class MapScreen extends StatefulWidget {
  const MapScreen({super.key});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  List<Marker> _markers = [];
  List<DetectionRecord> _records = [];
  bool _isLoading = true;
  bool _isLocatingNearest = false;
  bool _showOnlyMine = false;
  bool _hasAutoCentered = false;
  LatLng _mapCenter = const LatLng(18.5204, 73.8567);
  final MapController _mapController = MapController();

  @override
  void initState() {
    super.initState();
    _fetchDetections();
  }

  Future<void> _fetchDetections() async {
    if (!AppConfig.isSupabaseInitialized) {
      setState(() => _isLoading = false);
      return;
    }

    setState(() => _isLoading = true);
    try {
      var query = AppConfig.supabase
          .from('detections')
          .select('id, latitude, longitude, image_url, created_at, severity, user_id');

      if (_showOnlyMine) {
        final currentUserId = AppConfig.currentUser?.id;
        if (currentUserId != null) {
          query = query.eq('user_id', currentUserId);
        }
      }

      final dynamic response = await query
          .order('created_at', ascending: false)
          .limit(500)
          .timeout(const Duration(seconds: 8));

      final List<dynamic> rows = response as List<dynamic>;
      final List<DetectionRecord> newRecords = [];

      for (final row in rows) {
        final record = DetectionRecord.fromMap(row as Map<String, dynamic>);
        newRecords.add(record);
      }

      if (mounted) {
        setState(() {
          _records = newRecords;
          if (newRecords.isNotEmpty) {
            _mapCenter = LatLng(newRecords.first.latitude, newRecords.first.longitude);
          }
          _isLoading = false;
        });

        _rebuildMarkers();

        // Automatically move camera to the detections if opening for the first time
        if (!_hasAutoCentered && newRecords.isNotEmpty) {
          _hasAutoCentered = true;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            try {
              _mapController.move(
                LatLng(newRecords.first.latitude, newRecords.first.longitude),
                15.0,
              );
            } catch (e) {
              debugPrint("Auto-centering error: $e");
            }
          });
        }
      }
    } catch (e) {
      debugPrint("Map fetch error: $e");
      if (mounted) {
        setState(() => _isLoading = false);

        String errorMsg = "Failed to load map data.";
        final str = e.toString().toLowerCase();
        if (str.contains('socketexception') ||
            str.contains('failed host lookup') ||
            str.contains('no address associated') ||
            str.contains('clientexception')) {
          errorMsg = "No internet connection. Please check device/emulator network.";
        } else if (str.contains('timeout')) {
          errorMsg = "Connection timed out reaching server.";
        } else {
          errorMsg = "Error: ${e.toString().replaceAll('Exception: ', '').split('\n').first}";
        }

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Row(
              children: [
                const Icon(Icons.wifi_off_rounded, color: UberColors.white, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(errorMsg, style: const TextStyle(color: UberColors.white, fontWeight: FontWeight.w600)),
                ),
              ],
            ),
            backgroundColor: UberColors.red,
            duration: const Duration(seconds: 4),
            action: SnackBarAction(
              label: "RETRY",
              textColor: UberColors.white,
              onPressed: _fetchDetections,
            ),
          ),
        );
      }
    }
  }

  void _zoomIn() {
    try {
      final currentZoom = _mapController.camera.zoom;
      final currentCenter = _mapController.camera.center;
      _mapController.move(currentCenter, (currentZoom + 1.0).clamp(2.0, 18.0));
    } catch (e) {
      debugPrint("Zoom in error: $e");
    }
  }

  void _zoomOut() {
    try {
      final currentZoom = _mapController.camera.zoom;
      final currentCenter = _mapController.camera.center;
      _mapController.move(currentCenter, (currentZoom - 1.0).clamp(2.0, 18.0));
    } catch (e) {
      debugPrint("Zoom out error: $e");
    }
  }

  Future<void> _navigateToNearestDetection() async {
    if (_records.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("No detections available on the map to locate."),
          backgroundColor: UberColors.amber,
        ),
      );
      return;
    }

    setState(() => _isLocatingNearest = true);

    LatLng userPoint = _mapController.camera.center;
    bool usingGps = false;

    try {
      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }

      if (permission == LocationPermission.always || permission == LocationPermission.whileInUse) {
        Position? pos = await Geolocator.getLastKnownPosition();
        pos ??= await Geolocator.getCurrentPosition(
          desiredAccuracy: LocationAccuracy.medium,
          timeLimit: const Duration(seconds: 4),
        );
        userPoint = LatLng(pos.latitude, pos.longitude);
        usingGps = true;
      }
    } catch (e) {
      debugPrint("GPS location check fallback: $e");
    }

    const distanceCalc = Distance();
    DetectionRecord? nearestRecord;
    double minDistance = double.infinity;

    for (final record in _records) {
      final recordPoint = LatLng(record.latitude, record.longitude);
      final dist = distanceCalc.as(LengthUnit.Meter, userPoint, recordPoint);
      if (dist < minDistance) {
        minDistance = dist;
        nearestRecord = record;
      }
    }

    if (mounted) {
      setState(() => _isLocatingNearest = false);
    }

    if (nearestRecord != null) {
      final target = LatLng(nearestRecord.latitude, nearestRecord.longitude);
      try {
        _mapController.move(target, 16.5);
      } catch (e) {
        debugPrint("Map move error: $e");
      }

      final distStr = minDistance < 1000
          ? "${minDistance.toStringAsFixed(0)} m"
          : "${(minDistance / 1000).toStringAsFixed(1)} km";
      final originStr = usingGps ? "from your GPS" : "from map center";

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Row(
              children: [
                const Icon(Icons.near_me_rounded, color: UberColors.black, size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    "Nearest: $distStr $originStr (${nearestRecord.severity})",
                    style: const TextStyle(
                      color: UberColors.black,
                      fontWeight: FontWeight.w700,
                      fontSize: 12,
                    ),
                  ),
                ),
              ],
            ),
            backgroundColor: UberColors.white,
            duration: const Duration(seconds: 3),
          ),
        );

        _showPotholeBottomSheet(nearestRecord);
      }
    }
  }

  Color _getSeverityColor(String severity) {
    switch (severity.toLowerCase()) {
      case 'severe':
        return UberColors.red;
      case 'minor':
        return UberColors.green;
      default:
        return UberColors.amber;
    }
  }

  String? _extractStoragePath(String imageUrl, String bucketName) {
    if (imageUrl.isEmpty) return null;
    try {
      final uri = Uri.parse(imageUrl);
      final segments = uri.pathSegments;
      final bucketIndex = segments.indexOf(bucketName);
      if (bucketIndex != -1 && bucketIndex + 1 < segments.length) {
        return segments.sublist(bucketIndex + 1).join('/');
      }
      if (imageUrl.contains('/$bucketName/')) {
        final parts = imageUrl.split('/$bucketName/');
        if (parts.length > 1) {
          return parts[1].split('?').first;
        }
      }
    } catch (e) {
      debugPrint("Storage path extraction error from $imageUrl: $e");
    }
    return null;
  }

  void _rebuildMarkers() {
    final Map<String, List<DetectionRecord>> groups = {};
    for (final record in _records) {
      final key = "${record.latitude.toStringAsFixed(5)}_${record.longitude.toStringAsFixed(5)}";
      groups.putIfAbsent(key, () => []).add(record);
    }

    final List<Marker> newMarkers = [];
    for (final group in groups.values) {
      final primary = group.first;
      final point = LatLng(primary.latitude, primary.longitude);
      final count = group.length;

      final double markerWidth = count > 9 ? 52 : (count > 1 ? 46 : 30);
      const double markerHeight = 30;

      newMarkers.add(
        Marker(
          point: point,
          width: markerWidth,
          height: markerHeight,
          child: GestureDetector(
            onTap: () => _showPotholeBottomSheet(primary, group: group),
            child: Container(
              padding: count > 1 ? const EdgeInsets.symmetric(horizontal: 4) : EdgeInsets.zero,
              decoration: BoxDecoration(
                color: _getSeverityColor(primary.severity),
                borderRadius: BorderRadius.circular(15),
                border: Border.all(color: UberColors.white, width: 2),
                boxShadow: const [
                  BoxShadow(color: Colors.black87, blurRadius: 4, offset: Offset(0, 2)),
                ],
              ),
              child: Center(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 2),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(Icons.warning_amber_rounded, color: UberColors.black, size: 14),
                        if (count > 1) ...[
                          const SizedBox(width: 2),
                          Text(
                            count > 99 ? '99+' : '$count',
                            style: const TextStyle(
                              color: UberColors.black,
                              fontSize: 10,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    }

    if (mounted) {
      setState(() {
        _markers = newMarkers;
      });
    }
  }

  Future<void> _deleteDetectionRecords(List<DetectionRecord> recordsToDelete, StateSetter setModalState) async {
    if (recordsToDelete.isEmpty) return;

    final currentUserId = AppConfig.currentUser?.id;
    if (currentUserId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("Authentication required to delete reports."),
          backgroundColor: UberColors.red,
        ),
      );
      return;
    }

    final authorizedRecords = recordsToDelete.where((r) => r.userId == currentUserId).toList();
    if (authorizedRecords.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("Permission denied: You can only delete your own detection reports."),
          backgroundColor: UberColors.red,
        ),
      );
      return;
    }

    final targetIds = authorizedRecords
        .map((r) => (r.id is int) ? r.id as int : int.tryParse(r.id.toString()) ?? r.id)
        .toList();

    // Save previous state snapshot for rollback if network/backend fails
    final previousMarkers = List<Marker>.from(_markers);
    final previousRecords = List<DetectionRecord>.from(_records);

    try {
      bool deleteConfirmed = false;

      // 1. Preferred Primary: Atomic Server-Side RPC
      try {
        if (targetIds.length == 1) {
          final dynamic rpcResponse = await AppConfig.supabase.rpc(
            'delete_pothole_detection',
            params: {'p_detection_id': targetIds.first},
          ).timeout(const Duration(seconds: 10));

          if (rpcResponse is Map && rpcResponse['success'] == true) {
            deleteConfirmed = true;
          } else if (rpcResponse is Map && rpcResponse['error'] != null) {
            throw Exception(rpcResponse['message'] ?? rpcResponse['error']);
          }
        } else {
          final dynamic rpcResponse = await AppConfig.supabase.rpc(
            'bulk_delete_pothole_detections',
            params: {'p_detection_ids': targetIds},
          ).timeout(const Duration(seconds: 12));

          if (rpcResponse is Map && rpcResponse['success'] == true) {
            deleteConfirmed = true;
          } else if (rpcResponse is Map && rpcResponse['error'] != null) {
            throw Exception(rpcResponse['message'] ?? rpcResponse['error']);
          }
        }
      } catch (rpcErr) {
        debugPrint("RPC delete fallback: $rpcErr");
      }

      // 2. Resilient Direct API Fallback:
      if (!deleteConfirmed) {
        // Step A: Remove image assets from Supabase Storage bucket 'pothole-images'
        final storagePaths = <String>[];
        for (final rec in authorizedRecords) {
          final storagePath = _extractStoragePath(rec.imageUrl, 'pothole-images');
          if (storagePath != null && storagePath.isNotEmpty) {
            storagePaths.add(storagePath);
          }
        }
        if (storagePaths.isNotEmpty) {
          try {
            await AppConfig.supabase.storage
                .from('pothole-images')
                .remove(storagePaths);
          } catch (storageErr) {
            debugPrint("Direct storage remove error (proceeding to DB): $storageErr");
          }
        }

        // Step B: Delete from detections table strictly matching current user using inFilter
        final dynamic response = await AppConfig.supabase
            .from('detections')
            .delete()
            .inFilter('id', targetIds)
            .eq('user_id', currentUserId)
            .select()
            .timeout(const Duration(seconds: 10));

        final List<dynamic> deletedRows = response as List<dynamic>;

        if (deletedRows.isEmpty) {
          throw Exception(
            "Delete rejected by database (0 rows deleted). You may only delete your own reports.",
          );
        }
        deleteConfirmed = true;
      }

      // 3. Dynamic Frontend Synchronization (Zero Full-Page Reload)
      if (mounted) {
        setState(() {
          _records.removeWhere((r) => targetIds.contains(r.id));
        });

        _rebuildMarkers();

        Navigator.pop(context); // Dismiss modal sheet

        final countStr = targetIds.length > 1
            ? "${targetIds.length} detection reports"
            : "Detection report";

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Row(
              children: [
                const Icon(Icons.check_circle_outline, color: UberColors.black, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    "$countStr permanently deleted.",
                    style: const TextStyle(color: UberColors.black, fontWeight: FontWeight.w700),
                  ),
                ),
              ],
            ),
            backgroundColor: UberColors.white,
            duration: const Duration(seconds: 3),
          ),
        );
      }
    } catch (e) {
      debugPrint("Delete detection error: $e");
      if (mounted) {
        // Rollback state in case of failure
        setState(() {
          _markers = previousMarkers;
          _records = previousRecords;
        });

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              "Delete failed: ${e.toString().replaceAll('Exception: ', '')}",
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            backgroundColor: UberColors.red,
            duration: const Duration(seconds: 4),
          ),
        );
      }
    }
  }

  Future<void> _bulkDeleteDetections(Set<dynamic> ids, StateSetter setModalState) async {
    if (ids.isEmpty) return;

    final currentUserId = AppConfig.currentUser?.id;
    if (currentUserId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("Authentication required to delete reports."),
          backgroundColor: UberColors.red,
        ),
      );
      return;
    }

    final targetIds = ids
        .map((id) => (id is int) ? id : int.tryParse(id.toString()) ?? id)
        .toList();
    final recordsToDelete = _records.where((r) => targetIds.contains(r.id)).toList();

    final previousMarkers = List<Marker>.from(_markers);
    final previousRecords = List<DetectionRecord>.from(_records);

    try {
      bool bulkConfirmed = false;

      // 1. Preferred Primary: Atomic Server-Side Bulk RPC
      try {
        final dynamic rpcResponse = await AppConfig.supabase.rpc(
          'bulk_delete_pothole_detections',
          params: {'p_detection_ids': targetIds},
        ).timeout(const Duration(seconds: 15));

        if (rpcResponse is Map && rpcResponse['success'] == true) {
          bulkConfirmed = true;
        } else if (rpcResponse is Map && rpcResponse['error'] != null) {
          throw Exception(rpcResponse['message'] ?? rpcResponse['error']);
        }
      } catch (rpcErr) {
        debugPrint("RPC bulk_delete_pothole_detections fallback: $rpcErr");
      }

      // 2. Direct API Fallback if RPC pending:
      if (!bulkConfirmed) {
        // Step A: Purge images from storage
        final storagePaths = <String>[];
        for (final rec in recordsToDelete) {
          final p = _extractStoragePath(rec.imageUrl, 'pothole-images');
          if (p != null && p.isNotEmpty) storagePaths.add(p);
        }
        if (storagePaths.isNotEmpty) {
          try {
            await AppConfig.supabase.storage
                .from('pothole-images')
                .remove(storagePaths);
          } catch (storageErr) {
            debugPrint("Bulk storage delete warning: $storageErr");
          }
        }

        // Step B: Bulk delete strictly matching user_id using inFilter
        final dynamic response = await AppConfig.supabase
            .from('detections')
            .delete()
            .inFilter('id', targetIds)
            .eq('user_id', currentUserId)
            .select()
            .timeout(const Duration(seconds: 15));

        final List<dynamic> deletedRows = response as List<dynamic>;
        if (deletedRows.isEmpty) {
          throw Exception(
            "Bulk delete rejected by database (0 rows affected). You can only delete your own reports.",
          );
        }
        bulkConfirmed = true;
      }

      // 3. Dynamic Frontend Synchronization (Zero Full-Page Reload)
      if (mounted) {
        setState(() {
          _records.removeWhere((r) => targetIds.contains(r.id));
        });

        _rebuildMarkers();

        Navigator.pop(context); // Close bulk manager sheet

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Row(
              children: [
                const Icon(Icons.check_circle_outline, color: UberColors.black, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    "${targetIds.length} report(s) permanently deleted.",
                    style: const TextStyle(color: UberColors.black, fontWeight: FontWeight.w700),
                  ),
                ),
              ],
            ),
            backgroundColor: UberColors.white,
            duration: const Duration(seconds: 3),
          ),
        );
      }
    } catch (e) {
      debugPrint("Bulk delete error: $e");
      if (mounted) {
        setState(() {
          _markers = previousMarkers;
          _records = previousRecords;
        });

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              "Bulk delete failed: ${e.toString().replaceAll('Exception: ', '')}",
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            backgroundColor: UberColors.red,
            duration: const Duration(seconds: 4),
          ),
        );
      }
    }
  }

  void _showPotholeBottomSheet(DetectionRecord record, {List<DetectionRecord>? group}) {
    final currentUserId = AppConfig.currentUser?.id;

    // Locate all records associated with this physical location cluster
    final List<DetectionRecord> locationRecords = group ?? _records.where((r) =>
        (r.latitude - record.latitude).abs() < 0.00002 &&
        (r.longitude - record.longitude).abs() < 0.00002).toList();

    final userRecordsAtLocation = locationRecords.where((r) =>
        currentUserId != null && r.userId.isNotEmpty && r.userId == currentUserId).toList();

    final bool isOwner = userRecordsAtLocation.isNotEmpty;
    final color = _getSeverityColor(record.severity);
    bool isDeleting = false;

    showModalBottomSheet(
      context: context,
      backgroundColor: UberColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.only(
          topLeft: Radius.circular(20),
          topRight: Radius.circular(20),
        ),
        side: BorderSide(color: UberColors.border),
      ),
      builder: (_) => StatefulBuilder(
        builder: (context, setModalState) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Drag handle
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
                const SizedBox(height: 16),

                // Title, Severity Tag & Stack Count Badge
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        "Pothole Detected",
                        style: UberTypography.title.copyWith(fontSize: 18),
                      ),
                    ),
                    if (locationRecords.length > 1) ...[
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: UberColors.surfaceElevated,
                          borderRadius: BorderRadius.circular(4),
                          border: Border.all(color: UberColors.border),
                        ),
                        child: Text(
                          "${locationRecords.length} LOGS AT SPOT",
                          style: const TextStyle(
                            color: UberColors.white,
                            fontSize: 10,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 0.5,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                    ],
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: color.withValues(alpha: 0.2),
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(color: color, width: 1),
                      ),
                      child: Text(
                        record.severity.toUpperCase(),
                        style: TextStyle(
                          color: color,
                          fontSize: 11,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 0.6,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),

                // Metadata Row
                Text(
                  "Logged: ${record.formattedDate} • Coords: ${record.latitude.toStringAsFixed(4)}, ${record.longitude.toStringAsFixed(4)}",
                  style: const TextStyle(color: UberColors.textSecondary, fontSize: 12),
                ),
                const SizedBox(height: 16),

                // Image Evidence
                if (record.imageUrl.isNotEmpty)
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Container(
                      height: 180,
                      width: double.infinity,
                      color: UberColors.surfaceElevated,
                      child: Image.network(
                        record.imageUrl,
                        fit: BoxFit.cover,
                        loadingBuilder: (_, child, progress) {
                          if (progress == null) return child;
                          return const Center(
                            child: CircularProgressIndicator(color: UberColors.white, strokeWidth: 2),
                          );
                        },
                        errorBuilder: (_, __, ___) => const Center(
                          child: Icon(Icons.broken_image_outlined, color: UberColors.textTertiary, size: 36),
                        ),
                      ),
                    ),
                  ),
                const SizedBox(height: 20),

                // Action Buttons
                Row(
                  children: [
                    if (isOwner) ...[
                      Expanded(
                        child: ElevatedButton(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: UberColors.surfaceElevated,
                            foregroundColor: UberColors.red,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(8),
                              side: const BorderSide(color: UberColors.red),
                            ),
                          ),
                          onPressed: isDeleting
                              ? null
                              : () async {
                                  setModalState(() => isDeleting = true);
                                  await _deleteDetectionRecords(userRecordsAtLocation, setModalState);
                                  if (mounted) {
                                    setModalState(() => isDeleting = false);
                                  }
                                },
                          child: isDeleting
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(color: UberColors.red, strokeWidth: 2),
                                )
                              : Text(
                                  userRecordsAtLocation.length > 1
                                      ? "DELETE ALL AT SPOT (${userRecordsAtLocation.length})"
                                      : "DELETE REPORT",
                                ),
                        ),
                      ),
                      const SizedBox(width: 12),
                    ] else ...[
                      Expanded(
                        child: Container(
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          decoration: BoxDecoration(
                            color: UberColors.surfaceElevated,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: UberColors.border),
                          ),
                          child: const Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(Icons.lock_outline_rounded, color: UberColors.textTertiary, size: 14),
                              SizedBox(width: 6),
                              Text(
                                "REPORTED BY ANOTHER USER",
                                style: TextStyle(
                                  color: UberColors.textTertiary,
                                  fontSize: 10,
                                  fontWeight: FontWeight.w700,
                                  letterSpacing: 0.5,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                    ],
                    Expanded(
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: UberColors.white,
                          foregroundColor: UberColors.black,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                        ),
                        onPressed: isDeleting ? null : () => Navigator.pop(context),
                        child: const Text("DONE"),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _showMyDetectionsBottomSheet() {
    final currentUserId = AppConfig.currentUser?.id;
    if (currentUserId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("Please sign in to view and manage your detection reports."),
          backgroundColor: UberColors.amber,
        ),
      );
      return;
    }

    final myRecords = _records.where((r) => r.userId == currentUserId).toList();
    final Set<dynamic> selectedIds = {};
    bool isDeleting = false;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: UberColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.only(
          topLeft: Radius.circular(20),
          topRight: Radius.circular(20),
        ),
        side: BorderSide(color: UberColors.border),
      ),
      builder: (_) => StatefulBuilder(
        builder: (context, setModalState) {
          final allSelected = myRecords.isNotEmpty && selectedIds.length == myRecords.length;

          return SizedBox(
            height: MediaQuery.of(context).size.height * 0.75,
            child: Column(
              children: [
                // Drag handle
                Padding(
                  padding: const EdgeInsets.only(top: 12, bottom: 8),
                  child: Center(
                    child: Container(
                      width: 36,
                      height: 4,
                      decoration: BoxDecoration(
                        color: UberColors.border,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                ),

                // Header
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              "MY DETECTIONS",
                              style: UberTypography.title.copyWith(fontSize: 16),
                            ),
                            Text(
                              "${selectedIds.length} of ${myRecords.length} selected",
                              style: const TextStyle(color: UberColors.textSecondary, fontSize: 12),
                            ),
                          ],
                        ),
                      ),
                      if (myRecords.isNotEmpty)
                        TextButton(
                          onPressed: isDeleting
                              ? null
                              : () {
                                  setModalState(() {
                                    if (allSelected) {
                                      selectedIds.clear();
                                    } else {
                                      selectedIds.addAll(myRecords.map((r) => r.id));
                                    }
                                  });
                                },
                          child: Text(
                            allSelected ? "DESELECT ALL" : "SELECT ALL",
                            style: const TextStyle(
                              color: UberColors.white,
                              fontWeight: FontWeight.w700,
                              fontSize: 12,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),

                const Divider(color: UberColors.border, height: 1),

                // List of Records
                Expanded(
                  child: myRecords.isEmpty
                      ? const Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.layers_clear_outlined, color: UberColors.textTertiary, size: 48),
                              SizedBox(height: 12),
                              Text(
                                "No reports logged under your account yet.",
                                style: TextStyle(color: UberColors.textSecondary, fontSize: 14),
                              ),
                            ],
                          ),
                        )
                      : ListView.separated(
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                          itemCount: myRecords.length,
                          separatorBuilder: (_, __) => const SizedBox(height: 8),
                          itemBuilder: (context, index) {
                            final record = myRecords[index];
                            final isSelected = selectedIds.contains(record.id);
                            final color = _getSeverityColor(record.severity);

                            return InkWell(
                              onTap: isDeleting
                                  ? null
                                  : () {
                                      setModalState(() {
                                        if (isSelected) {
                                          selectedIds.remove(record.id);
                                        } else {
                                          selectedIds.add(record.id);
                                        }
                                      });
                                    },
                              borderRadius: BorderRadius.circular(10),
                              child: Container(
                                padding: const EdgeInsets.all(12),
                                decoration: BoxDecoration(
                                  color: isSelected ? UberColors.surfaceElevated : Colors.transparent,
                                  borderRadius: BorderRadius.circular(10),
                                  border: Border.all(
                                    color: isSelected ? UberColors.white : UberColors.border,
                                    width: isSelected ? 1.5 : 1,
                                  ),
                                ),
                                child: Row(
                                  children: [
                                    // Checkbox
                                    Container(
                                      width: 22,
                                      height: 22,
                                      decoration: BoxDecoration(
                                        color: isSelected ? UberColors.white : Colors.transparent,
                                        borderRadius: BorderRadius.circular(4),
                                        border: Border.all(
                                          color: isSelected ? UberColors.white : UberColors.textTertiary,
                                          width: 1.5,
                                        ),
                                      ),
                                      child: isSelected
                                          ? const Icon(Icons.check, size: 16, color: UberColors.black)
                                          : null,
                                    ),
                                    const SizedBox(width: 12),

                                    // Thumbnail
                                    ClipRRect(
                                      borderRadius: BorderRadius.circular(6),
                                      child: Container(
                                        width: 48,
                                        height: 48,
                                        color: UberColors.surfaceElevated,
                                        child: record.imageUrl.isNotEmpty
                                            ? Image.network(
                                                record.imageUrl,
                                                fit: BoxFit.cover,
                                                errorBuilder: (_, __, ___) => const Icon(
                                                  Icons.broken_image_outlined,
                                                  color: UberColors.textTertiary,
                                                  size: 20,
                                                ),
                                              )
                                            : const Icon(
                                                Icons.image_not_supported_outlined,
                                                color: UberColors.textTertiary,
                                                size: 20,
                                              ),
                                      ),
                                    ),
                                    const SizedBox(width: 12),

                                    // Details
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Row(
                                            children: [
                                              Container(
                                                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                                decoration: BoxDecoration(
                                                  color: color.withValues(alpha: 0.2),
                                                  borderRadius: BorderRadius.circular(4),
                                                  border: Border.all(color: color, width: 1),
                                                ),
                                                child: Text(
                                                  record.severity.toUpperCase(),
                                                  style: TextStyle(
                                                    color: color,
                                                    fontSize: 10,
                                                    fontWeight: FontWeight.w800,
                                                    letterSpacing: 0.5,
                                                  ),
                                                ),
                                              ),
                                              const SizedBox(width: 8),
                                              Text(
                                                record.formattedDate,
                                                style: const TextStyle(
                                                  color: UberColors.textSecondary,
                                                  fontSize: 11,
                                                ),
                                              ),
                                            ],
                                          ),
                                          const SizedBox(height: 4),
                                          Text(
                                            "${record.latitude.toStringAsFixed(4)}, ${record.longitude.toStringAsFixed(4)}",
                                            style: const TextStyle(
                                              color: UberColors.textTertiary,
                                              fontSize: 11,
                                              fontFamily: 'monospace',
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
                ),

                // Bottom Sticky Action Bar
                Container(
                  padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
                  decoration: const BoxDecoration(
                    color: UberColors.surface,
                    border: Border(top: BorderSide(color: UberColors.border)),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: ElevatedButton(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: selectedIds.isEmpty ? UberColors.surfaceElevated : UberColors.red,
                            foregroundColor: selectedIds.isEmpty ? UberColors.textTertiary : UberColors.white,
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                            padding: const EdgeInsets.symmetric(vertical: 14),
                          ),
                          onPressed: (selectedIds.isEmpty || isDeleting)
                              ? null
                              : () async {
                                  final confirmed = await showDialog<bool>(
                                    context: context,
                                    builder: (ctx) => AlertDialog(
                                      backgroundColor: UberColors.surface,
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(12),
                                        side: const BorderSide(color: UberColors.border),
                                      ),
                                      title: Text(
                                        "Delete ${selectedIds.length} Report(s)?",
                                        style: UberTypography.title.copyWith(fontSize: 16),
                                      ),
                                      content: const Text(
                                        "This will permanently delete the selected reports and their image evidence from Supabase.",
                                        style: TextStyle(color: UberColors.textSecondary, fontSize: 13),
                                      ),
                                      actions: [
                                        TextButton(
                                          onPressed: () => Navigator.pop(ctx, false),
                                          child: const Text("CANCEL", style: TextStyle(color: UberColors.white)),
                                        ),
                                        ElevatedButton(
                                          style: ElevatedButton.styleFrom(
                                            backgroundColor: UberColors.red,
                                            foregroundColor: UberColors.white,
                                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                                          ),
                                          onPressed: () => Navigator.pop(ctx, true),
                                          child: const Text("CONFIRM DELETE"),
                                        ),
                                      ],
                                    ),
                                  );

                                  if (confirmed == true) {
                                    setModalState(() => isDeleting = true);
                                    await _bulkDeleteDetections(selectedIds, setModalState);
                                  }
                                },
                          child: isDeleting
                              ? const SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(color: UberColors.white, strokeWidth: 2),
                                )
                              : Text(
                                  selectedIds.isEmpty
                                      ? "SELECT REPORTS TO DELETE"
                                      : "DELETE ${selectedIds.length} SELECTED",
                                  style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
                                ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: UberColors.background,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // 1. Dark Cartography Map
          Positioned.fill(
            child: FlutterMap(
              mapController: _mapController,
              options: MapOptions(
                initialCenter: _mapCenter,
                initialZoom: 14.0,
                backgroundColor: UberColors.background,
              ),
              children: [
                TileLayer(
                  urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                  userAgentPackageName: 'com.example.road_data_logger',
                  tileBuilder: (context, tileWidget, tile) {
                    return ColorFiltered(
                      colorFilter: const ColorFilter.matrix(<double>[
                        -0.85, 0, 0, 0, 240,
                        0, -0.85, 0, 0, 240,
                        0, 0, -0.85, 0, 240,
                        0, 0, 0, 1, 0,
                      ]),
                      child: tileWidget,
                    );
                  },
                ),
                MarkerLayer(markers: _markers),
              ],
            ),
          ),

          // 2. Top Header Navigation with Segmented Filter Control
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              bottom: false,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      // Back Button
                      Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          color: UberColors.surface,
                          shape: BoxShape.circle,
                          border: Border.all(color: UberColors.border),
                        ),
                        child: IconButton(
                          icon: const Icon(Icons.arrow_back, color: UberColors.white, size: 20),
                          onPressed: () => Navigator.pop(context),
                        ),
                      ),
                      const SizedBox(width: 12),

                      // Segmented Filter Toggle
                      Expanded(
                        child: Container(
                          height: 42,
                          padding: const EdgeInsets.all(3),
                          decoration: BoxDecoration(
                            color: UberColors.surface,
                            borderRadius: BorderRadius.circular(21),
                            border: Border.all(color: UberColors.border),
                          ),
                          child: Row(
                            children: [
                              Expanded(
                                child: GestureDetector(
                                  onTap: () {
                                    if (_showOnlyMine) {
                                      setState(() => _showOnlyMine = false);
                                      _fetchDetections();
                                    }
                                  },
                                  child: Container(
                                    alignment: Alignment.center,
                                    decoration: BoxDecoration(
                                      color: !_showOnlyMine ? UberColors.white : Colors.transparent,
                                      borderRadius: BorderRadius.circular(18),
                                    ),
                                    child: Text(
                                      "ALL REPORTS",
                                      style: TextStyle(
                                        color: !_showOnlyMine ? UberColors.black : UberColors.textSecondary,
                                        fontSize: 11,
                                        fontWeight: FontWeight.w700,
                                        letterSpacing: 0.6,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                              Expanded(
                                child: GestureDetector(
                                  onTap: () {
                                    if (!_showOnlyMine) {
                                      setState(() => _showOnlyMine = true);
                                      _fetchDetections();
                                    }
                                  },
                                  child: Container(
                                    alignment: Alignment.center,
                                    decoration: BoxDecoration(
                                      color: _showOnlyMine ? UberColors.white : Colors.transparent,
                                      borderRadius: BorderRadius.circular(18),
                                    ),
                                    child: Text(
                                      "MY REPORTS",
                                      style: TextStyle(
                                        color: _showOnlyMine ? UberColors.black : UberColors.textSecondary,
                                        fontSize: 11,
                                        fontWeight: FontWeight.w700,
                                        letterSpacing: 0.6,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),

                      // My Reports & Bulk Delete Manager
                      Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          color: UberColors.surface,
                          shape: BoxShape.circle,
                          border: Border.all(color: UberColors.border),
                        ),
                        child: IconButton(
                          icon: const Icon(Icons.checklist_rounded, color: UberColors.white, size: 20),
                          tooltip: "My Reports & Bulk Delete",
                          onPressed: _showMyDetectionsBottomSheet,
                        ),
                      ),
                      const SizedBox(width: 8),

                      // Refresh Button
                      Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          color: UberColors.surface,
                          shape: BoxShape.circle,
                          border: Border.all(color: UberColors.border),
                        ),
                        child: IconButton(
                          icon: const Icon(Icons.refresh, color: UberColors.white, size: 20),
                          tooltip: "Refresh Map",
                          onPressed: _fetchDetections,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),

          // 3. Loading Overlay
          if (_isLoading)
            Positioned(
              top: 80,
              left: 0,
              right: 0,
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  decoration: BoxDecoration(
                    color: UberColors.surface,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: UberColors.border),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(color: UberColors.white, strokeWidth: 2),
                      ),
                      SizedBox(width: 8),
                      Text("Updating markers...", style: TextStyle(color: UberColors.white, fontSize: 12)),
                    ],
                  ),
                ),
              ),
            ),

          // 4. Floating Map Controls (Nearest Detection & Zoom Controls)
          Positioned(
            right: 16,
            bottom: 32,
            child: SafeArea(
              top: false,
              left: false,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Nearest Detection Target Button
                  Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      color: UberColors.surface,
                      shape: BoxShape.circle,
                      border: Border.all(color: UberColors.border, width: 1.5),
                      boxShadow: const [
                        BoxShadow(
                          color: Colors.black87,
                          blurRadius: 8,
                          offset: Offset(0, 4),
                        ),
                      ],
                    ),
                    child: IconButton(
                      tooltip: "Locate Nearest Detection",
                      icon: _isLocatingNearest
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                color: UberColors.white,
                                strokeWidth: 2,
                              ),
                            )
                          : const Icon(Icons.near_me_rounded, color: UberColors.white, size: 22),
                      onPressed: _isLocatingNearest ? null : _navigateToNearestDetection,
                    ),
                  ),
                  const SizedBox(height: 12),

                  // Zoom Controls Capsule (Zoom In & Zoom Out)
                  Container(
                    width: 48,
                    decoration: BoxDecoration(
                      color: UberColors.surface,
                      borderRadius: BorderRadius.circular(24),
                      border: Border.all(color: UberColors.border, width: 1.5),
                      boxShadow: const [
                        BoxShadow(
                          color: Colors.black87,
                          blurRadius: 8,
                          offset: Offset(0, 4),
                        ),
                      ],
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          tooltip: "Zoom In",
                          icon: const Icon(Icons.add_rounded, color: UberColors.white, size: 22),
                          onPressed: _zoomIn,
                        ),
                        Container(
                          height: 1,
                          width: 28,
                          color: UberColors.border,
                        ),
                        IconButton(
                          tooltip: "Zoom Out",
                          icon: const Icon(Icons.remove_rounded, color: UberColors.white, size: 22),
                          onPressed: _zoomOut,
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
}

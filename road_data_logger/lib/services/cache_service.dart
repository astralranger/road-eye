import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';
import '../models/detection_record.dart';
import '../models/spatial_video_report.dart';

class _MemoryCacheEntry {
  final dynamic value;
  final DateTime expiry;

  _MemoryCacheEntry({required this.value, required this.expiry});

  bool get isExpired => DateTime.now().isAfter(expiry);
}

/// Advanced multi-tier Caching Service for RoadEye:
/// - L1: High-speed in-memory memoization with TTL expiration
/// - L2: Persistent local storage for instant (<5ms) map hydration
/// - Asset Pre-warming: Asynchronous pre-caching of pothole evidence images
class CacheService {
  static final CacheService _instance = CacheService._internal();
  factory CacheService() => _instance;
  CacheService._internal();

  final Map<String, _MemoryCacheEntry> _memoryCache = {};
  Directory? _cacheDir;

  static const String _detectionsCacheFilename = 'cached_map_detections.json';
  static const String _spatialReportsCacheFilename = 'cached_map_spatial_reports.json';
  static const String _memoKeyDetections = 'l1_cached_map_detections';
  static const String _memoKeySpatialReports = 'l1_cached_map_spatial_reports';

  /// Resolves the dedicated cache directory on disk safely with in-memory fallback
  Future<Directory?> _getCacheDirectory() async {
    if (_cacheDir != null) return _cacheDir;
    try {
      final docs = await getApplicationDocumentsDirectory();
      _cacheDir = Directory('${docs.path}/roadeye_cache');
      if (!await _cacheDir!.exists()) {
        await _cacheDir!.create(recursive: true);
      }
      return _cacheDir;
    } catch (e) {
      debugPrint("CacheService: Disk cache directory not available (memory-only mode active): $e");
      return null;
    }
  }

  // ---------------------------------------------------------------------------
  // L1: In-Memory Memoization Layer
  // ---------------------------------------------------------------------------

  /// Retrieves a memoized value if available and not expired
  T? getMemoized<T>(String key) {
    final entry = _memoryCache[key];
    if (entry == null) return null;
    if (entry.isExpired) {
      _memoryCache.remove(key);
      return null;
    }
    return entry.value as T?;
  }

  /// Sets a value in the in-memory memoization cache with an explicit TTL
  void setMemoized<T>(String key, T value, {Duration ttl = const Duration(minutes: 5)}) {
    _memoryCache[key] = _MemoryCacheEntry(
      value: value,
      expiry: DateTime.now().add(ttl),
    );
  }

  /// Invalidates a specific memoized key
  void invalidate(String key) {
    _memoryCache.remove(key);
  }

  /// Clears the entire in-memory cache
  void clearMemoryCache() {
    _memoryCache.clear();
  }

  // ---------------------------------------------------------------------------
  // L2: Persistent Map State Caching
  // ---------------------------------------------------------------------------

  /// Atomically saves 2D map detection records to persistent storage and L1 memory
  Future<void> saveMapDetections(List<DetectionRecord> records) async {
    // 1. Update L1
    setMemoized<List<DetectionRecord>>(_memoKeyDetections, records, ttl: const Duration(minutes: 15));

    // 2. Persist to L2 disk
    try {
      final dir = await _getCacheDirectory();
      if (dir == null) return;

      final file = File('${dir.path}/$_detectionsCacheFilename');
      final tempFile = File('${dir.path}/$_detectionsCacheFilename.tmp');

      final list = records.map((r) => r.toMap()).toList();
      final jsonString = jsonEncode(list);

      await tempFile.writeAsString(jsonString, flush: true);
      await tempFile.rename(file.path);
    } catch (e) {
      debugPrint("CacheService: Error persisting map detections to disk: $e");
    }
  }

  /// Loads 2D map detections: Checks L1 in-memory cache first, then reads L2 disk
  Future<List<DetectionRecord>> loadCachedMapDetections() async {
    // 1. Check L1
    final memoized = getMemoized<List<DetectionRecord>>(_memoKeyDetections);
    if (memoized != null && memoized.isNotEmpty) {
      return List<DetectionRecord>.from(memoized);
    }

    // 2. Check L2 Disk
    try {
      final dir = await _getCacheDirectory();
      if (dir == null) return [];

      final file = File('${dir.path}/$_detectionsCacheFilename');
      if (!await file.exists()) return [];

      final content = await file.readAsString();
      if (content.trim().isEmpty) return [];

      final dynamic decoded = jsonDecode(content);
      if (decoded is List) {
        final records = decoded
            .map((item) => DetectionRecord.fromMap(item as Map<String, dynamic>))
            .toList();
        // Warm L1
        setMemoized<List<DetectionRecord>>(_memoKeyDetections, records, ttl: const Duration(minutes: 15));
        return records;
      }
    } catch (e) {
      debugPrint("CacheService: Error loading cached map detections from disk: $e");
    }
    return [];
  }

  /// Atomically saves 3D spatial video reports to persistent storage and L1 memory
  Future<void> saveMapSpatialReports(List<SpatialVideoReport> reports) async {
    // 1. Update L1
    setMemoized<List<SpatialVideoReport>>(_memoKeySpatialReports, reports, ttl: const Duration(minutes: 15));

    // 2. Persist to L2 disk
    try {
      final dir = await _getCacheDirectory();
      if (dir == null) return;

      final file = File('${dir.path}/$_spatialReportsCacheFilename');
      final tempFile = File('${dir.path}/$_spatialReportsCacheFilename.tmp');

      final list = reports.map((r) => r.toLocalMap()).toList();
      final jsonString = jsonEncode(list);

      await tempFile.writeAsString(jsonString, flush: true);
      await tempFile.rename(file.path);
    } catch (e) {
      debugPrint("CacheService: Error persisting map spatial reports to disk: $e");
    }
  }

  /// Loads 3D spatial video reports: Checks L1 in-memory cache first, then reads L2 disk
  Future<List<SpatialVideoReport>> loadCachedMapSpatialReports() async {
    // 1. Check L1
    final memoized = getMemoized<List<SpatialVideoReport>>(_memoKeySpatialReports);
    if (memoized != null && memoized.isNotEmpty) {
      return List<SpatialVideoReport>.from(memoized);
    }

    // 2. Check L2 Disk
    try {
      final dir = await _getCacheDirectory();
      if (dir == null) return [];

      final file = File('${dir.path}/$_spatialReportsCacheFilename');
      if (!await file.exists()) return [];

      final content = await file.readAsString();
      if (content.trim().isEmpty) return [];

      final dynamic decoded = jsonDecode(content);
      if (decoded is List) {
        final reports = decoded
            .map((item) => SpatialVideoReport.fromLocalMap(item as Map<String, dynamic>))
            .toList();
        // Warm L1
        setMemoized<List<SpatialVideoReport>>(_memoKeySpatialReports, reports, ttl: const Duration(minutes: 15));
        return reports;
      }
    } catch (e) {
      debugPrint("CacheService: Error loading cached map spatial reports from disk: $e");
    }
    return [];
  }

  // ---------------------------------------------------------------------------
  // Asset Pre-warming: Pothole Evidence Images
  // ---------------------------------------------------------------------------

  /// Pre-caches recent pothole evidence images in Flutter's ImageCache
  /// so bottom sheet snapshots load instantaneously without network delay.
  void precachePotholeImages(
    BuildContext context,
    List<String> imageUrls, {
    int maxCount = 8,
  }) {
    if (!context.mounted) return;
    int prefetched = 0;
    for (final url in imageUrls) {
      if (prefetched >= maxCount) break;
      final trimmed = url.trim();
      if (trimmed.isEmpty || !trimmed.startsWith('http')) continue;

      try {
        final provider = NetworkImage(trimmed);
        precacheImage(provider, context).catchError((e) {
          debugPrint("CacheService: Pre-cache image warning for $trimmed: $e");
        });
        prefetched++;
      } catch (e) {
        debugPrint("CacheService: Failed to queue image pre-cache: $e");
      }
    }
  }

  /// Clears both L1 memory and L2 persistent cache files
  Future<void> clearAll() async {
    clearMemoryCache();
    try {
      final dir = await _getCacheDirectory();
      if (dir != null && await dir.exists()) {
        final files = dir.listSync();
        for (final f in files) {
          if (f is File) {
            await f.delete();
          }
        }
      }
    } catch (e) {
      debugPrint("CacheService: Error clearing disk cache: $e");
    }
  }
}

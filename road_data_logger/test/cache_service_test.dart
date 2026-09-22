import 'package:flutter_test/flutter_test.dart';
import 'package:road_data_logger/models/detection_record.dart';
import 'package:road_data_logger/models/spatial_video_report.dart';
import 'package:road_data_logger/services/cache_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late CacheService cacheService;

  setUp(() {
    cacheService = CacheService();
    cacheService.clearMemoryCache();
  });

  group('CacheService - In-Memory Memoization (L1)', () {
    test('Stores and retrieves memoized value within TTL', () {
      cacheService.setMemoized<String>('test_key', 'test_value', ttl: const Duration(minutes: 5));
      final result = cacheService.getMemoized<String>('test_key');
      expect(result, equals('test_value'));
    });

    test('Returns null when key has expired', () {
      // Set with negative duration so it is already expired
      cacheService.setMemoized<String>('expired_key', 'expired_value', ttl: const Duration(seconds: -1));
      final result = cacheService.getMemoized<String>('expired_key');
      expect(result, isNull);
    });

    test('Invalidates individual keys properly', () {
      cacheService.setMemoized<int>('count', 42);
      expect(cacheService.getMemoized<int>('count'), equals(42));

      cacheService.invalidate('count');
      expect(cacheService.getMemoized<int>('count'), isNull);
    });

    test('clearMemoryCache wipes all keys', () {
      cacheService.setMemoized<String>('k1', 'v1');
      cacheService.setMemoized<String>('k2', 'v2');

      cacheService.clearMemoryCache();
      expect(cacheService.getMemoized<String>('k1'), isNull);
      expect(cacheService.getMemoized<String>('k2'), isNull);
    });
  });

  group('CacheService - Map State Detections Serialization & Caching', () {
    test('DetectionRecord toMap and fromMap symmetry', () {
      const record = DetectionRecord(
        id: 'det_123',
        latitude: 18.5204,
        longitude: 73.8567,
        imageUrl: 'https://example.com/pothole.jpg',
        createdAt: '2026-09-21T10:00:00Z',
        severity: 'Severe',
        userId: 'user_456',
      );

      final map = record.toMap();
      expect(map['id'], equals('det_123'));
      expect(map['latitude'], equals(18.5204));
      expect(map['longitude'], equals(73.8567));
      expect(map['image_url'], equals('https://example.com/pothole.jpg'));
      expect(map['severity'], equals('Severe'));

      final restored = DetectionRecord.fromMap(map);
      expect(restored.id, equals(record.id));
      expect(restored.latitude, equals(record.latitude));
      expect(restored.longitude, equals(record.longitude));
      expect(restored.imageUrl, equals(record.imageUrl));
      expect(restored.severity, equals(record.severity));
      expect(restored.userId, equals(record.userId));
    });

    test('Saves and loads cached detection records via L1/L2', () async {
      final records = [
        const DetectionRecord(
          id: '101',
          latitude: 18.51,
          longitude: 73.84,
          imageUrl: 'https://img.example.com/1.jpg',
          createdAt: '2026-09-21T12:00:00Z',
          severity: 'Severe',
          userId: 'u1',
        ),
        const DetectionRecord(
          id: '102',
          latitude: 18.52,
          longitude: 73.85,
          imageUrl: 'https://img.example.com/2.jpg',
          createdAt: '2026-09-21T12:05:00Z',
          severity: 'Minor',
          userId: 'u2',
        ),
      ];

      await cacheService.saveMapDetections(records);

      final loaded = await cacheService.loadCachedMapDetections();
      expect(loaded.length, equals(2));
      expect(loaded[0].id, equals('101'));
      expect(loaded[0].severity, equals('Severe'));
      expect(loaded[1].id, equals('102'));
      expect(loaded[1].severity, equals('Minor'));
    });
  });

  group('CacheService - Map Spatial Video Reports Serialization & Caching', () {
    test('Saves and loads cached spatial reports via L1/L2', () async {
      final reports = [
        SpatialVideoReport(
          id: 'report_abc',
          userId: 'user_1',
          userEmail: 'driver@roadeye.ai',
          recordedAt: DateTime.parse('2026-09-21T14:30:00Z'),
          durationMs: 4500,
          resolution: '1280x720',
          fileSizeBytes: 1048576,
          localVideoPath: '/path/to/vid.mp4',
          videoFilename: 'vid.mp4',
          storageStatus: 'uploaded',
          checksumSha256: 'deadbeef',
          pointCount: 15,
          startLat: 18.5300,
          startLon: 73.8600,
          endLat: 18.5310,
          endLon: 73.8610,
          distanceMeters: 120.0,
          avgSpeedKmh: 35.0,
          gpsTrail: const [],
          splatStatus: 'completed',
          viewerHtmlPath: 'https://compute-node.tailscale.net/viewer/report_abc',
          cavityVolumeLiters: 4.85,
          maxDepthCm: 7.2,
        ),
      ];

      await cacheService.saveMapSpatialReports(reports);

      final loaded = await cacheService.loadCachedMapSpatialReports();
      expect(loaded.length, equals(1));
      expect(loaded[0].id, equals('report_abc'));
      expect(loaded[0].splatStatus, equals('completed'));
      expect(loaded[0].viewerHtmlPath, equals('https://compute-node.tailscale.net/viewer/report_abc'));
      expect(loaded[0].cavityVolumeLiters, equals(4.85));
      expect(loaded[0].maxDepthCm, equals(7.2));
    });
  });
}

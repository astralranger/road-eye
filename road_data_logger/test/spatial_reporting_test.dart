import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:road_data_logger/models/spatial_video_report.dart';
import 'package:road_data_logger/services/spatial_queue_service.dart';
import 'package:road_data_logger/utils/uuid_helper.dart';

class MockUploadHandler implements VideoUploadHandler {
  final bool shouldSucceed;
  final List<SpatialVideoReport> uploadedReports = [];

  MockUploadHandler({this.shouldSucceed = true});

  @override
  Future<bool> uploadReport(SpatialVideoReport report) async {
    if (!shouldSucceed) {
      throw Exception("Simulated network timeout");
    }
    uploadedReports.add(report);
    return true;
  }
}

void main() {
  group('UUID Helper RFC4122 v4 Tests', () {
    test('Generates valid v4 UUID matching canonical format', () {
      final uuid = UuidHelper.generateV4();
      final regex = RegExp(
        r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
      );
      expect(regex.hasMatch(uuid), isTrue, reason: "UUID $uuid must match RFC 4122 v4 format");
    });

    test('Generates unique identifiers in succession', () {
      final set = <String>{};
      for (int i = 0; i < 100; i++) {
        final id = UuidHelper.generateV4();
        expect(set.contains(id), isFalse);
        set.add(id);
      }
      expect(set.length, equals(100));
    });
  });

  group('GpsBreadcrumb Model Serialization', () {
    test('Serializes and deserializes accurately preserving all telemetry fields', () {
      final now = DateTime.now();
      final point = GpsBreadcrumb(
        latitude: 18.5204303,
        longitude: 73.8567437,
        altitude: 560.2,
        accuracy: 3.4,
        speed: 11.2,
        heading: 184.5,
        elapsedMs: 2450,
        timestamp: now,
        quality: GpsQuality.optimal,
      );

      final map = point.toMap();
      expect(map['lat'], equals(18.5204303));
      expect(map['lon'], equals(73.8567437));
      expect(map['alt'], equals(560.2));
      expect(map['acc'], equals(3.4));
      expect(map['spd'], equals(11.2));
      expect(map['hdg'], equals(184.5));
      expect(map['elapsed_ms'], equals(2450));
      expect(map['q'], equals('optimal'));

      final restored = GpsBreadcrumb.fromMap(map);
      expect(restored.latitude, equals(point.latitude));
      expect(restored.longitude, equals(point.longitude));
      expect(restored.altitude, equals(point.altitude));
      expect(restored.accuracy, equals(point.accuracy));
      expect(restored.speed, equals(point.speed));
      expect(restored.heading, equals(point.heading));
      expect(restored.elapsedMs, equals(point.elapsedMs));
      expect(restored.quality, equals(GpsQuality.optimal));
    });

    test('Correctly handles degraded and spoofed quality states', () {
      final degraded = GpsBreadcrumb.fromMap({
        'lat': 18.5,
        'lon': 73.8,
        'q': 'degraded',
      });
      expect(degraded.quality, equals(GpsQuality.degraded));

      final spoofed = GpsBreadcrumb.fromMap({
        'lat': 18.5,
        'lon': 73.8,
        'q': 'spoofed',
      });
      expect(spoofed.quality, equals(GpsQuality.spoofed));
    });
  });

  group('SpatialVideoReport Contract & Supabase Payload', () {
    test('Generates Supabase payload strictly conforming to PostgreSQL schema', () {
      final recordedAt = DateTime.utc(2026, 9, 19, 12, 0, 0);
      final trail = [
        GpsBreadcrumb(
          latitude: 18.5204,
          longitude: 73.8567,
          altitude: 560.0,
          accuracy: 2.5,
          speed: 10.0,
          heading: 90.0,
          elapsedMs: 0,
          timestamp: recordedAt,
          quality: GpsQuality.optimal,
        ),
        GpsBreadcrumb(
          latitude: 18.5210,
          longitude: 73.8575,
          altitude: 560.5,
          accuracy: 2.8,
          speed: 12.0,
          heading: 92.0,
          elapsedMs: 3000,
          timestamp: recordedAt.add(const Duration(seconds: 3)),
          quality: GpsQuality.optimal,
        ),
      ];

      final report = SpatialVideoReport(
        id: "d3b07384-d113-46fb-a0ff-5ecff22bc210",
        userId: "f47ac10b-58cc-4372-a567-0e02b2c3d479",
        userEmail: "engineer@autonomouscam.ai",
        recordedAt: recordedAt,
        durationMs: 3000,
        resolution: "1280x720",
        fileSizeBytes: 2450000,
        localVideoPath: "/data/spatial_videos/spatial_rec_1.mp4",
        videoFilename: "spatial_rec_1.mp4",
        storageStatus: "local_only",
        checksumSha256: "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        pointCount: 2,
        startLat: 18.5204,
        startLon: 73.8567,
        endLat: 18.5210,
        endLon: 73.8575,
        distanceMeters: 108.5,
        avgSpeedKmh: 39.6,
        gpsTrail: trail,
        isTamperVerified: true,
        splatStatus: "completed",
        syncStatus: SyncStatus.synced,
        processingNodeId: "node-gpu-rtx3080",
        progressPct: 100,
        cavityVolumeLiters: 3.42,
        maxDepthCm: 7.15,
        viewerHtmlPath: "https://gpu-node.ts.net/viewer",
      );

      final payload = report.toSupabasePayload();

      expect(payload['id'], equals("d3b07384-d113-46fb-a0ff-5ecff22bc210"));
      expect(payload['user_id'], equals("f47ac10b-58cc-4372-a567-0e02b2c3d479"));
      expect(payload['user_email'], equals("engineer@autonomouscam.ai"));
      expect(payload['storage_status'], equals("local_only"));
      expect(payload['duration_ms'], equals(3000));
      expect(payload['file_size_bytes'], equals(2450000));
      expect(payload['point_count'], equals(2));
      expect(payload['start_lat'], equals(18.5204));
      expect(payload['end_lon'], equals(73.8575));
      expect(payload['distance_meters'], equals(108.5));
      expect(payload['avg_speed_kmh'], equals(39.6));
      expect(payload['is_tamper_verified'], isTrue);
      expect(payload['splat_status'], equals("completed"));
      expect(payload['processing_node_id'], equals("node-gpu-rtx3080"));
      expect(payload['progress_pct'], equals(100));

      // Ensure trail is formatted as list of maps for PostgreSQL JSONB
      final dynamic gpsTrailPayload = payload['gps_trail'];
      expect(gpsTrailPayload is List, isTrue);
      expect((gpsTrailPayload as List).length, equals(2));

      // Local serialization check
      final localMap = report.toLocalMap();
      final restored = SpatialVideoReport.fromLocalMap(localMap);
      expect(restored.id, equals(report.id));
      expect(restored.localVideoPath, equals(report.localVideoPath));
      expect(restored.formattedDuration, equals("00:03"));
      expect(restored.formattedFileSize, equals("2.3 MB"));
      expect(restored.processingNodeId, equals("node-gpu-rtx3080"));
      expect(restored.progressPct, equals(100));
      expect(restored.cavityVolumeLiters, equals(3.42));
      expect(restored.maxDepthCm, equals(7.15));
      expect(restored.viewerHtmlPath, equals("https://gpu-node.ts.net/viewer"));
    });
  });

  group('Cryptographic Tamper-Proofing Integrity', () {
    test('Generates deterministic SHA-256 and detects metadata alterations', () {
      const userId = "test_user_1";
      const timestamp = "2026-09-19T14:30:00.000Z";
      const durationMs = 12000;
      const pointCount = 45;
      const startLat = 18.5204;
      const startLon = 73.8567;
      const endLat = 18.5290;
      const endLon = 73.8650;
      const fileSizeBytes = 5400000;

      final payloadString = utf8.encode(
        '$userId|$timestamp|$durationMs|$pointCount|$startLat|$startLon|$endLat|$endLon|$fileSizeBytes',
      );
      final hash1 = sha256.convert(payloadString).toString();
      final hash2 = sha256.convert(payloadString).toString();

      // Deterministic validation
      expect(hash1, equals(hash2));
      expect(hash1.length, equals(64));

      // Tampered coordinate check
      final tamperedPayload = utf8.encode(
        '$userId|$timestamp|$durationMs|$pointCount|18.5205|$startLon|$endLat|$endLon|$fileSizeBytes',
      );
      final tamperedHash = sha256.convert(tamperedPayload).toString();
      expect(tamperedHash, isNot(equals(hash1)), reason: "Even 0.0001 deg shift must invalidate checksum");
    });
  });

  group('Upload Handler Pluggability & Strategy Pattern', () {
    test('MetadataOnly upload records report in Mock handler', () async {
      final mock = MockUploadHandler(shouldSucceed: true);
      final report = SpatialVideoReport(
        id: UuidHelper.generateV4(),
        userId: "user_123",
        userEmail: "test@example.com",
        recordedAt: DateTime.now(),
        durationMs: 5000,
        resolution: "1280x720",
        fileSizeBytes: 1024 * 1024,
        localVideoPath: "/tmp/test.mp4",
        videoFilename: "test.mp4",
        checksumSha256: "abc123hash",
        pointCount: 10,
        startLat: 18.0,
        startLon: 73.0,
        endLat: 18.1,
        endLon: 73.1,
        distanceMeters: 50.0,
        avgSpeedKmh: 25.0,
        gpsTrail: [],
      );

      final ok = await mock.uploadReport(report);
      expect(ok, isTrue);
      expect(mock.uploadedReports.length, equals(1));
      expect(mock.uploadedReports.first.id, equals(report.id));
    });

    test('Failing handler throws for queue retry mechanism', () async {
      final failingMock = MockUploadHandler(shouldSucceed: false);
      final report = SpatialVideoReport(
        id: UuidHelper.generateV4(),
        userId: "user_123",
        userEmail: "test@example.com",
        recordedAt: DateTime.now(),
        durationMs: 5000,
        resolution: "1280x720",
        fileSizeBytes: 1024,
        localVideoPath: "/tmp/test.mp4",
        videoFilename: "test.mp4",
        checksumSha256: "abc",
        pointCount: 1,
        startLat: 18.0,
        startLon: 73.0,
        endLat: 18.0,
        endLon: 73.0,
        distanceMeters: 0.0,
        avgSpeedKmh: 0.0,
        gpsTrail: [],
      );

      expect(
        () => failingMock.uploadReport(report),
        throwsA(isA<Exception>()),
      );
    });
  });
}

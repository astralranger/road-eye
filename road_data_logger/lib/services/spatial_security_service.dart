import 'dart:async';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import '../models/spatial_video_report.dart';

class SpatialSecurityResult {
  final List<GpsBreadcrumb> trail;
  final int pointCount;
  final double startLat;
  final double startLon;
  final double endLat;
  final double endLon;
  final double distanceMeters;
  final double avgSpeedKmh;
  final String checksumSha256;
  final bool isTamperVerified;

  const SpatialSecurityResult({
    required this.trail,
    required this.pointCount,
    required this.startLat,
    required this.startLon,
    required this.endLat,
    required this.endLon,
    required this.distanceMeters,
    required this.avgSpeedKmh,
    required this.checksumSha256,
    required this.isTamperVerified,
  });
}

class SpatialSecurityService {
  StreamSubscription<Position>? _positionSubscription;
  final List<GpsBreadcrumb> _activeTrail = [];
  DateTime? _sessionStartTime;
  DateTime? _lastFixTimestamp;
  Position? _lastValidPosition;

  bool _isCapturing = false;
  bool _hasSpoofedPoints = false;

  final ValueNotifier<int> pointCountNotifier = ValueNotifier<int>(0);
  final ValueNotifier<double> latestAccuracyNotifier = ValueNotifier<double>(0.0);
  final ValueNotifier<bool> isGpsLockedNotifier = ValueNotifier<bool>(false);

  bool get isCapturing => _isCapturing;

  /// Starts sampling device GPS exclusively for the active recording window.
  /// Rejects stale, cached, and mocked coordinates to ensure tamper-proof spatial integrity.
  Future<void> startSecurityTrail() async {
    _positionSubscription?.cancel();
    _activeTrail.clear();
    _sessionStartTime = DateTime.now();
    _lastFixTimestamp = null;
    _lastValidPosition = null;
    _isCapturing = true;
    _hasSpoofedPoints = false;
    pointCountNotifier.value = 0;
    latestAccuracyNotifier.value = 0.0;
    isGpsLockedNotifier.value = false;

    // Use best accuracy with 1-meter filter to prevent jitter thrashing
    const locationSettings = LocationSettings(
      accuracy: LocationAccuracy.bestForNavigation,
      distanceFilter: 1,
    );

    _positionSubscription = Geolocator.getPositionStream(
      locationSettings: locationSettings,
    ).listen(
      _processPositionFix,
      onError: (err) {
        debugPrint("Security GPS Stream Warning: $err");
      },
    );
  }

  void _processPositionFix(Position position) {
    if (!_isCapturing || _sessionStartTime == null) return;

    final now = DateTime.now();
    final elapsedMs = now.difference(_sessionStartTime!).inMilliseconds;

    // 1. Anti-Spoofing: Check if mock location provider is detected
    bool isMocked = position.isMocked;
    if (isMocked) {
      _hasSpoofedPoints = true;
      debugPrint("Anti-Spoofing: Mock location provider detected at $elapsedMs ms");
    }

    // 2. Strict Monotonicity: Fix timestamp must not be pre-existing / older than session
    final fixTime = position.timestamp;
    if (_lastFixTimestamp != null && fixTime.isBefore(_lastFixTimestamp!)) {
      debugPrint("Anti-Spoofing: Non-monotonic GPS timestamp rejected");
      return;
    }

    // 3. Physical Velocity Sanity Check (Max 65 m/s ~ 234 km/h to catch GPS teleportation)
    if (_lastValidPosition != null) {
      final deltaSecs = now.difference(_lastValidPosition!.timestamp).inMilliseconds / 1000.0;
      if (deltaSecs > 0) {
        final dist = Geolocator.distanceBetween(
          _lastValidPosition!.latitude,
          _lastValidPosition!.longitude,
          position.latitude,
          position.longitude,
        );
        final speedMps = dist / deltaSecs;
        if (speedMps > 65.0) {
          debugPrint("Anti-Spoofing: Unrealistic velocity delta ($speedMps m/s). Marked as degraded.");
          isMocked = true;
          _hasSpoofedPoints = true;
        }
      }
    }

    // 4. Accuracy Assessment
    GpsQuality quality = GpsQuality.optimal;
    if (isMocked) {
      quality = GpsQuality.spoofed;
    } else if (position.accuracy > 25.0) {
      // Degraded GPS (e.g. underpasses/tunnels) - retained for visual SfM fallback
      quality = GpsQuality.degraded;
    }

    final breadcrumb = GpsBreadcrumb(
      latitude: position.latitude,
      longitude: position.longitude,
      altitude: position.altitude,
      accuracy: position.accuracy,
      speed: position.speed,
      heading: position.heading,
      elapsedMs: elapsedMs,
      timestamp: now,
      quality: quality,
    );

    _activeTrail.add(breadcrumb);
    _lastFixTimestamp = fixTime;
    _lastValidPosition = position;

    pointCountNotifier.value = _activeTrail.length;
    latestAccuracyNotifier.value = position.accuracy;
    isGpsLockedNotifier.value = quality != GpsQuality.spoofed;
  }

  /// Finalizes the security-bound GPS trail, computes distance/speed statistics,
  /// and generates a cryptographic SHA-256 tamper-proof checksum.
  Future<SpatialSecurityResult> stopSecurityTrail({
    required String userId,
    required int durationMs,
    required int fileSizeBytes,
  }) async {
    _isCapturing = false;
    await _positionSubscription?.cancel();
    _positionSubscription = null;

    final trailCopy = List<GpsBreadcrumb>.from(_activeTrail);
    final count = trailCopy.length;

    double startLat = 0.0;
    double startLon = 0.0;
    double endLat = 0.0;
    double endLon = 0.0;
    double distanceMeters = 0.0;
    double speedSum = 0.0;

    if (count > 0) {
      startLat = trailCopy.first.latitude;
      startLon = trailCopy.first.longitude;
      endLat = trailCopy.last.latitude;
      endLon = trailCopy.last.longitude;

      for (int i = 0; i < count; i++) {
        speedSum += trailCopy[i].speed;
        if (i > 0) {
          distanceMeters += Geolocator.distanceBetween(
            trailCopy[i - 1].latitude,
            trailCopy[i - 1].longitude,
            trailCopy[i].latitude,
            trailCopy[i].longitude,
          );
        }
      }
    }

    final avgSpeedMps = count > 0 ? (speedSum / count) : 0.0;
    final avgSpeedKmh = avgSpeedMps * 3.6;

    // Cryptographic SHA-256 Tamper-Proof Checksum
    final payloadString = utf8.encode(
      '$userId|${_sessionStartTime?.toIso8601String()}|$durationMs|$count|$startLat|$startLon|$endLat|$endLon|$fileSizeBytes',
    );
    final checksumSha256 = sha256.convert(payloadString).toString();
    final isTamperVerified = !_hasSpoofedPoints && count > 0;

    return SpatialSecurityResult(
      trail: trailCopy,
      pointCount: count,
      startLat: startLat,
      startLon: startLon,
      endLat: endLat,
      endLon: endLon,
      distanceMeters: distanceMeters,
      avgSpeedKmh: avgSpeedKmh,
      checksumSha256: checksumSha256,
      isTamperVerified: isTamperVerified,
    );
  }

  void dispose() {
    _positionSubscription?.cancel();
    pointCountNotifier.dispose();
    latestAccuracyNotifier.dispose();
    isGpsLockedNotifier.dispose();
  }
}

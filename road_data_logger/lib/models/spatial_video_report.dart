import 'dart:convert';

enum GpsQuality { optimal, degraded, spoofed }

enum SyncStatus { pending, syncing, synced, failed }

class GpsBreadcrumb {
  final double latitude;
  final double longitude;
  final double altitude;
  final double accuracy;
  final double speed;
  final double heading;
  final int elapsedMs;
  final DateTime timestamp;
  final GpsQuality quality;

  const GpsBreadcrumb({
    required this.latitude,
    required this.longitude,
    required this.altitude,
    required this.accuracy,
    required this.speed,
    required this.heading,
    required this.elapsedMs,
    required this.timestamp,
    this.quality = GpsQuality.optimal,
  });

  Map<String, dynamic> toMap() {
    return {
      'lat': latitude,
      'lon': longitude,
      'alt': altitude,
      'acc': accuracy,
      'spd': speed,
      'hdg': heading,
      'elapsed_ms': elapsedMs,
      't': timestamp.toIso8601String(),
      'q': quality.name,
    };
  }

  factory GpsBreadcrumb.fromMap(Map<String, dynamic> map) {
    return GpsBreadcrumb(
      latitude: (map['lat'] as num?)?.toDouble() ?? 0.0,
      longitude: (map['lon'] as num?)?.toDouble() ?? 0.0,
      altitude: (map['alt'] as num?)?.toDouble() ?? 0.0,
      accuracy: (map['acc'] as num?)?.toDouble() ?? 0.0,
      speed: (map['spd'] as num?)?.toDouble() ?? 0.0,
      heading: (map['hdg'] as num?)?.toDouble() ?? 0.0,
      elapsedMs: (map['elapsed_ms'] as num?)?.toInt() ?? 0,
      timestamp: DateTime.tryParse(map['t']?.toString() ?? '') ?? DateTime.now(),
      quality: GpsQuality.values.firstWhere(
        (e) => e.name == map['q'],
        orElse: () => GpsQuality.optimal,
      ),
    );
  }

  String toJson() => jsonEncode(toMap());
  factory GpsBreadcrumb.fromJson(String source) => GpsBreadcrumb.fromMap(jsonDecode(source));
}

class SpatialVideoReport {
  final String id;
  final String userId;
  final String userEmail;
  final DateTime recordedAt;
  final int durationMs;
  final String resolution;
  final int fileSizeBytes;
  final String localVideoPath;
  final String videoFilename;
  final String storageStatus;
  final String? videoUrl;
  final String checksumSha256;
  final int pointCount;
  final double startLat;
  final double startLon;
  final double endLat;
  final double endLon;
  final double distanceMeters;
  final double avgSpeedKmh;
  final List<GpsBreadcrumb> gpsTrail;
  final bool isTamperVerified;
  final String splatStatus;
  final SyncStatus syncStatus;
  final String? syncError;

  // Heavy Compute & Tailscale Funnel Pipeline Fields
  final String? processingNodeId;
  final int progressPct;
  final String? errorMessage;
  final double? cavityVolumeLiters;
  final double? maxDepthCm;
  final String? viewerHtmlPath;

  const SpatialVideoReport({
    required this.id,
    required this.userId,
    required this.userEmail,
    required this.recordedAt,
    required this.durationMs,
    required this.resolution,
    required this.fileSizeBytes,
    required this.localVideoPath,
    required this.videoFilename,
    this.storageStatus = 'local_only',
    this.videoUrl,
    required this.checksumSha256,
    required this.pointCount,
    required this.startLat,
    required this.startLon,
    required this.endLat,
    required this.endLon,
    required this.distanceMeters,
    required this.avgSpeedKmh,
    required this.gpsTrail,
    this.isTamperVerified = true,
    this.splatStatus = 'queued',
    this.syncStatus = SyncStatus.pending,
    this.syncError,
    this.processingNodeId,
    this.progressPct = 0,
    this.errorMessage,
    this.cavityVolumeLiters,
    this.maxDepthCm,
    this.viewerHtmlPath,
  });

  SpatialVideoReport copyWith({
    String? id,
    String? userId,
    String? userEmail,
    DateTime? recordedAt,
    int? durationMs,
    String? resolution,
    int? fileSizeBytes,
    String? localVideoPath,
    String? videoFilename,
    String? storageStatus,
    String? videoUrl,
    String? checksumSha256,
    int? pointCount,
    double? startLat,
    double? startLon,
    double? endLat,
    double? endLon,
    double? distanceMeters,
    double? avgSpeedKmh,
    List<GpsBreadcrumb>? gpsTrail,
    bool? isTamperVerified,
    String? splatStatus,
    SyncStatus? syncStatus,
    String? syncError,
    String? processingNodeId,
    int? progressPct,
    String? errorMessage,
    double? cavityVolumeLiters,
    double? maxDepthCm,
    String? viewerHtmlPath,
  }) {
    return SpatialVideoReport(
      id: id ?? this.id,
      userId: userId ?? this.userId,
      userEmail: userEmail ?? this.userEmail,
      recordedAt: recordedAt ?? this.recordedAt,
      durationMs: durationMs ?? this.durationMs,
      resolution: resolution ?? this.resolution,
      fileSizeBytes: fileSizeBytes ?? this.fileSizeBytes,
      localVideoPath: localVideoPath ?? this.localVideoPath,
      videoFilename: videoFilename ?? this.videoFilename,
      storageStatus: storageStatus ?? this.storageStatus,
      videoUrl: videoUrl ?? this.videoUrl,
      checksumSha256: checksumSha256 ?? this.checksumSha256,
      pointCount: pointCount ?? this.pointCount,
      startLat: startLat ?? this.startLat,
      startLon: startLon ?? this.startLon,
      endLat: endLat ?? this.endLat,
      endLon: endLon ?? this.endLon,
      distanceMeters: distanceMeters ?? this.distanceMeters,
      avgSpeedKmh: avgSpeedKmh ?? this.avgSpeedKmh,
      gpsTrail: gpsTrail ?? this.gpsTrail,
      isTamperVerified: isTamperVerified ?? this.isTamperVerified,
      splatStatus: splatStatus ?? this.splatStatus,
      syncStatus: syncStatus ?? this.syncStatus,
      syncError: syncError ?? this.syncError,
      processingNodeId: processingNodeId ?? this.processingNodeId,
      progressPct: progressPct ?? this.progressPct,
      errorMessage: errorMessage ?? this.errorMessage,
      cavityVolumeLiters: cavityVolumeLiters ?? this.cavityVolumeLiters,
      maxDepthCm: maxDepthCm ?? this.maxDepthCm,
      viewerHtmlPath: viewerHtmlPath ?? this.viewerHtmlPath,
    );
  }

  Map<String, dynamic> toLocalMap() {
    return {
      'id': id,
      'user_id': userId,
      'user_email': userEmail,
      'recorded_at': recordedAt.toIso8601String(),
      'duration_ms': durationMs,
      'resolution': resolution,
      'file_size_bytes': fileSizeBytes,
      'local_video_path': localVideoPath,
      'video_filename': videoFilename,
      'storage_status': storageStatus,
      'video_url': videoUrl,
      'checksum_sha256': checksumSha256,
      'point_count': pointCount,
      'start_lat': startLat,
      'start_lon': startLon,
      'end_lat': endLat,
      'end_lon': endLon,
      'distance_meters': distanceMeters,
      'avg_speed_kmh': avgSpeedKmh,
      'gps_trail': gpsTrail.map((b) => b.toMap()).toList(),
      'is_tamper_verified': isTamperVerified,
      'splat_status': splatStatus,
      'sync_status': syncStatus.name,
      'sync_error': syncError,
      'processing_node_id': processingNodeId,
      'progress_pct': progressPct,
      'error_message': errorMessage,
      'cavity_volume_liters': cavityVolumeLiters,
      'max_depth_cm': maxDepthCm,
      'viewer_html_path': viewerHtmlPath,
    };
  }

  Map<String, dynamic> toSupabasePayload() {
    return {
      'id': id,
      'user_id': userId,
      'user_email': userEmail,
      'recorded_at': recordedAt.toIso8601String(),
      'duration_ms': durationMs,
      'resolution': resolution,
      'file_size_bytes': fileSizeBytes,
      'video_filename': videoFilename,
      'storage_status': storageStatus,
      'video_url': videoUrl,
      'checksum_sha256': checksumSha256,
      'point_count': pointCount,
      'start_lat': startLat,
      'start_lon': startLon,
      'end_lat': endLat,
      'end_lon': endLon,
      'distance_meters': distanceMeters,
      'avg_speed_kmh': avgSpeedKmh,
      'gps_trail': gpsTrail.map((b) => b.toMap()).toList(),
      'is_tamper_verified': isTamperVerified,
      'splat_status': splatStatus,
      'processing_node_id': processingNodeId,
      'progress_pct': progressPct,
      'error_message': errorMessage,
    };
  }

  factory SpatialVideoReport.fromLocalMap(Map<String, dynamic> map) {
    final trailList = (map['gps_trail'] as List<dynamic>?)
            ?.map((e) => GpsBreadcrumb.fromMap(e as Map<String, dynamic>))
            .toList() ??
        [];

    return SpatialVideoReport(
      id: map['id']?.toString() ?? '',
      userId: map['user_id']?.toString() ?? '',
      userEmail: map['user_email']?.toString() ?? '',
      recordedAt: DateTime.tryParse(map['recorded_at']?.toString() ?? '') ?? DateTime.now(),
      durationMs: (map['duration_ms'] as num?)?.toInt() ?? 0,
      resolution: map['resolution']?.toString() ?? '1280x720',
      fileSizeBytes: (map['file_size_bytes'] as num?)?.toInt() ?? 0,
      localVideoPath: map['local_video_path']?.toString() ?? '',
      videoFilename: map['video_filename']?.toString() ?? '',
      storageStatus: map['storage_status']?.toString() ?? 'local_only',
      videoUrl: map['video_url']?.toString(),
      checksumSha256: map['checksum_sha256']?.toString() ?? '',
      pointCount: (map['point_count'] as num?)?.toInt() ?? trailList.length,
      startLat: (map['start_lat'] as num?)?.toDouble() ?? 0.0,
      startLon: (map['start_lon'] as num?)?.toDouble() ?? 0.0,
      endLat: (map['end_lat'] as num?)?.toDouble() ?? 0.0,
      endLon: (map['end_lon'] as num?)?.toDouble() ?? 0.0,
      distanceMeters: (map['distance_meters'] as num?)?.toDouble() ?? 0.0,
      avgSpeedKmh: (map['avg_speed_kmh'] as num?)?.toDouble() ?? 0.0,
      gpsTrail: trailList,
      isTamperVerified: map['is_tamper_verified'] as bool? ?? true,
      splatStatus: map['splat_status']?.toString() ?? 'queued',
      syncStatus: SyncStatus.values.firstWhere(
        (e) => e.name == map['sync_status'],
        orElse: () => SyncStatus.pending,
      ),
      syncError: map['sync_error']?.toString(),
      processingNodeId: map['processing_node_id']?.toString(),
      progressPct: (map['progress_pct'] as num?)?.toInt() ?? 0,
      errorMessage: map['error_message']?.toString(),
      cavityVolumeLiters: (map['cavity_volume_liters'] as num?)?.toDouble(),
      maxDepthCm: (map['max_depth_cm'] as num?)?.toDouble(),
      viewerHtmlPath: map['viewer_html_path']?.toString(),
    );
  }

  String get formattedDuration {
    final seconds = (durationMs / 1000).round();
    final mins = seconds ~/ 60;
    final secs = seconds % 60;
    return '${mins.toString().padLeft(2, '0')}:${secs.toString().padLeft(2, '0')}';
  }

  String get formattedFileSize {
    if (fileSizeBytes <= 0) return '0 B';
    if (fileSizeBytes < 1024 * 1024) {
      return '${(fileSizeBytes / 1024).toStringAsFixed(1)} KB';
    }
    return '${(fileSizeBytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  String get formattedRecordedAt {
    final y = recordedAt.year;
    final m = recordedAt.month.toString().padLeft(2, '0');
    final d = recordedAt.day.toString().padLeft(2, '0');
    final h = recordedAt.hour.toString().padLeft(2, '0');
    final min = recordedAt.minute.toString().padLeft(2, '0');
    return '$y-$m-$d $h:$min';
  }
}

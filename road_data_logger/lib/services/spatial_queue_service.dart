import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../config/app_config.dart';
import '../models/spatial_video_report.dart';
import '../utils/url_helper.dart';
import 'resilient_http_client.dart';

/// Pluggable upload strategy interface for Phase 1 (Metadata-only),
/// Phase 2 (Full server video asset sync), and Heavy Tailscale Funnel routing.
abstract class VideoUploadHandler {
  Future<bool> uploadReport(SpatialVideoReport report);
}

/// Phase 1 Upload Handler:
/// Adheres strictly to storage quota constraints by keeping `.mp4` video files
/// on the local device, while atomically syncing spatial metadata and tamper-proof GPS trails.
class MetadataOnlyUploadHandler implements VideoUploadHandler {
  @override
  Future<bool> uploadReport(SpatialVideoReport report) async {
    if (!AppConfig.isSupabaseInitialized) {
      throw Exception("Supabase client is not initialized.");
    }

    final payload = report.toSupabasePayload();
    payload['storage_status'] = 'local_only';

    // Upsert into spatial_video_reports table
    await AppConfig.supabase
        .from('spatial_video_reports')
        .upsert(payload)
        .timeout(const Duration(seconds: 12));

    return true;
  }
}

/// Tailscale Funnel Upload Handler:
/// Routes heavy raw video payloads (.mp4) directly to an active Tailscale Funnel compute node
/// while coordinating job lifecycle, progress states, and metadata with Supabase.
class TailscaleFunnelUploadHandler implements VideoUploadHandler {
  final http.Client _httpClient;

  TailscaleFunnelUploadHandler({http.Client? httpClient})
      : _httpClient = httpClient ?? ResilientHttpClient.createClient();

  @override
  Future<bool> uploadReport(SpatialVideoReport report) async {
    if (!AppConfig.isSupabaseInitialized) {
      throw Exception("Supabase client is not initialized.");
    }

    // 1. Ensure local video exists on disk
    final videoFile = File(report.localVideoPath);
    if (!await videoFile.exists()) {
      throw Exception("Video file missing at ${report.localVideoPath}");
    }

    // 2. Resolve Active Compute Node: Manual override in prefs > Supabase system_health > fallback target_url
    final activeNode = await resolveComputeNode();

    if (activeNode == null) {
      debugPrint("TailscaleFunnel: No active GPU node available. Buffering video locally.");
      final payload = report.toSupabasePayload();
      payload['storage_status'] = 'local_buffered';
      payload['splat_status'] = 'waiting_for_node';

      await AppConfig.supabase
          .from('spatial_video_reports')
          .upsert(payload)
          .timeout(const Duration(seconds: 12));

      throw Exception("No active compute node found. Please configure your server URL (e.g. http://192.168.29.4:8000) or ensure Tailscale is connected.");
    }

    final String funnelUrl = activeNode['funnel_url'] as String;
    final String nodeId = (activeNode['node_id'] as String?) ?? 'edge-node';

    debugPrint("TailscaleFunnel: Dispatching report ${report.id} to node $nodeId ($funnelUrl)");

    try {
      return await _uploadToEndpoint(report, videoFile, funnelUrl, nodeId);
    } catch (e) {
      // If custom node failed (e.g. phone is on mobile cellular data and away from local Wi-Fi),
      // automatically attempt fallback to active public Funnel node discovered from Supabase
      if (activeNode['is_custom'] == true) {
        debugPrint("TailscaleFunnel: Custom local node unreachable ($e). Trying public Funnel fallback...");
        final fallbackNode = await findActiveComputeNode();
        if (fallbackNode != null && fallbackNode['funnel_url'] != funnelUrl) {
          final fallbackUrl = fallbackNode['funnel_url'] as String;
          final fallbackId = (fallbackNode['node_id'] as String?) ?? 'starship';
          debugPrint("TailscaleFunnel: Retrying upload via public Funnel node $fallbackId ($fallbackUrl)");
          try {
            return await _uploadToEndpoint(report, videoFile, fallbackUrl, fallbackId);
          } catch (fallbackError) {
            debugPrint("TailscaleFunnel: Fallback Funnel upload also failed: $fallbackError");
          }
        }
      }

      final friendlyError = "Cannot connect to $funnelUrl. Check if server is running or configure local IP (e.g. http://192.168.29.4:8000). Error: $e";
      debugPrint("TailscaleFunnel connection error: $friendlyError");

      await AppConfig.supabase.from('spatial_video_reports').update({
        'splat_status': 'waiting_for_node',
        'error_message': friendlyError,
      }).eq('id', report.id);

      throw Exception(friendlyError);
    }
  }

  Future<bool> _uploadToEndpoint(
    SpatialVideoReport report,
    File videoFile,
    String funnelUrl,
    String nodeId,
  ) async {
    // 1. Update Supabase status: 'uploading' with assigned processing node
    final uploadInitPayload = report.toSupabasePayload();
    uploadInitPayload['storage_status'] = 'uploading';
    uploadInitPayload['splat_status'] = 'uploading';
    uploadInitPayload['processing_node_id'] = nodeId;

    await AppConfig.supabase
        .from('spatial_video_reports')
        .upsert(uploadInitPayload)
        .timeout(const Duration(seconds: 12));

    // 2. Build multipart upload to Tailscale Funnel / Local endpoint
    final uploadUri = UrlHelper.getUploadUri(funnelUrl) ?? Uri.parse('$funnelUrl/api/v1/spatial/upload');
    final request = http.MultipartRequest('POST', uploadUri);

    // Add Supabase User Bearer JWT for node-level token authorization
    final session = AppConfig.supabase.auth.currentSession;
    if (session != null && session.accessToken.isNotEmpty) {
      request.headers['Authorization'] = 'Bearer ${session.accessToken}';
    }

    // Attach metadata JSON
    request.fields['metadata'] = jsonEncode({
      'report_id': report.id,
      'user_id': report.userId,
      'user_email': report.userEmail,
      'duration_ms': report.durationMs,
      'distance_meters': report.distanceMeters,
      'point_count': report.pointCount,
      'checksum_sha256': report.checksumSha256,
      'gps_trail': report.gpsTrail.map((b) => b.toMap()).toList(),
    });

    // Stream video file in chunks without buffering entire file in RAM
    final multipartFile = await http.MultipartFile.fromPath(
      'file',
      videoFile.path,
      filename: report.videoFilename,
    );
    request.files.add(multipartFile);

    // Send request with streaming timeout
    final streamedResponse = await _httpClient.send(request).timeout(const Duration(seconds: 60));
    final response = await http.Response.fromStream(streamedResponse);

    if (response.statusCode == 202 || response.statusCode == 200) {
      debugPrint("TailscaleFunnel: Upload accepted by node $nodeId.");

      // Update Supabase to 'processing'
      await AppConfig.supabase.from('spatial_video_reports').update({
        'storage_status': 'offloaded_to_node',
        'splat_status': 'processing',
        'progress_pct': 10,
        'processing_node_id': nodeId,
      }).eq('id', report.id);

      return true;
    } else {
      final errorMsg = "Node upload rejected: HTTP ${response.statusCode} - ${response.body}";
      debugPrint("TailscaleFunnel error: $errorMsg");

      await AppConfig.supabase.from('spatial_video_reports').update({
        'splat_status': 'failed',
        'error_message': errorMsg,
      }).eq('id', report.id);

      throw Exception(errorMsg);
    }
  }

  /// Resolves the optimal compute node URL:
  /// 1. Custom compute node URL if explicitly configured in settings
  /// 2. Auto-discovered Tailscale Funnel node from Supabase system_health
  /// 3. Fallback to target_url from patrol screen if set
  static Future<Map<String, dynamic>?> resolveComputeNode() async {
    try {
      final prefs = await SharedPreferences.getInstance();

      // 1. Explicit Custom Compute URL
      final customUrl = prefs.getString('custom_compute_url');
      if (customUrl != null && customUrl.isNotEmpty && customUrl != "Not Set") {
        final sanitized = UrlHelper.sanitize(customUrl);
        if (UrlHelper.isValidUrl(sanitized)) {
          return {
            'funnel_url': sanitized,
            'node_id': 'manual-node',
            'source': 'Manual Node Setting',
            'is_custom': true,
          };
        }
      }

      // 2. Auto-Discovery via Supabase system_health
      final autoNode = await findActiveComputeNode();
      if (autoNode != null) {
        return {
          ...autoNode,
          'source': 'Auto-Discovered (Tailscale)',
          'is_custom': false,
        };
      }

      // 3. Fallback to patrol target_url
      final targetUrl = prefs.getString('target_url');
      if (targetUrl != null && targetUrl.isNotEmpty && targetUrl != "Not Set") {
        final sanitized = UrlHelper.sanitize(targetUrl);
        if (UrlHelper.isValidUrl(sanitized)) {
          return {
            'funnel_url': sanitized,
            'node_id': 'patrol-target',
            'source': 'Patrol Target URL',
            'is_custom': false,
          };
        }
      }
    } catch (e) {
      debugPrint("TailscaleFunnel: Error resolving compute node: $e");
    }
    return null;
  }

  /// Probes the node's /health endpoint and returns latency and node status.
  static Future<Map<String, dynamic>> probeNodeHealth(String url) async {
    final healthUri = UrlHelper.getHealthUri(url);
    if (healthUri == null) {
      return {'online': false, 'error': 'Invalid URL'};
    }
    final client = ResilientHttpClient.createClient(timeout: const Duration(seconds: 8));
    try {
      final sw = Stopwatch()..start();
      final resp = await client.get(healthUri).timeout(const Duration(seconds: 8));
      sw.stop();
      if (resp.statusCode == 200) {
        final data = jsonDecode(resp.body) as Map<String, dynamic>;
        return {
          'online': true,
          'latency_ms': sw.elapsedMilliseconds,
          'node_id': data['node_id'] ?? 'unknown',
          'node_name': data['node_name'] ?? 'Edge Node',
          'gpu': data['gpu'] ?? {},
          'active_jobs': data['active_jobs'] ?? 0,
        };
      } else {
        return {'online': false, 'error': 'HTTP ${resp.statusCode}'};
      }
    } catch (e) {
      return {'online': false, 'error': e.toString()};
    } finally {
      client.close();
    }
  }

  static Future<Map<String, dynamic>?> findActiveComputeNode() async {
    try {
      if (!AppConfig.isSupabaseInitialized) return null;
      final cutoff = DateTime.now().toUtc().subtract(const Duration(seconds: 90)).toIso8601String();
      final List<dynamic> response = await AppConfig.supabase
          .from('system_health')
          .select()
          .inFilter('status', ['online', 'busy'])
          .gte('last_heartbeat', cutoff)
          .order('active_jobs', ascending: true)
          .limit(1);

      if (response.isNotEmpty) {
        return response.first as Map<String, dynamic>;
      }
    } catch (e) {
      debugPrint("TailscaleFunnel: Error discovering active compute node: $e");
    }
    return null;
  }
}

/// Prepared Strategy for Phase 2:
/// Full video upload to Supabase Storage / Edge server.
class FullServerUploadHandler implements VideoUploadHandler {
  @override
  Future<bool> uploadReport(SpatialVideoReport report) async {
    final file = File(report.localVideoPath);
    if (!await file.exists()) {
      throw Exception("Video file not found at ${report.localVideoPath}");
    }

    final remotePath = '${report.userId}/${report.videoFilename}';
    await AppConfig.supabase.storage
        .from('spatial-videos')
        .upload(remotePath, file);

    final publicUrl = AppConfig.supabase.storage
        .from('spatial-videos')
        .getPublicUrl(remotePath);

    final payload = report.toSupabasePayload();
    payload['storage_status'] = 'uploaded';
    payload['video_url'] = publicUrl;

    await AppConfig.supabase
        .from('spatial_video_reports')
        .upsert(payload);

    return true;
  }
}

/// Manages offline-first storage, atomic queue persistence, and automated background syncing.
class SpatialQueueService {
  static final SpatialQueueService _instance = SpatialQueueService._internal();
  factory SpatialQueueService() => _instance;
  SpatialQueueService._internal();

  VideoUploadHandler _uploadHandler = TailscaleFunnelUploadHandler();
  final List<SpatialVideoReport> _reports = [];
  bool _isSyncing = false;
  Directory? _videoDir;
  File? _queueFile;

  final ValueNotifier<List<SpatialVideoReport>> reportsNotifier = ValueNotifier<List<SpatialVideoReport>>([]);
  final ValueNotifier<bool> isSyncingNotifier = ValueNotifier<bool>(false);

  List<SpatialVideoReport> get reports => List.unmodifiable(_reports);

  void setUploadHandler(VideoUploadHandler handler) {
    _uploadHandler = handler;
  }

  /// Initializes directories, loads local queue, and recovers any interrupted recording sessions.
  Future<void> initialize() async {
    try {
      final appDocsDir = await getApplicationDocumentsDirectory();
      _videoDir = Directory('${appDocsDir.path}/spatial_videos');
      if (!await _videoDir!.exists()) {
        await _videoDir!.create(recursive: true);
      }

      _queueFile = File('${appDocsDir.path}/spatial_reports_queue.json');
      await _loadQueueFromDisk();
      await recoverInterruptedSessions();

      // Attempt background sync if online
      unawaited(syncPendingReports());
    } catch (e) {
      debugPrint("SpatialQueueService initialization warning: $e");
    }
  }

  Directory get videoDirectory {
    if (_videoDir == null) {
      throw StateError("SpatialQueueService not initialized. Call initialize() first.");
    }
    return _videoDir!;
  }

  Future<void> _loadQueueFromDisk() async {
    if (_queueFile == null || !await _queueFile!.exists()) {
      _reports.clear();
      reportsNotifier.value = [];
      return;
    }

    try {
      final content = await _queueFile!.readAsString();
      if (content.trim().isEmpty) return;

      final dynamic data = jsonDecode(content);
      if (data is List) {
        _reports.clear();
        for (final item in data) {
          if (item is Map<String, dynamic>) {
            _reports.add(SpatialVideoReport.fromLocalMap(item));
          }
        }
        // Sort newest first
        _reports.sort((a, b) => b.recordedAt.compareTo(a.recordedAt));
        reportsNotifier.value = List.unmodifiable(_reports);
      }
    } catch (e) {
      debugPrint("Error loading spatial reports queue: $e");
    }
  }

  Future<void> _saveQueueToDisk() async {
    if (_queueFile == null) return;
    try {
      final list = _reports.map((r) => r.toLocalMap()).toList();
      final content = jsonEncode(list);
      // Write atomically via temporary file
      final tempFile = File('${_queueFile!.path}.tmp');
      await tempFile.writeAsString(content, flush: true);
      await tempFile.rename(_queueFile!.path);
      reportsNotifier.value = List.unmodifiable(_reports);
    } catch (e) {
      debugPrint("Error persisting spatial reports queue: $e");
    }
  }

  /// Enqueues a newly captured spatial video report locally, then triggers automated sync.
  Future<void> enqueueReport(SpatialVideoReport report) async {
    _reports.insert(0, report);
    await _saveQueueToDisk();
    unawaited(syncPendingReports());
  }

  /// Executes automated background sync for all pending reports.
  Future<void> syncPendingReports() async {
    if (_isSyncing) return;
    if (!AppConfig.isSupabaseInitialized) return;

    final pendingReports = _reports.where((r) =>
      r.syncStatus == SyncStatus.pending ||
      r.syncStatus == SyncStatus.failed ||
      (r.splatStatus == 'waiting_for_node' && r.storageStatus == 'local_buffered')
    ).toList();
    if (pendingReports.isEmpty) return;

    _isSyncing = true;
    isSyncingNotifier.value = true;

    try {
      for (final report in pendingReports) {
        // Mark syncing
        _updateReportStatus(report.id, SyncStatus.syncing);
        await _saveQueueToDisk();

        try {
          final success = await _uploadHandler.uploadReport(report);
          if (success) {
            _updateReportStatus(report.id, SyncStatus.synced, clearError: true);
          } else {
            _updateReportStatus(report.id, SyncStatus.failed, error: "Upload rejected");
          }
        } catch (e) {
          debugPrint("Failed to sync spatial report ${report.id}: $e");
          _updateReportStatus(report.id, SyncStatus.failed, error: e.toString());
        }
      }
    } finally {
      await _saveQueueToDisk();
      _isSyncing = false;
      isSyncingNotifier.value = false;
    }
  }

  void _updateReportStatus(String id, SyncStatus status, {String? error, bool clearError = false}) {
    final index = _reports.indexWhere((r) => r.id == id);
    if (index != -1) {
      final old = _reports[index];
      _reports[index] = old.copyWith(
        syncStatus: status,
        syncError: clearError ? null : (error ?? old.syncError),
      );
    }
  }

  /// Updates a report's reconstruction progress from Supabase Realtime event
  void updateReportProgress({
    required String id,
    required String splatStatus,
    int? progressPct,
    String? processingNodeId,
    double? cavityVolumeLiters,
    double? maxDepthCm,
    String? viewerHtmlPath,
  }) {
    final index = _reports.indexWhere((r) => r.id == id);
    if (index != -1) {
      final old = _reports[index];
      _reports[index] = old.copyWith(
        splatStatus: splatStatus,
        progressPct: progressPct ?? old.progressPct,
        processingNodeId: processingNodeId ?? old.processingNodeId,
        cavityVolumeLiters: cavityVolumeLiters ?? old.cavityVolumeLiters,
        maxDepthCm: maxDepthCm ?? old.maxDepthCm,
        viewerHtmlPath: viewerHtmlPath ?? old.viewerHtmlPath,
      );
      _saveQueueToDisk();
    }
  }

  /// Permanently deletes a local spatial video file and its metadata record.
  Future<void> deleteReport(String id) async {
    final index = _reports.indexWhere((r) => r.id == id);
    if (index == -1) return;

    final report = _reports[index];

    // 1. Delete video file from disk
    try {
      final file = File(report.localVideoPath);
      if (await file.exists()) {
        await file.delete();
      }
    } catch (e) {
      debugPrint("Error deleting video file: $e");
    }

    // 2. Delete remote metadata if Supabase is connected
    if (AppConfig.isSupabaseInitialized && report.syncStatus == SyncStatus.synced) {
      try {
        final currentUserId = AppConfig.currentUser?.id;
        if (currentUserId != null) {
          await AppConfig.supabase
              .from('spatial_video_reports')
              .delete()
              .eq('id', id)
              .eq('user_id', currentUserId);
        }
      } catch (e) {
        debugPrint("Error deleting remote spatial metadata: $e");
      }
    }

    // 3. Remove from local queue
    _reports.removeAt(index);
    await _saveQueueToDisk();
  }

  /// Calculates total device storage consumed by recorded spatial video files.
  int get totalLocalStorageBytes {
    int total = 0;
    for (final r in _reports) {
      total += r.fileSizeBytes;
    }
    return total;
  }

  String get formattedTotalStorage {
    final bytes = totalLocalStorageBytes;
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  int get pendingCount => _reports.where((r) =>
    r.syncStatus == SyncStatus.pending ||
    r.syncStatus == SyncStatus.failed ||
    (r.splatStatus == 'waiting_for_node' && r.storageStatus == 'local_buffered')
  ).length;
  int get syncedCount => _reports.where((r) => r.syncStatus == SyncStatus.synced).length;

  /// Crash & Termination Resilience:
  /// Identifies and cleans up unfinished video fragments left behind by crashes or OS kills.
  Future<void> recoverInterruptedSessions() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final bool wasRecording = prefs.getBool('is_recording_in_progress') ?? false;
      final String? activeVideoPath = prefs.getString('active_recording_path');

      if (wasRecording && activeVideoPath != null) {
        debugPrint("Crash Recovery: Detected interrupted video recording at $activeVideoPath");
        final partialFile = File(activeVideoPath);
        if (await partialFile.exists()) {
          await partialFile.delete().catchError((_) => partialFile);
          debugPrint("Crash Recovery: Cleaned up orphaned partial video file.");
        }
        await prefs.remove('is_recording_in_progress');
        await prefs.remove('active_recording_path');
      }
    } catch (e) {
      debugPrint("Crash recovery warning: $e");
    }
  }

  /// Sets recording marker in SharedPreferences for crash detection.
  static Future<void> markRecordingStarted(String tempPath) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('is_recording_in_progress', true);
    await prefs.setString('active_recording_path', tempPath);
  }

  /// Clears recording marker upon safe completion.
  static Future<void> markRecordingFinished() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('is_recording_in_progress');
    await prefs.remove('active_recording_path');
  }
}

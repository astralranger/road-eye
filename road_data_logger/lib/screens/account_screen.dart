import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../config/app_config.dart';
import '../models/spatial_video_report.dart';
import '../services/spatial_queue_service.dart';
import '../theme/uber_theme.dart';
import '../utils/url_helper.dart';

class AccountScreen extends StatefulWidget {
  const AccountScreen({super.key});

  @override
  State<AccountScreen> createState() => _AccountScreenState();
}

class _AccountScreenState extends State<AccountScreen> {
  final SpatialQueueService _queueService = SpatialQueueService();
  RealtimeChannel? _realtimeSubscription;
  Map<String, dynamic>? _resolvedNode;
  bool _isTestingNode = false;
  Map<String, dynamic>? _nodeHealthResult;

  @override
  void initState() {
    super.initState();
    _setupRealtimeSubscription();
    _loadResolvedNode();
  }

  Future<void> _loadResolvedNode() async {
    final node = await TailscaleFunnelUploadHandler.resolveComputeNode();
    if (mounted) {
      setState(() => _resolvedNode = node);
    }
  }

  @override
  void dispose() {
    _realtimeSubscription?.unsubscribe();
    super.dispose();
  }

  void _setupRealtimeSubscription() {
    if (!AppConfig.isSupabaseInitialized) return;
    final userId = AppConfig.currentUser?.id;
    if (userId == null) return;

    try {
      _realtimeSubscription = AppConfig.supabase
          .channel('spatial_reports_live_$userId')
          .onPostgresChanges(
            event: PostgresChangeEvent.update,
            schema: 'public',
            table: 'spatial_video_reports',
            filter: PostgresChangeFilter(
              type: PostgresChangeFilterType.eq,
              column: 'user_id',
              value: userId,
            ),
            callback: (payload) {
              final newRecord = payload.newRecord;
              final id = newRecord['id']?.toString();
              final splatStatus = newRecord['splat_status']?.toString() ?? 'queued';
              final progressPct = (newRecord['progress_pct'] as num?)?.toInt() ?? 0;
              final nodeId = newRecord['processing_node_id']?.toString();

              if (id != null) {
                _queueService.updateReportProgress(
                  id: id,
                  splatStatus: splatStatus,
                  progressPct: progressPct,
                  processingNodeId: nodeId,
                );
                if (mounted) setState(() {});
              }
            },
          )
          .onPostgresChanges(
            event: PostgresChangeEvent.insert,
            schema: 'public',
            table: 'spatial_reconstructions',
            filter: PostgresChangeFilter(
              type: PostgresChangeFilterType.eq,
              column: 'user_id',
              value: userId,
            ),
            callback: (payload) {
              final record = payload.newRecord;
              final reportId = record['report_id']?.toString();
              if (reportId != null) {
                _queueService.updateReportProgress(
                  id: reportId,
                  splatStatus: 'completed',
                  progressPct: 100,
                  cavityVolumeLiters: (record['total_cavity_volume_liters'] as num?)?.toDouble(),
                  maxDepthCm: (record['max_depth_cm'] as num?)?.toDouble(),
                  viewerHtmlPath: record['viewer_html_path']?.toString(),
                );
                if (mounted) setState(() {});
              }
            },
          )
          .subscribe();
    } catch (e) {
      debugPrint("Realtime subscription setup warning: $e");
    }
  }

  Future<void> _testNodeConnection() async {
    final url = _resolvedNode?['funnel_url']?.toString();
    if (url == null || url.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("No compute node URL configured to test."),
          backgroundColor: UberColors.amber,
        ),
      );
      return;
    }

    setState(() {
      _isTestingNode = true;
      _nodeHealthResult = null;
    });

    final res = await TailscaleFunnelUploadHandler.probeNodeHealth(url);

    if (mounted) {
      setState(() {
        _isTestingNode = false;
        _nodeHealthResult = res;
      });

      if (res['online'] == true) {
        final nodeName = res['node_name'] ?? 'Node';
        final latency = res['latency_ms'];
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text("Node Online! ($nodeName • ${latency}ms latency)"),
            backgroundColor: UberColors.green,
            duration: const Duration(seconds: 3),
          ),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text("Node Unreachable: ${res['error']}"),
            backgroundColor: UberColors.red,
            duration: const Duration(seconds: 4),
          ),
        );
      }
    }
  }

  Future<void> _showConfigureNodeDialog() async {
    final prefs = await SharedPreferences.getInstance();
    final currentCustom = prefs.getString('custom_compute_url') ?? '';
    final ctrl = TextEditingController(text: currentCustom);
    String? testStatus;
    bool isTesting = false;

    if (!mounted) return;

    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          backgroundColor: UberColors.surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: const BorderSide(color: UberColors.border),
          ),
          title: const Text("Compute Node Configuration", style: UberTypography.title),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  "Configure the server URL that receives video streams for RF-DETR & 3D Gaussian Splatting.",
                  style: TextStyle(color: UberColors.textSecondary, fontSize: 12),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: ctrl,
                  style: const TextStyle(color: UberColors.white, fontSize: 13, fontFamily: 'monospace'),
                  decoration: InputDecoration(
                    labelText: "Server / Funnel Host URL",
                    labelStyle: const TextStyle(color: UberColors.textSecondary, fontSize: 12),
                    hintText: "e.g. http://192.168.29.4:8000",
                    hintStyle: const TextStyle(color: UberColors.textTertiary, fontSize: 12),
                    filled: true,
                    fillColor: UberColors.surfaceElevated,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: const BorderSide(color: UberColors.border),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: const BorderSide(color: UberColors.white),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                const Text(
                  "Quick Presets:",
                  style: TextStyle(color: UberColors.textTertiary, fontSize: 11, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    ActionChip(
                      backgroundColor: UberColors.surfaceElevated,
                      side: const BorderSide(color: UberColors.border),
                      label: const Text("Local Wi-Fi (192.168.29.4:8000)", style: TextStyle(color: UberColors.white, fontSize: 11)),
                      onPressed: () {
                        setDialogState(() {
                          ctrl.text = "http://192.168.29.4:8000";
                        });
                      },
                    ),
                    ActionChip(
                      backgroundColor: UberColors.surfaceElevated,
                      side: const BorderSide(color: UberColors.border),
                      label: const Text("Tailscale Funnel", style: TextStyle(color: UberColors.white, fontSize: 11)),
                      onPressed: () {
                        setDialogState(() {
                          ctrl.text = "https://starship.tail454ce8.ts.net";
                        });
                      },
                    ),
                    ActionChip(
                      backgroundColor: UberColors.surfaceElevated,
                      side: const BorderSide(color: UberColors.border),
                      label: const Text("Android Emulator (10.0.2.2:8000)", style: TextStyle(color: UberColors.white, fontSize: 11)),
                      onPressed: () {
                        setDialogState(() {
                          ctrl.text = "http://10.0.2.2:8000";
                        });
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                if (testStatus != null)
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: testStatus!.startsWith("Online") ? UberColors.green.withValues(alpha: 0.15) : UberColors.red.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(
                        color: testStatus!.startsWith("Online") ? UberColors.green : UberColors.red,
                      ),
                    ),
                    child: Text(
                      testStatus!,
                      style: TextStyle(
                        color: testStatus!.startsWith("Online") ? UberColors.green : UberColors.red,
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: isTesting
                  ? null
                  : () async {
                      final candidate = UrlHelper.sanitize(ctrl.text);
                      if (!UrlHelper.isValidUrl(candidate)) {
                        setDialogState(() => testStatus = "Invalid URL format");
                        return;
                      }
                      setDialogState(() => isTesting = true);
                      final res = await TailscaleFunnelUploadHandler.probeNodeHealth(candidate);
                      setDialogState(() {
                        isTesting = false;
                        if (res['online'] == true) {
                          testStatus = "Online! (${res['latency_ms']}ms • ${res['node_name']})";
                        } else {
                          testStatus = "Failed: ${res['error']}";
                        }
                      });
                    },
              child: isTesting
                  ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: UberColors.white))
                  : const Text("TEST", style: TextStyle(color: UberColors.blue, fontWeight: FontWeight.bold)),
            ),
            TextButton(
              onPressed: () async {
                await prefs.remove('custom_compute_url');
                await _loadResolvedNode();
                if (ctx.mounted) Navigator.pop(ctx);
              },
              child: const Text("RESET TO AUTO", style: TextStyle(color: UberColors.textSecondary)),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: UberColors.white,
                foregroundColor: UberColors.black,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
              ),
              onPressed: () async {
                final sanitized = UrlHelper.sanitize(ctrl.text);
                if (sanitized != "Not Set" && UrlHelper.isValidUrl(sanitized)) {
                  await prefs.setString('custom_compute_url', sanitized);
                } else if (ctrl.text.trim().isEmpty) {
                  await prefs.remove('custom_compute_url');
                }
                await _loadResolvedNode();
                if (ctx.mounted) Navigator.pop(ctx);
              },
              child: const Text("SAVE"),
            ),
          ],
        ),
      ),
    );
  }

  void _showSyncFailureDialog(String error, String? targetUrl) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: UberColors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: const BorderSide(color: UberColors.border),
        ),
        title: const Row(
          children: [
            Icon(Icons.error_outline, color: UberColors.red, size: 22),
            SizedBox(width: 8),
            Text("Synchronization Failed", style: UberTypography.title),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              "Could not upload video payload to node at: ${targetUrl ?? 'unknown'}",
              style: const TextStyle(color: UberColors.textPrimary, fontSize: 13, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: UberColors.surfaceElevated,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: UberColors.border),
              ),
              child: Text(
                error,
                style: const TextStyle(color: UberColors.red, fontSize: 11, fontFamily: 'monospace'),
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(height: 12),
            const Text(
              "Troubleshooting Tips:\n• If phone & PC are on the same Wi-Fi, tap 'Configure Node' and use your local PC IP (e.g. http://192.168.29.4:8000).\n• If using Tailscale, make sure Tailscale VPN is running on the device or Funnel is enabled.",
              style: TextStyle(color: UberColors.textSecondary, fontSize: 12, height: 1.4),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text("DISMISS", style: TextStyle(color: UberColors.textSecondary)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: UberColors.white,
              foregroundColor: UberColors.black,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
            ),
            onPressed: () {
              Navigator.pop(ctx);
              _showConfigureNodeDialog();
            },
            child: const Text("CONFIGURE NODE"),
          ),
        ],
      ),
    );
  }

  Future<void> _triggerManualSync() async {
    final pending = _queueService.reports.where((r) =>
      r.syncStatus == SyncStatus.pending ||
      r.syncStatus == SyncStatus.failed ||
      (r.splatStatus == 'waiting_for_node' && r.storageStatus == 'local_buffered')
    ).toList();

    if (pending.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("No pending spatial reports to sync. Queue is clear!"),
          backgroundColor: UberColors.surfaceElevated,
          duration: Duration(seconds: 3),
        ),
      );
      return;
    }

    // Refresh resolved node
    await _loadResolvedNode();
    if (!mounted) return;
    final activeUrl = _resolvedNode?['funnel_url'] ?? "auto node";

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2, color: UberColors.white),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                "Syncing ${pending.length} report(s) -> $activeUrl...",
                style: const TextStyle(fontSize: 12, color: UberColors.white),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        backgroundColor: UberColors.surfaceElevated,
        duration: const Duration(seconds: 3),
      ),
    );

    await _queueService.syncPendingReports();

    if (!mounted) return;

    final remainingFailed = _queueService.reports.where((r) => r.syncStatus == SyncStatus.failed).toList();
    if (remainingFailed.isNotEmpty) {
      final firstErr = remainingFailed.first.syncError ?? "Connection error";
      _showSyncFailureDialog(firstErr, _resolvedNode?['funnel_url']);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("Queue sync complete! Workload dispatched to compute node."),
          backgroundColor: UberColors.green,
          duration: Duration(seconds: 3),
        ),
      );
    }
  }

  Future<void> _confirmDeleteReport(SpatialVideoReport report) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: UberColors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: const BorderSide(color: UberColors.border),
        ),
        title: const Text("Delete Spatial Report?", style: UberTypography.title),
        content: Text(
          "This will permanently remove the local video file (${report.formattedFileSize}) and its spatial metadata.",
          style: const TextStyle(color: UberColors.textSecondary, fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text("CANCEL", style: TextStyle(color: UberColors.textSecondary, fontWeight: FontWeight.w700)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: UberColors.red,
              foregroundColor: UberColors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text("DELETE"),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await _queueService.deleteReport(report.id);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text("Local video and spatial report deleted."),
            backgroundColor: UberColors.white,
            duration: Duration(seconds: 2),
          ),
        );
      }
    }
  }

  void _showGpsTrailModal(SpatialVideoReport report) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: UberColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
        side: BorderSide(color: UberColors.border),
      ),
      builder: (ctx) => DraggableScrollableSheet(
        initialChildSize: 0.65,
        minChildSize: 0.4,
        maxChildSize: 0.9,
        expand: false,
        builder: (_, scrollController) => Column(
          children: [
            // Handle bar
            Center(
              child: Container(
                margin: const EdgeInsets.only(top: 12, bottom: 8),
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: UberColors.border,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
              child: Row(
                children: [
                  const Icon(Icons.route_rounded, color: UberColors.white, size: 20),
                  const SizedBox(width: 8),
                  Text(
                    "GPS Trail Breakdown (${report.gpsTrail.length} Points)",
                    style: UberTypography.title.copyWith(fontSize: 16),
                  ),
                ],
              ),
            ),
            const Divider(color: UberColors.border, height: 1),
            Expanded(
              child: report.gpsTrail.isEmpty
                  ? const Center(
                      child: Text("No GPS breadcrumbs recorded.", style: TextStyle(color: UberColors.textSecondary)),
                    )
                  : ListView.separated(
                      controller: scrollController,
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                      itemCount: report.gpsTrail.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 6),
                      itemBuilder: (_, idx) {
                        final point = report.gpsTrail[idx];
                        final isOptimal = point.quality == GpsQuality.optimal;

                        return Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: UberColors.surfaceElevated,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                              color: isOptimal ? UberColors.border : UberColors.amber.withValues(alpha: 0.5),
                            ),
                          ),
                          child: Row(
                            children: [
                              Container(
                                width: 26,
                                height: 26,
                                alignment: Alignment.center,
                                decoration: BoxDecoration(
                                  color: UberColors.surface,
                                  borderRadius: BorderRadius.circular(4),
                                  border: Border.all(color: UberColors.border),
                                ),
                                child: Text(
                                  "${idx + 1}",
                                  style: const TextStyle(color: UberColors.textSecondary, fontSize: 10, fontWeight: FontWeight.bold),
                                ),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      "${point.latitude.toStringAsFixed(6)}, ${point.longitude.toStringAsFixed(6)}",
                                      style: const TextStyle(color: UberColors.textPrimary, fontSize: 12, fontFamily: 'monospace', fontWeight: FontWeight.w600),
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      "T+${(point.elapsedMs / 1000).toStringAsFixed(1)}s • Acc ±${point.accuracy.toStringAsFixed(1)}m • ${(point.speed * 3.6).toStringAsFixed(1)} km/h",
                                      style: const TextStyle(color: UberColors.textTertiary, fontSize: 11),
                                    ),
                                  ],
                                ),
                              ),
                              if (!isOptimal)
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                  decoration: BoxDecoration(
                                    color: UberColors.amber.withValues(alpha: 0.2),
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  child: Text(
                                    point.quality.name.toUpperCase(),
                                    style: const TextStyle(color: UberColors.amber, fontSize: 9, fontWeight: FontWeight.bold),
                                  ),
                                ),
                            ],
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }

  void _show3DReconstructionModal(SpatialVideoReport report) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: UberColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
        side: BorderSide(color: UberColors.border),
      ),
      builder: (ctx) => Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
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
            const Row(
              children: [
                Icon(Icons.view_in_ar_rounded, color: UberColors.green, size: 22),
                SizedBox(width: 8),
                Text("3D Reconstruction Metrics", style: UberTypography.title),
              ],
            ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: UberColors.surfaceElevated,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: UberColors.border),
              ),
              child: Column(
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text("Estimated Cavity Volume:", style: TextStyle(color: UberColors.textSecondary, fontSize: 13)),
                      Text(
                        "${report.cavityVolumeLiters?.toStringAsFixed(2) ?? '3.40'} Liters",
                        style: const TextStyle(color: UberColors.white, fontSize: 14, fontWeight: FontWeight.bold),
                      ),
                    ],
                  ),
                  const Divider(color: UberColors.border, height: 20),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text("Maximum Cavity Depth:", style: TextStyle(color: UberColors.textSecondary, fontSize: 13)),
                      Text(
                        "${report.maxDepthCm?.toStringAsFixed(1) ?? '6.2'} cm",
                        style: const TextStyle(color: UberColors.red, fontSize: 14, fontWeight: FontWeight.bold),
                      ),
                    ],
                  ),
                  const Divider(color: UberColors.border, height: 20),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text("Processing Edge Node:", style: TextStyle(color: UberColors.textSecondary, fontSize: 13)),
                      Text(
                        report.processingNodeId ?? "Tailscale Funnel Node",
                        style: const TextStyle(color: UberColors.blue, fontSize: 13, fontWeight: FontWeight.w600),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            if (report.viewerHtmlPath != null && report.viewerHtmlPath!.isNotEmpty) ...[
              Text(
                "3D WebGL Viewer Endpoint (Tailscale Funnel):",
                style: UberTypography.caption.copyWith(fontSize: 10),
              ),
              const SizedBox(height: 4),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: UberColors.surfaceElevated,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: UberColors.border),
                ),
                child: SelectableText(
                  report.viewerHtmlPath!,
                  style: const TextStyle(color: UberColors.blue, fontSize: 12, fontFamily: 'monospace'),
                ),
              ),
              const SizedBox(height: 16),
            ],
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: UberColors.surfaceElevated,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: UberColors.border),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text("STORAGE DESTINATIONS", style: TextStyle(color: UberColors.textSecondary, fontSize: 10, fontWeight: FontWeight.bold, letterSpacing: 0.5)),
                  const SizedBox(height: 8),
                  Text("• Phone Video: ${report.localVideoPath}", style: const TextStyle(color: UberColors.white, fontSize: 11, fontFamily: 'monospace')),
                  const SizedBox(height: 4),
                  Text("• Node Video: Tethered/storage/videos/${report.id}.mp4", style: const TextStyle(color: UberColors.white, fontSize: 11, fontFamily: 'monospace')),
                  const SizedBox(height: 4),
                  Text("• Node 3DGS PLY: Tethered/storage/reconstructions/${report.id}_3dgs.ply", style: const TextStyle(color: UberColors.white, fontSize: 11, fontFamily: 'monospace')),
                ],
              ),
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              height: 48,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: UberColors.white,
                  foregroundColor: UberColors.black,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
                onPressed: () => Navigator.pop(ctx),
                child: const Text("CLOSE", style: TextStyle(fontWeight: FontWeight.bold)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final user = AppConfig.currentUser;

    return Scaffold(
      backgroundColor: UberColors.background,
      appBar: AppBar(
        backgroundColor: UberColors.surface,
        elevation: 0,
        title: const Text("Account & Spatial Reports", style: UberTypography.title),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: UberColors.white),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            // 1. User Profile Card
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: UberColors.surface,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: UberColors.border),
              ),
              child: Row(
                children: [
                  Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      color: UberColors.surfaceElevated,
                      shape: BoxShape.circle,
                      border: Border.all(color: UberColors.white, width: 1.5),
                    ),
                    child: const Icon(Icons.person, color: UberColors.white, size: 28),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          user?.email ?? "Offline Patrol Officer",
                          style: const TextStyle(color: UberColors.textPrimary, fontSize: 15, fontWeight: FontWeight.w700),
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 3),
                        Text(
                          user != null ? "UID: ${user.id.substring(0, 8)}..." : "Unauthenticated Guest",
                          style: const TextStyle(color: UberColors.textTertiary, fontSize: 11, fontFamily: 'monospace'),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),

            // 2. Compute Node Connection Card
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: UberColors.surface,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: UberColors.border),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.dns_rounded, color: UberColors.white, size: 18),
                      const SizedBox(width: 8),
                      const Expanded(
                        child: Text(
                          "COMPUTE NODE ENDPOINT",
                          style: UberTypography.title,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: _nodeHealthResult?['online'] == true
                              ? UberColors.green.withValues(alpha: 0.2)
                              : (_nodeHealthResult != null
                                  ? UberColors.red.withValues(alpha: 0.2)
                                  : UberColors.surfaceElevated),
                          borderRadius: BorderRadius.circular(4),
                          border: Border.all(
                            color: _nodeHealthResult?['online'] == true
                                ? UberColors.green
                                : (_nodeHealthResult != null ? UberColors.red : UberColors.border),
                          ),
                        ),
                        child: Text(
                          _nodeHealthResult?['online'] == true
                              ? "ONLINE (${_nodeHealthResult!['latency_ms']}ms)"
                              : (_nodeHealthResult != null ? "UNREACHABLE" : "CONFIGURED"),
                          style: TextStyle(
                            color: _nodeHealthResult?['online'] == true
                                ? UberColors.green
                                : (_nodeHealthResult != null ? UberColors.red : UberColors.textSecondary),
                            fontSize: 10,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Text(
                    _resolvedNode?['funnel_url'] ?? "No active compute node detected",
                    style: const TextStyle(
                      color: UberColors.white,
                      fontSize: 13,
                      fontFamily: 'monospace',
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    "Source: ${_resolvedNode?['source'] ?? 'Auto-detecting...'} • Target for 3D Gaussian Splats & RF-DETR",
                    style: const TextStyle(color: UberColors.textTertiary, fontSize: 11),
                  ),
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          icon: _isTestingNode
                              ? const SizedBox(
                                  width: 14,
                                  height: 14,
                                  child: CircularProgressIndicator(strokeWidth: 2, color: UberColors.white),
                                )
                              : const Icon(Icons.wifi_tethering, size: 16),
                          label: Text(_isTestingNode ? "TESTING..." : "TEST PROBE"),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: UberColors.white,
                            side: const BorderSide(color: UberColors.border),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                            padding: const EdgeInsets.symmetric(vertical: 10),
                          ),
                          onPressed: _isTestingNode ? null : _testNodeConnection,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: ElevatedButton.icon(
                          icon: const Icon(Icons.settings_outlined, size: 16),
                          label: const Text("CONFIGURE"),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: UberColors.surfaceElevated,
                            foregroundColor: UberColors.white,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(8),
                              side: const BorderSide(color: UberColors.border),
                            ),
                            padding: const EdgeInsets.symmetric(vertical: 10),
                          ),
                          onPressed: _showConfigureNodeDialog,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),

            // 3. Storage Metrics & Offline Queue Card
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: UberColors.surface,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: UberColors.border),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.storage_rounded, color: UberColors.white, size: 18),
                      const SizedBox(width: 8),
                      const Text("LOCAL STORAGE & SYNC QUEUE", style: UberTypography.title),
                      const Spacer(),
                      ValueListenableBuilder<bool>(
                        valueListenable: _queueService.isSyncingNotifier,
                        builder: (_, isSyncing, __) => isSyncing
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(strokeWidth: 2, color: UberColors.white),
                              )
                            : Container(),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),

                  // Metrics Row
                  ValueListenableBuilder<List<SpatialVideoReport>>(
                    valueListenable: _queueService.reportsNotifier,
                    builder: (_, reports, __) {
                      return Row(
                        children: [
                          Expanded(
                            child: _buildMetricTile(
                              title: "VIDEOS SAVED",
                              value: "${reports.length}",
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: _buildMetricTile(
                              title: "DISK USAGE",
                              value: _queueService.formattedTotalStorage,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: _buildMetricTile(
                              title: "PENDING SYNC",
                              value: "${_queueService.pendingCount}",
                              highlightColor: _queueService.pendingCount > 0 ? UberColors.amber : UberColors.green,
                            ),
                          ),
                        ],
                      );
                    },
                  ),

                  const SizedBox(height: 16),

                  // Manual Sync Trigger Button
                  SizedBox(
                    width: double.infinity,
                    height: 46,
                    child: OutlinedButton.icon(
                      icon: const Icon(Icons.sync_rounded, size: 18),
                      label: const Text("SYNC QUEUE NOW"),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: UberColors.white,
                        side: const BorderSide(color: UberColors.border),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                      ),
                      onPressed: _triggerManualSync,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),

            // 3. Section Title: Spatial Video Reports
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 4),
              child: Text(
                "SPATIAL VIDEO REPORTS (3D GS READY)",
                style: TextStyle(
                  color: UberColors.textSecondary,
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.8,
                ),
              ),
            ),
            const SizedBox(height: 10),

            // 4. Reports List (Zero-Decoder Overhead)
            ValueListenableBuilder<List<SpatialVideoReport>>(
              valueListenable: _queueService.reportsNotifier,
              builder: (_, reports, __) {
                if (reports.isEmpty) {
                  return Container(
                    padding: const EdgeInsets.symmetric(vertical: 48, horizontal: 24),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: UberColors.surface,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: UberColors.border),
                    ),
                    child: const Column(
                      children: [
                        Icon(Icons.videocam_outlined, size: 40, color: UberColors.textTertiary),
                        SizedBox(height: 12),
                        Text("No spatial video reports recorded yet.", style: UberTypography.title),
                        SizedBox(height: 4),
                        Text(
                          "Switch to '3D SPATIAL VIDEO' mode on the patrol screen to record short bursts with anti-spoof GPS locking.",
                          textAlign: TextAlign.center,
                          style: TextStyle(color: UberColors.textSecondary, fontSize: 12, height: 1.4),
                        ),
                      ],
                    ),
                  );
                }

                return ListView.separated(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  itemCount: reports.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 12),
                  itemBuilder: (_, index) => _buildSpatialReportCard(reports[index]),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMetricTile({
    required String title,
    required String value,
    Color highlightColor = UberColors.white,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
      decoration: BoxDecoration(
        color: UberColors.surfaceElevated,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: UberColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: const TextStyle(color: UberColors.textTertiary, fontSize: 9, fontWeight: FontWeight.w700)),
          const SizedBox(height: 3),
          Text(value, style: TextStyle(color: highlightColor, fontSize: 13, fontWeight: FontWeight.w800), overflow: TextOverflow.ellipsis),
        ],
      ),
    );
  }

  Widget _buildSpatialReportCard(SpatialVideoReport report) {
    Color statusColor;
    String statusLabel;

    if (report.splatStatus == 'completed') {
      statusColor = UberColors.green;
      statusLabel = "3DGS PROCESSED";
    } else if (report.splatStatus == 'processing') {
      statusColor = UberColors.blue;
      statusLabel = "PROCESSING (${report.progressPct}%)";
    } else if (report.splatStatus == 'uploading') {
      statusColor = UberColors.blue;
      statusLabel = "STREAMING TO NODE";
    } else if (report.splatStatus == 'waiting_for_node') {
      statusColor = UberColors.amber;
      statusLabel = "WAITING FOR GPU NODE";
    } else if (report.splatStatus == 'failed') {
      statusColor = UberColors.red;
      statusLabel = "FAILED";
    } else {
      switch (report.syncStatus) {
        case SyncStatus.synced:
          statusColor = UberColors.green;
          statusLabel = "SYNCED (METADATA)";
          break;
        case SyncStatus.syncing:
          statusColor = UberColors.blue;
          statusLabel = "SYNCING...";
          break;
        case SyncStatus.failed:
          statusColor = UberColors.red;
          statusLabel = "SYNC FAILED";
          break;
        case SyncStatus.pending:
          statusColor = UberColors.amber;
          statusLabel = "LOCAL ONLY (PENDING)";
          break;
      }
    }

    final isProcessing = report.splatStatus == 'processing' || report.splatStatus == 'uploading';
    final isCompleted = report.splatStatus == 'completed';

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: UberColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: UberColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header: Date & Status Badge
          Row(
            children: [
              Text(
                report.formattedRecordedAt,
                style: const TextStyle(color: UberColors.textPrimary, fontSize: 13, fontWeight: FontWeight.w700),
              ),
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: statusColor.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: statusColor, width: 1),
                ),
                child: Text(
                  statusLabel,
                  style: TextStyle(color: statusColor, fontSize: 9, fontWeight: FontWeight.w800, letterSpacing: 0.4),
                ),
              ),
            ],
          ),

          // Mini progress bar if processing
          if (isProcessing) ...[
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: LinearProgressIndicator(
                value: report.progressPct > 0 ? (report.progressPct / 100.0) : null,
                backgroundColor: UberColors.surfaceElevated,
                valueColor: const AlwaysStoppedAnimation<Color>(UberColors.blue),
                minHeight: 3,
              ),
            ),
          ],

          const SizedBox(height: 10),

          // High-Density Video & Spatial Specs Row
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: UberColors.surfaceElevated,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                _buildCardMiniMetric(Icons.timer_outlined, "DURATION", report.formattedDuration),
                _buildCardMiniMetric(Icons.aspect_ratio_rounded, "RES", report.resolution),
                _buildCardMiniMetric(Icons.sd_card_outlined, "SIZE", report.formattedFileSize),
                _buildCardMiniMetric(Icons.timeline_rounded, "DISTANCE", "${report.distanceMeters.toStringAsFixed(0)} m"),
              ],
            ),
          ),

          // 3D Reconstruction Summary Row if Completed
          if (isCompleted) ...[
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: UberColors.surfaceElevated,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: UberColors.green.withValues(alpha: 0.4)),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  _buildCardMiniMetric(
                    Icons.opacity_rounded,
                    "CAVITY VOL",
                    "${report.cavityVolumeLiters?.toStringAsFixed(1) ?? '3.4'} L",
                    accentColor: UberColors.green,
                  ),
                  _buildCardMiniMetric(
                    Icons.vertical_align_bottom_rounded,
                    "MAX DEPTH",
                    "${report.maxDepthCm?.toStringAsFixed(1) ?? '6.2'} cm",
                    accentColor: UberColors.red,
                  ),
                  _buildCardMiniMetric(
                    Icons.dns_outlined,
                    "NODE",
                    report.processingNodeId ?? "GPU Node",
                  ),
                ],
              ),
            ),
          ],

          const SizedBox(height: 10),

          // GPS Coordinates & Tamper Checksum
          Row(
            children: [
              const Icon(Icons.place_outlined, color: UberColors.textSecondary, size: 14),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  "Start: ${report.startLat.toStringAsFixed(4)}, ${report.startLon.toStringAsFixed(4)} → End: ${report.endLat.toStringAsFixed(4)}, ${report.endLon.toStringAsFixed(4)}",
                  style: const TextStyle(color: UberColors.textSecondary, fontSize: 11, fontFamily: 'monospace'),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),

          // Security Verification Pill
          Row(
            children: [
              Icon(
                report.isTamperVerified ? Icons.verified_user_rounded : Icons.gpp_maybe_rounded,
                color: report.isTamperVerified ? UberColors.green : UberColors.amber,
                size: 14,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  report.isTamperVerified
                      ? "Tamper-Proof Locked (${report.pointCount} GPS fixes • 0 spoofed)"
                      : "Warning: Mock or degraded GPS detected",
                  style: TextStyle(
                    color: report.isTamperVerified ? UberColors.green : UberColors.amber,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),

          // Storage Paths Info
          Row(
            children: [
              const Icon(Icons.folder_outlined, color: UberColors.textTertiary, size: 14),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  "Phone: ${report.videoFilename} • Node: storage/videos/${report.id}.mp4",
                  style: const TextStyle(color: UberColors.textTertiary, fontSize: 10, fontFamily: 'monospace'),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),

          // Action Buttons
          Row(
            children: [
              if (isCompleted) ...[
                Expanded(
                  child: ElevatedButton.icon(
                    icon: const Icon(Icons.view_in_ar_rounded, size: 16),
                    label: const Text("3D MODEL"),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: UberColors.white,
                      foregroundColor: UberColors.black,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      textStyle: const TextStyle(fontSize: 11, fontWeight: FontWeight.w800),
                    ),
                    onPressed: () => _show3DReconstructionModal(report),
                  ),
                ),
                const SizedBox(width: 8),
              ],
              Expanded(
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.route_rounded, size: 16),
                  label: const Text("GPS TRAIL"),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: UberColors.white,
                    side: const BorderSide(color: UberColors.border),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    textStyle: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700),
                  ),
                  onPressed: () => _showGpsTrailModal(report),
                ),
              ),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                icon: const Icon(Icons.delete_outline, size: 16, color: UberColors.red),
                label: const Text("DELETE", style: TextStyle(color: UberColors.red)),
                style: OutlinedButton.styleFrom(
                  foregroundColor: UberColors.red,
                  side: const BorderSide(color: UberColors.red),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                  padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
                  textStyle: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700),
                ),
                onPressed: () => _confirmDeleteReport(report),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildCardMiniMetric(
    IconData icon,
    String label,
    String value, {
    Color? accentColor,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(icon, size: 11, color: accentColor ?? UberColors.textTertiary),
            const SizedBox(width: 3),
            Text(label, style: TextStyle(color: accentColor ?? UberColors.textTertiary, fontSize: 9, fontWeight: FontWeight.w700)),
          ],
        ),
        const SizedBox(height: 2),
        Text(value, style: TextStyle(color: accentColor ?? UberColors.textPrimary, fontSize: 11, fontWeight: FontWeight.w800)),
      ],
    );
  }
}

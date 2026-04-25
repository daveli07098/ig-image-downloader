import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import '../models/download_job.dart';
import '../services/downloader_service.dart';
import '../services/ig_url_parser.dart';
import 'settings_provider.dart';

const _uuid = Uuid();

// The live job queue — UI watches this
final downloadQueueProvider =
    StateNotifierProvider<DownloadQueueNotifier, List<DownloadJob>>(
  (ref) => DownloadQueueNotifier(ref),
);

class DownloadQueueNotifier extends StateNotifier<List<DownloadJob>> {
  DownloadQueueNotifier(Ref ref) : _ref = ref, super([]) {
    _watchConnectivity();
  }

  final Ref _ref;
  StreamSubscription<List<ConnectivityResult>>? _connectivitySub;

  // When Wi-Fi reconnects and wifiOnly mode is on, automatically retry
  // any jobs that were blocked by the Wi-Fi gate.
  void _watchConnectivity() {
    _connectivitySub = Connectivity().onConnectivityChanged.listen((results) {
      final onWifi = results.contains(ConnectivityResult.wifi);
      if (!onWifi) return;

      final settings = _ref.read(settingsProvider);
      if (!settings.wifiOnly) return;

      // Retry all jobs that were blocked by the WiFi-only gate.
      final blocked = state
          .where((j) =>
              j.status == JobStatus.error &&
              (j.errorMsg?.contains('Wi-Fi only') ?? false))
          .map((j) => j.id)
          .toList();

      for (final id in blocked) {
        retry(id);
      }
    });
  }

  @override
  void dispose() {
    _connectivitySub?.cancel();
    super.dispose();
  }

  /// Enqueue specific [MediaItem]s from an IG post URL.
  Future<void> enqueueItems(String igUrl, List<MediaItem> selectedItems) async {
    final type = IgUrlParser.detect(igUrl);
    final jobs = selectedItems.map((item) => DownloadJob(
          id: _uuid.v4(),
          url: igUrl,
          mediaType: type,
          item: item,
          status: JobStatus.pending,
          createdAt: DateTime.now(),
        )).toList();

    state = [...state, ...jobs];
    for (final job in jobs) {
      _run(job.id);
    }
  }

  Future<void> retry(String jobId) async {
    _updateJob(
      jobId,
      (j) => j.copyWith(status: JobStatus.pending, progress: 0, errorMsg: null),
    );
    await _run(jobId);
  }

  void remove(String jobId) {
    state = state.where((j) => j.id != jobId).toList();
  }

  void clearFinished() {
    state = state
        .where((j) =>
            j.status == JobStatus.pending ||
            j.status == JobStatus.downloading)
        .toList();
  }

  // ── internals ──────────────────────────────────────────────────

  Future<void> _run(String jobId) async {
    // ── WiFi-only gate ───────────────────────────────────────────────────
    final settings = _ref.read(settingsProvider);
    if (settings.wifiOnly) {
      final results = await Connectivity().checkConnectivity();
      final onWifi = results.contains(ConnectivityResult.wifi);
      if (!onWifi) {
        _updateJob(
          jobId,
          (j) => j.copyWith(
            status: JobStatus.error,
            errorMsg:
                'Wi-Fi only mode is on — connect to Wi-Fi to download.',
          ),
        );
        return;
      }
    }

    _updateJob(jobId, (j) => j.copyWith(status: JobStatus.downloading));

    final job = state.firstWhere((j) => j.id == jobId);
    final service = DownloaderService();

    try {
      final savedPath = await service.downloadItem(
        job.item,
        onProgress: (progress) {
          _updateJob(jobId, (j) => j.copyWith(progress: progress));
        },
      );
      _updateJob(
        jobId,
        (j) => j.copyWith(
          status: JobStatus.done,
          progress: 1.0,
          outputPath: savedPath,
        ),
      );
    } catch (e) {
      _updateJob(jobId, (j) => j.copyWith(status: JobStatus.error, errorMsg: e.toString()));
    }
  }

  void _updateJob(String id, DownloadJob Function(DownloadJob) updater) {
    state = [
      for (final j in state)
        if (j.id == id) updater(j) else j,
    ];
  }
}

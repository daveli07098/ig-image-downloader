import 'dart:async';
import 'dart:math';

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
  final _random = Random();
  StreamSubscription<List<ConnectivityResult>>? _connectivitySub;
  // Sequential download queue — one job at a time, with a pause between each
  bool _isRunning = false;
  final _pendingIds = <String>[];

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
  /// Jobs are added to the sequential queue and downloaded one at a time
  /// with a random 1–3 s pause between each to avoid rate-limiting.
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
    _pendingIds.addAll(jobs.map((j) => j.id));
    _startWorker();
  }

  Future<void> retry(String jobId) async {
    _updateJob(
      jobId,
      (j) => j.copyWith(status: JobStatus.pending, progress: 0, errorMsg: null),
    );
    _pendingIds.add(jobId);
    _startWorker();
  }

  /// Starts the sequential worker loop if not already running.
  void _startWorker() {
    if (_isRunning) return;
    _isRunning = true;
    _runNext();
  }

  /// Processes pending jobs one at a time with a pause between each.
  Future<void> _runNext() async {
    while (_pendingIds.isNotEmpty) {
      final jobId = _pendingIds.removeAt(0);
      // Job may have been removed from state while queued
      if (!state.any((j) => j.id == jobId)) continue;

      await _run(jobId);

      // Pause between downloads — random 1–3 s to avoid rate-limiting
      if (_pendingIds.isNotEmpty) {
        final pauseMs = 1000 + _random.nextInt(2000);
        await Future.delayed(Duration(milliseconds: pauseMs));
      }
    }
    _isRunning = false;
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

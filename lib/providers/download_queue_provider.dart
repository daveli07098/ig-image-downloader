import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import '../models/download_job.dart';
import '../services/downloader_service.dart';
import '../services/facebook_downloader_service.dart';
import '../services/ig_url_parser.dart';
import '../services/threads_downloader_service.dart';
import '../services/x_downloader_service.dart';
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
    // Signal completes when persisted jobs are loaded — enqueueItems awaits it
    // so new shares never race against the initial load.
    _loadCompleter = Completer<void>();
    _loadPersistedJobs().then((_) {
      if (!_loadCompleter.isCompleted) _loadCompleter.complete();
    }).catchError((_) {
      if (!_loadCompleter.isCompleted) _loadCompleter.complete();
    });
  }

  static const _prefsKey = 'job_queue_v2';

  final Ref _ref;
  final _random = Random();
  late final Completer<void> _loadCompleter;
  StreamSubscription<List<ConnectivityResult>>? _connectivitySub;
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

  /// Enqueue specific [MediaItem]s from a post URL (Instagram or X).
  /// Jobs are added to the sequential queue and downloaded one at a time
  /// with a random 1–3 s pause between each to avoid rate-limiting.
  Future<void> enqueueItems(String postUrl, List<MediaItem> selectedItems) async {
    // Ensure persisted jobs are loaded first so they are never clobbered
    // by a new share arriving during the async SharedPreferences read.
    await _loadCompleter.future;

    final type = XDownloaderService.isXUrl(postUrl)
        ? IgMediaType.xPost
        : ThreadsDownloaderService.isThreadsUrl(postUrl)
            ? IgMediaType.threadsPost
            : FacebookDownloaderService.isFacebookUrl(postUrl)
                ? IgMediaType.facebookPost
                : IgUrlParser.detect(postUrl);
    final jobs = selectedItems.map((item) => DownloadJob(
          id: _uuid.v4(),
          url: postUrl,
          mediaType: type,
          item: item,
          status: JobStatus.pending,
          createdAt: DateTime.now(),
        )).toList();

    state = [...state, ...jobs];
    _pendingIds.addAll(jobs.map((j) => j.id));
    _pruneFinished();   // removes finished jobs >1h old, calls _persistJobs
    _persistJobs();     // also persist the new pending jobs immediately
    _startWorker();
  }

  /// Keeps the queue tidy: finished (done/error) jobs older than 1 hour are
  /// removed. Active (pending/downloading) jobs are never pruned.
  void _pruneFinished() {
    final cutoff = DateTime.now().subtract(const Duration(hours: 1));
    state = state.where((j) {
      if (j.status == JobStatus.pending || j.status == JobStatus.downloading) {
        return true;
      }
      return j.createdAt.isAfter(cutoff);
    }).toList();
    _persistJobs();
  }

  /// Persist all jobs so they survive Android process kills between shares.
  /// In-progress downloads are saved as pending so they can be retried.
  Future<void> _persistJobs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final toSave = state.map((j) {
        // Treat downloading as pending so it shows as resumable on restart
        if (j.status == JobStatus.downloading) {
          return j.copyWith(status: JobStatus.pending, progress: 0);
        }
        return j;
      }).map((j) => j.toJson()).toList();
      await prefs.setString(_prefsKey, jsonEncode(toSave));
    } catch (_) {}
  }

  /// Load persisted jobs on startup. Pending jobs were queued when the app
  /// was killed — restore them as errors with "Interrupted" so the user
  /// can see them and tap retry to re-queue individually.
  Future<void> _loadPersistedJobs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefsKey);
      if (raw == null || raw.isEmpty) return;
      final cutoff = DateTime.now().subtract(const Duration(hours: 1));
      final existingIds = state.map((j) => j.id).toSet();
      final toRetry = <String>[];
      final loaded = (jsonDecode(raw) as List)
          .map((e) => DownloadJob.fromJson(Map<String, dynamic>.from(e as Map)))
          .where((j) => j.createdAt.isAfter(cutoff))
          // Skip jobs already in state (e.g. process wasn't killed)
          .where((j) => !existingIds.contains(j.id))
          .map((j) {
            // Auto-retry interrupted pending/downloading jobs — no user tap needed
            if (j.status == JobStatus.pending ||
                j.status == JobStatus.downloading) {
              toRetry.add(j.id);
              return j.copyWith(status: JobStatus.pending, progress: 0, errorMsg: null);
            }
            return j;
          })
          .toList();
      if (loaded.isNotEmpty) {
        state = [...loaded, ...state];
        if (toRetry.isNotEmpty) {
          _pendingIds.insertAll(0, toRetry);
          _startWorker();
        }
      }
    } catch (_) {}
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
            errorMsg: 'Wi-Fi only mode is on — connect to Wi-Fi to download.',
          ),
        );
        return;
      }
    }

    _updateJob(jobId, (j) => j.copyWith(status: JobStatus.downloading));

    final job = state.firstWhere((j) => j.id == jobId);
    final service = DownloaderService();

    // Retry up to 3 times for transient network errors (DNS failure, timeout,
    // connection reset) which happen when the app is backgrounded on Android.
    const maxAttempts = 3;
    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      try {
        final result = await service.downloadItem(
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
            outputPath: result.path,
            skipped: result.skipped,
          ),
        );
        _pruneFinished();
        return; // success
      } catch (e) {
        final isNetworkError = _isTransientNetworkError(e.toString());
        if (isNetworkError && attempt < maxAttempts) {
          // Exponential backoff: 2s, 4s before retries
          final backoff = Duration(seconds: attempt * 2);
          _updateJob(
            jobId,
            (j) => j.copyWith(
              progress: 0,
              errorMsg: 'Network error, retrying ($attempt/$maxAttempts)…',
            ),
          );
          await Future.delayed(backoff);
          _updateJob(jobId, (j) => j.copyWith(errorMsg: null));
        } else {
          _updateJob(
            jobId,
            (j) => j.copyWith(
              status: JobStatus.error,
              errorMsg: e.toString(),
            ),
          );
          return;
        }
      }
    }
  }

  /// Returns true for errors that are worth retrying automatically:
  /// DNS lookup failures, connection resets, and timeouts — all common
  /// when Android restricts network access for backgrounded apps.
  static bool _isTransientNetworkError(String msg) {
    const transient = [
      'Failed host lookup',
      'Connection reset',
      'Connection refused',
      'SocketException',
      'connection error',
      'ConnectTimeout',
      'ReceiveTimeout',
      'errno = 7',
    ];
    final lower = msg.toLowerCase();
    return transient.any((t) => lower.contains(t.toLowerCase()));
  }

  void _updateJob(String id, DownloadJob Function(DownloadJob) updater) {
    state = [
      for (final j in state)
        if (j.id == id) updater(j) else j,
    ];
  }
}

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import '../models/download_job.dart';
import '../services/downloader_service.dart';
import '../services/ig_url_parser.dart';

final _uuid = const Uuid();

// The live job queue — UI watches this
final downloadQueueProvider =
    StateNotifierProvider<DownloadQueueNotifier, List<DownloadJob>>(
  (ref) => DownloadQueueNotifier(ref),
);

class DownloadQueueNotifier extends StateNotifier<List<DownloadJob>> {
  DownloadQueueNotifier(this._ref) : super([]);

  final Ref _ref;

  /// Enqueue a new URL. No-op if the same URL is already pending/downloading.
  Future<void> enqueue(String rawUrl) async {
    final url = rawUrl.trim();
    if (url.isEmpty) return;

    final alreadyExists = state.any(
      (j) =>
          j.url == url &&
          (j.status == JobStatus.pending ||
              j.status == JobStatus.downloading),
    );
    if (alreadyExists) return;

    final job = DownloadJob(
      id: _uuid.v4(),
      url: url,
      mediaType: IgUrlParser.detect(url),
      status: JobStatus.pending,
      createdAt: DateTime.now(),
    );

    state = [...state, job];
    await _run(job.id);
  }

  Future<void> retry(String jobId) async {
    _updateJob(
      jobId,
      (j) => j.copyWith(
        status: JobStatus.pending,
        progress: 0,
        errorMsg: null,
        outputPath: null,
      ),
    );
    await _run(jobId);
  }

  void remove(String jobId) {
    state = state.where((j) => j.id != jobId).toList();
  }

  void clearFinished() {
    state = state
        .where(
          (j) =>
              j.status == JobStatus.pending ||
              j.status == JobStatus.downloading,
        )
        .toList();
  }

  // ── internals ──────────────────────────────────────────────────

  Future<void> _run(String jobId) async {
    _updateJob(jobId, (j) => j.copyWith(status: JobStatus.downloading));

    final job = state.firstWhere((j) => j.id == jobId);
    final service = DownloaderService();

    try {
      final outputPath = await service.download(
        job.url,
        onProgress: (progress) {
          _updateJob(jobId, (j) => j.copyWith(progress: progress));
        },
      );
      _updateJob(
        jobId,
        (j) => j.copyWith(
          status: JobStatus.done,
          progress: 1.0,
          outputPath: outputPath,
        ),
      );
    } catch (e) {
      _updateJob(
        jobId,
        (j) => j.copyWith(
          status: JobStatus.error,
          errorMsg: e.toString(),
        ),
      );
    }
  }

  void _updateJob(String id, DownloadJob Function(DownloadJob) updater) {
    state = [
      for (final j in state)
        if (j.id == id) updater(j) else j,
    ];
  }
}

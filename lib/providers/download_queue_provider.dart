import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import '../models/download_job.dart';
import '../services/downloader_service.dart';
import '../services/ig_url_parser.dart';

const _uuid = Uuid();

// The live job queue — UI watches this
final downloadQueueProvider =
    StateNotifierProvider<DownloadQueueNotifier, List<DownloadJob>>(
  (ref) => DownloadQueueNotifier(ref),
);

class DownloadQueueNotifier extends StateNotifier<List<DownloadJob>> {
  DownloadQueueNotifier(Ref ref) : _ref = ref, super([]);

  // ignore: unused_field
  final Ref _ref;

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

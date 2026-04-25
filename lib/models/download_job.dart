import 'media_item.dart';

export 'media_item.dart';

enum IgMediaType { post, reel, story, igtv, unknown }

enum JobStatus { pending, downloading, done, error }

class DownloadJob {
  final String id;
  final String url;           // original IG post URL
  final IgMediaType mediaType;
  final MediaItem item;       // the specific media item being downloaded
  final JobStatus status;
  final double progress;      // 0.0 – 1.0
  final String? errorMsg;
  final String? outputPath;   // permanent file path after successful download
  final DateTime createdAt;

  const DownloadJob({
    required this.id,
    required this.url,
    required this.mediaType,
    required this.item,
    required this.status,
    this.progress = 0.0,
    this.errorMsg,
    this.outputPath,
    required this.createdAt,
  });

  DownloadJob copyWith({
    String? id,
    String? url,
    IgMediaType? mediaType,
    MediaItem? item,
    JobStatus? status,
    double? progress,
    String? errorMsg,
    String? outputPath,
    DateTime? createdAt,
  }) {
    return DownloadJob(
      id: id ?? this.id,
      url: url ?? this.url,
      mediaType: mediaType ?? this.mediaType,
      item: item ?? this.item,
      status: status ?? this.status,
      progress: progress ?? this.progress,
      errorMsg: errorMsg ?? this.errorMsg,
      outputPath: outputPath ?? this.outputPath,
      createdAt: createdAt ?? this.createdAt,
    );
  }

  String get mediaTypeLabel {
    switch (mediaType) {
      case IgMediaType.post:
        return 'Post';
      case IgMediaType.reel:
        return 'Reel';
      case IgMediaType.story:
        return 'Story';
      case IgMediaType.igtv:
        return 'IGTV';
      case IgMediaType.unknown:
        return 'IG';
    }
  }
}

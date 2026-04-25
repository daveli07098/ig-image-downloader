enum IgMediaType { post, reel, story, igtv, unknown }

enum JobStatus { pending, downloading, done, error }

class DownloadJob {
  final String id;
  final String url;
  final IgMediaType mediaType;
  final JobStatus status;
  final double progress; // 0.0 – 1.0
  final String? outputPath;
  final String? errorMsg;
  final DateTime createdAt;

  const DownloadJob({
    required this.id,
    required this.url,
    required this.mediaType,
    required this.status,
    this.progress = 0.0,
    this.outputPath,
    this.errorMsg,
    required this.createdAt,
  });

  DownloadJob copyWith({
    String? id,
    String? url,
    IgMediaType? mediaType,
    JobStatus? status,
    double? progress,
    String? outputPath,
    String? errorMsg,
    DateTime? createdAt,
  }) {
    return DownloadJob(
      id: id ?? this.id,
      url: url ?? this.url,
      mediaType: mediaType ?? this.mediaType,
      status: status ?? this.status,
      progress: progress ?? this.progress,
      outputPath: outputPath ?? this.outputPath,
      errorMsg: errorMsg ?? this.errorMsg,
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

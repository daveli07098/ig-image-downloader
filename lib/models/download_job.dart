import 'dart:convert';

import 'media_item.dart';

export 'media_item.dart';

enum IgMediaType { post, reel, story, igtv, unknown, xPost, threadsPost, facebookPost }

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
  final bool skipped;         // true when file already existed and download was skipped
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
    this.skipped = false,
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
    bool? skipped,
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
      skipped: skipped ?? this.skipped,
      createdAt: createdAt ?? this.createdAt,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'url': url,
        'mediaType': mediaType.name,
        'item': item.toJson(),
        'status': status.name,
        'progress': progress,
        'errorMsg': errorMsg,
        'outputPath': outputPath,
        'skipped': skipped,
        'createdAt': createdAt.millisecondsSinceEpoch,
      };

  factory DownloadJob.fromJson(Map<String, dynamic> j) => DownloadJob(
        id: j['id'] as String,
        url: j['url'] as String,
        mediaType: IgMediaType.values.firstWhere(
          (e) => e.name == j['mediaType'],
          orElse: () => IgMediaType.unknown,
        ),
        item: MediaItem.fromJson(
            Map<String, dynamic>.from(j['item'] as Map)),
        status: JobStatus.values.firstWhere(
          (e) => e.name == j['status'],
          orElse: () => JobStatus.error,
        ),
        progress: (j['progress'] as num?)?.toDouble() ?? 0,
        errorMsg: j['errorMsg'] as String?,
        outputPath: j['outputPath'] as String?,
        skipped: j['skipped'] as bool? ?? false,
        createdAt: DateTime.fromMillisecondsSinceEpoch(
            j['createdAt'] as int),
      );

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
      case IgMediaType.xPost:
        return 'X Post';
      case IgMediaType.threadsPost:
        return 'Threads';
      case IgMediaType.facebookPost:
        return 'Facebook';
    }
  }
}

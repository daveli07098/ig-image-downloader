enum MediaItemType { video, image }

/// A single downloadable media item extracted from an Instagram post.
/// A carousel post can have many of these.
class MediaItem {
  final String id;             // internal key (unused in filenames)
  final String mediaUrl;       // direct CDN URL to download
  final String? thumbnailUrl;  // preview thumbnail
  final MediaItemType type;
  final String username;       // IG account name
  final int itemIndex;         // 1-based position within the post (1, 2, 3…)
  final int? postTimestamp;    // post's taken_at (Unix seconds) for filename

  const MediaItem({
    required this.id,
    required this.mediaUrl,
    this.thumbnailUrl,
    required this.type,
    this.username = 'unknown',
    this.itemIndex = 1,
    this.postTimestamp,
  });

  bool get isVideo => type == MediaItemType.video;

  /// Filename base: eyes198877_20260504_1_a3b2c1  (no extension)
  ///
  /// The 6-char hex suffix is a stable hash of the media URL path (no query
  /// params). It prevents filename collisions between different posts that share
  /// the same username, date, and item index — e.g. two different Facebook posts
  /// downloaded on the same day both produce `facebook_reel_20260518_1` without
  /// this suffix, causing the second download to be silently skipped and the
  /// user to be shown the wrong file.
  String get filenameBase {
    final dateStr = _formatDate(postTimestamp);
    // Stable polynomial hash of the URL path — same URL always produces same
    // hash across app restarts, different URLs produce different hashes.
    final path = mediaUrl.split('?').first;
    var h = 0;
    for (final c in path.codeUnits) {
      h = ((h * 31) + c) & 0xFFFFFF;
    }
    final hash = h.toRadixString(16).padLeft(6, '0');
    return '${username}_${dateStr}_${itemIndex}_$hash';
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'mediaUrl': mediaUrl,
        'thumbnailUrl': thumbnailUrl,
        'type': type.name,
        'username': username,
        'itemIndex': itemIndex,
        'postTimestamp': postTimestamp,
      };

  factory MediaItem.fromJson(Map<String, dynamic> j) => MediaItem(
        id: j['id'] as String,
        mediaUrl: j['mediaUrl'] as String,
        thumbnailUrl: j['thumbnailUrl'] as String?,
        type: j['type'] == 'video' ? MediaItemType.video : MediaItemType.image,
        username: j['username'] as String? ?? 'unknown',
        itemIndex: j['itemIndex'] as int? ?? 1,
        postTimestamp: j['postTimestamp'] as int?,
      );

  static String _formatDate(int? ts) {
    if (ts == null) {
      final now = DateTime.now();
      return '${now.year}'
          '${now.month.toString().padLeft(2, '0')}'
          '${now.day.toString().padLeft(2, '0')}';
    }
    final dt = DateTime.fromMillisecondsSinceEpoch(ts * 1000);
    return '${dt.year}'
        '${dt.month.toString().padLeft(2, '0')}'
        '${dt.day.toString().padLeft(2, '0')}';
  }
}

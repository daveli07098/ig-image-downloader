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

  /// Filename base: eyes198877_20260504_1  (no extension)
  String get filenameBase {
    final dateStr = _formatDate(postTimestamp);
    return '${username}_${dateStr}_$itemIndex';
  }

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

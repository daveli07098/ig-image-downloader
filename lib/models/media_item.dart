enum MediaItemType { video, image }

/// A single downloadable media item extracted from an Instagram post.
/// A carousel post can have many of these.
class MediaItem {
  final String id;             // index-based, e.g. "0", "1"
  final String mediaUrl;       // direct CDN URL to download
  final String? thumbnailUrl;  // preview thumbnail (og:image even for videos)
  final MediaItemType type;
  final String username;       // IG account name, used for folder + filename

  const MediaItem({
    required this.id,
    required this.mediaUrl,
    this.thumbnailUrl,
    required this.type,
    this.username = 'unknown',
  });

  bool get isVideo => type == MediaItemType.video;
}

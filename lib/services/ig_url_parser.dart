import '../models/download_job.dart';

/// Determines the media type of an Instagram URL.
class IgUrlParser {
  IgUrlParser._();

  // e.g. https://www.instagram.com/reel/ABC123/
  static final _reelPattern =
      RegExp(r'instagram\.com/reel/([A-Za-z0-9_-]+)', caseSensitive: false);

  // e.g. https://www.instagram.com/p/ABC123/
  static final _postPattern =
      RegExp(r'instagram\.com/p/([A-Za-z0-9_-]+)', caseSensitive: false);

  // e.g. https://www.instagram.com/stories/username/123456/
  static final _storyPattern = RegExp(
    r'instagram\.com/stories/[^/]+/(\d+)',
    caseSensitive: false,
  );

  // e.g. https://www.instagram.com/tv/ABC123/
  static final _igtvPattern =
      RegExp(r'instagram\.com/tv/([A-Za-z0-9_-]+)', caseSensitive: false);

  static IgMediaType detect(String url) {
    if (_reelPattern.hasMatch(url)) return IgMediaType.reel;
    if (_postPattern.hasMatch(url)) return IgMediaType.post;
    if (_storyPattern.hasMatch(url)) return IgMediaType.story;
    if (_igtvPattern.hasMatch(url)) return IgMediaType.igtv;
    return IgMediaType.unknown;
  }

  static bool isInstagramUrl(String url) =>
      url.contains('instagram.com') || url.contains('instagr.am');
}

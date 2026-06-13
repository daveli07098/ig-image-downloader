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

  // ── Native app deep linking ────────────────────────────────────────────────
  //
  // Instagram exposes no API to *switch the logged-in account* from a third
  // party; whichever account is active inside the IG app is what renders the
  // post. What we can do is jump straight into the IG app on the exact post via
  // the `instagram://media?id=<numericId>` scheme, where IG natively shows the
  // timestamp and lets the user scroll to the posts before/after it.

  /// Instagram shortcodes are a URL-safe base64 encoding of the numeric media
  /// id. This is the alphabet used (index = the 6-bit value of each char).
  static const _shortcodeAlphabet =
      'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_';

  /// Pulls the base64 shortcode out of a /p/, /reel/ or /tv/ URL.
  static String? extractShortcode(String url) {
    final match = _reelPattern.firstMatch(url) ??
        _postPattern.firstMatch(url) ??
        _igtvPattern.firstMatch(url);
    return match?.group(1);
  }

  /// Decodes an IG shortcode (e.g. `C1aB2cD3eF`) into its numeric media id.
  /// Uses [BigInt] because real media ids exceed 2^53. Returns null if the
  /// shortcode contains a character outside the IG alphabet.
  static BigInt? shortcodeToMediaId(String shortcode) {
    if (shortcode.isEmpty) return null;
    final base = BigInt.from(64);
    var id = BigInt.zero;
    for (final char in shortcode.split('')) {
      final value = _shortcodeAlphabet.indexOf(char);
      if (value < 0) return null;
      id = id * base + BigInt.from(value);
    }
    return id;
  }

  /// Builds an `instagram://media?id=…` deep link for a post/reel/IGTV URL so
  /// the IG app opens directly on that post. Returns null for URLs that don't
  /// carry a shortcode (stories, unknown, non-IG) — callers should fall back to
  /// the original https link in that case.
  static Uri? instagramAppUri(String url) {
    final type = detect(url);
    if (type != IgMediaType.post &&
        type != IgMediaType.reel &&
        type != IgMediaType.igtv) {
      return null;
    }
    final shortcode = extractShortcode(url);
    if (shortcode == null) return null;
    final id = shortcodeToMediaId(shortcode);
    if (id == null) return null;
    return Uri.parse('instagram://media?id=$id');
  }
}

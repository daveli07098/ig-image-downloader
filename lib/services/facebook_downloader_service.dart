import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:html/parser.dart' as html_parser;
import '../models/media_item.dart';

/// Downloads media from Facebook posts, videos, and Reels.
///
/// Uses the facebookexternalhit user-agent which causes Facebook's servers to
/// render a fully-populated OG tag response without JavaScript execution. This
/// works reliably for public posts, videos (/share/r/), and photos (/share/).
///
/// URL formats supported:
///   https://www.facebook.com/share/XXXXXXXX/         (post/photo)
///   https://www.facebook.com/share/r/XXXXXXXX/       (reel/video)
///   https://www.facebook.com/<user>/videos/<id>/
///   https://www.facebook.com/<user>/posts/<id>/
///   https://www.facebook.com/reel/<id>/
class FacebookDownloaderService {
  // Facebook renders full OG tags for their own crawler UA.
  static const _ua =
      'facebookexternalhit/1.1 (+http://www.facebook.com/externalhit_uatext.php)';

  final Dio _dio;

  FacebookDownloaderService({Dio? dio})
      : _dio = dio ??
            Dio(BaseOptions(
              connectTimeout: const Duration(seconds: 15),
              receiveTimeout: const Duration(seconds: 30),
              followRedirects: true,
              maxRedirects: 8,
              headers: {
                'User-Agent': _ua,
                'Accept-Language': 'en-US,en;q=0.9',
              },
            ));

  // ── URL helpers ──────────────────────────────────────────────────────────

  static bool isFacebookUrl(String url) =>
      RegExp(r'facebook\.com|fb\.com', caseSensitive: false).hasMatch(url);

  /// Extract a display username from a Facebook URL after redirect resolves.
  static String _usernameFromUrl(String url) {
    final re = RegExp(
      r'facebook\.com/([^/?#]+)/(?:videos|posts|reels)',
      caseSensitive: false,
    );
    final m = re.firstMatch(url);
    if (m != null) {
      final raw = m.group(1)!;
      // Skip numeric profile IDs and generic path segments
      if (!RegExp(r'^\d+$').hasMatch(raw) && raw != 'reel') return raw;
    }
    // /reel/<id>/ pattern
    final reelRe = RegExp(r'facebook\.com/reel/(\d+)', caseSensitive: false);
    if (reelRe.hasMatch(url)) return 'facebook_reel';
    return 'facebook';
  }

  // ── Fetch media items ────────────────────────────────────────────────────

  Future<List<MediaItem>> fetchItems(String url) async {
    final cleanUrl = url.split('?').first;
    debugPrint('[FB] URL: $cleanUrl');

    final resp = await _dio.get<String>(cleanUrl);

    if (resp.statusCode != 200 || resp.data == null) {
      throw Exception('Failed to load Facebook page (${resp.statusCode})');
    }

    // Use the final URL after redirects for username extraction
    final finalUrl = resp.realUri.toString();
    final username = _usernameFromUrl(finalUrl);
    debugPrint('[FB] final URL: $finalUrl  username: $username');

    return _parsePage(resp.data!, username);
  }

  List<MediaItem> _parsePage(String html, String username) {
    final document = html_parser.parse(html);
    final ogVideos = <String>[];
    final ogImages = <String>[];
    bool hasEmbedVideoOnly = false;

    for (final tag in document.querySelectorAll('meta[property]')) {
      final property = tag.attributes['property'] ?? '';
      final content = tag.attributes['content'] ?? '';
      if (content.isEmpty) continue;

      if (property == 'og:video' ||
          property == 'og:video:url' ||
          property == 'og:video:secure_url') {
        if (!ogVideos.contains(content)) ogVideos.add(content);
      } else if (property == 'og:image' || property == 'og:image:url') {
        // Exclude generic Facebook share / logo images
        if (!content.contains('static.xx.fbcdn') &&
            !content.contains('/rsrc.php/') &&
            !ogImages.contains(content)) {
          ogImages.add(content);
        }
      }
    }

    // ── Real video URL extraction ─────────────────────────────────────────
    // og:video from Facebook is often an embed iframe URL (text/html), not
    // an actual MP4. Parse the page's embedded JSON for the real CDN URL.
    String? realVideoUrl;
    if (ogVideos.isNotEmpty) {
      final isEmbedUrl = ogVideos.first.contains('video/embed') ||
          ogVideos.first.contains('video.php') ||
          !ogVideos.first.contains('fbcdn.net');
      if (isEmbedUrl) {
        realVideoUrl = _extractVideoUrlFromJson(html);
        hasEmbedVideoOnly = realVideoUrl == null;
      } else {
        realVideoUrl = ogVideos.first;
      }
    } else {
      // No og:video at all — still try JSON extraction (Reels often omit it)
      realVideoUrl = _extractVideoUrlFromJson(html);
    }

    // ── Carousel image extraction ─────────────────────────────────────────
    // og:image only exposes the first photo. Pull extra CDN images from
    // the page's embedded JSON for multi-photo posts.
    final allImages = List<String>.from(ogImages);
    _extractCarouselImagesFromJson(html, allImages);

    debugPrint('[FB] video: ${realVideoUrl != null ? "found" : "none"}, '
        'images: ${allImages.length} for @$username');

    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final items = <MediaItem>[];

    if (realVideoUrl != null) {
      items.add(MediaItem(
        id: '0',
        mediaUrl: realVideoUrl,
        thumbnailUrl: allImages.isNotEmpty ? allImages.first : null,
        type: MediaItemType.video,
        username: username,
        itemIndex: 1,
        postTimestamp: now,
      ));
    } else if (hasEmbedVideoOnly) {
      throw Exception(
        'Could not extract video URL.\n'
        'Facebook Reels may require login or a different share link.',
      );
    }

    final imageStart = realVideoUrl != null ? 0 : 0;
    for (var i = imageStart; i < allImages.length; i++) {
      // Skip if it's already used as the video thumbnail (index 0 when video present)
      if (realVideoUrl != null && i == 0) continue;
      items.add(MediaItem(
        id: '$i',
        mediaUrl: allImages[i],
        thumbnailUrl: allImages[i],
        type: MediaItemType.image,
        username: username,
        itemIndex: realVideoUrl != null ? i + 1 : i + 1,
        postTimestamp: now,
      ));
    }

    if (items.isEmpty) {
      throw Exception(
        'No downloadable media found.\n'
        'Facebook public posts require a direct post/video URL.\n'
        'Private content cannot be downloaded.',
      );
    }
    return items;
  }

  // ── Helpers ──────────────────────────────────────────────────────────────

  /// Searches page HTML for the real video CDN URL from Facebook's embedded JSON.
  /// Facebook puts the actual MP4 URLs in JavaScript data blobs — these patterns
  /// cover Videos, Reels, and Watch posts.
  String? _extractVideoUrlFromJson(String html) {
    final patterns = [
      RegExp(r'"browser_native_hd_url"\s*:\s*"([^"]+)"'),
      RegExp(r'"browser_native_sd_url"\s*:\s*"([^"]+)"'),
      RegExp(r'"playable_url_quality_hd"\s*:\s*"([^"]+)"'),
      RegExp(r'"playable_url"\s*:\s*"([^"]+)"'),
      RegExp(r'"hd_src"\s*:\s*"([^"]+)"'),
      RegExp(r'"sd_src"\s*:\s*"([^"]+)"'),
      RegExp(r'"video_url"\s*:\s*"([^"]+)"'),
      RegExp(r'"src"\s*:\s*"(https://[^"]*fbcdn\.net[^"]*\.mp4[^"]*)"'),
    ];

    for (final pattern in patterns) {
      final m = pattern.firstMatch(html);
      if (m != null) {
        final url = _unescape(m.group(1)!);
        if (url.startsWith('https://') &&
            (url.contains('fbcdn.net') || url.contains('fbcdn.com')) &&
            !url.contains('video/embed') &&
            !url.contains('.jpg') &&
            !url.contains('.png')) {
          debugPrint('[FB] Video URL found via: ${pattern.pattern.substring(0, 30)}');
          return url;
        }
      }
    }
    return null;
  }

  /// Extracts additional carousel/album image URLs from Facebook's embedded JSON.
  /// Only adds CDN images not already in [existing].
  void _extractCarouselImagesFromJson(String html, List<String> existing) {
    final seen = existing.toSet();
    // Facebook stores image URIs in its JSON payload — look for scontent CDN URLs
    final pattern = RegExp(
      r'"uri"\s*:\s*"(https://[^"]*scontent[^"]*\.(?:jpg|jpeg|png|webp)[^"]*)"',
    );
    for (final m in pattern.allMatches(html)) {
      final url = _unescape(m.group(1)!);
      // Exclude profile photos and generic UI assets
      if (!url.contains('/profile') &&
          !url.contains('/rsrc') &&
          seen.add(url)) {
        existing.add(url);
      }
    }
  }

  String _unescape(String s) =>
      s.replaceAll(r'\/', '/').replaceAll(r'\u0026', '&');
}

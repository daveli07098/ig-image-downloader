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
    final videos = <String>[];
    final images = <String>[];

    for (final tag in document.querySelectorAll('meta[property]')) {
      final property = tag.attributes['property'] ?? '';
      final content = tag.attributes['content'] ?? '';
      if (content.isEmpty) continue;

      if (property == 'og:video' ||
          property == 'og:video:url' ||
          property == 'og:video:secure_url') {
        if (!videos.contains(content)) videos.add(content);
      } else if (property == 'og:image' || property == 'og:image:url') {
        // Exclude generic Facebook share / logo images
        if (!content.contains('static.xx.fbcdn') &&
            !content.contains('/rsrc.php/') &&
            !images.contains(content)) {
          images.add(content);
        }
      }
    }

    debugPrint('[FB] ${videos.length} videos, ${images.length} images for @$username');

    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final items = <MediaItem>[];

    if (videos.isNotEmpty) {
      for (var i = 0; i < videos.length; i++) {
        items.add(MediaItem(
          id: '$i',
          mediaUrl: videos[i],
          thumbnailUrl: i < images.length ? images[i] : null,
          type: MediaItemType.video,
          username: username,
          itemIndex: i + 1,
          postTimestamp: now,
        ));
      }
      for (var i = videos.length; i < images.length; i++) {
        items.add(MediaItem(
          id: '$i',
          mediaUrl: images[i],
          thumbnailUrl: images[i],
          type: MediaItemType.image,
          username: username,
          itemIndex: i + 1,
          postTimestamp: now,
        ));
      }
    } else {
      for (var i = 0; i < images.length; i++) {
        items.add(MediaItem(
          id: '$i',
          mediaUrl: images[i],
          thumbnailUrl: images[i],
          type: MediaItemType.image,
          username: username,
          itemIndex: i + 1,
          postTimestamp: now,
        ));
      }
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
}

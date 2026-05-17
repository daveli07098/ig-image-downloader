import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:html/parser.dart' as html_parser;
import '../models/media_item.dart';

/// Downloads media from Facebook posts, videos, and Reels.
///
/// Primary strategy: facebookexternalhit UA — Facebook renders fully-populated
/// OG tags for this UA without JavaScript execution. Works for public content.
/// For video/reel pages, og:video is intentionally omitted by Facebook; instead,
/// the real MP4 URL is fetched from /video/embed?video_id=<id> which returns
/// hd_src/sd_src in its JSON payload.
///
/// NEVER mix user session cookies with facebookexternalhit UA — that combination
/// is an instant automation detection signal. User cookies are only used in the
/// browser-UA fallback when bot UA finds nothing (private content).
///
/// URL formats supported:
///   https://www.facebook.com/share/XXXXXXXX/         (post/photo)
///   https://www.facebook.com/share/r/XXXXXXXX/       (reel/video)
///   https://www.facebook.com/<user>/videos/<id>/
///   https://www.facebook.com/<user>/posts/<id>/
///   https://www.facebook.com/reel/<id>/
class FacebookDownloaderService {
  // Bot UA: causes Facebook to render full OG tags for anonymous/public content.
  static const _botUA =
      'facebookexternalhit/1.1 (+http://www.facebook.com/externalhit_uatext.php)';

  // Browser UA: used for authenticated requests so they look like a real user.
  // Never mix this with facebookexternalhit — bots don't have user sessions.
  static const _browserUA =
      'Mozilla/5.0 (Linux; Android 14; SM-S928B) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/124.0.6367.82 Mobile Safari/537.36';

  final Dio _dio;

  FacebookDownloaderService({Dio? dio})
      : _dio = dio ??
            Dio(BaseOptions(
              connectTimeout: const Duration(seconds: 15),
              receiveTimeout: const Duration(seconds: 30),
              followRedirects: true,
              maxRedirects: 8,
              headers: {
                'User-Agent': _botUA,
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

  /// [fbCookies] — the full Facebook cookie string captured from the WebView
  /// login (contains c_user, xs, datr, etc.). When provided, authenticated
  /// pages are used as a private-content fallback after public fetch fails.
  Future<List<MediaItem>> fetchItems(String url, {String? fbCookies}) async {
    final cleanUrl = url.split('?').first;
    debugPrint('[FB] URL: $cleanUrl  session: ${fbCookies != null ? 'YES' : 'NO'}');

    // Always fetch with bot UA first — Facebook returns full OG tags for
    // facebookexternalhit and the response is reliably parseable.
    // Browser UA returns a React SPA without OG tags, so it cannot be used
    // for the primary fetch. User cookies are NEVER sent with the bot UA
    // request (mixing the two is an automation detection signal).
    final resp = await _dio.get<String>(cleanUrl);

    if (resp.statusCode != 200 || resp.data == null) {
      throw Exception('Failed to load Facebook page (${resp.statusCode})');
    }

    final html = resp.data!;
    final finalUrl = resp.realUri.toString();
    final username = _usernameFromUrl(finalUrl);
    debugPrint('[FB] final URL: $finalUrl  username: $username');

    // ── Parse OG tags ─────────────────────────────────────────────────────
    final document = html_parser.parse(html);
    String? ogVideoUrl;
    String? ogType;
    String? ogUrl;
    final ogImages = <String>[];

    for (final tag in document.querySelectorAll('meta[property]')) {
      final property = tag.attributes['property'] ?? '';
      final content = tag.attributes['content'] ?? '';
      if (content.isEmpty) continue;

      if ((property == 'og:video' ||
              property == 'og:video:url' ||
              property == 'og:video:secure_url') &&
          ogVideoUrl == null) {
        ogVideoUrl = content;
      } else if (property == 'og:image' ||
          property == 'og:image:url' ||
          property == 'og:image:secure_url') {
        if (!content.contains('static.xx.fbcdn') &&
            !content.contains('/rsrc.php/') &&
            !ogImages.contains(content)) {
          ogImages.add(content);
        }
      } else if (property == 'og:type' && ogType == null) {
        ogType = content;
      } else if (property == 'og:url' && ogUrl == null) {
        ogUrl = content;
      }
    }

    // ── Carousel image extraction from page JSON ───────────────────────────
    final allImages = List<String>.from(ogImages);
    _extractCarouselImagesFromJson(html, allImages);

    // ── Real video URL extraction ──────────────────────────────────────────
    // og:video from Facebook is typically an embed iframe URL, not an MP4.
    // Strategy:
    //   1. If og:video is already a real CDN video URL, use it directly.
    //   2. Try to extract from JSON in the main page source.
    //   3. Fetch the embed URL itself and look for <video> or JSON video data.
    String? realVideoUrl;

    if (ogVideoUrl != null) {
      final isRealCdn = ogVideoUrl.contains('fbcdn.net') &&
          !ogVideoUrl.contains('embed') &&
          !ogVideoUrl.contains('video.php');
      if (isRealCdn) {
        realVideoUrl = ogVideoUrl;
      }
    }

    // Try JSON patterns in main page source
    realVideoUrl ??= _extractVideoUrlFromJson(html);

    // ── Video embed URL strategy ────────────────────────────────────────
    // Facebook reels/videos never include og:video in bot UA responses — the
    // actual MP4 URL lives in the /video/embed?video_id=<id> endpoint.
    // When og:type is "video.other" and no MP4 found yet, extract the video
    // ID from the resolved og:url or final URL and fetch the embed page.
    if (realVideoUrl == null && ogType == 'video.other') {
      final videoId = _extractVideoIdFromUrl(ogUrl ?? finalUrl);
      if (videoId != null) {
        try {
          final embedUrl =
              'https://www.facebook.com/video/embed?video_id=$videoId';
          debugPrint('[FB] Trying video embed endpoint: $embedUrl');
          final embedDio = Dio(BaseOptions(
            connectTimeout: const Duration(seconds: 15),
            receiveTimeout: const Duration(seconds: 30),
            followRedirects: true,
            maxRedirects: 8,
            headers: {
              'User-Agent': _botUA,
              'Accept-Language': 'en-US,en;q=0.9',
            },
          ));
          final embedResp = await embedDio.get<String>(embedUrl);
          if (embedResp.statusCode == 200 && embedResp.data != null) {
            realVideoUrl = _extractVideoUrlFromJson(embedResp.data!);
            debugPrint(
                '[FB] Embed endpoint video: ${realVideoUrl != null ? "found" : "not found"}');
          }
        } catch (e) {
          debugPrint('[FB] Video embed fetch failed: $e');
        }
      }
    }

    // Legacy: if ogVideoUrl is an embed/php URL (not a CDN URL), fetch it
    if (realVideoUrl == null && ogVideoUrl != null) {
      final isEmbedUrl = ogVideoUrl.contains('embed') ||
          ogVideoUrl.contains('video.php') ||
          !ogVideoUrl.contains('fbcdn.net');
      if (isEmbedUrl) {
        try {
          debugPrint('[FB] Fetching legacy embed URL: $ogVideoUrl');
          final embedDio = Dio(BaseOptions(
            connectTimeout: const Duration(seconds: 15),
            receiveTimeout: const Duration(seconds: 30),
            followRedirects: true,
            maxRedirects: 8,
            headers: {
              'User-Agent': _botUA,
              'Accept-Language': 'en-US,en;q=0.9',
            },
          ));
          final embedResp = await embedDio.get<String>(ogVideoUrl);
          if (embedResp.statusCode == 200 && embedResp.data != null) {
            final embedHtml = embedResp.data!;
            realVideoUrl = _extractVideoUrlFromJson(embedHtml) ??
                _extractVideoTagSrc(embedHtml);
            debugPrint(
                '[FB] Legacy embed video: ${realVideoUrl != null ? "found" : "not found"}');
          }
        } catch (e) {
          debugPrint('[FB] Legacy embed fetch failed: $e');
        }
      }
    }

    debugPrint(
        '[FB] video: ${realVideoUrl != null}, images: ${allImages.length}, user: $username');

    // ── Build items ───────────────────────────────────────────────────────
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
    }

    for (var i = 0; i < allImages.length; i++) {
      // Skip index 0 when a video is present — it's used as the thumbnail
      if (realVideoUrl != null && i == 0) continue;
      items.add(MediaItem(
        id: '${items.length}',
        mediaUrl: allImages[i],
        thumbnailUrl: allImages[i],
        type: MediaItemType.image,
        username: username,
        itemIndex: items.length + 1,
        postTimestamp: now,
      ));
    }

    // ── Private content fallback ──────────────────────────────────────────
    // If bot UA found nothing AND the user is logged in, retry with browser
    // UA + cookies. The browser response is a React SPA — no OG tags — so
    // we fall back to JSON pattern extraction only.
    if (items.isEmpty && fbCookies != null) {
      debugPrint('[FB] Bot UA found nothing; retrying with auth browser UA...');
      try {
        final authDio = Dio(BaseOptions(
          connectTimeout: const Duration(seconds: 15),
          receiveTimeout: const Duration(seconds: 30),
          followRedirects: true,
          maxRedirects: 8,
          headers: {
            'User-Agent': _browserUA,
            'Cookie': fbCookies,
            'Referer': 'https://www.facebook.com/',
            'Accept':
                'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
            'sec-fetch-dest': 'document',
            'sec-fetch-mode': 'navigate',
            'sec-fetch-site': 'same-origin',
          },
        ));
        final authResp = await authDio.get<String>(cleanUrl);
        if (authResp.statusCode == 200 && authResp.data != null) {
          final authHtml = authResp.data!;
          final authVideoUrl = _extractVideoUrlFromJson(authHtml);
          final authImages = <String>[];
          _extractCarouselImagesFromJson(authHtml, authImages);

          if (authVideoUrl != null) {
            items.add(MediaItem(
              id: '0',
              mediaUrl: authVideoUrl,
              thumbnailUrl: authImages.isNotEmpty ? authImages.first : null,
              type: MediaItemType.video,
              username: username,
              itemIndex: 1,
              postTimestamp: now,
            ));
          }
          for (var i = 0; i < authImages.length; i++) {
            if (authVideoUrl != null && i == 0) continue;
            items.add(MediaItem(
              id: '${items.length}',
              mediaUrl: authImages[i],
              thumbnailUrl: authImages[i],
              type: MediaItemType.image,
              username: username,
              itemIndex: items.length + 1,
              postTimestamp: now,
            ));
          }
          debugPrint(
              '[FB] Auth retry: video=${authVideoUrl != null}, images=${authImages.length}');
        }
      } catch (e) {
        debugPrint('[FB] Auth retry failed: $e');
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
  /// Searches multiple field names (`uri`, `src`, `url`) and both CDN domains.
  /// Only adds images not already in [existing].
  void _extractCarouselImagesFromJson(String html, List<String> existing) {
    final seen = existing.toSet();

    // Facebook uses various field names for image URIs in its JS payloads.
    // Both scontent (user photos) and fbcdn (general CDN) are valid image hosts.
    final patterns = [
      RegExp(
        r'"uri"\s*:\s*"(https://[^"\\]+(?:scontent|fbcdn)[^"\\]+\.(?:jpg|jpeg|png|webp)[^"\\]*)"',
      ),
      RegExp(
        r'"src"\s*:\s*"(https://[^"\\]+(?:scontent|fbcdn)[^"\\]+\.(?:jpg|jpeg|png|webp)[^"\\]*)"',
      ),
      RegExp(
        r'"url"\s*:\s*"(https://[^"\\]+(?:scontent|fbcdn)[^"\\]+\.(?:jpg|jpeg|png|webp)[^"\\]*)"',
      ),
    ];

    for (final pattern in patterns) {
      for (final m in pattern.allMatches(html)) {
        final url = _unescape(m.group(1)!);
        if (!url.contains('/profile') &&
            !url.contains('/rsrc') &&
            !url.contains('/emoji') &&
            !url.contains('static.xx.fbcdn') &&
            seen.add(url)) {
          existing.add(url);
        }
      }
    }
  }

  /// Extracts a numeric video/reel ID from a Facebook URL.
  /// Matches /reel/<id>/ and /videos/<id>/ path segments.
  static String? _extractVideoIdFromUrl(String url) {
    final re = RegExp(
      r'/(?:reel|videos|video)/([\d]+)',
      caseSensitive: false,
    );
    return re.firstMatch(url)?.group(1);
  }

  /// Extracts a video URL from a `<video src="...">` tag in embed page HTML.
  String? _extractVideoTagSrc(String html) {
    final re = RegExp(r'<video[^>]+src="([^"]+\.mp4[^"]*)"', caseSensitive: false);
    final m = re.firstMatch(html);
    if (m == null) return null;
    final url = _unescape(m.group(1)!);
    return url.startsWith('https://') ? url : null;
  }

  String _unescape(String s) =>
      s.replaceAll(r'\/', '/').replaceAll(r'\u0026', '&');
}

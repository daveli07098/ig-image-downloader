import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:html/parser.dart' as html_parser;
import '../models/media_item.dart';
import 'facebook_downloader_service.dart';
import 'generic_article_downloader_service.dart';
import 'ig_url_parser.dart';
import 'session_service.dart';
import 'storage_service.dart';
import 'threads_downloader_service.dart';
import 'x_downloader_service.dart';

/// Fetches an Instagram page, extracts all media items (carousel-aware),
/// and downloads selected items to the public Downloads folder.
/// Files are registered with Android's MediaScanner so they appear in the
/// media browser without being duplicated into Pictures.
///
/// Extraction strategy (in order):
///   0. Instagram private API — i.instagram.com (requires session cookie)
///      Full carousel, original resolution, full video
///   1. Embed page → window.__additionalDataLoaded JSON (public posts, limited)
///   2. Main page OG tags + display_url JSON fallback (single posts)
class DownloaderService {
  static const _crawlerUA =
      'facebookexternalhit/1.1 (+http://www.facebook.com/externalhit_uatext.php)';

  // Instagram Android app user-agent — required for the private API
  static const _mobileUA =
      'Instagram 219.0.0.12.117 Android (26/8.0.0; 480dpi; 1080x1920; '
      'OnePlus; ONEPLUS A3010; OnePlus3T; qcom; en_US; 314665256)';

  // Web client app ID accepted by i.instagram.com without an app-level token
  static const _igAppId = '936619743392459';

  final Dio _dio;    // HTML page fetching (crawler UA)
  final Dio _apiDio; // Instagram private API (mobile UA + App-ID)

  DownloaderService({Dio? dio})
      : _dio = dio ??
            Dio(
              BaseOptions(
                connectTimeout: const Duration(seconds: 15),
                receiveTimeout: const Duration(seconds: 60),
                headers: {
                  'User-Agent': _crawlerUA,
                  'Accept-Language': 'en-US,en;q=0.9',
                  'Referer': 'https://www.instagram.com/',
                },
              ),
            ),
        _apiDio = Dio(
          BaseOptions(
            connectTimeout: const Duration(seconds: 15),
            receiveTimeout: const Duration(seconds: 30),
            headers: {
              'User-Agent': _mobileUA,
              'X-IG-App-ID': _igAppId,
              'X-IG-Capabilities': '3brTvwE=',
              'X-IG-Connection-Type': 'WIFI',
              'Accept-Language': 'en-US',
              'Accept': 'application/json',
            },
          ),
        );

  // ── 1.  Fetch all media items from a URL (IG or X) ──────────────────────

  Future<List<MediaItem>> fetchItems(String url) async {
    if (XDownloaderService.isXUrl(url)) {
      return XDownloaderService().fetchItems(url);
    }
    if (ThreadsDownloaderService.isThreadsUrl(url)) {
      // Threads shares Instagram's auth backend — reuse the IG session cookie
      final igSessionId =
          await SessionService.getSessionId(LoginPlatform.instagram);
      return ThreadsDownloaderService().fetchItems(url, igSessionId: igSessionId);
    }
    if (FacebookDownloaderService.isFacebookUrl(url)) {
      final fbCookies =
          await SessionService.getSessionId(LoginPlatform.facebook);
      return FacebookDownloaderService().fetchItems(url, fbCookies: fbCookies);
    }
    if (!IgUrlParser.isInstagramUrl(url)) {
      // Not IG, X, Threads, or Facebook — try generic article extraction
      return GenericArticleDownloaderService().fetchItems(url);
    }
    return _fetchIgItems(url);
  }

  Future<List<MediaItem>> _fetchIgItems(String igUrl) async {
    // Normalise: strip query string, ensure trailing slash
    final cleanUrl = igUrl.split('?').first.replaceAll(RegExp(r'/+$'), '') + '/';
    debugPrint('[IG] URL: $cleanUrl');

    // Attach session cookie if the user has logged in
    final sessionId = await SessionService.getSessionId(LoginPlatform.instagram);
    debugPrint('[IG] sessionId: ${sessionId != null ? 'SET (${sessionId.length} chars)' : 'NULL — not logged in'}');
    final cookieHeader =
        sessionId != null ? 'sessionid=$sessionId' : null;

    // ── Strategy 0: Instagram private API (requires login) ───────────────
    // Returns full carousel + original resolution for any public/private post
    if (sessionId != null) {
      final shortcode = _extractShortcode(cleanUrl);
      if (shortcode != null) {
        try {
          final items = await _fetchViaPrivateApi(shortcode, sessionId);
          if (items.isNotEmpty) {
            debugPrint('[IG] Private API succeeded: ${items.length} items');
            return items;
          }
        } catch (e) {
          debugPrint('[IG] Private API failed: $e');
        }
      }
    }

    // ── Strategy 0b: Story via private API ──────────────────────────────
    // Story URLs already contain the numeric media ID, so no shortcode
    // conversion is needed. Stories are always behind a session wall.
    final storyMediaId = _extractStoryMediaId(cleanUrl);
    if (storyMediaId != null) {
      if (sessionId == null) {
        throw Exception(
          'Stories require login.\nPlease log in to download Instagram Stories.',
        );
      }
      try {
        final items = await _fetchViaMediaId(storyMediaId, sessionId);
        if (items.isNotEmpty) {
          debugPrint('[IG] Story API succeeded: ${items.length} items');
          return items;
        }
      } catch (e) {
        debugPrint('[IG] Story API failed: $e');
        rethrow;
      }
      throw Exception(
        'Could not download story. It may have expired (stories last 24 hours).',
      );
    }

    // ── Strategy A: embed captioned page ────────────────────────────────
    try {
      final embedUrl = '${cleanUrl}embed/captioned/';
      debugPrint('[IG] Trying embed: $embedUrl');
      final resp = await _dio.get<String>(
        embedUrl,
        options: cookieHeader != null
            ? Options(headers: {'Cookie': cookieHeader})
            : null,
      );
      if (resp.statusCode == 200 && resp.data != null) {
        final items = _parseEmbedPage(resp.data!, cleanUrl);
        if (items.isNotEmpty) {
          debugPrint('[IG] Embed succeeded: ${items.length} items');
          return items;
        }
      }
    } catch (e) {
      debugPrint('[IG] Embed failed: $e');
    }

    // ── Strategy B: main page ─────────────────────────────────────────────
    debugPrint('[IG] Falling back to main page');
    final resp = await _dio.get<String>(
      cleanUrl,
      options: cookieHeader != null
          ? Options(headers: {'Cookie': cookieHeader})
          : null,
    );
    if (resp.statusCode != 200 || resp.data == null) {
      throw Exception('Failed to load Instagram page (${resp.statusCode})');
    }
    return _parseMainPage(resp.data!, cleanUrl);
  }

  // ── Strategy 0: Instagram private API ──────────────────────────────────

  /// Extracts the shortcode from an Instagram URL.
  /// Handles /p/, /reel/, /tv/ paths.
  static String? _extractShortcode(String url) {
    final re = RegExp(r'instagram\.com/(?:p|reel|tv)/([A-Za-z0-9_-]+)');
    return re.firstMatch(url)?.group(1);
  }

  /// Extracts the numeric media ID from an Instagram Story URL.
  /// e.g. https://www.instagram.com/stories/username/123456/ → '123456'
  static String? _extractStoryMediaId(String url) {
    final re = RegExp(r'instagram\.com/stories/[^/]+/(\d+)');
    return re.firstMatch(url)?.group(1);
  }

  /// Converts an Instagram URL shortcode to its numeric media ID.
  /// Instagram uses a URL-safe base64 alphabet over 64-value digits.
  /// Uses BigInt to safely handle IDs larger than 2^53.
  static String _shortcodeToId(String shortcode) {
    const alphabet =
        'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_';
    var id = BigInt.zero;
    for (final c in shortcode.split('')) {
      final idx = alphabet.indexOf(c);
      if (idx < 0) continue;
      id = id * BigInt.from(64) + BigInt.from(idx);
    }
    return id.toString();
  }

  Future<List<MediaItem>> _fetchViaPrivateApi(
      String shortcode, String sessionId) async {
    final mediaId = _shortcodeToId(shortcode);
    return _fetchViaMediaId(mediaId, sessionId);
  }

  /// Calls the Instagram private API with a numeric media ID.
  /// Used by both regular posts (after shortcode→ID conversion) and Stories
  /// (whose URL already contains the numeric ID).
  Future<List<MediaItem>> _fetchViaMediaId(
      String mediaId, String sessionId) async {
    final url = 'https://i.instagram.com/api/v1/media/$mediaId/info/';
    debugPrint('[IG] Private API: $url');

    final resp = await _apiDio.get<String>(
      url,
      options: Options(headers: {'Cookie': 'sessionid=$sessionId'}),
    );

    if (resp.statusCode != 200 || resp.data == null) return [];

    final data = jsonDecode(resp.data!) as Map<String, dynamic>;
    final item = _dig(data, ['items', 0]) as Map<String, dynamic>?;
    if (item == null) return [];

    final username =
        (_dig(item, ['user', 'username']) as String?) ?? 'unknown';
    final postTimestamp = (item['taken_at'] as num?)?.toInt();

    final carouselList = item['carousel_media'];
    if (carouselList is List && carouselList.isNotEmpty) {
      debugPrint('[IG] Private API carousel: ${carouselList.length} slides');
      return _extractFromSlides(
        carouselList.cast<Map<String, dynamic>>(),
        username,
        postTimestamp: postTimestamp,
      );
    }

    debugPrint('[IG] Private API single item');
    return _extractFromSlides(
      [item],
      username,
      postTimestamp: postTimestamp,
    );
  }

  List<MediaItem> _parseEmbedPage(String html, String pageUrl) {
    // window.__additionalDataLoaded('extra', {...});
    final re = RegExp(
      r'window\.__additionalDataLoaded\s*\(\s*[^,]+,\s*(\{.+?\})\s*\)\s*;',
      dotAll: true,
    );
    final match = re.firstMatch(html);
    if (match == null) {
      debugPrint('[IG] No __additionalDataLoaded found in embed page');
      return [];
    }

    Map<String, dynamic> data;
    try {
      data = jsonDecode(match.group(1)!) as Map<String, dynamic>;
    } catch (e) {
      debugPrint('[IG] JSON parse error: $e');
      return [];
    }

    // items[0] is the post object
    final item = _dig(data, ['items', 0]) as Map<String, dynamic>?;
    if (item == null) {
      debugPrint('[IG] No items[0] in embed JSON');
      return [];
    }

    final username = (_dig(item, ['user', 'username']) as String?) ?? 'unknown';
    final postTimestamp = (item['taken_at'] as num?)?.toInt();
    debugPrint('[IG] username: $username, taken_at: $postTimestamp');

    // Carousel post: carousel_media array
    final carouselList = item['carousel_media'];
    if (carouselList is List && carouselList.isNotEmpty) {
      debugPrint('[IG] carousel_media: ${carouselList.length} slides');
      return _extractFromSlides(
        carouselList.cast<Map<String, dynamic>>(),
        username,
        postTimestamp: postTimestamp,
      );
    }

    // Single post
    return _extractFromSlides([item], username, postTimestamp: postTimestamp);
  }

  /// Extracts MediaItems from a list of Instagram media nodes
  /// (each node has image_versions2 and optionally video_versions).
  List<MediaItem> _extractFromSlides(
      List<Map<String, dynamic>> slides, String username,
      {int? postTimestamp}) {
    final items = <MediaItem>[];
    for (var i = 0; i < slides.length; i++) {
      final slide = slides[i];
      // Use the slide's own taken_at if available, else the post's
      final ts = (slide['taken_at'] as num?)?.toInt() ?? postTimestamp;
      final isVideo = slide['media_type'] == 2 ||
          (slide['video_versions'] != null &&
              (slide['video_versions'] as List).isNotEmpty);

      if (isVideo) {
        final versions = slide['video_versions'] as List?;
        final videoUrl = versions != null && versions.isNotEmpty
            ? (versions.first as Map<String, dynamic>)['url'] as String?
            : null;
        final thumbUrl = _bestImageUrl(slide);
        if (videoUrl != null) {
          items.add(MediaItem(
            id: '$i',
            mediaUrl: videoUrl,
            thumbnailUrl: thumbUrl,
            type: MediaItemType.video,
            username: username,
            itemIndex: i + 1,
            postTimestamp: ts,
          ));
        }
      } else {
        final imageUrl = _bestImageUrl(slide);
        if (imageUrl != null) {
          items.add(MediaItem(
            id: '$i',
            mediaUrl: imageUrl,
            thumbnailUrl: imageUrl,
            type: MediaItemType.image,
            username: username,
            itemIndex: i + 1,
            postTimestamp: ts,
          ));
        }
      }
    }
    return items;
  }

  String? _bestImageUrl(Map<String, dynamic> node) {
    final candidates =
        _dig(node, ['image_versions2', 'candidates']) as List?;
    if (candidates != null && candidates.isNotEmpty) {
      return (candidates.first as Map<String, dynamic>)['url'] as String?;
    }
    return null;
  }

  // ── Strategy B: main page (OG tags + regex JSON) ───────────────────────

  List<MediaItem> _parseMainPage(String html, String pageUrl) {
    final videos = <String>[];
    final images = <String>[];
    String username = _usernameFromUrl(pageUrl);

    // OG meta tags
    final document = html_parser.parse(html);
    for (final tag in document.querySelectorAll('meta[property]')) {
      final property = tag.attributes['property'] ?? '';
      final content = tag.attributes['content'] ?? '';
      if (content.isEmpty) continue;
      if (property == 'og:url') {
        final u = _usernameFromUrl(content);
        if (u != 'unknown') username = u;
      }
      if (property == 'og:video' || property == 'og:video:url') {
        videos.add(content);
      } else if (property == 'og:image') {
        images.add(content);
      }
    }

    // JSON regex fallback for display_url / video_url keys
    for (final m in RegExp(r'"video_url"\s*:\s*"([^"]+)"').allMatches(html)) {
      final url = _unescape(m.group(1)!);
      if (url.startsWith('https://') && !videos.contains(url)) videos.add(url);
    }
    for (final m in RegExp(r'"display_url"\s*:\s*"([^"]+)"').allMatches(html)) {
      final url = _unescape(m.group(1)!);
      if (url.startsWith('https://') && !images.any((u) => _sameMedia(u, url))) {
        images.add(url);
      }
    }

    debugPrint('[IG] main page: ${videos.length} videos, ${images.length} images, user: $username');

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
        ));
      }
    }

    if (items.isEmpty) {
      throw Exception(
        'No downloadable media found.\n'
        'Private accounts and Stories require login.',
      );
    }
    return items;
  }

  // ── Helpers ─────────────────────────────────────────────────────────────

  /// Safe nested map/list traversal. Keys can be String or int (list index).
  dynamic _dig(dynamic obj, List<Object> path) {
    dynamic cur = obj;
    for (final key in path) {
      if (cur == null) return null;
      if (key is int && cur is List) {
        cur = cur.length > key ? cur[key] : null;
      } else if (key is String && cur is Map) {
        cur = cur[key];
      } else {
        return null;
      }
    }
    return cur;
  }

  String _usernameFromUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return 'unknown';
    final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
    if (segments.length >= 2 &&
        (segments[1] == 'p' || segments[1] == 'reel' || segments[1] == 'tv')) {
      return segments[0];
    }
    return 'unknown';
  }

  bool _sameMedia(String a, String b) {
    if (a == b) return true;
    String fname(String url) {
      final path = Uri.tryParse(url)?.path ?? '';
      return path.split('/').last;
    }
    return fname(a) == fname(b) && fname(a).isNotEmpty;
  }

  String _unescape(String s) =>
      s.replaceAll(r'\/', '/').replaceAll(r'\u0026', '&');

  // ── 2.  Download a single MediaItem ───────────────────────────────────

  static const _mediaScannerChannel =
      MethodChannel('ig_downloader/media_scanner');

  /// Downloads [item] to the per-account folder inside public Downloads,
  /// then notifies Android's media scanner so it appears in the media browser
  /// without being duplicated into Pictures. Returns the saved file path.
  Future<String> downloadItem(
    MediaItem item, {
    required void Function(double progress) onProgress,
  }) async {
    final ext = item.isVideo ? 'mp4' : 'jpg';
    final saveDir = await StorageService.getOrCreateSaveDir(item.username);
    final filename = '${item.filenameBase}.$ext';
    final savePath = '${saveDir.path}/$filename';
    debugPrint('[IG] savePath: $savePath');

    // File already exists — skip re-download (e.g. after permission-denied on first attempt
    // that was actually a "file exists" OS error on Android public storage).
    if (File(savePath).existsSync()) {
      debugPrint('[IG] Already exists, skipping download: $savePath');
      return savePath;
    }

    final sessionId = await SessionService.getSessionId(LoginPlatform.instagram);
    // Only send Instagram cookies for Instagram CDN URLs
    final isIgCdn = item.mediaUrl.contains('cdninstagram.com') ||
        item.mediaUrl.contains('instagram.com') ||
        item.mediaUrl.contains('fbcdn.net');
    await _dio.download(
      item.mediaUrl,
      savePath,
      options: (sessionId != null && isIgCdn)
          ? Options(headers: {'Cookie': 'sessionid=$sessionId'})
          : null,
      onReceiveProgress: (received, total) {
        if (total > 0) onProgress(received / total);
      },
    );

    // Tell Android's MediaStore about the new file so it shows up in the
    // media browser (gallery apps, Files app) immediately, without copying
    // it into Pictures.
    if (defaultTargetPlatform == TargetPlatform.android) {
      final mimeType = item.isVideo ? 'video/mp4' : 'image/jpeg';
      try {
        await _mediaScannerChannel.invokeMethod('scanFile', {
          'path': savePath,
          'mimeType': mimeType,
        });
      } catch (e) {
        debugPrint('[IG] MediaScanner failed (non-fatal): $e');
      }
    }

    return savePath;
  }
}

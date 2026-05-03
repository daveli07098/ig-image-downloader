import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:gal/gal.dart';
import 'package:html/parser.dart' as html_parser;
import '../models/media_item.dart';
import 'storage_service.dart';

/// Fetches an Instagram page, extracts all media items (carousel-aware),
/// and downloads selected items to the device gallery.
///
/// Extraction strategy (in order):
///   1. Embed page → window.__additionalDataLoaded JSON
///      (gives image_versions2/video_versions with full carousel)
///   2. Main page OG tags + display_url JSON fallback (single posts)
class DownloaderService {
  static const _crawlerUA =
      'facebookexternalhit/1.1 (+http://www.facebook.com/externalhit_uatext.php)';

  final Dio _dio;

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
            );

  // ── 1.  Fetch all media items from an IG URL ───────────────────────────

  Future<List<MediaItem>> fetchItems(String igUrl) async {
    // Normalise: strip query string, ensure trailing slash
    final cleanUrl = igUrl.split('?').first.trimRight('/') + '/';
    debugPrint('[IG] URL: $cleanUrl');

    // ── Strategy A: embed captioned page ────────────────────────────────
    // The embed page serves window.__additionalDataLoaded(...) with the
    // full carousel (image_versions2 + video_versions per slide).
    try {
      final embedUrl = '${cleanUrl}embed/captioned/';
      debugPrint('[IG] Trying embed: $embedUrl');
      final resp = await _dio.get<String>(embedUrl);
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

    // ── Strategy B: main page with crawler UA (OG tags + JSON blobs) ─────
    debugPrint('[IG] Falling back to main page');
    final resp = await _dio.get<String>(cleanUrl);
    if (resp.statusCode != 200 || resp.data == null) {
      throw Exception('Failed to load Instagram page (${resp.statusCode})');
    }
    return _parseMainPage(resp.data!, cleanUrl);
  }

  // ── Strategy A: embed page ──────────────────────────────────────────────

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

  /// Downloads [item] directly to the persistent save folder and also saves
  /// it to the device gallery. Returns the permanent file path.
  Future<String> downloadItem(
    MediaItem item, {
    required void Function(double progress) onProgress,
  }) async {
    final ext = item.isVideo ? 'mp4' : 'jpg';
    final saveDir = await StorageService.getOrCreateSaveDir(item.username);
    final filename = '${item.filenameBase}.$ext';
    final savePath = '${saveDir.path}/$filename';

    await _dio.download(
      item.mediaUrl,
      savePath,
      onReceiveProgress: (received, total) {
        if (total > 0) onProgress(received / total);
      },
    );

    // Request gallery permission on first save (required on both platforms).
    // gal throws GalException.accessDenied if permission is not granted.
    if (!await Gal.hasAccess()) {
      final granted = await Gal.requestAccess();
      if (!granted) {
        throw Exception(
          'Gallery permission denied. '
          'Please allow Photos access in Settings to save media.',
        );
      }
    }

    // Also add to the device gallery so it appears in Photos / Gallery app.
    if (item.isVideo) {
      await Gal.putVideo(savePath);
    } else {
      await Gal.putImage(savePath);
    }

    return savePath;
  }
}

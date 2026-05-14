import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:html/parser.dart' as html_parser;
import '../models/media_item.dart';

/// Downloads media from Threads (threads.com / threads.net) posts.
///
/// Three-strategy waterfall:
///   A. Desktop Chrome UA — SSR page may contain __NEXT_DATA__ (Next.js) or
///      raw Instagram-style JSON with full carousel/video data.
///   B. CDN URL regex on the same HTML — uses Instagram CDN path prefixes
///      (t50.2886-16 = video, t51.2885-15 = post image) to find real URLs.
///   C. facebookexternalhit UA → OG tag fallback (embed URLs filtered out).
class ThreadsDownloaderService {
  static const _desktopUA =
      'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';

  static const _botUA =
      'facebookexternalhit/1.1 (+http://www.facebook.com/externalhit_uatext.php)';

  final Dio _desktopDio;
  final Dio _botDio;

  ThreadsDownloaderService()
      : _desktopDio = Dio(BaseOptions(
          connectTimeout: const Duration(seconds: 15),
          receiveTimeout: const Duration(seconds: 30),
          followRedirects: true,
          maxRedirects: 5,
          headers: {
            'User-Agent': _desktopUA,
            'Accept':
                'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
            'Accept-Language': 'en-US,en;q=0.9',
          },
        )),
        _botDio = Dio(BaseOptions(
          connectTimeout: const Duration(seconds: 15),
          receiveTimeout: const Duration(seconds: 30),
          followRedirects: true,
          maxRedirects: 5,
          headers: {
            'User-Agent': _botUA,
            'Accept': 'text/html,*/*;q=0.8',
            'Accept-Language': 'en-US,en;q=0.9',
            'Referer': 'https://www.threads.com/',
          },
        ));

  // ── URL helpers ──────────────────────────────────────────────────────────

  static bool isThreadsUrl(String url) =>
      url.contains('threads.com') || url.contains('threads.net');

  static String? extractUsername(String url) {
    final re = RegExp(
      r'threads\.(?:com|net)/@([^/?#]+)/post',
      caseSensitive: false,
    );
    return re.firstMatch(url)?.group(1);
  }

  // ── Fetch ────────────────────────────────────────────────────────────────

  Future<List<MediaItem>> fetchItems(String url) async {
    final cleanUrl = url.split('?').first;
    debugPrint('[Threads] URL: $cleanUrl');
    final username = extractUsername(cleanUrl) ?? 'threads';

    // ── Strategy A: Desktop Chrome UA ────────────────────────────────────
    String? desktopHtml;
    try {
      final resp = await _desktopDio.get<String>(cleanUrl);
      if (resp.statusCode == 200 && resp.data != null) {
        desktopHtml = resp.data!;

        // A1: __NEXT_DATA__ (Next.js SSR — full structured post data)
        final nextItems = _parseNextData(desktopHtml, username);
        if (nextItems.isNotEmpty) {
          debugPrint('[Threads] __NEXT_DATA__: ${nextItems.length} items');
          return nextItems;
        }

        // A2: CDN URL regex (Instagram CDN path prefixes)
        final cdnItems = _parseCdnUrls(desktopHtml, username);
        if (cdnItems.isNotEmpty) {
          debugPrint('[Threads] CDN regex: ${cdnItems.length} items');
          return cdnItems;
        }
      }
    } catch (e) {
      debugPrint('[Threads] Desktop UA failed: $e');
    }

    // ── Strategy B: facebookexternalhit → OG tags ────────────────────────
    try {
      final resp = await _botDio.get<String>(cleanUrl);
      if (resp.statusCode == 200 && resp.data != null) {
        final items = _parseOgTags(resp.data!, username);
        if (items.isNotEmpty) {
          debugPrint('[Threads] OG tags: ${items.length} items');
          return items;
        }
      }
    } catch (e) {
      debugPrint('[Threads] Bot UA failed: $e');
    }

    throw Exception(
      'No media found in this Threads post.\n'
      'The post may be private or require login.',
    );
  }

  // ── A1: Parse __NEXT_DATA__ (Next.js SSR) ────────────────────────────────

  List<MediaItem> _parseNextData(String html, String username) {
    try {
      final re = RegExp(
        r'<script[^>]+id="__NEXT_DATA__"[^>]*>([\s\S]*?)</script>',
      );
      final match = re.firstMatch(html);
      if (match == null) return [];

      final data = jsonDecode(match.group(1)!) as Map<String, dynamic>;
      final pageProps = _dig(data, ['props', 'pageProps']) as Map?;
      if (pageProps == null) return [];

      List? threadItems = pageProps['thread_items'] as List?;
      if (threadItems == null) {
        final post = pageProps['post'];
        if (post != null) {
          threadItems = [<String, dynamic>{'post': post}];
        }
      }
      if (threadItems == null || threadItems.isEmpty) return [];

      final items = <MediaItem>[];
      for (final ti in threadItems) {
        final post = (ti as Map)['post'] as Map<String, dynamic>?;
        if (post != null) items.addAll(_extractFromPost(post, username));
      }
      return items;
    } catch (e) {
      debugPrint('[Threads] __NEXT_DATA__ error: $e');
      return [];
    }
  }

  List<MediaItem> _extractFromPost(
      Map<String, dynamic> post, String fallback) {
    final username =
        (_dig(post, ['user', 'username']) as String?) ?? fallback;
    final takenAt = post['taken_at'] as int?;

    final carousel = post['carousel_media'] as List?;
    if (carousel != null && carousel.isNotEmpty) {
      final items = <MediaItem>[];
      for (var i = 0; i < carousel.length; i++) {
        final m = _itemFromNode(
            carousel[i] as Map<String, dynamic>, username, takenAt, i + 1);
        if (m != null) items.add(m);
      }
      if (items.isNotEmpty) return items;
    }

    final single = _itemFromNode(post, username, takenAt, 1);
    return single != null ? [single] : [];
  }

  MediaItem? _itemFromNode(
      Map<String, dynamic> node, String username, int? takenAt, int idx) {
    if (node['media_type'] == 2) {
      final vv = (node['video_versions'] as List?)?.cast<Map>();
      if (vv != null && vv.isNotEmpty) {
        final url = vv.first['url'] as String?;
        if (url != null) {
          return MediaItem(
            id: '$idx',
            mediaUrl: url,
            thumbnailUrl: _firstCandidate(node),
            type: MediaItemType.video,
            username: username,
            itemIndex: idx,
            postTimestamp: takenAt,
          );
        }
      }
    }
    final img = _firstCandidate(node);
    if (img != null) {
      return MediaItem(
        id: '$idx',
        mediaUrl: img,
        thumbnailUrl: img,
        type: MediaItemType.image,
        username: username,
        itemIndex: idx,
        postTimestamp: takenAt,
      );
    }
    return null;
  }

  String? _firstCandidate(Map<String, dynamic> node) {
    final candidates =
        (_dig(node, ['image_versions2', 'candidates']) as List?)?.cast<Map>();
    if (candidates == null || candidates.isEmpty) return null;
    return candidates.first['url'] as String?;
  }

  // ── A2: CDN URL regex ────────────────────────────────────────────────────
  //
  // Instagram/Threads CDN path conventions:
  //   t50.2886-16  →  video assets
  //   t51.2885-15  →  post images (full-res originals)
  // These appear in JSON blobs embedded in the SSR HTML.

  List<MediaItem> _parseCdnUrls(String html, String username) {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final items = <MediaItem>[];
    final seenUrls = <String>{};

    // Video
    final videoRe = RegExp(
      r'"url"\s*:\s*"(https://[^"\\]+t50\.2886-16[^"\\]*\.mp4[^"\\]*)"',
    );
    for (final m in videoRe.allMatches(html)) {
      final url = _unescape(m.group(1)!);
      if (seenUrls.add(url)) {
        items.add(MediaItem(
          id: '${items.length}',
          mediaUrl: url,
          thumbnailUrl: null,
          type: MediaItemType.video,
          username: username,
          itemIndex: items.length + 1,
          postTimestamp: now,
        ));
      }
    }

    // Images — deduplicate by filename (same image at multiple sizes)
    final imgRe = RegExp(
      r'"url"\s*:\s*"(https://[^"\\]+t51\.2885-15[^"\\]+)"',
    );
    final seenFilenames = <String>{};
    final imageUrls = <String>[];
    for (final m in imgRe.allMatches(html)) {
      final url = _unescape(m.group(1)!);
      final filename = url.split('?').first.split('/').last;
      if (seenFilenames.add(filename) && seenUrls.add(url)) {
        imageUrls.add(url);
      }
    }

    if (items.isEmpty) {
      // Photo / carousel post
      for (var i = 0; i < imageUrls.length; i++) {
        items.add(MediaItem(
          id: '$i',
          mediaUrl: imageUrls[i],
          thumbnailUrl: imageUrls[i],
          type: MediaItemType.image,
          username: username,
          itemIndex: i + 1,
          postTimestamp: now,
        ));
      }
    } else if (imageUrls.isNotEmpty) {
      // Attach first image as thumbnail to all video items
      final thumb = imageUrls.first;
      for (var i = 0; i < items.length; i++) {
        final v = items[i];
        items[i] = MediaItem(
          id: v.id,
          mediaUrl: v.mediaUrl,
          thumbnailUrl: thumb,
          type: v.type,
          username: v.username,
          itemIndex: v.itemIndex,
          postTimestamp: v.postTimestamp,
        );
      }
    }

    return items;
  }

  // ── B: OG tag fallback ────────────────────────────────────────────────────

  List<MediaItem> _parseOgTags(String html, String username) {
    final document = html_parser.parse(html);
    final videos = <String>[];
    final images = <String>[];

    for (final tag in document.querySelectorAll('meta[property]')) {
      final property = tag.attributes['property'] ?? '';
      final content = tag.attributes['content'] ?? '';
      if (content.isEmpty) continue;
      if (property == 'og:video' || property == 'og:video:url') {
        // Exclude embed page URLs — they are HTML, not downloadable video files
        if (!content.contains('embed') &&
            !content.contains('video.php') &&
            !videos.contains(content)) {
          videos.add(content);
        }
      } else if (property == 'og:image') {
        if (!content.contains('profilepic') && !images.contains(content)) {
          images.add(content);
        }
      }
    }

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
    return items;
  }

  // ── Helpers ──────────────────────────────────────────────────────────────

  dynamic _dig(dynamic obj, List<String> path) {
    dynamic cur = obj;
    for (final key in path) {
      if (cur == null || cur is! Map) return null;
      cur = cur[key];
    }
    return cur;
  }

  String _unescape(String s) =>
      s.replaceAll(r'\/', '/').replaceAll(r'\u0026', '&');
}

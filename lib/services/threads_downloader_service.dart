import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:html/parser.dart' as html_parser;
import '../models/media_item.dart';
import 'session_service.dart';

/// Downloads media from Threads (threads.com / threads.net) posts.
///
/// Threads is owned by Meta and shares infrastructure with Instagram, so the
/// Instagram session cookie is reused for authenticated requests. Public posts
/// are accessible without login via OG tag scraping.
///
/// URL formats supported:
///   https://www.threads.com/@username/post/POSTID
///   https://www.threads.net/@username/post/POSTID
class ThreadsDownloaderService {
  // Mobile Safari UA — Threads serves OG tags reliably to mobile browsers.
  static const _ua =
      'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) '
      'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 '
      'Safari/604.1';

  final Dio _dio;

  ThreadsDownloaderService({Dio? dio})
      : _dio = dio ??
            Dio(BaseOptions(
              connectTimeout: const Duration(seconds: 15),
              receiveTimeout: const Duration(seconds: 30),
              followRedirects: true,
              maxRedirects: 5,
              headers: {
                'User-Agent': _ua,
                'Accept-Language': 'en-US,en;q=0.9',
              },
            ));

  // ── URL helpers ──────────────────────────────────────────────────────────

  static bool isThreadsUrl(String url) =>
      url.contains('threads.com') || url.contains('threads.net');

  /// Extracts the username from a Threads URL: /@username/post/...
  static String? extractUsername(String url) {
    final re = RegExp(
      r'threads\.(?:com|net)/@([^/?#]+)/post',
      caseSensitive: false,
    );
    return re.firstMatch(url)?.group(1);
  }

  // ── Fetch media items ────────────────────────────────────────────────────

  Future<List<MediaItem>> fetchItems(String url) async {
    final cleanUrl = url.split('?').first;
    debugPrint('[Threads] URL: $cleanUrl');

    final username = extractUsername(cleanUrl) ?? 'threads';

    // Reuse Instagram session cookie — Threads shares Meta's auth infra
    final sessionId = await SessionService.getSessionId(LoginPlatform.instagram);
    final cookieHeader = sessionId != null ? 'sessionid=$sessionId' : null;

    final resp = await _dio.get<String>(
      cleanUrl,
      options: cookieHeader != null
          ? Options(headers: {'Cookie': cookieHeader})
          : null,
    );

    if (resp.statusCode != 200 || resp.data == null) {
      throw Exception('Failed to load Threads page (${resp.statusCode})');
    }

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
      } else if (property == 'og:image') {
        // Skip generic Threads profile/placeholder images
        if (!content.contains('profilepic') && !images.contains(content)) {
          images.add(content);
        }
      }
    }

    debugPrint('[Threads] ${videos.length} videos, ${images.length} images for @$username');

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
      // Extra images beyond paired thumbnails
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
        'The post may be private or require login.',
      );
    }
    return items;
  }
}

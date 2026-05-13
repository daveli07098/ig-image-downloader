import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:html/parser.dart' as html_parser;
import '../models/media_item.dart';

/// Downloads images from funnynews-media.com (and its mirror domains).
///
/// The site serves images as `.js` files — raw JPEG bytes stored with a
/// renamed extension as an anti-scraping measure. The app downloads them
/// normally; [DownloaderService.downloadItem] saves all non-video items
/// as `.jpg` regardless of the URL extension.
///
/// Extraction strategy:
///   1. Fetch the article HTML with a desktop browser user-agent.
///   2. Find the `td-post-content` div (Newspaper theme article body).
///   3. Collect all `<img class="... size-full ...">` elements — these are
///      the full-resolution article images. `size-medium` images are
///      related-post thumbnails and are skipped.
///   4. Use the `src` attribute directly — it is always the highest-res
///      version (no dimension suffix in the filename, e.g. `IMG_5105.js`).
class FunnynewsDownloaderService {
  static const _ua =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

  // All known domains that use the same WordPress theme + .js image trick
  static const _domains = [
    'funnynews-media.com',
    'funnymedianews.com',
    'funestnews.com',
  ];

  final Dio _dio;

  FunnynewsDownloaderService({Dio? dio})
      : _dio = dio ??
            Dio(BaseOptions(
              connectTimeout: const Duration(seconds: 15),
              receiveTimeout: const Duration(seconds: 30),
              headers: {
                'User-Agent': _ua,
                'Accept-Language': 'zh-HK,zh;q=0.9,en;q=0.8',
                'Referer': 'https://funnynews-media.com/',
              },
            ));

  // ── URL helpers ──────────────────────────────────────────────────────────

  static bool isFunnynewsUrl(String url) =>
      _domains.any((d) => url.contains(d));

  // ── Fetch items ──────────────────────────────────────────────────────────

  Future<List<MediaItem>> fetchItems(String url) async {
    final cleanUrl = url.split('?').first.split('#').first;
    debugPrint('[FN] URL: $cleanUrl');

    final resp = await _dio.get<String>(cleanUrl);
    if (resp.statusCode != 200 || resp.data == null) {
      throw Exception('Failed to load page (${resp.statusCode})');
    }

    return _parsePage(resp.data!, cleanUrl);
  }

  List<MediaItem> _parsePage(String html, String pageUrl) {
    final document = html_parser.parse(html);

    // Extract post timestamp from <time datetime="..."> if present
    int? postTimestamp;
    final timeEl = document.querySelector('time[datetime]');
    if (timeEl != null) {
      final dt = DateTime.tryParse(timeEl.attributes['datetime'] ?? '');
      if (dt != null) postTimestamp = dt.millisecondsSinceEpoch ~/ 1000;
    }

    // Find the Newspaper-theme article body
    final contentDiv = document.querySelector('.td-post-content');
    if (contentDiv == null) {
      throw Exception('Could not find article content on this page.');
    }

    // size-full = full-resolution article images
    // size-medium = related-post thumbnails (different post IDs) — skip
    final imgEls = contentDiv.querySelectorAll('img.size-full');
    if (imgEls.isEmpty) {
      throw Exception(
        'No downloadable images found.\n'
        'This article may contain only video or text.',
      );
    }

    final items = <MediaItem>[];
    for (var i = 0; i < imgEls.length; i++) {
      final src = imgEls[i].attributes['src'];
      if (src == null || src.isEmpty) continue;
      if (!src.contains('wp-content/uploads')) continue;

      items.add(MediaItem(
        id: '$i',
        mediaUrl: src,
        thumbnailUrl: src,
        type: MediaItemType.image,
        username: 'funnynews',
        itemIndex: i + 1,
        postTimestamp: postTimestamp,
      ));
    }

    if (items.isEmpty) {
      throw Exception('No downloadable images found in this article.');
    }

    debugPrint('[FN] Found ${items.length} images');
    return items;
  }
}

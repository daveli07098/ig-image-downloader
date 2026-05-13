import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:html/dom.dart' as dom;
import '../models/media_item.dart';

/// General-purpose article image downloader.
///
/// Works for any webpage — detection is structural (inspects HTML) rather
/// than domain-based. Useful for WordPress / Newspaper-theme sites and
/// other article pages.
///
/// Extraction strategy:
///   1. Fetch the page with a desktop browser user-agent.
///   2. Walk a list of common article-body selectors until one matches.
///   3. Within the content area, prefer `img.size-full` / `img.size-large`
///      (WordPress full-res class) — fall back to all `<img>` tags whose
///      `src` comes from an uploads path.
///   4. `src` is used directly — it is the highest-res version (no
///      dimension suffix), e.g. `IMG_5105.js` is a raw JPEG with a
///      renamed extension.
///
/// [canHandle] probes the HTML without downloading — call it after
/// fetching to decide whether to route here or surface an error.
class GenericArticleDownloaderService {
  static const _ua =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

  // CSS selectors tried in order — first match wins.
  // Covers: Newspaper theme, Genesis, Twenty-*, plain <article>.
  static const _contentSelectors = [
    '.td-post-content',   // Newspaper / tagDiv theme
    '.entry-content',     // Genesis, Twenty-*, most WP themes
    '.post-content',      // common custom themes
    'article',            // HTML5 semantic fallback
  ];

  // WordPress image size classes that indicate full/large resolution.
  // Excludes size-medium / size-thumbnail (sidebars, related posts).
  static const _fullSizeClasses = ['size-full', 'size-large'];

  final Dio _dio;

  GenericArticleDownloaderService({Dio? dio})
      : _dio = dio ??
            Dio(BaseOptions(
              connectTimeout: const Duration(seconds: 15),
              receiveTimeout: const Duration(seconds: 30),
              headers: {
                'User-Agent': _ua,
                'Accept-Language': 'en-US,en;q=0.9',
              },
            ));

  // ── Structural detection ─────────────────────────────────────────────────

  /// Returns true if [html] contains a recognisable article content area
  /// with at least one candidate image. No domain check — purely structural.
  static bool canHandle(String html) {
    final doc = html_parser.parse(html);
    final content = _findContent(doc);
    if (content == null) return false;
    return _extractImages(content).isNotEmpty;
  }

  // ── Fetch items ──────────────────────────────────────────────────────────

  /// Fetches [url], checks structure, and returns all article images.
  /// Throws a descriptive [Exception] if the page has no usable content.
  Future<List<MediaItem>> fetchItems(String url) async {
    final cleanUrl = url.split('?').first.split('#').first;
    debugPrint('[Article] URL: $cleanUrl');

    final resp = await _dio.get<String>(cleanUrl);
    if (resp.statusCode != 200 || resp.data == null) {
      throw Exception('Failed to load page (${resp.statusCode})');
    }

    return _parsePage(resp.data!, cleanUrl);
  }

  List<MediaItem> _parsePage(String html, String pageUrl) {
    final document = html_parser.parse(html);

    // Post timestamp from <time datetime="..."> if present
    int? postTimestamp;
    final timeEl = document.querySelector('time[datetime]');
    if (timeEl != null) {
      final dt = DateTime.tryParse(timeEl.attributes['datetime'] ?? '');
      if (dt != null) postTimestamp = dt.millisecondsSinceEpoch ~/ 1000;
    }

    // Derive a display name from the hostname
    final host = Uri.tryParse(pageUrl)?.host ?? 'article';
    final siteName = host.replaceFirst('www.', '').replaceAll('.', '_');

    final content = _findContent(document);
    if (content == null) {
      throw Exception(
        'No article content found on this page.\n'
        'The page structure is not recognised.',
      );
    }

    final srcs = _extractImages(content);
    if (srcs.isEmpty) {
      throw Exception(
        'No downloadable images found in this article.\n'
        'The article may contain only video or text.',
      );
    }

    final items = <MediaItem>[];
    for (var i = 0; i < srcs.length; i++) {
      items.add(MediaItem(
        id: '$i',
        mediaUrl: srcs[i],
        thumbnailUrl: srcs[i],
        type: MediaItemType.image,
        username: siteName,
        itemIndex: i + 1,
        postTimestamp: postTimestamp,
      ));
    }

    debugPrint('[Article] Found ${items.length} images');
    return items;
  }

  // ── Private helpers ──────────────────────────────────────────────────────

  static dom.Element? _findContent(dom.Document doc) {
    for (final sel in _contentSelectors) {
      final el = doc.querySelector(sel);
      if (el != null) return el;
    }
    return null;
  }

  /// Returns deduplicated full-resolution image URLs from [content].
  ///
  /// Preference order:
  ///   1. `img` with a WordPress full-size class (`size-full`, `size-large`)
  ///   2. Any `img` whose `src` comes from a `wp-content/uploads` path
  ///
  /// Falls back to (2) only if (1) yields nothing — avoids pulling in
  /// thumbnails / sidebar images when explicit size classes are present.
  static List<String> _extractImages(dom.Element content) {
    // Try WordPress full-size classes first
    for (final cls in _fullSizeClasses) {
      final imgs = content
          .querySelectorAll('img.$cls')
          .map((el) => el.attributes['src'] ?? '')
          .where((src) => src.startsWith('http'))
          .toList();
      if (imgs.isNotEmpty) return _dedupe(imgs);
    }

    // Fallback: any img with an uploads path (works for non-WP sites too)
    final imgs = content
        .querySelectorAll('img')
        .map((el) => el.attributes['src'] ?? '')
        .where((src) => src.startsWith('http') && src.contains('/uploads/'))
        .toList();
    return _dedupe(imgs);
  }

  static List<String> _dedupe(List<String> urls) =>
      urls.toSet().toList();
}

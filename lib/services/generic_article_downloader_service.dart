import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:html/dom.dart' as dom;
import '../models/media_item.dart';

/// General-purpose article / forum image downloader.
///
/// Works for any webpage — detection is structural (inspects HTML) rather than
/// domain-based. Tuned for modern news sites and forums:
///   * lazy-loaded images (`data-src`, `data-original`, `data-lazy-src`)
///   * responsive `srcset` (picks the highest-resolution candidate)
///   * `<picture><source srcset>` and `<figure><img>`
///   * relative URLs resolved against the page URL
///   * og:image as a seed
///   * junk filtering (icons, avatars, logos, spacers, tracking pixels, SVG)
///
/// Extraction strategy:
///   1. Fetch the page with a desktop browser user-agent.
///   2. Pick the best article-content container; fall back to <body>.
///   3. Collect every candidate image, choosing the largest variant available.
///   4. Drop obvious non-content images and de-duplicate.
class GenericArticleDownloaderService {
  static const _ua =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

  // CSS selectors tried in order — first match wins. Covers common news themes,
  // WordPress, and generic semantic markup.
  static const _contentSelectors = [
    '.td-post-content',          // Newspaper / tagDiv theme
    '.entry-content',            // Genesis, Twenty-*, most WP themes
    '.post-content',             // common custom themes
    '.article-content',
    '.article-body',
    '.story-body',
    '.post__content',
    '[itemprop="articleBody"]',
    'article',                   // HTML5 semantic
    'main',                      // last structural fallback before <body>
  ];

  // src/href substrings that mark an image as chrome rather than content.
  static const _junkMarkers = [
    'avatar', 'gravatar', 'logo', 'icon', 'favicon', 'sprite', 'emoji',
    'placeholder', 'spacer', 'blank.', '1x1', 'pixel', 'tracking', 'beacon',
    'loading', 'spinner', 'data:image',
  ];

  final Dio _dio;

  GenericArticleDownloaderService({Dio? dio})
      : _dio = dio ??
            Dio(BaseOptions(
              connectTimeout: const Duration(seconds: 15),
              receiveTimeout: const Duration(seconds: 30),
              followRedirects: true,
              maxRedirects: 8,
              headers: {
                'User-Agent': _ua,
                'Accept-Language': 'en-US,en;q=0.9',
                'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
              },
            ));

  // ── Structural detection ─────────────────────────────────────────────────

  /// Returns true if [html] yields at least one usable content image.
  /// No domain check — purely structural. (Kept for callers that probe HTML
  /// before deciding how to route; [fetchItems] does its own extraction.)
  static bool canHandle(String html, {String baseUrl = ''}) {
    final doc = html_parser.parse(html);
    final scope = _findContent(doc) ?? doc.body ?? doc.documentElement!;
    return _extractImages(scope, baseUrl).isNotEmpty;
  }

  // ── Fetch items ──────────────────────────────────────────────────────────

  /// Fetches [url], checks structure, and returns all article images.
  /// Throws a descriptive [Exception] if the page has no usable images.
  Future<List<MediaItem>> fetchItems(String url) async {
    final cleanUrl = url.split('#').first;
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

    // Prefer the article container, but fall back to the whole body so news
    // layouts that don't use a recognised content class still work.
    final scope =
        _findContent(document) ?? document.body ?? document.documentElement!;

    final srcs = _extractImages(scope, pageUrl);

    // Seed with og:image so the lead photo is never missed.
    final og = document
        .querySelector('meta[property="og:image"]')
        ?.attributes['content'];
    final ordered = <String>[];
    final seen = <String>{};
    void add(String? s) {
      if (s == null) return;
      final r = _resolveUrl(s, pageUrl);
      if (r != null && seen.add(_dedupeKey(r))) ordered.add(r);
    }

    add(og);
    for (final s in srcs) {
      add(s);
    }

    if (ordered.isEmpty) {
      throw Exception(
        'No downloadable images found on this page.\n'
        'It may be text/video only, or the images load via a script this app '
        'cannot run.',
      );
    }

    debugPrint('[Article] Found ${ordered.length} images on $host');
    return [
      for (var i = 0; i < ordered.length; i++)
        MediaItem(
          id: '$i',
          mediaUrl: ordered[i],
          thumbnailUrl: ordered[i],
          type: MediaItemType.image,
          username: siteName,
          itemIndex: i + 1,
          postTimestamp: postTimestamp,
        ),
    ];
  }

  // ── Private helpers ──────────────────────────────────────────────────────

  static dom.Element? _findContent(dom.Document doc) {
    for (final sel in _contentSelectors) {
      final el = doc.querySelector(sel);
      if (el != null) return el;
    }
    return null;
  }

  /// Returns ordered, raw (possibly relative) image URLs from [scope].
  /// Considers <img> (with lazy-load attrs + srcset) and <picture><source>.
  static List<String> _extractImages(dom.Element scope, String baseUrl) {
    final out = <String>[];

    for (final img in scope.querySelectorAll('img')) {
      // Skip tiny declared sizes (icons/spacers) when width/height are present.
      final w = int.tryParse(img.attributes['width'] ?? '');
      final h = int.tryParse(img.attributes['height'] ?? '');
      if ((w != null && w < 150) || (h != null && h < 150)) continue;

      final best = _bestImgSrc(img);
      if (best != null && !_isJunk(best)) out.add(best);
    }

    // <picture><source srcset="..."> — used by many news CMSes for hi-res.
    for (final source in scope.querySelectorAll('picture source[srcset]')) {
      final best = _largestFromSrcset(source.attributes['srcset'] ?? '');
      if (best != null && !_isJunk(best)) out.add(best);
    }

    return out;
  }

  /// Best available URL for one <img>: prefer a lazy-load data-* attr, then the
  /// largest srcset candidate, then plain src.
  static String? _bestImgSrc(dom.Element img) {
    final a = img.attributes;
    // Lazy-load attributes hold the real image; src is often a placeholder.
    for (final key in ['data-original', 'data-src', 'data-lazy-src', 'data-url']) {
      final v = a[key];
      if (v != null && v.trim().isNotEmpty) return v.trim();
    }
    final fromSet = _largestFromSrcset(
        a['data-srcset'] ?? a['srcset'] ?? '');
    if (fromSet != null) return fromSet;
    final src = a['src'];
    if (src != null && src.trim().isNotEmpty) return src.trim();
    return null;
  }

  /// Picks the highest-resolution URL from a `srcset` value.
  /// Handles both width ("url 1080w") and density ("url 2x") descriptors.
  static String? _largestFromSrcset(String srcset) {
    if (srcset.trim().isEmpty) return null;
    String? best;
    num bestScore = -1;
    for (final part in srcset.split(',')) {
      final tokens = part.trim().split(RegExp(r'\s+'));
      if (tokens.isEmpty || tokens.first.isEmpty) continue;
      final url = tokens.first;
      num score = 1;
      if (tokens.length > 1) {
        final d = tokens[1];
        final n = num.tryParse(d.replaceAll(RegExp(r'[wx]$'), ''));
        if (n != null) score = n;
      }
      if (score > bestScore) {
        bestScore = score;
        best = url;
      }
    }
    return best;
  }

  static bool _isJunk(String url) {
    final lower = url.toLowerCase();
    if (lower.endsWith('.svg')) return true;
    return _junkMarkers.any(lower.contains);
  }

  /// Resolves a possibly-relative/protocol-relative URL against [pageUrl].
  static String? _resolveUrl(String raw, String pageUrl) {
    var s = raw.trim();
    if (s.isEmpty) return null;
    if (s.startsWith('//')) {
      final scheme = Uri.tryParse(pageUrl)?.scheme ?? 'https';
      return '$scheme:$s';
    }
    if (s.startsWith('http://') || s.startsWith('https://')) return s;
    final base = Uri.tryParse(pageUrl);
    if (base == null) return null;
    try {
      return base.resolve(s).toString();
    } catch (_) {
      return null;
    }
  }

  /// De-dupe key that collapses the same image requested with different query
  /// params (common with CDN resize params) while keeping distinct paths apart.
  static String _dedupeKey(String url) => url.split('?').first;
}

import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:html/dom.dart' as dom;
import '../models/media_item.dart';
import 'image_junk_filter.dart';
import 'js_challenge_detector.dart';
import 'webview_user_agent.dart';

/// Internal signal thrown by [GenericArticleDownloaderService._fetchPlain]
/// when a 403 response's body was confirmed (via [looksLikeJsChallenge]) to
/// be the anti-bot challenge page, carrying that body so
/// [GenericArticleDownloaderService.fetchItems] can hand it to
/// [GenericArticleDownloaderService.renderedHtmlFallback] instead of parsing
/// it as real content.
class _JsChallengeResponse implements Exception {
  const _JsChallengeResponse(this.html);
  final String html;
}

/// General-purpose article / forum image AND video downloader.
///
/// Works for any webpage — detection is structural (inspects HTML) rather than
/// domain-based. Tuned for modern news sites and forums:
///   * lazy-loaded images (`data-src`, `data-original`, `data-lazy-src`)
///   * responsive `srcset` (picks the highest-resolution candidate)
///   * `<picture><source srcset>` and `<figure><img>`
///   * `og:video(:url)` meta + `<video>`/`<source>` (poster frame becomes a
///     thumbnail, never a separate downloadable item)
///   * relative URLs resolved against the page URL
///   * og:image as a seed
///   * junk filtering (icons, avatars, logos, spacers, tracking pixels, SVG)
///
/// Tumblr has no dedicated scraper/service of its own; its posts are handled
/// entirely by this class, via two paths (see [_parseTumblrState] and
/// [_parsePage]):
///   1. PRIMARY — Tumblr's NPF (Neue Post Format) JSON, embedded in every
///      page as `<script id="___INITIAL_STATE___">`. The only path that
///      works for community-labelled (mature/sensitive) posts, which serve
///      an empty client-rendered shell to the DOM path below.
///   2. FALLBACK — structural DOM scraping, same as any other site.
///
/// Extraction strategy:
///   1. Fetch the page with a mobile Chrome user-agent (see [kRealChromeMobileUA]
///      — a desktop UA gets a 403 anti-bot challenge from some sites, e.g.
///      Tumblr, that a mobile UA sails through with a plain 200).
///   2. Pick the best article-content container; fall back to <body>.
///   3. Collect every candidate image, choosing the largest variant available.
///   4. Drop obvious non-content images and de-duplicate.
class GenericArticleDownloaderService {

  // CSS selectors tried in order — first match wins. Covers common news themes,
  // WordPress, generic semantic markup, and Tumblr's DOM-fallback markup (see
  // the class doc comment — Tumblr's primary path is the NPF JSON parser,
  // not this selector list).
  static const _contentSelectors = [
    '.td-post-content',          // Newspaper / tagDiv theme
    '.entry-content',            // Genesis, Twenty-*, most WP themes
    '.post-content',             // common custom themes
    '.article-content',
    '.article-body',
    '.story-body',
    '.post__content',
    '[itemprop="articleBody"]',
    '[data-post-id]',            // Tumblr post wrapper (React/lazy-loaded themes)
    '.post',                     // Tumblr's own generic post container
    'article',                   // HTML5 semantic
    'main',                      // last structural fallback before <body>
  ];

  final Dio _dio;

  /// Optional callback that re-fetches a URL's HTML through a real WebView,
  /// letting a JS-based anti-bot challenge (see [looksLikeJsChallenge]) run
  /// and clear naturally. Supplied by the UI layer (see selection_screen.dart
  /// / webview_html_fetcher.dart) — this service stays free of Flutter UI
  /// imports and unit-testable, since it never touches a BuildContext itself.
  final Future<String> Function(String url)? renderedHtmlFallback;

  GenericArticleDownloaderService({Dio? dio, this.renderedHtmlFallback})
      : _dio = dio ??
            Dio(BaseOptions(
              connectTimeout: const Duration(seconds: 15),
              receiveTimeout: const Duration(seconds: 30),
              followRedirects: true,
              maxRedirects: 8,
              headers: {
                'User-Agent': kRealChromeMobileUA,
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

  /// Fetches [url] and returns every downloadable image/video found on it —
  /// via Tumblr's NPF JSON when present (see [_parseTumblrState]), else via
  /// structural DOM scraping. Throws a descriptive [Exception] if the page
  /// has no usable media.
  ///
  /// Fast path: a plain Dio GET (no JS). If that comes back blocked — a 403
  /// confirmed as an anti-bot challenge, or a 200 whose body is itself a JS
  /// anti-bot challenge page — and [renderedHtmlFallback] was supplied,
  /// re-fetch through it (a real WebView that lets the challenge's own JS run
  /// and clear) and parse that HTML instead. A genuine 403 (paywall,
  /// geo-block, IP ban) is NOT a challenge and propagates as a clear
  /// "Failed to load page (403)" error instead of being parsed as content.
  Future<List<MediaItem>> fetchItems(String url) async {
    final cleanUrl = url.split('#').first;
    debugPrint('[Article] URL: $cleanUrl');

    String html;
    try {
      html = await _fetchPlain(cleanUrl);
    } on _JsChallengeResponse {
      // 403 whose body was confirmed (via looksLikeJsChallenge) to be the
      // anti-bot challenge page itself, not a genuine access failure.
      html = await _resolveChallenge(cleanUrl);
      return _parsePage(html, cleanUrl);
    }

    // Tumblr posts with a community label (mature/sensitive content) serve a
    // bare client-rendered shell on a normal 200 — no <img>, no og:image, and
    // a useless "Tumblr" <title> — so looksLikeJsChallenge would never flag
    // it and the DOM path below would find nothing. The real post is still
    // embedded as NPF JSON in a #___INITIAL_STATE___ script tag, so that is
    // tried FIRST and unconditionally, ahead of the challenge check, rather
    // than relying on any signal in the (possibly empty) shell HTML.
    final npf = _parseTumblrState(html, cleanUrl);
    if (npf != null && npf.isNotEmpty) return npf;

    if (looksLikeJsChallenge(html, wasForbidden: false)) {
      html = await _resolveChallenge(cleanUrl);
    }

    return _parsePage(html, cleanUrl);
  }

  /// Runs [renderedHtmlFallback] for a page identified as a JS anti-bot
  /// challenge, or throws a descriptive error if no fallback was supplied.
  Future<String> _resolveChallenge(String cleanUrl) async {
    if (renderedHtmlFallback == null) {
      throw Exception(
        'This page is protected by an anti-bot / JS challenge that this '
        'app could not clear automatically.',
      );
    }
    debugPrint('[Article] Blocked by anti-bot challenge — trying WebView fallback');
    return renderedHtmlFallback!(cleanUrl);
  }

  /// Plain (no-JS) fetch. Returns the body on a normal 200. On a 403 —
  /// Automattic's hashcash challenge (and similar gates) return 403 with the
  /// challenge page as the body — the body is checked via
  /// [looksLikeJsChallenge] (with `wasForbidden: true`, so its WEAK signals
  /// are trusted) before being treated as a challenge; if that check fails,
  /// or the body isn't a String at all (e.g. a JSON error payload), this is a
  /// genuine 403 rather than an anti-bot block, and throws the original,
  /// accurate "Failed to load page (403)" error so the caller doesn't
  /// silently parse it as content. Any other HTTP failure rethrows.
  Future<String> _fetchPlain(String url) async {
    try {
      final resp = await _dio.get<String>(url);
      if (resp.statusCode != 200 || resp.data == null) {
        throw Exception('Failed to load page (${resp.statusCode})');
      }
      return resp.data!;
    } on DioException catch (e) {
      if (e.response?.statusCode == 403) {
        final data = e.response?.data;
        if (data is String && looksLikeJsChallenge(data, wasForbidden: true)) {
          debugPrint('[Article] 403 — confirmed anti-bot challenge');
          throw _JsChallengeResponse(data);
        }
        debugPrint('[Article] 403 — not a JS challenge, treating as a failed load');
        throw Exception('Failed to load page (403)');
      }
      rethrow;
    }
  }

  List<MediaItem> _parsePage(String html, String pageUrl) {
    // Covers HTML that reaches here via the WebView challenge fallback or the
    // confirmed-403-challenge branch — both skip fetchItems' own NPF check,
    // and Tumblr's rendered/challenge-cleared page still carries the same
    // #___INITIAL_STATE___ script tag. Re-parsing an HTML string that turns
    // out not to be a Tumblr NPF page is a cheap no-op (see
    // _parseTumblrState), so this is safe to try unconditionally.
    final npf = _parseTumblrState(html, pageUrl);
    if (npf != null && npf.isNotEmpty) return npf;

    final document = html_parser.parse(html);

    // Post timestamp from <time datetime="..."> if present
    int? postTimestamp;
    final timeEl = document.querySelector('time[datetime]');
    if (timeEl != null) {
      final dt = DateTime.tryParse(timeEl.attributes['datetime'] ?? '');
      if (dt != null) postTimestamp = dt.millisecondsSinceEpoch ~/ 1000;
    }

    // Derive a display name from the hostname, with a Tumblr-specific
    // override — see _siteName.
    final host = Uri.tryParse(pageUrl)?.host ?? 'article';
    final siteName = _siteName(pageUrl);

    // Prefer the article container, but fall back to the whole body so news
    // layouts that don't use a recognised content class still work.
    final scope =
        _findContent(document) ?? document.body ?? document.documentElement!;

    // Videos: og:video(:url) meta (checked against the whole document — it
    // lives in <head>, and acts as a safety net if a theme renders the
    // player outside the matched content container) + <video>/<source>
    // elements WITHIN [scope] only — matching _extractImages' scoping so a
    // header autoplay loop, sidebar promo, or video ad elsewhere on the page
    // is never picked up as post content. Their poster frame becomes a
    // thumbnail, never a separate downloadable item — see _extractVideos and
    // _dedupeKey (which collapses a video and its poster to the same key on
    // Tumblr's media CDN).
    final videos = _extractVideos(document, scope, pageUrl);

    final srcs = _extractImages(scope, pageUrl);

    // Seed with og:image so the lead photo is never missed. `seen` starts
    // pre-loaded with every video's own URL + poster key so a video post's
    // poster frame (also commonly served as og:image and/or a plain <img>)
    // is never ALSO emitted as a separate downloadable image.
    final ogRaw = document
        .querySelector('meta[property="og:image"]')
        ?.attributes['content'];
    final og = ogRaw != null ? _resolveUrl(ogRaw, pageUrl) : null;
    final ordered = <String>[];
    final seen = <String>{
      for (final v in videos) _dedupeKey(v.url),
      for (final v in videos)
        if (v.poster != null) _dedupeKey(v.poster!),
    };
    void add(String? r) {
      if (r != null && seen.add(_dedupeKey(r))) ordered.add(r);
    }

    add(og);
    for (final s in srcs) {
      add(_resolveUrl(s, pageUrl));
    }

    if (ordered.isEmpty && videos.isEmpty) {
      throw Exception(
        'No downloadable media found on this page.\n'
        'It may be text-only, or the media loads via a script this app '
        'cannot run.',
      );
    }

    debugPrint(
        '[Article] Found ${videos.length} videos, ${ordered.length} images on $host');

    final items = <MediaItem>[];
    var index = 1;
    for (final v in videos) {
      items.add(MediaItem(
        id: '${index - 1}',
        mediaUrl: v.url,
        thumbnailUrl: v.poster ?? og,
        type: MediaItemType.video,
        username: siteName,
        itemIndex: index,
        postTimestamp: postTimestamp,
      ));
      index++;
    }
    for (final s in ordered) {
      items.add(MediaItem(
        id: '${index - 1}',
        mediaUrl: s,
        thumbnailUrl: s,
        type: MediaItemType.image,
        username: siteName,
        itemIndex: index,
        postTimestamp: postTimestamp,
      ));
      index++;
    }
    return items;
  }

  /// Display name for [pageUrl]'s host, with a Tumblr-specific override.
  /// Every Tumblr blog otherwise collapses to the same "tumblr_com" name
  /// because the host is always (www.)tumblr.com (blog name lives in the
  /// path: tumblr.com/<blog>/<id>) or <blog>.tumblr.com (blog name is the
  /// subdomain: <blog>.tumblr.com/post/<id>/...). Falls back to the plain
  /// host-derived name — unchanged — for custom domains and every
  /// non-Tumblr site.
  static String _siteName(String pageUrl) {
    final uri = Uri.tryParse(pageUrl);
    final host = uri?.host ?? 'article';
    final bareHost = host.replaceFirst('www.', '');

    if (bareHost == 'tumblr.com' && uri != null) {
      final segs = uri.pathSegments.where((s) => s.isNotEmpty).toList();
      if (segs.isNotEmpty) {
        // Normally tumblr.com/<blog>/<id> — <blog> is segs.first. But some
        // Tumblr URL shapes put extra path segments before the blog name
        // (tumblr.com/blog/view/<blog>/<id>, tumblr.com/dashboard/blog/<blog>/<id>);
        // when a numeric post id is found, the blog name is the segment
        // immediately before it rather than always the first segment.
        final idIndex = segs.indexWhere((s) => _numericIdRe.hasMatch(s));
        if (idIndex > 0) return segs[idIndex - 1];
        return segs.first;
      }
    } else if (bareHost.endsWith('.tumblr.com')) {
      final blog =
          bareHost.substring(0, bareHost.length - '.tumblr.com'.length);
      if (blog.isNotEmpty) return blog;
    }

    return bareHost.replaceAll('.', '_');
  }

  /// Video URLs + their poster/thumbnail frame from <meta property="og:video">
  /// / "og:video:url" (checked against [document] — always in <head>) and
  /// <video>/<video><source> elements found within [scope] (the same content
  /// container [_extractImages] is confined to, so a header/sidebar/ad video
  /// elsewhere on the page is never mistaken for post content). The poster
  /// is carried alongside the video (as [MediaItem.thumbnailUrl] via
  /// [_parsePage]) rather than returned as a separate downloadable item —
  /// otherwise a video post yields both the .mov/.mp4 AND the identical
  /// poster frame as a .jpg.
  static List<({String url, String? poster})> _extractVideos(
      dom.Document document, dom.Element scope, String pageUrl) {
    final out = <({String url, String? poster})>[];
    final seen = <String>{};

    void add(String? rawUrl, String? rawPoster) {
      if (rawUrl == null) return;
      final url = _resolveUrl(rawUrl, pageUrl);
      if (url == null || !seen.add(_dedupeKey(url))) return;
      final poster =
          rawPoster != null ? _resolveUrl(rawPoster, pageUrl) : null;
      out.add((url: url, poster: poster));
    }

    for (final video in scope.querySelectorAll('video')) {
      final poster = video.attributes['poster'];
      final directSrc = video.attributes['src'];
      if (directSrc != null && directSrc.trim().isNotEmpty) {
        add(directSrc, poster);
      }
      for (final source in video.querySelectorAll('source')) {
        final type = source.attributes['type'] ?? '';
        if (type.isNotEmpty && !type.startsWith('video/')) continue;
        add(source.attributes['src'], poster);
      }
    }

    // og:video / og:video:url meta as a seed — some pages (including
    // Tumblr's server-rendered fallback markup) expose the video only via
    // meta tags, with no <video> element at all.
    final ogVideo = document
            .querySelector('meta[property="og:video:url"]')
            ?.attributes['content'] ??
        document
            .querySelector('meta[property="og:video"]')
            ?.attributes['content'];
    if (ogVideo != null) {
      final ogImage = document
          .querySelector('meta[property="og:image"]')
          ?.attributes['content'];
      add(ogVideo, ogImage);
    }

    return out;
  }

  // ── Tumblr NPF (Neue Post Format) JSON extraction ───────────────────────
  //
  // Tumblr's React app embeds the full initial page state — including every
  // post's structured content blocks — as JSON in a
  // <script type="application/json" id="___INITIAL_STATE___"> tag (a plain
  // JSON blob, not a `window.___INITIAL_STATE___ = …` assignment). This is
  // the ONLY reliable source for posts Tumblr flags with a community label
  // (mature/sensitive content): those serve a bare client-rendered shell
  // with no <img>, no og:image, and a useless "Tumblr" <title> — nothing for
  // the DOM scraper below (or even the WebView, which shows a "mature
  // content" interstitial instead of the post) to find. It is tried BEFORE
  // the DOM path for every Tumblr page, not just the community-labelled
  // ones, since it is strictly more accurate when present (native
  // resolution, real blog name, real timestamp) and falls through cleanly
  // (returns null) for any page that doesn't have it.

  /// Parses the `#___INITIAL_STATE___` NPF JSON blob in [html], if present,
  /// into the target post's [MediaItem]s. Returns null — never throws — when
  /// the script tag is absent, isn't valid JSON, or doesn't have the
  /// expected shape, so callers can unconditionally fall back to DOM
  /// scraping. Returns an empty list only if the post was found but truly
  /// has no downloadable image/video content blocks.
  static List<MediaItem>? _parseTumblrState(String html, String pageUrl) {
    // Cheap pre-check so the (much more common) non-Tumblr / no-NPF path
    // never pays for a full HTML parse just to discover the script tag isn't
    // there — this function runs up to twice per fetch (fetchItems + _parsePage).
    if (!html.contains('___INITIAL_STATE___')) return null;
    try {
      final document = html_parser.parse(html);
      final scriptEl = document.querySelector('script#___INITIAL_STATE___');
      final raw = scriptEl?.text;
      if (raw == null || raw.trim().isEmpty) return null;

      final state = jsonDecode(raw);
      if (state is! Map) return null;
      final peeprRoute = state['PeeprRoute'];
      if (peeprRoute is! Map) return null;
      final initialTimeline = peeprRoute['initialTimeline'];
      if (initialTimeline is! Map) return null;
      final objects = initialTimeline['objects'];
      if (objects is! List || objects.isEmpty) return null;

      final targetId = _postIdFromUrl(pageUrl);
      Map? post;
      if (targetId != null) {
        for (final o in objects) {
          if (o is Map && o['idString']?.toString() == targetId) {
            post = o;
            break;
          }
        }
        // The URL named a specific post id and it isn't in this blob — do
        // NOT silently fall back to objects.first (a DIFFERENT, unrelated
        // post would be downloaded instead). Return null so the DOM path
        // gets a chance instead.
        if (post == null) return null;
      } else {
        post = objects.first is Map ? objects.first as Map : null;
      }
      if (post == null) return null;

      // A reblog can have its own non-empty `content` that is text-only (a
      // caption/commentary with no media blocks of its own) — checking only
      // "is content empty" misses that case and never looks at the trail, so
      // fall back to the trail whenever `content` has no image/video block,
      // not only when it's empty outright.
      var content = post['content'];
      final hasOwnMedia = content is List &&
          content.any((b) =>
              b is Map && (b['type'] == 'image' || b['type'] == 'video'));
      if (!hasOwnMedia) {
        // The media lives on the last (most recent) entry of the reblog trail.
        final trail = post['trail'];
        if (trail is List && trail.isNotEmpty) {
          final last = trail.last;
          if (last is Map && last['content'] is List) {
            content = last['content'] as List;
          }
        }
      }
      if (content is! List || content.isEmpty) return null;

      final username = post['blogName']?.toString() ?? _siteName(pageUrl);
      final ts = post['timestamp'];
      final postTimestamp =
          ts is num ? ts.toInt() : int.tryParse(ts?.toString() ?? '');

      final items = <MediaItem>[];
      var videoCount = 0;
      var imageCount = 0;
      for (final block in content) {
        if (block is! Map) continue;
        final type = block['type'];
        if (type == 'video') {
          // Per NPF, a missing `provider` means a native Tumblr-hosted
          // video (only explicit non-Tumblr providers — e.g. embedded
          // YouTube — are not directly downloadable and get skipped).
          final provider = block['provider'];
          if (provider != null && provider != 'tumblr') {
            continue;
          }
          final media = block['media'];
          final videoUrl = (media is Map ? media['url'] : null)?.toString() ??
              block['url']?.toString();
          if (videoUrl == null) continue;
          String? poster;
          final posterList = block['poster'];
          if (posterList is List && posterList.isNotEmpty) {
            final first = posterList.first;
            if (first is Map) poster = first['url']?.toString();
          }
          videoCount++;
          items.add(MediaItem(
            id: '${items.length}',
            mediaUrl: videoUrl,
            thumbnailUrl: poster,
            type: MediaItemType.video,
            username: username,
            itemIndex: items.length + 1,
            postTimestamp: postTimestamp,
          ));
        } else if (type == 'image') {
          final variants = block['media'];
          if (variants is! List || variants.isEmpty) continue;
          Map? best;
          num bestWidth = -1;
          for (final v in variants) {
            if (v is! Map) continue;
            if (v['cropped'] == true) continue;
            if (v['hasOriginalDimensions'] == true) {
              best = v;
              break;
            }
            final w = v['width'];
            if (w is num && w > bestWidth) {
              bestWidth = w;
              best = v;
            }
          }
          final imageUrl = best?['url']?.toString();
          if (imageUrl == null) continue;
          imageCount++;
          items.add(MediaItem(
            id: '${items.length}',
            mediaUrl: imageUrl,
            thumbnailUrl: imageUrl,
            type: MediaItemType.image,
            username: username,
            itemIndex: items.length + 1,
            postTimestamp: postTimestamp,
          ));
        }
      }

      debugPrint(
          '[Article] Tumblr NPF: $imageCount images, $videoCount videos');
      return items;
    } catch (e) {
      // Malformed/unexpected JSON shape — fall back to DOM scraping rather
      // than surfacing a parse error for what may just be a non-Tumblr page.
      debugPrint('[Article] Tumblr NPF parse failed, falling back: $e');
      return null;
    }
  }

  static final RegExp _numericIdRe = RegExp(r'^\d{10,}$');

  /// Extracts the numeric post id from a Tumblr URL — either
  /// `tumblr.com/<blog>/<id>` or `<blog>.tumblr.com/post/<id>/<slug>` — as
  /// the first all-digit path segment of at least 10 characters (Tumblr post
  /// ids are large snowflake-style integers, long enough that this can't
  /// collide with a blog name or the literal "post" segment). Returns null
  /// if the URL has no such segment.
  static String? _postIdFromUrl(String pageUrl) {
    final uri = Uri.tryParse(pageUrl);
    if (uri == null) return null;
    for (final seg in uri.pathSegments) {
      if (_numericIdRe.hasMatch(seg)) return seg;
    }
    return null;
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
      final best = _bestImgSrc(img);
      if (best == null) continue;
      if (_looksTinyBySize(img, best)) continue;
      if (isJunkElement(
        url: best,
        className: img.attributes['class'],
        id: img.attributes['id'],
        alt: img.attributes['alt'],
      )) {
        continue;
      }
      out.add(best);
    }

    // <picture><source srcset="..."> — used by many news CMSes for hi-res.
    for (final source in scope.querySelectorAll('picture source[srcset]')) {
      final best = _largestFromSrcset(source.attributes['srcset'] ?? '');
      if (best != null && !isJunkUrl(best)) out.add(best);
    }

    return out;
  }

  // URL patterns that hint at a small CDN-served thumbnail size, used as a
  // last-resort size signal when neither width/height attributes nor an
  // inline style declare a size (Tumblr's React/lazy-loaded markup usually
  // omits both). "75x75", "s150x150", "_128." style path segments and
  // "?w=48"/"&width=32" resize query params are the common conventions.
  static final RegExp _urlDimensionRe = RegExp(r'(\d{2,4})x(\d{2,4})');
  static final RegExp _urlQuerySizeRe =
      RegExp(r'[?&](?:w|width|s|size)=(\d{2,4})(?:&|$)', caseSensitive: false);
  static final RegExp _styleDimensionRe =
      RegExp(r'(width|height)\s*:\s*(\d{1,4})px', caseSensitive: false);

  /// Returns true only when a size signal — declared width/height attributes,
  /// an inline `style` width/height, or a small-size hint baked into the
  /// resolved URL — positively indicates a tiny (icon/avatar) image.
  ///
  /// When NO signal is available at all (the width/height attributes are
  /// absent — normal for Tumblr's React/lazy-loaded markup — and there is no
  /// inline style or URL size hint either), this returns false: an unknown
  /// size must never be treated as "small". Dropping a real content image on
  /// a false positive here loses user content, which is worse than letting
  /// an extra avatar through for [isJunkElement] to catch instead.
  static bool _looksTinyBySize(dom.Element img, String resolvedSrc) {
    final w = int.tryParse(img.attributes['width'] ?? '');
    final h = int.tryParse(img.attributes['height'] ?? '');
    if (w != null && w < 150) return true;
    if (h != null && h < 150) return true;
    if (w != null || h != null) return false; // one dimension known, >= 150

    final style = img.attributes['style'];
    if (style != null && style.isNotEmpty) {
      for (final m in _styleDimensionRe.allMatches(style)) {
        final n = int.tryParse(m.group(2)!);
        if (n != null && n < 150) return true;
      }
    }

    final qm = _urlQuerySizeRe.firstMatch(resolvedSrc);
    if (qm != null) {
      final n = int.tryParse(qm.group(1)!);
      if (n != null && n < 150) return true;
    }
    final dm = _urlDimensionRe.firstMatch(resolvedSrc);
    if (dm != null) {
      final dw = int.tryParse(dm.group(1)!);
      final dh = int.tryParse(dm.group(2)!);
      if (dw != null && dh != null && dw < 150 && dh < 150) return true;
    }

    // Nothing knowable — keep accepting; see doc comment above.
    return false;
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

  // Tumblr media path shape: /<hash1>/<hash2>/s<WxH>[_fN]/<filename>.<ext> —
  // resolution lives in this path segment rather than the query string.
  static final RegExp _tumblrSizeSegmentRe =
      RegExp(r'/s\d+(?:x\d+)?(?:_f\d+)?/');

  /// De-dupe key that collapses the same image requested with different query
  /// params (common with CDN resize params) while keeping distinct paths
  /// apart.
  ///
  /// For Tumblr's media CDN (`*.media.tumblr.com`) this also strips the
  /// resolution path segment AND everything after it (host and filename
  /// included): both the CDN shard host (44.media vs 64.media) and the
  /// filename hash after the size segment vary between renditions of the
  /// SAME underlying asset — e.g. a video and its auto-extracted poster
  /// frame, or the same photo served at two sizes — so keying on just the
  /// pre-size path collapses them into one item instead of downloading both.
  static String _dedupeKey(String url) {
    final noQuery = url.split('?').first;
    final uri = Uri.tryParse(noQuery);
    if (uri != null && uri.host.endsWith('tumblr.com')) {
      final m = _tumblrSizeSegmentRe.firstMatch(uri.path);
      if (m != null) return uri.path.substring(0, m.start);
    }
    return noQuery;
  }
}

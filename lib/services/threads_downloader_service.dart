import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:html/parser.dart' as html_parser;
import '../models/media_item.dart';
import 'rate_guard_service.dart';

/// Renders [url] in a real (JS-enabled, cookie-sharing) WebView and returns
/// its HTML plus the final URL it landed on — see
/// `webview_html_fetcher.fetchRenderedHtmlWithUrl`. Injected by the caller
/// (ultimately `selection_screen.dart`, which owns the `BuildContext` and a
/// `cancelled` flag tied to this fetch's lifecycle) rather than this service
/// reaching for a root navigator key itself — an abandoned fetch (the user
/// backed out of `SelectionScreen`) must never pop a full-screen WebView over
/// whatever screen the user is on next. Null when the caller doesn't want to
/// support this (or on platforms without a navigator context available).
typedef ThreadsRenderedFetch = Future<({String html, String? finalUrl})>
    Function(String url);

/// Downloads media from Threads (threads.com / threads.net) posts.
///
/// Strategy waterfall (reordered 2026-09-07 — see below for why):
///   0. `data-sjs` JSON via a Googlebot-UA request — PRIMARY, unauthenticated.
///      Meta's BigPipe payload embeds the full post JSON (carousel/video
///      data, unauthenticated) in `<script type="application/json" data-sjs>`
///      blocks — but FIELD-VERIFIED 2026-09-07 (one curl per UA, same IP)
///      that Meta only server-renders this payload for search-crawler UAs:
///      the desktop Chrome UA gets a client-rendered shell (0 data-sjs post
///      data, and doesn't even redirect a `/share/` link), and
///      facebookexternalhit gets OG tags only (0 data-sjs post data, even
///      after following the redirect) — only a Googlebot UA got the real
///      payload. See the `_crawlerUA` comment. Runs BEFORE every other
///      strategy, including the authenticated API, so a successful parse
///      never touches the Instagram account at all.
///   A1. __NEXT_DATA__ (Next.js SSR) on the Desktop-UA HTML — verified DEAD
///       on 2026-09-07 (0 matches in a live fixture). Kept as a defensive
///       fallback in case Threads reintroduces Next.js SSR for some traffic
///       segment; costs nothing when absent.
///   A2. CDN URL regex on the same HTML — uses Instagram CDN path prefixes
///       (t50.2886-16 = video, t51.2885-15 = post image). Also verified DEAD
///       on 2026-09-07 (0 matches) — Threads no longer uses these path
///       prefixes for this content. Kept as a defensive fallback.
///   B. Threads/Instagram private REST API — authenticated (requires a
///      session), tried only once the unauthenticated strategies above have
///      failed to keep the authenticated, rate-limited surface as a last
///      resort rather than the default path.
///   C. facebookexternalhit UA → OG tag fallback (embed URLs filtered out).
class ThreadsDownloaderService {
  static const _desktopUA =
      'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';

  static const _botUA =
      'facebookexternalhit/1.1 (+http://www.facebook.com/externalhit_uatext.php)';

  // Google's crawler UA. Field-verified 2026-09-07 (one curl per UA, same
  // IP, both the share-link and canonical URL): Meta only server-renders the
  // `data-sjs` post JSON for search-crawler UAs. The desktop Chrome UA
  // (_desktopUA) gets a client-rendered shell (0 `data-sjs` post data, no
  // redirect even on a `/share/` link) and facebookexternalhit (_botUA) gets
  // OG tags only (0 `data-sjs` post data, even after following the redirect
  // to the canonical URL) — only Googlebot's UA got the real payload
  // (35 video_versions, the target post's `code` present) in that test.
  static const _crawlerUA =
      'Mozilla/5.0 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)';

  final Dio _desktopDio;
  final Dio _botDio;
  final Dio _crawlerDio;

  ThreadsDownloaderService()
      : _desktopDio = Dio(BaseOptions(
          connectTimeout: const Duration(seconds: 15),
          receiveTimeout: const Duration(seconds: 30),
          followRedirects: true,
          maxRedirects: 10,
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
          maxRedirects: 10,
          headers: {
            'User-Agent': _botUA,
            'Accept': 'text/html,*/*;q=0.8',
            'Accept-Language': 'en-US,en;q=0.9',
            'Referer': 'https://www.threads.com/',
          },
        )),
        // No Cookie header is ever set on this client (see fetchItems) — the
        // crawler UA must look like a genuinely anonymous search bot, never
        // carrying a session.
        _crawlerDio = Dio(BaseOptions(
          connectTimeout: const Duration(seconds: 15),
          receiveTimeout: const Duration(seconds: 30),
          followRedirects: true,
          maxRedirects: 10,
          headers: {
            'User-Agent': _crawlerUA,
            'Accept': 'text/html,*/*;q=0.8',
            'Accept-Language': 'en-US,en;q=0.9',
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

  /// Normalises a URL to `host+path` for equality comparisons that must
  /// survive http→https and www./non-www. differences — a bare string
  /// compare of full URLs would otherwise log a "resolved short link" (and,
  /// worse, cache a bogus gate/dedup key) for a same-page scheme/host
  /// normalisation that carries no new information. Query string is already
  /// irrelevant here (callers strip it before comparing) and a trailing `/`
  /// is trimmed so `/foo` and `/foo/` are the same page.
  static String _normalizedHostPath(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return url;
    final host = uri.host.toLowerCase().replaceFirst(RegExp(r'^www\.'), '');
    var path = uri.path;
    if (path.length > 1 && path.endsWith('/')) {
      path = path.substring(0, path.length - 1);
    }
    return '$host$path';
  }

  /// Resolves a short link (`/share/<code>`, `/t/<code>`) using [realUri] —
  /// the final URL a request we already made landed on after Dio followed
  /// any redirect. No extra network request. `/share/` and `/t/` links match
  /// neither [extractUsername] (needs `/@user/post`) nor [_extractShortcode]
  /// (needs `/post/`), so both stay unresolved until a redirect lands on the
  /// canonical `/@user/post/<code>` form — re-running the same extractors on
  /// THAT URL is enough. Returns the [currentUsername]/[currentShortcode]
  /// unchanged (and a null `canonicalUrl`) when [realUri] didn't actually
  /// redirect anywhere new.
  /// [stepLabel] identifies which fetch resolved it for the "Resolved short
  /// link via <label>" log line the coordinator greps logcat for — callers
  /// MUST NOT call this with a [realUri] that [_isInvalidPostResponse]
  /// flags; that case must be handled (and logged) as a failure BEFORE this
  /// is reached, never fed in as if it were a real canonical URL.
  ({String username, String? shortcode, String? canonicalUrl}) _resolveCanonical(
      Uri realUri,
      String originalUrl,
      String currentUsername,
      String? currentShortcode,
      String stepLabel) {
    final canonical = realUri.toString().split('?').first;
    if (_normalizedHostPath(canonical) == _normalizedHostPath(originalUrl)) {
      return (
        username: currentUsername,
        shortcode: currentShortcode,
        canonicalUrl: null,
      );
    }
    final resolvedUsername = extractUsername(canonical);
    final resolvedShortcode = _extractShortcode(canonical);
    if (resolvedUsername != null || resolvedShortcode != null) {
      debugPrint('[Threads] Resolved short link via $stepLabel -> $canonical '
          '(user=${resolvedUsername ?? currentUsername}, shortcode=${resolvedShortcode ?? currentShortcode})');
    }
    return (
      username: resolvedUsername ?? currentUsername,
      shortcode: resolvedShortcode ?? currentShortcode,
      canonicalUrl: canonical,
    );
  }

  // ── Fetch ────────────────────────────────────────────────────────────────

  /// [igSessionId] — the Instagram `sessionid` cookie value (from instagram.com).
  /// [threadsSessionId] — the `sessionid` cookie captured from threads.com after IG
  /// login (different domain). Used directly for the threads.com REST API.
  /// As of 2025, Threads requires authentication for ALL content via their REST API.
  ///
  /// [renderedFetch] — optional WebView-backed fetch used ONLY to resolve a
  /// `/share/`/`/t/` short link that stays unresolved after the anonymous
  /// and authenticated-Dio attempts (see below); when null, that step is
  /// skipped entirely rather than reaching for a root navigator itself —
  /// this service must never push UI on its own. The caller (ultimately
  /// `selection_screen.dart`) owns the `BuildContext` and is responsible for
  /// making the callback throw/return null once the fetch has been
  /// abandoned, exactly like the existing `renderedHtmlFallback` pattern in
  /// `DownloaderService.fetchItems`.
  Future<List<MediaItem>> fetchItems(String url,
      {String? igSessionId,
      String? threadsSessionId,
      ThreadsRenderedFetch? renderedFetch}) async {
    final cleanUrl = url.split('?').first;
    debugPrint('[Threads] URL: $cleanUrl  session: ${igSessionId != null ? 'YES' : 'NO'}');

    // `/share/<code>` and `/t/<code>` short links match neither
    // extractUsername (needs `/@user/post`) nor _extractShortcode (needs
    // `/post/`) — both stay null until resolved below via the redirect a
    // fetch we already perform lands on. Mutable: refined once the short
    // link resolves to its canonical `/@user/post/<code>` form.
    String username = extractUsername(cleanUrl) ?? 'threads';
    String? shortcode = _extractShortcode(cleanUrl);
    // Set once any fetch below resolves a short link to its canonical URL —
    // fed into the later strategies' urlsToTry so they don't have to
    // re-discover it.
    String? canonicalUrl;
    // Set whenever any fetch's realUri lands on Threads' logged-out
    // "invalid post" gate (see _isInvalidPostResponse) — used at the very
    // end to throw a clear, specific error instead of the generic
    // deleted/private message, and (more importantly) that response's HTML
    // is NEVER used as a source for any strategy below, so its og:image
    // (the Threads LOGO) can never be "downloaded" as if it were the post.
    var hitInvalidPostGate = false;
    // Normalised (host+path) keys of every URL a fetch already confirmed as
    // the invalid-post gate THIS call — checked before every subsequent GET
    // in this method so a gated URL is never re-fetched. Deliberately does
    // NOT cache network exceptions/timeouts (those are transient and worth
    // retrying elsewhere) — only a clean, confirmed gate response.
    final gatedUrlKeys = <String>{};
    void markGated(String triedUrl) =>
        gatedUrlKeys.add(_normalizedHostPath(triedUrl));
    bool isGated(String candidateUrl) =>
        gatedUrlKeys.contains(_normalizedHostPath(candidateUrl));

    // ── Strategy 0 (PRIMARY): Googlebot UA → data-sjs ──────────────────────
    // A single unauthenticated GET (+1 request per fetch, no retry loop, no
    // cookie ever sent — see _crawlerDio) — Meta only server-renders the
    // data-sjs post JSON for search-crawler UAs (see the _crawlerUA comment
    // for the field verification). This also resolves `/share/`/`/t/` short
    // links via whatever redirect Dio followed to get here, same as the
    // Desktop UA loop below.
    try {
      final resp = await _crawlerDio.get<String>(cleanUrl);
      if (resp.statusCode == 200 && resp.data != null) {
        if (_isInvalidPostResponse(resp.realUri)) {
          debugPrint('[Threads] Googlebot UA: invalid-post/login-gate redirect '
              '(${resp.realUri})');
          hitInvalidPostGate = true;
          markGated(cleanUrl);
        } else {
          final crawlerHtml = resp.data!;
          final resolved = _resolveCanonical(
              resp.realUri, cleanUrl, username, shortcode, 'googlebot');
          username = resolved.username;
          shortcode = resolved.shortcode;
          canonicalUrl ??= resolved.canonicalUrl;

          if (shortcode != null) {
            final sjsItems = parseDataSjs(crawlerHtml, shortcode, username);
            if (sjsItems.isNotEmpty) {
              debugPrint('[Threads] SERVED BY data-sjs (Googlebot UA): ${sjsItems.length} items');
              return sjsItems;
            }
          }
          debugPrint('[Threads] Googlebot UA: no data-sjs match (shortcode=$shortcode)');
        }
      } else {
        debugPrint('[Threads] Googlebot UA: unexpected status ${resp.statusCode}');
      }
    } catch (e) {
      debugPrint('[Threads] Googlebot UA failed: $e');
    }

    // Inject ONLY the Threads-domain session into Dio for HTML strategies.
    // Using the Instagram-domain sessionid on threads.com triggers an auth
    // redirect loop (Threads sees an invalid session and bounces back and forth).
    // If we only have an IG session (no threads session), fetch without cookies;
    // public Threads posts are accessible without auth from unauthenticated requests.
    if (threadsSessionId != null) {
      final cookieHeader = 'sessionid=$threadsSessionId';
      _desktopDio.options.headers['Cookie'] = cookieHeader;
      _botDio.options.headers['Cookie'] = cookieHeader;
    } else {
      _desktopDio.options.headers.remove('Cookie');
      _botDio.options.headers.remove('Cookie');
    }

    // Cached HTML from the authenticated desktop/bot attempts below, keyed
    // by intent rather than URL — reused by Strategy A/C further down so
    // they never re-fetch cleanUrl with the SAME Dio+cookie state that
    // already answered for it (request-budget fix, 2026-09-07: a gated
    // `/share/` link with a session used to cost 6–9 GETs, several of them
    // re-fetching cleanUrl after it had already come back gated).
    String? preResolvedDesktopHtml;
    String? preResolvedBotHtml;

    // ── Authenticated short-link resolution ────────────────────────────────
    // The anonymous Googlebot attempt above can't resolve every `/share/`/
    // `/t/` link — some posts (deleted, or visible only to logged-in users)
    // redirect anonymous requests to the logged-out "invalid post" gate
    // (see _isInvalidPostResponse) instead of the real post. When a session
    // exists, the user explicitly wants it used to resolve these, so we try
    // two more ways before falling back to the plain anonymous retry below:
    //   (a) Desktop UA WITH the threads.com session cookie just injected —
    //       an authenticated request may get a real redirect where the
    //       anonymous one got the login gate.
    //   (b) The app's own WebView, which shares the Android CookieManager —
    //       logged in if the user ever signed into threads.com in-app.
    //       Capped at ONE attempt per fetch (it's expensive: a real page
    //       load) and only ever runs when a session exists.
    if (shortcode == null &&
        _isShortLink(cleanUrl) &&
        (igSessionId != null || threadsSessionId != null)) {
      try {
        final resp = await _desktopDio.get<String>(cleanUrl);
        if (resp.statusCode == 200 && resp.data != null) {
          if (_isInvalidPostResponse(resp.realUri)) {
            debugPrint('[Threads] Desktop UA (threads-cookie): '
                'invalid-post/login-gate redirect (${resp.realUri})');
            hitInvalidPostGate = true;
            markGated(cleanUrl);
          } else {
            preResolvedDesktopHtml = resp.data!;
            final resolved = _resolveCanonical(resp.realUri, cleanUrl,
                username, shortcode, 'threads-cookie');
            username = resolved.username;
            shortcode = resolved.shortcode;
            canonicalUrl ??= resolved.canonicalUrl;
            if (shortcode != null) {
              final sjsItems = parseDataSjs(resp.data!, shortcode, username);
              if (sjsItems.isNotEmpty) {
                debugPrint('[Threads] SERVED BY data-sjs (threads-cookie): ${sjsItems.length} items');
                return sjsItems;
              }
            }
          }
        }
      } catch (e) {
        debugPrint('[Threads] Desktop UA (threads-cookie) short-link resolve failed: $e');
      }

      if (shortcode == null) {
        try {
          final webviewResult = await _resolveViaWebView(
            cleanUrl,
            username,
            shortcode,
            renderedFetch: renderedFetch,
            onInvalidPostGate: () {
              hitInvalidPostGate = true;
              markGated(cleanUrl);
            },
          );
          if (webviewResult != null) {
            username = webviewResult.username;
            shortcode = webviewResult.shortcode;
            canonicalUrl ??= webviewResult.canonicalUrl;
            if (shortcode != null) {
              final sjsItems =
                  parseDataSjs(webviewResult.html, shortcode, username);
              if (sjsItems.isNotEmpty) {
                debugPrint('[Threads] SERVED BY data-sjs (webview): ${sjsItems.length} items');
                return sjsItems;
              }
            }
          }
        } catch (e) {
          debugPrint('[Threads] WebView short-link resolve failed: $e');
        }
      }
    }

    // Short-link resolution safety net: if none of the steps above resolved
    // a shortcode (no session, or they all failed) AND the URL genuinely is
    // a `/share/`/`/t/` short link, do ONE more anonymous redirect-following
    // GET before Strategy B's authenticated-API gate needs a real shortcode
    // to even attempt — the Desktop UA is known NOT to redirect `/share/`
    // links (see its own comment below), so this uses the bot UA, which
    // does. Skipped entirely if this exact URL already came back gated
    // above (request-budget fix). The response is kept so the Strategy C
    // bot-UA loop further down doesn't re-fetch the same URL.
    if (shortcode == null && _isShortLink(cleanUrl) && !isGated(cleanUrl)) {
      try {
        final resp = await _botDio.get<String>(cleanUrl);
        if (resp.statusCode == 200 && resp.data != null) {
          if (_isInvalidPostResponse(resp.realUri)) {
            debugPrint('[Threads] Bot UA short-link resolve: '
                'invalid-post/login-gate redirect (${resp.realUri})');
            hitInvalidPostGate = true;
            markGated(cleanUrl);
          } else {
            preResolvedBotHtml = resp.data!;
            final resolved = _resolveCanonical(
                resp.realUri, cleanUrl, username, shortcode, 'bot-ua-shortlink');
            username = resolved.username;
            shortcode = resolved.shortcode;
            canonicalUrl ??= resolved.canonicalUrl;
            debugPrint('[Threads] Bot UA short-link resolve: '
                'shortcode=$shortcode user=$username');
          }
        }
      } catch (e) {
        debugPrint('[Threads] Bot UA short-link resolve failed: $e');
      }
    } else if (shortcode == null && _isShortLink(cleanUrl)) {
      debugPrint('[Threads] Bot UA short-link resolve: skipping $cleanUrl '
          '— already confirmed invalid-post gate');
    }

    // ── Strategy A: Desktop Chrome UA ────────────────────────────────────
    // Try both threads.com and threads.net — Threads migrated domains and one
    // may succeed while the other redirect-loops. Also try with the original
    // URL (including query params like slof=1) if the clean URL loops.
    String? desktopHtml;
    final urlsToTry = {
      cleanUrl,
      if (canonicalUrl != null) canonicalUrl,
      if (cleanUrl.contains('threads.com'))
        cleanUrl.replaceFirst('threads.com', 'threads.net')
      else
        cleanUrl.replaceFirst('threads.net', 'threads.com'),
      // If query params were stripped, also try the original URL
      if (url != cleanUrl) url,
    }.toList();

    if (preResolvedDesktopHtml != null) {
      // Already fetched cleanUrl with the exact same Dio+cookie state above
      // (the threads-cookie short-link resolution step) — reuse it instead
      // of fetching it again here.
      desktopHtml = preResolvedDesktopHtml;
      debugPrint('[Threads] Desktop UA: reusing threads-cookie response for '
          '$cleanUrl (no re-fetch)');
    } else {
      for (final tryUrl in urlsToTry) {
        if (isGated(tryUrl)) {
          debugPrint('[Threads] Desktop UA: skipping $tryUrl — already '
              'confirmed invalid-post gate');
          continue;
        }
        try {
          final resp = await _desktopDio.get<String>(tryUrl);
          if (resp.statusCode == 200 && resp.data != null) {
            if (_isInvalidPostResponse(resp.realUri)) {
              debugPrint('[Threads] Desktop UA: invalid-post/login-gate '
                  'redirect ($tryUrl -> ${resp.realUri})');
              hitInvalidPostGate = true;
              markGated(tryUrl);
              continue; // never accept the login gate — try the next variant
            }
            desktopHtml = resp.data!;
            debugPrint('[Threads] Desktop UA succeeded: $tryUrl');
            // Resolve short links (/share/, /t/) — no extra request: Dio
            // already followed any redirect to get here. Usually a no-op by
            // this point (the Googlebot step above already resolved it), but
            // covers the case where that step failed outright (network error)
            // while this one still landed on the canonical URL.
            final resolved = _resolveCanonical(
                resp.realUri, cleanUrl, username, shortcode, 'desktop-ua');
            username = resolved.username;
            shortcode = resolved.shortcode;
            if (resolved.canonicalUrl != null) {
              canonicalUrl ??= resolved.canonicalUrl;
              // Also worth trying for the bot-UA fallback below.
              urlsToTry.add(resolved.canonicalUrl!);
            }
            break;
          }
        } catch (e) {
          debugPrint('[Threads] Desktop UA failed ($tryUrl): $e');
        }
      }
    }

    // Defensive re-attempt: try data-sjs on the Desktop UA's HTML too, in
    // case Meta's crawler-only rendering policy changes. Field-verified DEAD
    // on 2026-09-07 (the desktop Chrome UA gets a client-rendered shell, 0
    // data-sjs post data) — the Googlebot-UA attempt above is what actually
    // serves this strategy today.
    if (desktopHtml != null && shortcode != null) {
      final sjsItems = parseDataSjs(desktopHtml, shortcode, username);
      if (sjsItems.isNotEmpty) {
        debugPrint('[Threads] SERVED BY data-sjs (Desktop UA): ${sjsItems.length} items');
        return sjsItems;
      }
    }

    if (desktopHtml != null) {
      // A1: __NEXT_DATA__ (Next.js SSR — full structured post data).
      // Verified DEAD on 2026-09-07 (0 matches in a live fixture) — kept as
      // a defensive fallback; see the class doc comment.
      final nextItems = _parseNextData(desktopHtml, username);
      if (nextItems.isNotEmpty) {
        debugPrint('[Threads] SERVED BY __NEXT_DATA__: ${nextItems.length} items');
        return nextItems;
      }

      // A2: CDN URL regex (Instagram CDN path prefixes).
      // Verified DEAD on 2026-09-07 (0 matches in a live fixture) — kept as
      // a defensive fallback; see the class doc comment.
      final cdnItems = _parseCdnUrls(desktopHtml, username);
      if (cdnItems.isNotEmpty) {
        debugPrint('[Threads] SERVED BY CDN regex: ${cdnItems.length} items');
        return cdnItems;
      }
    }

    // ── Strategy B: Threads REST API (authenticated, last resort) ─────────
    // Threads removed unauthenticated access to some content in 2025. We try
    // two endpoints, only now that the unauthenticated strategies above have
    // failed:
    //   A. i.instagram.com/api/v1/media/<id>/info/ — mobile app endpoint that
    //      accepts the IG sessionid + x-ig-app-id. The Threads app uses this.
    //   B. threads.com/api/v1/media/<id>/info/ — web endpoint that needs the
    //      threads.com domain sessionid (captured after IG login).
    // Remembers a RateLimitException from the API attempt below (if any) so
    // it can be surfaced instead of the generic "deleted or private" message
    // if every remaining fallback also comes up empty — a rate-limited fetch
    // deserves the actionable RateGuard message, not a misleading "not
    // found". If a later, lossier strategy DOES serve items, this is simply
    // discarded — the caller got a real result.
    RateLimitException? apiRateLimitError;

    final anySession = igSessionId ?? threadsSessionId;
    if (anySession != null) {
      final postId = shortcode != null ? _shortcodeToId(shortcode) : null;
      if (postId != null) {
        try {
          final apiItems = await _fetchFromApi(
              postId, igSessionId: igSessionId, threadsSessionId: threadsSessionId);
          if (apiItems.isNotEmpty) {
            debugPrint('[Threads] SERVED BY API: ${apiItems.length} items');
            return apiItems;
          }
        } catch (e) {
          debugPrint('[Threads] API failed: $e');
          if (e is RateLimitException) apiRateLimitError = e;
        }
      }
    }

    // ── Strategy C: facebookexternalhit → OG tags + embed URL fetch ───────
    // Threads sets og:video to an embed iframe URL (not a direct MP4).
    // We collect embed URLs separately and fetch them for the real video.
    // Try threads.net as well if threads.com redirect-loops.
    String? botHtml = preResolvedBotHtml;
    if (botHtml != null) {
      debugPrint('[Threads] Bot UA: reusing short-link-resolve response '
          '(no re-fetch)');
    } else {
      for (final tryUrl in urlsToTry) {
        if (isGated(tryUrl)) {
          debugPrint('[Threads] Bot UA: skipping $tryUrl — already '
              'confirmed invalid-post gate');
          continue;
        }
        try {
          final resp = await _botDio.get<String>(tryUrl);
          if (resp.statusCode == 200 && resp.data != null) {
            if (_isInvalidPostResponse(resp.realUri)) {
              debugPrint('[Threads] Bot UA: invalid-post/login-gate '
                  'redirect ($tryUrl -> ${resp.realUri})');
              hitInvalidPostGate = true;
              markGated(tryUrl);
              continue; // never accept the login gate — try the next variant
            }
            botHtml = resp.data!;
            debugPrint('[Threads] Bot UA succeeded: $tryUrl');
            // For completeness: the bot UA does follow redirects (unlike the
            // desktop UA), so resolve here too in case this is the first
            // fetch in the whole chain that actually landed on the
            // canonical URL (e.g. the Googlebot attempt failed outright and
            // this URL wasn't a short link, so the safety net above didn't
            // run either).
            final resolved = _resolveCanonical(
                resp.realUri, cleanUrl, username, shortcode, 'bot-ua');
            username = resolved.username;
            shortcode = resolved.shortcode;
            canonicalUrl ??= resolved.canonicalUrl;
            break;
          }
        } catch (e) {
          debugPrint('[Threads] Bot UA failed ($tryUrl): $e');
        }
      }
    }

    // Defensive re-attempt: try data-sjs on the Bot UA's HTML too. Field-
    // verified DEAD on 2026-09-07 (facebookexternalhit gets OG tags only —
    // 0 data-sjs post data — even after following the redirect to the
    // canonical URL); the Googlebot-UA attempt at the top of this method is
    // what actually serves this strategy today. Kept because it costs
    // nothing (no extra request — botHtml is already fetched below) and
    // covers a future policy change.
    if (botHtml != null && shortcode != null) {
      final sjsItems = parseDataSjs(botHtml, shortcode, username);
      if (sjsItems.isNotEmpty) {
        debugPrint('[Threads] SERVED BY data-sjs (Bot UA): ${sjsItems.length} items');
        return sjsItems;
      }
    }

    if (botHtml != null) {
      final (:realVideos, :embedVideos, :images) = _parseOgData(botHtml);
      debugPrint(
          '[Threads] OG: ${realVideos.length} real, '
          '${embedVideos.length} embed videos, ${images.length} images');

      // Prefer a real (non-embed) video URL; fall back to fetching the embed
      String? videoUrl = realVideos.isNotEmpty ? realVideos.first : null;
      if (videoUrl == null && embedVideos.isNotEmpty) {
        videoUrl = await _fetchVideoFromEmbedUrl(embedVideos.first);
      }

      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final items = <MediaItem>[];

      if (videoUrl != null) {
        items.add(MediaItem(
          id: '0',
          mediaUrl: videoUrl,
          thumbnailUrl: images.isNotEmpty ? images.first : null,
          type: MediaItemType.video,
          username: username,
          itemIndex: 1,
          postTimestamp: now,
        ));
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

      if (items.isNotEmpty) {
        debugPrint('[Threads] SERVED BY OG+embed: ${items.length} items');
        return items;
      }
    }

    // Surface a rate-limit block explicitly rather than the generic
    // "deleted or private" message below — nothing served a result, but the
    // real cause (if any strategy hit one) was Instagram pushback, not a
    // missing post.
    if (apiRateLimitError != null) {
      throw apiRateLimitError;
    }

    // Every HTML fetch that succeeded landed on the logged-out "invalid
    // post" gate (never a real post) — a distinct, more accurate cause than
    // "deleted or private", and specifically NOT a green light to fall
    // through to a generic message that would leave the user thinking a
    // retry might help when logging in is what's actually needed.
    if (hitInvalidPostGate) {
      throw Exception(
        "This Threads post isn't available without logging in "
        '(or it was deleted).',
      );
    }

    if (igSessionId == null) {
      throw Exception(
        'Threads now requires login to download content.\n'
        'Please log in with Instagram in the Accounts tab.',
      );
    }
    throw Exception(
      'Could not download this Threads post.\n'
      'The post may have been deleted or made private.',
    );
  }

  // ── Strategy 0: Parse data-sjs JSON (PRIMARY, unauthenticated) ───────────
  //
  // Meta's BigPipe payload embeds the full post JSON — carousel/video data,
  // no auth needed — in `<script type="application/json" data-sjs>` blocks on
  // every Threads page. Verified present (33 `video_versions` occurrences) on
  // a live fixture on 2026-09-07, while __NEXT_DATA__ and the CDN regexes in
  // A1/A2 below were both verified DEAD (0 matches) on the same fixture.
  //
  // SCOPING IS CRITICAL: a single post's combined data-sjs payload routinely
  // contains 30+ `video_versions`/`carousel_media` entries because replies
  // and related posts ship in the same page. We only ever trust the ONE node
  // whose `code` (fallback: `pk`/`id`) matches the target post — see
  // [_findPostNode] — and never fall back to "the first video/image we see".

  /// Parses every `data-sjs` block in [html] looking for the post identified
  /// by [shortcode], scoped via [_findPostNode]. Returns items from the FIRST
  /// block containing a match; empty (never a guess) when no block matches,
  /// so the caller falls through to the next strategy.
  ///
  /// `@visibleForTesting`: exercised directly by the unit test against a
  /// fixture extracted from a real Threads page (see test/ for details).
  @visibleForTesting
  List<MediaItem> parseDataSjs(String html, String shortcode, String username) {
    final mediaId = _shortcodeToId(shortcode);
    final blockRe = RegExp(
      r'<script type="application/json"[^>]*data-sjs[^>]*>([\s\S]*?)</script>',
    );
    for (final m in blockRe.allMatches(html)) {
      dynamic decoded;
      try {
        decoded = jsonDecode(m.group(1)!);
      } catch (_) {
        continue; // some data-sjs blocks are JS, not JSON — skip silently
      }
      final node = _findPostNode(decoded, shortcode, mediaId);
      if (node == null) continue;
      final foundUsername =
          (_dig(node, ['user', 'username']) as String?) ?? username;
      final items = _extractFromPost(node, foundUsername);
      if (items.isNotEmpty) return items;
    }
    return [];
  }

  /// Recursively searches a decoded data-sjs JSON tree for the Map
  /// representing the target post — identified by `code == shortcode` or,
  /// when a candidate lacks `code` (e.g. a bare reference), by `pk`/`id`
  /// matching [mediaId]. A code/id match is only ACCEPTED if the node also
  /// carries media (`carousel_media`, `video_versions`, or
  /// `image_versions2.candidates`) — a bare route/reference echoing the
  /// shortcode (e.g. inside a `"url":".../post/<code>?..."` string's parent
  /// object) must not be mistaken for the real post object. Returns null
  /// (never a guess) when nothing qualifies, so callers move on to the next
  /// data-sjs block or the next strategy entirely.
  Map<String, dynamic>? _findPostNode(
      dynamic node, String shortcode, String? mediaId) {
    if (node is Map) {
      final code = node['code'];
      // pk/id is a fallback for when `code` is ABSENT, not an alternative
      // match on top of a `code` that's simply different from the target —
      // a node that HAS a `code` but it doesn't match is a different real
      // post, and must never be accepted just because its numeric pk/id
      // happens to coincide with mediaId.
      final looksLikeMatch = code != null
          ? code == shortcode
          : (mediaId != null &&
              (node['pk']?.toString() == mediaId ||
                  node['id']?.toString() == mediaId));
      if (looksLikeMatch && _nodeHasMedia(node)) {
        return node.cast<String, dynamic>();
      }
      for (final v in node.values) {
        final found = _findPostNode(v, shortcode, mediaId);
        if (found != null) return found;
      }
    } else if (node is List) {
      for (final v in node) {
        final found = _findPostNode(v, shortcode, mediaId);
        if (found != null) return found;
      }
    }
    return null;
  }

  /// True when [node] carries actual displayable media of its own —
  /// `carousel_media`, `video_versions`, or `image_versions2.candidates`,
  /// all non-empty. Used by [_findPostNode] to confirm a code/id match is
  /// the real post object and not a bare reference.
  bool _nodeHasMedia(Map node) {
    final carousel = node['carousel_media'];
    final video = node['video_versions'];
    final images = _dig(node.cast<String, dynamic>(), ['image_versions2', 'candidates']);
    return (carousel is List && carousel.isNotEmpty) ||
        (video is List && video.isNotEmpty) ||
        (images is List && images.isNotEmpty);
  }

  /// Extracts a canonical post URL from rendered HTML via
  /// `<link rel="canonical">` or `<meta property="og:url">` — a fallback for
  /// [_resolveViaWebView] when the WebView's own current-URL didn't yield a
  /// shortcode (e.g. Threads updates the DOM via JS without changing
  /// `window.location` for a share-link redirect).
  String? _extractCanonicalFromHtml(String html) {
    final canonicalTag = RegExp(
      '''<link[^>]+rel=["']canonical["'][^>]+href=["']([^"']+)["']''',
      caseSensitive: false,
    ).firstMatch(html);
    if (canonicalTag != null) return canonicalTag.group(1);
    final ogUrlTag = RegExp(
      '''<meta[^>]+property=["']og:url["'][^>]+content=["']([^"']+)["']''',
      caseSensitive: false,
    ).firstMatch(html);
    return ogUrlTag?.group(1);
  }

  /// Step (b) of authenticated short-link resolution: loads [url] through
  /// [renderedFetch] (a WebView that shares the Android CookieManager with
  /// the rest of the app, so it's logged in if the user has ever signed
  /// into threads.com in-app — see the [ThreadsRenderedFetch] doc comment).
  /// Returns null (skips this step, logged) when [renderedFetch] is null —
  /// this method never reaches for a navigator itself.
  ///
  /// SCOPING IS CRITICAL (field-verified 2026-09-07: a logged-in WebView
  /// landing on the "invalid post" gate renders the user's own FEED, not an
  /// error page — an earlier version of this method picked "the first
  /// media-bearing post on the page" there, which could silently return a
  /// completely unrelated post). A shortcode is accepted ONLY when a URL
  /// that (a) is confirmed NOT the invalid-post gate and (b) matches
  /// `/@user/post/<code>` or `/post/<code>` is found — first from the
  /// WebView's own final URL, then (only because the final URL already
  /// cleared the gate check) from `<link rel="canonical">`/`og:url` in the
  /// rendered HTML. Guessing a post from page CONTENT (e.g. the first
  /// `"code"` with media anywhere in the data-sjs payload) is never done —
  /// if the final URL IS the gate, [onInvalidPostGate] is invoked and this
  /// returns null immediately, without inspecting the page content at all.
  Future<({String html, String username, String? shortcode, String? canonicalUrl})?>
      _resolveViaWebView(
    String url,
    String currentUsername,
    String? currentShortcode, {
    required ThreadsRenderedFetch? renderedFetch,
    required void Function() onInvalidPostGate,
  }) async {
    if (renderedFetch == null) {
      debugPrint('[Threads] WebView short-link resolve: no renderedFetch '
          'callback supplied — skipping');
      return null;
    }

    final result = await renderedFetch(url);
    final html = result.html;
    final finalUrl = result.finalUrl;
    final finalUri = finalUrl != null ? Uri.tryParse(finalUrl) : null;

    if (finalUri == null) {
      debugPrint('[Threads] webview: could not determine the final URL — '
          'treating as unresolved (never guessing from page content)');
      return null;
    }

    if (_isInvalidPostResponse(finalUri)) {
      debugPrint('[Threads] webview landed on '
          '${finalUri.path.isEmpty ? '/' : finalUri.path} — not a post page '
          '(invalid-post/login gate)');
      onInvalidPostGate();
      return null;
    }

    // (a) the WebView's own final URL.
    if (_extractShortcode(finalUri.toString()) != null) {
      final resolved = _resolveCanonical(
          finalUri, url, currentUsername, currentShortcode, 'webview');
      return (
        html: html,
        username: resolved.username,
        shortcode: resolved.shortcode,
        canonicalUrl: resolved.canonicalUrl,
      );
    }

    // (b) <link rel="canonical">/og:url in the rendered HTML — only trusted
    // because the final URL above already confirmed this ISN'T the
    // invalid-post gate.
    final canonicalFromHtml = _extractCanonicalFromHtml(html);
    final canonicalUri =
        canonicalFromHtml != null ? Uri.tryParse(canonicalFromHtml) : null;
    if (canonicalUri != null &&
        !_isInvalidPostResponse(canonicalUri) &&
        _extractShortcode(canonicalUri.toString()) != null) {
      final resolved = _resolveCanonical(
          canonicalUri, url, currentUsername, currentShortcode, 'webview');
      return (
        html: html,
        username: resolved.username,
        shortcode: resolved.shortcode,
        canonicalUrl: resolved.canonicalUrl,
      );
    }

    debugPrint('[Threads] webview landed on '
        '${finalUri.path.isEmpty ? '/' : finalUri.path} — not a post page');
    return null;
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

  /// Test-only passthrough to [_itemFromNode] — lets unit tests exercise the
  /// video/image classification logic directly (in particular: an empty or
  /// absent `video_versions` list must classify as an image even when the
  /// key is present) without needing a full post-shaped data-sjs blob.
  @visibleForTesting
  MediaItem? itemFromNodeForTesting(
          Map<String, dynamic> node, String username, int? takenAt, int idx) =>
      _itemFromNode(node, username, takenAt, idx);

  MediaItem? _itemFromNode(
      Map<String, dynamic> node, String username, int? takenAt, int idx) {
    // A node is a video if it either declares media_type == 2 (the shape
    // used by the authenticated media-info API) OR simply carries a
    // non-empty video_versions list — the data-sjs GraphQL payload's
    // carousel sub-items omit `media_type` entirely, so relying on it alone
    // silently misclassified every such video as its own poster image (the
    // field-verified play-triangle-over-a-static-image bug, 2026-09-07).
    final vv = (node['video_versions'] as List?)?.cast<Map>();
    final isVideo = node['media_type'] == 2 || (vv != null && vv.isNotEmpty);
    if (isVideo && vv != null && vv.isNotEmpty) {
      final url = _bestVideoUrl(vv);
      if (url != null) {
        return MediaItem(
          id: '$idx',
          mediaUrl: url,
          thumbnailUrl: _bestImageUrl(node),
          type: MediaItemType.video,
          username: username,
          itemIndex: idx,
          postTimestamp: takenAt,
        );
      }
    }
    final img = _bestImageUrl(node);
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

  /// Picks the best-quality video rendition instead of blindly taking
  /// `.first`. The data-sjs schema's `video_versions` entries carry no
  /// width/height (only a `type` code — field-verified: 101/102/103, no
  /// dimensions) so when width/height ARE present (other schemas) the
  /// largest-area entry wins; otherwise fall back to the lowest `type`
  /// value — Instagram has historically used type 101 for its
  /// highest-quality rendition (102/103 are progressively more
  /// compressed/legacy variants).
  String? _bestVideoUrl(List<Map> versions) {
    if (versions.isEmpty) return null;
    final hasDimensions =
        versions.any((v) => v['width'] != null && v['height'] != null);
    final best = versions.reduce((a, b) {
      if (hasDimensions) {
        final areaA = ((a['width'] as num?) ?? 0) * ((a['height'] as num?) ?? 0);
        final areaB = ((b['width'] as num?) ?? 0) * ((b['height'] as num?) ?? 0);
        return areaB > areaA ? b : a;
      }
      final typeA = (a['type'] as num?) ?? 999999;
      final typeB = (b['type'] as num?) ?? 999999;
      return typeB < typeA ? b : a;
    });
    return best['url'] as String?;
  }

  /// Picks the best-quality image candidate instead of blindly taking
  /// `.first` — `image_versions2.candidates` entries always carry
  /// width/height (field-verified), so the largest-area candidate is the
  /// original-resolution source; candidate order is not documented or
  /// guaranteed across schema variants.
  String? _bestImageUrl(Map<String, dynamic> node) {
    final candidates =
        (_dig(node, ['image_versions2', 'candidates']) as List?)?.cast<Map>();
    if (candidates == null || candidates.isEmpty) return null;
    final hasDimensions =
        candidates.any((c) => c['width'] != null && c['height'] != null);
    if (!hasDimensions) return candidates.first['url'] as String?;
    final best = candidates.reduce((a, b) {
      final areaA = ((a['width'] as num?) ?? 0) * ((a['height'] as num?) ?? 0);
      final areaB = ((b['width'] as num?) ?? 0) * ((b['height'] as num?) ?? 0);
      return areaB > areaA ? b : a;
    });
    return best['url'] as String?;
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

    // Video — pattern allows backslash so JSON-encoded https:\/\/ is matched;
    // _unescape() converts the \/ sequences back to / after capture.
    final videoRe = RegExp(
      r'"url"\s*:\s*"(https[^"]*t50\.2886-16[^"]*\.mp4[^"]*)"',
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

    // Images — CDN-path-specific pattern first (t51.2885-15 = post images),
    // then a broader scontent/cdninstagram fallback if the specific one finds
    // nothing. Both allow backslash in the capture group so JSON-encoded
    // https:\/\/ URLs are matched; _unescape() normalises them afterward.
    // Deduplicate by filename (same image at multiple sizes).
    final imgRe = RegExp(
      r'"url"\s*:\s*"(https[^"]*t51\.2885-15[^"]+)"',
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

    // Broader fallback: any scontent/cdninstagram image URL in the JSON blob.
    // Catches carousel images when Threads uses a different CDN path segment
    // (e.g. t51.29350-15 instead of t51.2885-15). Only runs if the specific
    // pattern found nothing, to avoid duplicating already-matched images.
    if (imageUrls.isEmpty && items.isEmpty) {
      final broadImgRe = RegExp(
        r'"url"\s*:\s*"(https[^"]*(?:cdninstagram\.com|scontent)[^"]*\.(?:jpg|jpeg|webp)[^"]*)"',
      );
      for (final m in broadImgRe.allMatches(html)) {
        final url = _unescape(m.group(1)!);
        if (_isExcludedOgImage(url)) continue;
        final filename = url.split('?').first.split('/').last;
        if (seenFilenames.add(filename) && seenUrls.add(url)) {
          imageUrls.add(url);
        }
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
      // A mixed carousel (photos + a video) used to discard EVERY image once
      // any video existed, silently dropping real photo slides. Emit every
      // image as its own slide too, appended after the video(s). This
      // regex-based strategy has no way to tell a video's poster frame apart
      // from an actual photo slide, so it may over-emit (the poster frame
      // could show up twice: once as the thumbnail above, once as its own
      // "image" slide) — acceptable here because A2 is a defensive fallback
      // only (verified DEAD as of 2026-09-07; see the class doc comment) and
      // the scoped, structured data-sjs strategy is authoritative whenever
      // it's available.
      final videoCount = items.length;
      for (var i = 0; i < imageUrls.length; i++) {
        items.add(MediaItem(
          id: '${videoCount + i}',
          mediaUrl: imageUrls[i],
          thumbnailUrl: imageUrls[i],
          type: MediaItemType.image,
          username: username,
          itemIndex: videoCount + i + 1,
          postTimestamp: now,
        ));
      }
    }

    return items;
  }

  // ── B: OG tag parsing + embed URL video extraction ────────────────────────

  /// Parses OG meta tags, separating real video URLs from embed page URLs.
  ({
    List<String> realVideos,
    List<String> embedVideos,
    List<String> images,
  }) _parseOgData(String html) {
    final document = html_parser.parse(html);
    final realVideos = <String>[];
    final embedVideos = <String>[];
    final images = <String>[];

    for (final tag in document.querySelectorAll('meta[property]')) {
      final property = tag.attributes['property'] ?? '';
      final content = tag.attributes['content'] ?? '';
      if (content.isEmpty) continue;
      if (property == 'og:video' || property == 'og:video:url') {
        // Embed iframe URLs are HTML pages — collect separately for fetching
        if (content.contains('embed') || content.contains('video.php')) {
          if (!embedVideos.contains(content)) embedVideos.add(content);
        } else if (!realVideos.contains(content)) {
          realVideos.add(content);
        }
      } else if (property == 'og:image') {
        if (!_isExcludedOgImage(content) && !images.contains(content)) {
          images.add(content);
        }
      }
    }
    return (realVideos: realVideos, embedVideos: embedVideos, images: images);
  }

  /// Fetches a Threads embed page and extracts the real video CDN URL from it.
  /// The embed page is a public iframe-friendly page that contains the video player.
  // ── Strategy 0 helpers: REST API ─────────────────────────────────────────

  /// Extracts the post shortcode from a Threads URL.
  /// e.g. https://www.threads.com/@user/post/ABC123 → "ABC123"
  static String? _extractShortcode(String url) {
    final re = RegExp(r'/post/([A-Za-z0-9_-]+)', caseSensitive: false);
    return re.firstMatch(url)?.group(1);
  }

  /// True for `/share/<code>` and `/t/<code>` short links — the shapes that
  /// need a redirect before [extractUsername]/[_extractShortcode] can match
  /// anything.
  static bool _isShortLink(String url) {
    final re = RegExp(r'threads\.(?:com|net)/(?:share|t)/', caseSensitive: false);
    return re.hasMatch(url);
  }

  /// True when [realUri] is Threads' logged-out "invalid post" gate rather
  /// than a real post page. Field-verified 2026-09-07: an anonymous (and
  /// sometimes even authenticated-but-insufficient) request for a post that
  /// doesn't exist anonymously — deleted, or visible only when logged in —
  /// redirects to `https://www.threads.com/?error=invalid_post`, the
  /// logged-out home page (`og:title` "Threads • Log in",
  /// `og:image` the Threads LOGO). Silently accepting that page's content as
  /// if it were the post is exactly the bug this guards against: it must
  /// never be treated as a successful fetch.
  static bool _isInvalidPostResponse(Uri realUri) {
    if (realUri.queryParameters.containsKey('error')) return true;
    final path = realUri.path;
    return path.isEmpty || path == '/';
  }

  /// True for OG images that are Threads/Meta CHROME (logo, static UI
  /// assets) rather than actual post media — extends the pre-existing
  /// `profilepic` exclusion. Field-verified 2026-09-07: the logged-out
  /// "invalid post" gate's `og:image` is
  /// `https://static.cdninstagram.com/rsrc.php/yd/r/kHwIMM5b8PW.webp` (the
  /// Threads logo) — without this, Strategy C would happily "download" the
  /// logo as if it were the post's own image.
  static bool _isExcludedOgImage(String url) {
    if (url.contains('profilepic') || url.contains('profile_pic')) {
      return true;
    }
    if (url.contains('/rsrc.php/')) return true;
    final host = Uri.tryParse(url)?.host;
    return host == 'static.cdninstagram.com';
  }

  /// Converts a Threads/Instagram post shortcode to its numeric media ID string.
  /// Uses the same base-64 alphabet as the Instagram shortcode encoding.
  static String? _shortcodeToId(String shortcode) {
    const alphabet =
        'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_';
    var n = BigInt.zero;
    for (final char in shortcode.split('')) {
      final idx = alphabet.indexOf(char);
      if (idx == -1) return null;
      n = n * BigInt.from(64) + BigInt.from(idx);
    }
    return n.toString();
  }

  // Instagram mobile app UA — the Threads app uses this to call i.instagram.com.
  static const _mobileUA =
      'Instagram 219.0.0.12.117 Android (26/8.0.0; 480dpi; 1080x1920; '
      'OnePlus; ONEPLUS A3010; OnePlus3T; qcom; en_US; 314665256)';

  // Instagram web app-id (used for www.instagram.com API)
  static const _igAppId = '936619743392459';
  // Threads web app-id (used by threads.com itself for its own API calls)
  static const _threadsAppId = '238260118697367';

  /// Calls the media info API using available sessions.
  /// Order of attempts:
  ///   1. i.instagram.com with mobile UA + x-ig-app-id (IG web) + IG sessionid
  ///   2. i.instagram.com with mobile UA + x-ig-app-id (Threads) + IG sessionid
  ///      (what the Threads mobile app actually calls)
  ///   3. threads.com with desktop UA + threads.com sessionid
  ///      (requires threads session captured after IG login)
  ///   4. threads.com with desktop UA + IG sessionid (last resort)
  Future<List<MediaItem>> _fetchFromApi(String mediaId,
      {String? igSessionId, String? threadsSessionId}) async {
    // Attempts 1 & 2: Instagram mobile API with both app IDs.
    // This hits i.instagram.com/api/v1/media/<id>/info/ — the exact
    // authenticated, account-attributed endpoint RateGuard exists to protect
    // — up to twice per fetch, so it is rate-gated exactly like
    // DownloaderService._fetchViaMediaId: assert before the call, pace it,
    // record it, and classify any pushback instead of swallowing it in a
    // bare catch.
    if (igSessionId != null) {
      for (final appId in [_igAppId, _threadsAppId]) {
        // Throws RateLimitException when the hourly budget is spent or a
        // challenge cooldown is active. Deliberately NOT caught here (nor
        // anywhere else in this method) — a trip aborts this whole call
        // chain, including attempts 3 & 4 below (threads.com, same account)
        // below rather than hammering another endpoint right after Instagram
        // just pushed back. The caller (fetchItems) already swallows
        // whatever this throws and falls through to the next strategy.
        RateGuard.instance.assertCanCall();
        // Paces successive authenticated calls — delays, never fails.
        await RateGuard.instance.awaitCallSlot();
        await RateGuard.instance.recordApiCall();

        final apiDio = Dio(BaseOptions(
          connectTimeout: const Duration(seconds: 15),
          receiveTimeout: const Duration(seconds: 30),
          followRedirects: true,
          maxRedirects: 3,
          headers: {
            'User-Agent': _mobileUA,
            'Cookie': 'sessionid=$igSessionId',
            'x-ig-app-id': appId,
            'Accept': 'application/json',
          },
        ));
        final apiUrl = 'https://i.instagram.com/api/v1/media/$mediaId/info/';

        final Response<String> resp;
        try {
          // get<String> (not <Map>) so a pushback body can be inspected as
          // text before decoding — mirrors DownloaderService._fetchViaMediaId.
          resp = await apiDio.get<String>(apiUrl);
        } on DioException catch (e) {
          final code = e.response?.statusCode;
          final body = e.response?.data?.toString().toLowerCase() ?? '';
          final pushback = RateGuard.pushbackReason(code, body);
          if (pushback != null) {
            // Never log the body itself (may echo cookies/session) — only
            // the classified reason, status, and media ID.
            debugPrint('[RateGuard] BLOCK tripped (Threads i.instagram.com): '
                'reason=${pushback.code} http=${code ?? '-'} mediaId=$mediaId');
            await RateGuard.instance
                .triggerChallengeCooldown(reason: pushback, statusCode: code);
            throw RateLimitException(
              'Instagram flagged automated activity (HTTP $code). Requests '
              'are paused to protect your account — open the Instagram app, '
              'clear any prompt, then wait before retrying.',
            );
          }
          debugPrint('[Threads] i.instagram.com (app-id $appId) failed: $code ${e.message}');
          continue;
        }

        if (resp.statusCode != 200 || resp.data == null) continue;

        // A 200 can still carry a soft challenge/login wall in its body.
        final lowerBody = resp.data!.toLowerCase();
        final softPushback = RateGuard.pushbackReason(resp.statusCode, lowerBody);
        if (softPushback != null) {
          debugPrint('[RateGuard] BLOCK tripped (Threads i.instagram.com, soft): '
              'reason=${softPushback.code} http=${resp.statusCode} mediaId=$mediaId');
          await RateGuard.instance.triggerChallengeCooldown(
              reason: softPushback, statusCode: resp.statusCode);
          throw RateLimitException(
            'Instagram flagged automated activity. Requests are paused to '
            'protect your account — open the Instagram app, clear any '
            'prompt, then wait before retrying.',
          );
        }

        // Clean authenticated 200 — clears any lingering cooldown/auth state.
        await RateGuard.instance.noteAuthenticatedSuccess();

        final data = jsonDecode(resp.data!) as Map<String, dynamic>;
        final items = _parseApiResponse(data);
        if (items.isNotEmpty) {
          debugPrint('[Threads] i.instagram.com API (app-id $appId): ${items.length} items');
          return items;
        }
      }
    }

    // Attempt 3: threads.com API with threads-domain session
    final threadsSession = threadsSessionId;
    if (threadsSession != null) {
      try {
        final items = await _callThreadsApi(mediaId, threadsSession);
        if (items.isNotEmpty) {
          debugPrint('[Threads] threads.com API (threads session): ${items.length} items');
          return items;
        }
      } catch (e) {
        debugPrint('[Threads] threads.com API (threads session) failed: $e');
      }
    }

    // Attempt 4: threads.com API with IG session (may work if sessions are shared)
    if (igSessionId != null) {
      try {
        final items = await _callThreadsApi(mediaId, igSessionId);
        if (items.isNotEmpty) {
          debugPrint('[Threads] threads.com API (ig session): ${items.length} items');
          return items;
        }
      } catch (e) {
        debugPrint('[Threads] threads.com API (ig session) failed: $e');
      }
    }

    return [];
  }

  Future<List<MediaItem>> _callThreadsApi(String mediaId, String sessionId) async {
    final apiDio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 30),
      followRedirects: false,
      headers: {
        // Mobile UA is required — the threads.com and threads.net API endpoints
        // use the same backend as i.instagram.com and reject desktop UAs.
        'User-Agent': _mobileUA,
        'Cookie': 'sessionid=$sessionId',
        'x-ig-app-id': _threadsAppId,
        'Accept': 'application/json',
        'Accept-Language': 'en-US,en;q=0.9',
      },
    ));
    // Try both threads.com and threads.net — the migration between the two
    // domains means one may return results while the other does not.
    for (final domain in ['www.threads.com', 'www.threads.net']) {
      try {
        final resp = await apiDio.get<Map<String, dynamic>>(
          'https://$domain/api/v1/media/$mediaId/info/',
        );
        if (resp.statusCode == 200 && resp.data != null) {
          final items = _parseApiResponse(resp.data!);
          if (items.isNotEmpty) {
            debugPrint('[Threads] $domain API: ${items.length} items');
            return items;
          }
        }
      } on DioException catch (e) {
        debugPrint('[Threads] $domain API (threads session) failed: ${e.response?.statusCode} ${e.message}');
      }
    }
    return [];
  }

  List<MediaItem> _parseApiResponse(Map<String, dynamic> data) {
    final itemsList = data['items'] as List?;
    if (itemsList == null || itemsList.isEmpty) return [];
    final post = itemsList.first as Map<String, dynamic>;
    final username = (_dig(post, ['user', 'username']) as String?) ?? 'threads';
    return _extractFromPost(post, username);
  }

  Future<String?> _fetchVideoFromEmbedUrl(String embedUrl) async {
    for (final dio in [_botDio, _desktopDio]) {
      try {
        debugPrint('[Threads] Fetching embed: $embedUrl');
        final resp = await dio.get<String>(embedUrl);
        if (resp.statusCode != 200 || resp.data == null) continue;
        final html = resp.data!;

        // <video src="..."> — most common in embed players
        final videoTagRe =
            RegExp(r'<video[^>]+src="([^"]+)"', caseSensitive: false);
        final vMatch = videoTagRe.firstMatch(html);
        if (vMatch != null) {
          final url = _unescape(vMatch.group(1)!);
          if (url.startsWith('https://') && !url.contains('embed')) {
            debugPrint('[Threads] Embed: found via <video> tag');
            return url;
          }
        }

        // JavaScript / JSON patterns (Instagram/Threads SSR or inline data)
        final patterns = [
          RegExp(r'"playable_url"\s*:\s*"([^"]+)"'),
          RegExp(r'"video_url"\s*:\s*"([^"]+)"'),
          RegExp(r'"url"\s*:\s*"(https://[^"]+t50\.2886-16[^"]+\.mp4[^"]*)"'),
          RegExp(r'"src"\s*:\s*"(https://[^"]+\.mp4[^"]*)"'),
          // bare MP4 URL anywhere in the page (last resort)
          RegExp(r'(https://[^\s"\x27]+\.mp4(?:\?[^\s"\x27]*)?)'),
        ];
        for (final p in patterns) {
          final m = p.firstMatch(html);
          if (m != null) {
            final url = _unescape(m.group(1)!);
            if (url.startsWith('https://') &&
                url.contains('.mp4') &&
                !url.contains('embed')) {
              debugPrint('[Threads] Embed: found via JSON/regex pattern');
              return url;
            }
          }
        }
      } catch (e) {
        debugPrint('[Threads] Embed fetch error: $e');
      }
    }
    return null;
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

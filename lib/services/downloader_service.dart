import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:html/parser.dart' as html_parser;
import '../models/fetch_result.dart';
import '../models/media_item.dart';
import 'download_ledger_service.dart';
import 'facebook_downloader_service.dart';
import 'generic_article_downloader_service.dart';
import 'ig_url_parser.dart';
import 'rate_guard_service.dart';
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
///   A. Embed page → window.__additionalDataLoaded JSON — cookie-less, so it
///      spends zero authenticated-surface risk; structurally identical
///      extraction to the private API (same _extractFromSlides helpers).
///      Thin/truncated carousel payloads are rejected so 0 can serve them.
///   0. Instagram private API — i.instagram.com (requires session cookie)
///      Full carousel, original resolution, full video. The ONLY strategy
///      that can serve private-account posts — but also the exact surface
///      Meta polices for automation, so it runs only when A can't deliver.
///   B. Main page OG tags + display_url JSON fallback (lossy last resort:
///      no taken_at, username often 'unknown')
/// Stories are a separate URL-gated branch (0b) and always need the API.
class DownloaderService {
  static const _crawlerUA =
      'facebookexternalhit/1.1 (+http://www.facebook.com/externalhit_uatext.php)';

  // Desktop Chrome UA — used for browser-facing pages (embed, main page)
  static const _desktopUA =
      'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';

  // Instagram Android app user-agent — required for the private API
  static const _mobileUA =
      'Instagram 219.0.0.12.117 Android (26/8.0.0; 480dpi; 1080x1920; '
      'OnePlus; ONEPLUS A3010; OnePlus3T; qcom; en_US; 314665256)';

  // Web client app ID accepted by i.instagram.com without an app-level token
  static const _igAppId = '936619743392459';

  final Dio _dio;        // OG-tag fetching (crawler UA)
  final Dio _desktopDio; // Browser-facing pages: embed + main page fallback
  final Dio _apiDio;     // Instagram private API (mobile UA + App-ID)

  DownloaderService({Dio? dio})
      : _dio = dio ??
            Dio(
              BaseOptions(
                connectTimeout: const Duration(seconds: 15),
                receiveTimeout: const Duration(seconds: 60),
                followRedirects: true,
                maxRedirects: 10,
                headers: {
                  'User-Agent': _crawlerUA,
                  'Accept-Language': 'en-US,en;q=0.9',
                  'Referer': 'https://www.instagram.com/',
                },
              ),
            ),
        _desktopDio = Dio(
          BaseOptions(
            connectTimeout: const Duration(seconds: 15),
            receiveTimeout: const Duration(seconds: 60),
            followRedirects: true,
            maxRedirects: 10,
            headers: {
              'User-Agent': _desktopUA,
              'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
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

  /// Returns a [FetchResult] rather than a bare item list so the Instagram
  /// path can flag a degraded (possibly-incomplete) Strategy B result — see
  /// [FetchResult.degradedReason]. Every non-Instagram branch is inherently
  /// non-degraded and wraps its list as-is.
  Future<FetchResult> fetchItems(
    String url, {
    Future<String> Function(String url)? renderedHtmlFallback,
  }) async {
    if (XDownloaderService.isXUrl(url)) {
      return FetchResult(items: await XDownloaderService().fetchItems(url));
    }
    if (ThreadsDownloaderService.isThreadsUrl(url)) {
      // Pass both sessions: IG session for i.instagram.com API (Threads app approach),
      // and threads.com session (captured after IG login) for the threads.com API.
      final igSessionId =
          await SessionService.getSessionId(LoginPlatform.instagram);
      final threadsSessionId = await SessionService.getThreadsSessionId();
      return FetchResult(
          items: await ThreadsDownloaderService().fetchItems(url,
              igSessionId: igSessionId, threadsSessionId: threadsSessionId));
    }
    if (FacebookDownloaderService.isFacebookUrl(url)) {
      final fbCookies =
          await SessionService.getSessionId(LoginPlatform.facebook);
      return FetchResult(
          items: await FacebookDownloaderService()
              .fetchItems(url, fbCookies: fbCookies));
    }
    if (!IgUrlParser.isInstagramUrl(url)) {
      // Direct media link (e.g. a raw CDN .jpg/.mp4 URL shared straight out of
      // a gallery, like https://64.media.tumblr.com/abc/def.jpg) — download it
      // as-is rather than HTML-scraping raw media bytes, which the generic
      // article parser can't handle (it expects a page, not an image/video).
      if (_looksLikeDirectMediaUrl(url)) {
        final host = Uri.tryParse(url)?.host ?? 'media';
        final siteName = host.replaceFirst('www.', '').replaceAll('.', '_');
        return FetchResult(items: [
          MediaItem(
            id: '0',
            mediaUrl: url,
            thumbnailUrl: _urlLooksLikeVideo(url) ? null : url,
            type: _urlLooksLikeVideo(url)
                ? MediaItemType.video
                : MediaItemType.image,
            username: siteName,
            itemIndex: 1,
          ),
        ]);
      }
      // Not IG, X, Threads, or Facebook — try generic article extraction
      return FetchResult(
          items: await GenericArticleDownloaderService(
        renderedHtmlFallback: renderedHtmlFallback,
      ).fetchItems(url));
    }
    return _fetchIgItems(url);
  }

  /// Extensions that mark a URL as pointing directly at a media file rather
  /// than an HTML page. Checked against the path only (query string stripped)
  /// so CDN cache-busting params (`?resize=…`) don't defeat the match.
  static const _directMediaExtensions = [
    '.jpg', '.jpeg', '.png', '.webp', '.gif', '.mp4', '.mov',
  ];

  static bool _looksLikeDirectMediaUrl(String url) {
    final path = Uri.tryParse(url)?.path.toLowerCase() ??
        url.toLowerCase().split('?').first;
    return _directMediaExtensions.any(path.endsWith);
  }

  Future<FetchResult> _fetchIgItems(String igUrl) async {
    // Normalise: strip query string, ensure trailing slash
    final cleanUrl = igUrl.split('?').first.replaceAll(RegExp(r'/+$'), '') + '/';
    debugPrint('[IG] URL: $cleanUrl');

    // Attach session cookie if the user has logged in
    final sessionId = await SessionService.getSessionId(LoginPlatform.instagram);
    debugPrint('[IG] sessionId: ${sessionId != null ? 'SET (${sessionId.length} chars)' : 'NULL — not logged in'}');

    // ── Strategy 0b: Story via private API ──────────────────────────────
    // Story URLs already contain the numeric media ID, so no shortcode
    // conversion is needed. Stories are always behind a session wall.
    // This branch is URL-pattern-gated (never matches /p/, /reel/, /tv/) and
    // stays ahead of the A → 0 → B chain: story URLs have no embed page, so
    // running Strategy A on them would only waste a doomed request before the
    // "Stories require login" message.
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
          debugPrint('[IG] SERVED BY Story API (0b): ${items.length} items');
          return FetchResult(items: items);
        }
      } catch (e) {
        debugPrint('[IG] Story API failed: $e');
        rethrow;
      }
      throw Exception(
        'Could not download story. It may have expired (stories last 24 hours).',
      );
    }

    // Regular posts (/p/, /reel/, /tv/) run the chain A → 0 → B: the
    // cookie-less embed first (zero account risk, identical extraction), the
    // authenticated private API only when the embed can't deliver, and the
    // lossy main-page scrape as the last resort.
    debugPrint(
        '[IG] Strategy order: A (embed, no cookie) → 0 (private API) → B (main page)');

    // WHY Strategy 0 could not serve, when it couldn't — carried into the
    // FetchResult if the lossy Strategy B ends up serving, so the UI can warn
    // that the result may silently be incomplete (field case: B returned 1
    // item for a genuine 4-slide carousel). Null while 0 is still viable.
    DegradedReason? strategy0Unavailable =
        sessionId == null ? DegradedReason.notLoggedIn : null;

    // ── Strategy A: embed captioned page — FIRST ─────────────────────────
    // /embed/captioned/ is a public iframe endpoint — no cookie sent (cookie
    // triggers auth redirect loop), so this spends none of the authenticated
    // account-risk budget. Try desktop Chrome UA first (most likely to get
    // __additionalDataLoaded JSON), then facebookexternalhit as fallback.
    // _parseEmbedPage returns [] for thin/truncated carousel payloads, which
    // falls through to Strategy 0 below.
    try {
      final embedUrl = '${cleanUrl}embed/captioned/';
      debugPrint('[IG] Trying embed: $embedUrl');
      for (final embedDio in [_desktopDio, _dio]) {
        try {
          final resp = await embedDio.get<String>(embedUrl);
          if (resp.statusCode == 200 && resp.data != null) {
            final items = _parseEmbedPage(resp.data!, cleanUrl);
            if (items.isNotEmpty) {
              debugPrint('[IG] SERVED BY Strategy A (embed): ${items.length} items');
              return FetchResult(items: items);
            }
          }
        } catch (e) {
          debugPrint('[IG] Embed attempt failed: $e');
        }
      }
    } catch (e) {
      debugPrint('[IG] Embed failed: $e');
    }

    // ── Strategy 0: Instagram private API — SECOND (requires login) ──────
    // Returns full carousel + original resolution for any public/private post.
    // Must run whenever Strategy A returned empty, thin, or threw: private-
    // account posts can ONLY be served here. Runs after A because it sends the
    // session cookie to i.instagram.com — the exact surface Meta polices for
    // automation. A RateGuard block (RateLimitException) is swallowed like any
    // other failure so the chain still falls through to Strategy B.
    if (sessionId != null) {
      final shortcode = _extractShortcode(cleanUrl);
      if (shortcode != null) {
        debugPrint('[IG] Embed could not serve — escalating to private API');
        // Probe-then-proceed: when Strategy 0 is blocked by a challenge/auth
        // cooldown, run ONE inline recovery probe first — if access has in
        // fact recovered, THIS request gets the full-quality Strategy 0
        // result instead of the degraded Strategy B fallback. Deliberately a
        // probe and not a trial media call: a failed real call would re-enter
        // the pushback branch and bump the escalation ladder (2h→4h→8h),
        // whereas maybeReprobe fails closed, is ladder-neutral, and enforces
        // its own 5-minute floor internally (so this is a cheap timestamp
        // check when called again sooner).
        if (RateGuard.instance.status.isChallenge) {
          debugPrint('[IG] Strategy 0 blocked '
              '(${RateGuard.instance.status.challengeReason?.code ?? 'unknown'})'
              ' — attempting inline recovery probe before falling back');
          final recovered = await RateGuard.instance.maybeReprobe();
          if (recovered) {
            debugPrint(
                '[IG] Inline probe cleared the block — proceeding with Strategy 0');
          }
        }
        try {
          final items = await _fetchViaPrivateApi(shortcode, sessionId);
          if (items.isNotEmpty) {
            debugPrint('[IG] SERVED BY Strategy 0 (private API): ${items.length} items');
            return FetchResult(items: items);
          }
          strategy0Unavailable = DegradedReason.strategy0Failed;
        } catch (e) {
          debugPrint('[IG] Private API failed: $e');
          // Classify WHY for the degraded-result warning. Only a
          // RateLimitException is a block signal: RateGuard's refusal thrown
          // before the call, or the pushback throw right after THIS call
          // tripped the cooldown (both pushback branches in _fetchViaMediaId
          // throw it). Consulting rg.isChallenge for arbitrary exceptions
          // would mislabel an unrelated failure (JSON parse, timeout) as a
          // block whenever a DIFFERENT concurrent fetch happened to trip the
          // challenge first; the auth flavour still points at re-login.
          if (e is RateLimitException) {
            final rg = RateGuard.instance.status;
            strategy0Unavailable = rg.needsRelogin
                ? DegradedReason.authInvalid
                : DegradedReason.blockedByCooldown;
          } else {
            strategy0Unavailable = DegradedReason.strategy0Failed;
          }
        }
      } else {
        // Logged in but no shortcode could be extracted — Strategy 0 can't
        // even identify the post, so a B result is just as unverifiable.
        strategy0Unavailable = DegradedReason.strategy0Failed;
      }
    }

    // ── Strategy B: main page (crawler UA, no cookie) — LAST ──────────────
    // facebookexternalhit UA reliably gets OG meta tags for public posts.
    // We do NOT send the session cookie here — bot UA + sessionid is an
    // instant automation-detection signal that causes IG to redirect to login.
    // Private posts are handled exclusively by Strategy 0 (private API).
    // Last in the chain because it is lossy: OG tags carry no taken_at (so
    // filenames get stamped with TODAY's date) and the username often
    // degrades to 'unknown' for bare /p/<code>/ links.
    debugPrint('[IG] Falling back to main page (Strategy B — lossy last resort)');
    try {
      final resp = await _dio.get<String>(cleanUrl);
      if (resp.statusCode != 200 || resp.data == null) {
        throw Exception('Failed to load Instagram page (${resp.statusCode})');
      }
      final items = _parseMainPage(resp.data!, cleanUrl);
      debugPrint('[IG] SERVED BY Strategy B (main page): ${items.length} items'
          '${strategy0Unavailable != null ? ' — DEGRADED (${strategy0Unavailable.name}): may be incomplete' : ''}');
      // B serving while Strategy 0 was unavailable is a DEGRADED result: OG
      // tags routinely expose only the first slide of a carousel, and there is
      // no error to tell the user — so the reason is surfaced as a warning.
      return FetchResult(items: items, degradedReason: strategy0Unavailable);
    } catch (e) {
      final msg = e.toString().toLowerCase();
      if (msg.contains('redirect')) {
        throw Exception(
          'Instagram redirected to login — this post may be private or your '
          'session has expired.\n'
          'Try re-logging in from the Accounts tab.',
        );
      }
      rethrow;
    }
  }

  // ── Strategy 0: Instagram private API ──────────────────────────────────
  // Pushback detection (`RateGuard.pushbackReason`) lives in
  // rate_guard_service.dart so it's shared with RateGuard's own recovery
  // probe instead of duplicated.

  /// Scrubs session/auth material from [text] before it can reach any log —
  /// the dev log overlay is user-visible and logs may be shared.
  ///
  /// Two independent passes, so no single miss can leak:
  /// 1. The literal [sessionId] value (and its lowercased form, since pushback
  ///    bodies are lowercased before matching) is replaced verbatim — even an
  ///    unexpected echo of the session in the body cannot survive.
  /// 2. Cookie/auth-style `key=value` pairs (sessionid, csrftoken, cookie,
  ///    authorization, token, ds_user_id) have their values blanked.
  static String _redactForLog(String text, String sessionId) {
    var out = text;
    if (sessionId.isNotEmpty) {
      out = out
          .replaceAll(sessionId, '<redacted>')
          .replaceAll(sessionId.toLowerCase(), '<redacted>');
    }
    out = out.replaceAllMapped(
      RegExp(
          r'(sessionid|csrftoken|authorization|cookie|ds_user_id|token)'
          r'(["\s]*[:=]["\s]*)[^;,&"\s]+',
          caseSensitive: false),
      (m) => '${m[1]}${m[2]}<redacted>',
    );
    return out;
  }

  /// Redacts (see [_redactForLog]) THEN truncates [body] to ~300 chars for a
  /// log snippet. Order matters: truncating first could slice a secret in half
  /// and leave a fragment the pattern pass no longer recognises.
  static String _safeBodySnippet(String body, String sessionId) {
    final redacted = _redactForLog(body, sessionId);
    return redacted.length <= 300
        ? redacted
        : '${redacted.substring(0, 300)}…[truncated]';
  }

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

    // Rate-gate the authenticated surface that triggers automation flags.
    // Throws RateLimitException when the hourly budget is spent or a challenge
    // cooldown is active; counts this call against the budget once allowed.
    RateGuard.instance.assertCanCall();
    // Pace the call: back-to-back authenticated bursts are a strong automation
    // signal, so successive private-API calls are spaced out with jitter. This
    // DELAYS (never fails) the call — see RateGuard.awaitCallSlot.
    await RateGuard.instance.awaitCallSlot();
    await RateGuard.instance.recordApiCall();

    final Response<String> resp;
    try {
      resp = await _apiDio.get<String>(
        url,
        options: Options(headers: {'Cookie': 'sessionid=$sessionId'}),
      );
    } on DioException catch (e) {
      final code = e.response?.statusCode;
      final body = e.response?.data?.toString().toLowerCase() ?? '';
      final pushback = RateGuard.pushbackReason(code, body);
      if (pushback != null) {
        // Log the diagnostic BEFORE throwing so the cause is captured even if
        // the exception is swallowed upstream. Only the URL (media ID, no
        // secrets) and a redacted+truncated body snippet are logged — never
        // headers, cookies, or the session value in any form.
        debugPrint('[RateGuard] BLOCK tripped: reason=${pushback.code} '
            'http=${code ?? '-'} url=$url '
            'body="${_safeBodySnippet(body, sessionId)}"');
        await RateGuard.instance
            .triggerChallengeCooldown(reason: pushback, statusCode: code);
        // RateLimitException (not a generic Exception) so catch sites can
        // tell "THIS call hit a block" apart from unrelated failures by type
        // — see the degraded-reason classification in _fetchIgItems. The
        // message text (and thus SelectionScreen's classifier) is unchanged.
        throw RateLimitException(
          'Instagram flagged automated activity (HTTP $code). Requests are '
          'paused to protect your account — open the Instagram app, clear any '
          'prompt, then wait before retrying.',
        );
      }
      rethrow;
    }

    if (resp.statusCode != 200 || resp.data == null) return [];

    // A 200 can still carry a soft challenge/login wall in its JSON body.
    final lowerBody = resp.data!.toLowerCase();
    final softPushback = RateGuard.pushbackReason(resp.statusCode, lowerBody);
    if (softPushback != null) {
      // Same diagnostic as the DioException branch — see the redaction notes
      // there. This is the HTTP-200-with-failure-body variant.
      debugPrint('[RateGuard] BLOCK tripped: reason=${softPushback.code} '
          'http=${resp.statusCode ?? '-'} url=$url '
          'body="${_safeBodySnippet(lowerBody, sessionId)}"');
      await RateGuard.instance.triggerChallengeCooldown(
          reason: softPushback, statusCode: resp.statusCode);
      // RateLimitException for the same type-based classification reason as
      // the DioException branch above.
      throw RateLimitException(
        'Instagram flagged automated activity. Requests are paused to protect '
        'your account — open the Instagram app, clear any prompt, then wait '
        'before retrying.',
      );
    }

    // Clean authenticated 200 — definitional proof any active block's premise
    // is gone (stronger than the synthetic probe, which hits a different
    // endpoint). Clears a lingering cooldown/auth state; no-op otherwise.
    await RateGuard.instance.noteAuthenticatedSuccess();

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

  /// Extracts the balanced JSON object starting at [start] in [text].
  /// Uses a brace-counter rather than a regex so nested objects don't confuse
  /// the parser — the regex `\{.+?\}` (non-greedy) stops at the first inner
  /// closing brace, which breaks JSON extraction for complex carousel responses.
  static String? _extractBalancedJson(String text, int start) {
    var depth = 0;
    for (var i = start; i < text.length; i++) {
      if (text[i] == '{') {
        depth++;
      } else if (text[i] == '}') {
        depth--;
        if (depth == 0) return text.substring(start, i + 1);
      }
    }
    return null;
  }

  List<MediaItem> _parseEmbedPage(String html, String pageUrl) {
    // window.__additionalDataLoaded('extra', {...});
    // We locate the opening { of the JSON argument, then use balanced-brace
    // extraction to capture the full object regardless of nesting depth.
    final callRe = RegExp(
      r'window\.__additionalDataLoaded\s*\(\s*[^,]+,\s*',
      dotAll: true,
    );
    final callMatch = callRe.firstMatch(html);
    if (callMatch == null) {
      debugPrint('[IG] No __additionalDataLoaded found in embed page');
      return [];
    }
    final jsonStart = html.indexOf('{', callMatch.end);
    if (jsonStart < 0) {
      debugPrint('[IG] No JSON object after __additionalDataLoaded');
      return [];
    }
    final jsonStr = _extractBalancedJson(html, jsonStart);
    if (jsonStr == null) {
      debugPrint('[IG] Could not balance braces in embed JSON');
      return [];
    }

    Map<String, dynamic> data;
    try {
      data = jsonDecode(jsonStr) as Map<String, dynamic>;
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

    // Instagram's own slide count for carousels. Present in the API-shaped
    // embed payload even when carousel_media itself is truncated; 0/absent
    // for genuine single-media posts.
    final declaredCount = (item['carousel_media_count'] as num?)?.toInt() ?? 0;

    // Carousel post: carousel_media array
    final carouselList = item['carousel_media'];
    if (carouselList is List && carouselList.isNotEmpty) {
      debugPrint('[IG] carousel_media: ${carouselList.length} slides'
          '${declaredCount > 0 ? ' (declared: $declaredCount)' : ''}');
      final items = _extractFromSlides(
        carouselList.cast<Map<String, dynamic>>(),
        username,
        postTimestamp: postTimestamp,
      );
      // Thin-payload guard: the embed JSON is a "limited" payload and can
      // truncate carousels. Reject ONLY on positive evidence of TRUNCATION:
      // the payload declaring more slides (carousel_media_count) than it
      // actually delivered (carouselList.length). Deliberately NOT compared
      // against how many items we EXTRACTED — a slide that ships in
      // carousel_media but yields no MediaItem (e.g. an ad / paid-partnership
      // slide with no image_versions2/video_versions) is a local extraction
      // miss, not a thin payload; escalating to the private API can't recover
      // it and would spend account-attributed calls on every fetch of that
      // post. A legitimate single-image post has no carousel_media and
      // declaredCount 0, so it can never trip this guard. Returning [] makes
      // the caller fall through to Strategy 0 (private API), which serves
      // the full post.
      if (declaredCount > carouselList.length) {
        debugPrint('[IG] Embed carousel truncated: payload delivered '
            '${carouselList.length} of $declaredCount declared slides — '
            'rejecting so the private API can serve the full post');
        return [];
      }
      if (items.length < carouselList.length) {
        // Complete payload, partial extraction — keep what we got (see above).
        debugPrint('[IG] Extracted ${items.length} of ${carouselList.length} '
            'delivered slides (non-media slide?) — keeping embed result');
      }
      return items;
    }

    // The payload claims this is a carousel (count > 1) but shipped no
    // carousel_media at all — a maximally-thin embed response. Same guard,
    // same fall-through to Strategy 0.
    if (declaredCount > 1) {
      debugPrint('[IG] Embed declares a $declaredCount-slide carousel but has '
          'no carousel_media — rejecting so the private API can serve the full post');
      return [];
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
          // Safety net: if the image CDN URL is actually a video, reclassify.
          final effectiveType = _urlLooksLikeVideo(imageUrl)
              ? MediaItemType.video
              : MediaItemType.image;
          items.add(MediaItem(
            id: '$i',
            mediaUrl: imageUrl,
            thumbnailUrl: effectiveType == MediaItemType.video ? null : imageUrl,
            type: effectiveType,
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
    for (final m
        in RegExp(r'"display_url"\s*:\s*"([^"]+)"').allMatches(html)) {
      final url = _unescape(m.group(1)!);
      // If this "display_url" is actually a video CDN URL, treat it as video
      if (_urlLooksLikeVideo(url)) {
        if (!videos.contains(url)) videos.add(url);
      } else if (!images.any((u) => _sameMedia(u, url))) {
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

  /// Returns true when a CDN URL is clearly a video regardless of OG type.
  /// Used as a fallback when the HTML scraper can't determine type from OG tags.
  static bool _urlLooksLikeVideo(String url) {
    final lower = url.toLowerCase().split('?').first;
    return lower.endsWith('.mp4') ||
        lower.endsWith('.mov') ||
        lower.contains('t50.2886-16') || // Instagram video CDN path
        lower.contains('/video/') ||
        lower.contains('video_url');
  }

  // ── 2.  Download a single MediaItem ───────────────────────────────────

  static const _mediaScannerChannel =
      MethodChannel('ig_downloader/media_scanner');

  /// Downloads [item] to the per-account folder inside public Downloads,
  /// then notifies Android's media scanner so it appears in the media browser
  /// without being duplicated into Pictures. Returns the saved file path.
  /// Returns `({path, skipped})` where [skipped] is true when the file
  /// already existed on disk and the download was bypassed.
  Future<({String path, bool skipped})> downloadItem(
    MediaItem item, {
    required void Function(double progress) onProgress,
  }) async {
    final ext = item.isVideo ? 'mp4' : 'jpg';
    final saveDir = await StorageService.getOrCreateSaveDir(item.username);
    final filename = '${item.filenameBase}.$ext';
    final savePath = '${saveDir.path}/$filename';
    // Download to a temp sibling first, then atomically rename on success. A
    // complete file therefore ONLY ever appears at the final path, so the
    // existence check below is a reliable "already downloaded" signal even if a
    // previous attempt was killed mid-stream while the app was backgrounded.
    final tempPath = '$savePath.part';
    debugPrint('[IG] savePath: $savePath');

    // Skip only when a COMPLETE file already exists. A zero-byte file is a
    // leftover from an interrupted download and must be re-fetched, not skipped
    // — this was the cause of false "already downloaded" reports.
    final existing = File(savePath);
    if (existing.existsSync() && existing.lengthSync() > 0) {
      debugPrint('[IG] Already exists (${existing.lengthSync()} B), skipping: $savePath');
      // Backfill: a file from before the ledger existed (or one the ledger
      // otherwise missed) still needs an entry so the selection screen hides
      // it from now on instead of just this one download bypassing it.
      await DownloadLedgerService.instance.record(item);
      return (path: savePath, skipped: true);
    }
    // Remove a stale 0-byte final file or a leftover .part from a prior attempt.
    if (existing.existsSync()) {
      try { existing.deleteSync(); } catch (_) {}
    }
    final stalePart = File(tempPath);
    if (stalePart.existsSync()) {
      try { stalePart.deleteSync(); } catch (_) {}
    }

    final sessionId = await SessionService.getSessionId(LoginPlatform.instagram);
    // Only send Instagram cookies for Instagram CDN URLs
    final isIgCdn = item.mediaUrl.contains('cdninstagram.com') ||
        item.mediaUrl.contains('instagram.com') ||
        item.mediaUrl.contains('fbcdn.net');

    await _dio.download(
      item.mediaUrl,
      tempPath,
      // On any Dio error the partial temp file is deleted, so an interrupted
      // download never leaves a file that looks complete.
      deleteOnError: true,
      options: (sessionId != null && isIgCdn)
          ? Options(headers: {'Cookie': 'sessionid=$sessionId'})
          : null,
      onReceiveProgress: (received, total) {
        if (total > 0) onProgress(received / total);
      },
    );

    // Verify we actually received bytes before promoting to the final name.
    final temp = File(tempPath);
    if (!temp.existsSync() || temp.lengthSync() == 0) {
      if (temp.existsSync()) {
        try { temp.deleteSync(); } catch (_) {}
      }
      throw Exception('Download produced an empty file — please retry.');
    }
    // Atomic promote within the same directory.
    await temp.rename(savePath);

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

    // Record the successful download so the selection screen hides this item
    // from the grid on any future fetch of the same post — the whole point
    // of the ledger (see its doc comment for why the key is date-independent).
    await DownloadLedgerService.instance.record(item);

    return (path: savePath, skipped: false);
  }
}

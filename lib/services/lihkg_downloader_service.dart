import 'dart:convert';
import 'dart:io' show HttpDate;
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:html/parser.dart' as html_parser;

import '../models/media_item.dart';
import 'host_rate_limiter.dart';

/// Image extractor for LIHKG (lihkg.com) forum threads, including its
/// `lih.kg` short-link form.
///
/// LIHKG is a single-page React app behind Cloudflare, so the server HTML of a
/// thread URL only contains the og:image — the actual post images load later
/// via its JSON API. We therefore pull images straight from the API:
///   https://lihkg.com/api_v2/thread/{threadId}/page/{page}?order=reply_time
/// Each reply's `msg` field is an HTML fragment; we collect every <img> in it.
///
/// Pages are fetched until an empty page or [_maxPages] is reached, so a long
/// thread still yields a bounded, de-duplicated set of images. This is a
/// public JSON API, not an account-bearing endpoint, so unlike the Instagram
/// path there is no session and no RateGuard involved here — only a jittered
/// delay between page requests to be a polite crawler, plus a per-page
/// retry-with-backoff (see [_backoffForRetry]) when LIHKG answers 429/503.
///
/// Client-side protection against LIHKG's own rate limiting (a field-verified
/// 429 with a persistent block, see [HostRateLimiter]'s doc comment) is
/// layered on top via [_rateLimiter]: a persisted cooldown checked before any
/// request goes out at all, an in-memory request-volume bucket, adaptive
/// pacing of the inter-page delay, and a short-lived response cache so
/// re-sharing the same thread doesn't refetch it.
class LihkgDownloaderService {
  static const _ua =
      'Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/124.0.0.0 Mobile Safari/537.36';

  // Bound the crawl so a very long thread doesn't hammer the API or the UI.
  static const _maxPages = 10;

  // Retries per page on a 429/503 before giving up on that page — see
  // [_backoffForRetry] for the 2s/4s/8s schedule this pairs with.
  static const _maxRetriesPerPage = 3;

  // Never let a Retry-After header (or our own backoff) stall the UI longer
  // than this, however hostile the server's value.
  static const _maxBackoff = Duration(seconds: 15);

  // Host key for every HostRateLimiter lookup below — LIHKG only for now
  // (see HostRateLimiter's class doc for why it's keyed by host at all).
  static const _rateLimiterHost = 'lihkg.com';

  final Dio _dio;
  final Random _random;
  final Future<void> Function(Duration) _delay;
  final HostRateLimiter _rateLimiter;

  LihkgDownloaderService({
    Dio? dio,
    Random? random,
    Future<void> Function(Duration)? delay,
    HostRateLimiter? rateLimiter,
  })  : _dio = dio ??
            Dio(BaseOptions(
              connectTimeout: const Duration(seconds: 15),
              receiveTimeout: const Duration(seconds: 30),
              headers: {
                'User-Agent': _ua,
                'Accept': 'application/json, text/plain, */*',
                'Accept-Language': 'zh-HK,zh;q=0.9,en;q=0.8',
                'Referer': 'https://lihkg.com/',
                'X-Requested-With': 'XMLHttpRequest',
              },
            )),
        _random = random ?? Random(),
        _delay = delay ?? ((d) => Future.delayed(d)),
        // Defaults to the shared singleton, NOT a fresh instance per call —
        // this service is constructed fresh on every share
        // (DownloaderService.fetchItems), so the cooldown/bucket/cache state
        // needs to live in something longer-lived than one instance. See
        // HostRateLimiter.instance's doc comment. Tests inject their own.
        _rateLimiter = rateLimiter ?? HostRateLimiter.instance;

  /// True for a LIHKG thread URL, either the canonical form
  ///   https://lihkg.com/thread/1234567
  ///   https://lihkg.com/thread/1234567/page/3
  /// or the `lih.kg` short-link form
  ///   https://lih.kg/1234567
  ///
  /// The host is parsed properly with [Uri] rather than a substring check —
  /// post markup can carry `https://i.lih.kg/thumbnail?u=https%3A%2F%2F...`
  /// (the thumbnail proxy, see [_imagesFromMsg]'s doc comment), and a naive
  /// `url.contains('lih.kg/')` would wrongly match that subdomain's URL too.
  static bool isLihkgUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return false;
    final host = uri.host.toLowerCase();
    if (host == 'lihkg.com' || host == 'www.lihkg.com') {
      return uri.path.toLowerCase().contains('/thread/');
    }
    // Only the bare `lih.kg` (or `www.lih.kg`) host counts as a short link —
    // NOT `i.lih.kg` or any other subdomain. The path form is checked in
    // [fetchItems] via [_resolveThreadId], which falls back to a single
    // redirect-following request for a non-numeric path.
    return host == 'lih.kg' || host == 'www.lih.kg';
  }

  /// Thread id from a URL already known to match one of the two forms in
  /// [isLihkgUrl]'s doc comment. Returns null for a `lih.kg` URL whose path
  /// isn't a bare numeric id — that case is handled by [_resolveThreadId].
  static String? _threadId(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return null;
    final host = uri.host.toLowerCase();
    if (host == 'lihkg.com' || host == 'www.lihkg.com') {
      return RegExp(r'/thread/(\d+)').firstMatch(uri.path)?.group(1);
    }
    if (host == 'lih.kg' || host == 'www.lih.kg') {
      return RegExp(r'^/(\d+)/?$').firstMatch(uri.path)?.group(1);
    }
    return null;
  }

  /// Resolves [url] to a numeric thread id, following ONE redirect when the
  /// `lih.kg` path isn't already numeric (an unknown future slug form).
  /// Never issues more than this single request — if it doesn't yield a
  /// `lihkg.com/thread/<id>` URL, [fetchItems] reports the URL as
  /// unrecognised rather than retrying.
  Future<String?> _resolveThreadId(String url) async {
    final direct = _threadId(url);
    if (direct != null) return direct;

    final uri = Uri.tryParse(url);
    final host = uri?.host.toLowerCase();
    if (uri == null || (host != 'lih.kg' && host != 'www.lih.kg')) {
      return null;
    }

    debugPrint('[LIHKG] lih.kg path is not a bare numeric id — resolving '
        'via one redirect-following request: $url');
    try {
      // Gate this one request too — it's a real HTTP request to the same
      // host as the page crawl below.
      await _rateLimiter.awaitSlot(_rateLimiterHost);
      final resp = await _dio.get<dynamic>(
        url,
        options: Options(
          followRedirects: true,
          validateStatus: (_) => true,
        ),
      );
      final finalUrl = resp.realUri.toString();
      final resolved = _threadId(finalUrl);
      if (resolved == null) {
        debugPrint('[LIHKG] redirect target was not a recognised thread URL: '
            '$finalUrl');
      }
      return resolved;
    } catch (e) {
      debugPrint('[LIHKG] redirect resolution failed: $e');
      return null;
    }
  }

  /// Extract all post images from a LIHKG thread.
  Future<List<MediaItem>> fetchItems(String url) async {
    await _rateLimiter.init();

    // Checked BEFORE anything else — including thread-id resolution's own
    // request — so a fresh share never sends a single byte while LIHKG is
    // in cooldown. This is the change that stops the app extending its own
    // block: without it, every re-share fired a fresh doomed burst that
    // re-triggered (and extended) the 429.
    final cooldown = _rateLimiter.cooldownRemaining(_rateLimiterHost);
    if (cooldown != null) {
      final secs = (cooldown.inMilliseconds / 1000).ceil();
      throw Exception(
        'LIHKG is rate-limiting requests right now — try again in ${secs}s.',
      );
    }

    final threadId = await _resolveThreadId(url);
    if (threadId == null) {
      throw Exception('Not a recognised LIHKG thread URL.');
    }
    debugPrint('[LIHKG] thread $threadId');

    final seen = <String>{};
    final urls = <String>[];
    num? lastTotalPage;
    var pagesFetched = 0;
    // Whether any page in this crawl was actually throttled, and whether any
    // real HTTP request was made at all (an all-cache-hit crawl is zero
    // evidence about the host's health either way) — together these decide
    // whether a clean fetch is reported to the rate limiter at the end, so
    // the adaptive-pacing multiplier can decay back down.
    var sawThrottle = false;
    var madeAnyRequest = false;

    for (var page = 1; page <= _maxPages; page++) {
      final cacheKey = 'lihkg:$threadId:page:$page';
      var data = _rateLimiter.cached<Map<dynamic, dynamic>>(cacheKey);
      // Per-PAGE, not per-crawl: only a page just fetched fresh over the
      // network in THIS iteration is eligible to be (re-)cached below —
      // reading a value back out of the cache must never re-store it.
      var fetchedFresh = false;
      if (data != null) {
        debugPrint('[LIHKG] page $page from cache');
      } else {
        madeAnyRequest = true;
        fetchedFresh = true;
        if (page > 1) {
          // Jittered pause between page requests — deliberate politeness
          // toward a public API (not a latency bug), paced generously enough
          // that a long thread's page-by-page crawl doesn't itself trip
          // LIHKG's rate limiter. Widened by the adaptive-pacing multiplier
          // ([HostRateLimiter.pace]) after a recent throttle.
          final jitterMs = 700 + _random.nextInt(501); // 700-1200ms
          await _delay(_rateLimiter.pace(
              _rateLimiterHost, Duration(milliseconds: jitterMs)));
        }
        final api =
            'https://lihkg.com/api_v2/thread/$threadId/page/$page?order=reply_time';

        for (var attempt = 0; attempt <= _maxRetriesPerPage; attempt++) {
          try {
            await _rateLimiter.awaitSlot(_rateLimiterHost);
            // responseType json — but tolerate string bodies behind Cloudflare.
            final resp = await _dio.get<dynamic>(api);
            final parsed = resp.data is String
                ? jsonDecode(resp.data as String)
                : resp.data;
            data = parsed is Map ? parsed : null;
            break;
          } on DioException catch (e) {
            final status = e.response?.statusCode;
            final isThrottled = status == 429 || status == 503;
            if (!isThrottled) {
              debugPrint('[LIHKG] api page $page failed: $e');
              break;
            }
            // Record the throttle/pacing signal immediately — before any of
            // the branches below (including the fail-fast throw), so a
            // fail-fast on the very first attempt still reaches
            // HostRateLimiter and the next share doesn't re-trigger the
            // same block.
            final askedFor = _parseRetryAfter(e.response);
            sawThrottle = true;
            await _rateLimiter.noteThrottled(_rateLimiterHost,
                retryAfter: askedFor);
            if (attempt < _maxRetriesPerPage) {
              final retryNum = attempt + 1;
              // LIHKG asked us to wait longer than we are willing to hold
              // the UI for. Retrying at the capped delay would just burn
              // the remaining attempts inside the same block and make the
              // user wait ~45s for a certain failure, so stop now and
              // report the real wait instead. (Leaving `data` null breaks
              // the page loop.)
              if (askedFor != null && askedFor > _maxBackoff) {
                if (urls.isEmpty) {
                  throw Exception(
                    'LIHKG is rate-limiting requests right now — it asked us to '
                    'wait ${askedFor.inSeconds}s. Try again shortly.',
                  );
                }
                debugPrint('[LIHKG] rate-limited at page $page (Retry-After '
                    '${askedFor.inSeconds}s) — returning the ${urls.length} '
                    'images found so far');
                break;
              }
              final backoff = _backoffForRetry(retryNum, e.response);
              debugPrint('[LIHKG] page $page rate-limited ($status) — retry '
                  '$retryNum/$_maxRetriesPerPage in '
                  '${(backoff.inMilliseconds / 1000).toStringAsFixed(1)}s');
              await _delay(backoff);
              continue;
            }
            // Retries exhausted on this page.
            if (urls.isEmpty) {
              throw Exception(
                'LIHKG is rate-limiting requests right now. Wait a minute and '
                'try again.',
              );
            }
            debugPrint('[LIHKG] rate-limited at page $page — returning the '
                '${urls.length} images found so far');
            break;
          } catch (e) {
            debugPrint('[LIHKG] api page $page failed: $e');
            break;
          }
        }
      }
      if (data == null) break;

      if (data['success'] == 0 || data['success'] == false) {
        debugPrint('[LIHKG] api page $page not successful');
        break;
      }

      // Cache only a genuinely successful page, and only what was actually
      // just fetched fresh (not a value we just read back out of the cache)
      // — caching a `{"success":0}` blip would otherwise strand the user on
      // "no images found" for the full 15-minute TTL with no way to retry
      // sooner.
      if (fetchedFresh) _rateLimiter.store(cacheKey, data);

      final items = (data['response'] as Map?)?['item_data'] as List?;
      if (items == null || items.isEmpty) break;

      for (final it in items) {
        final msg = (it as Map)['msg'] as String?;
        if (msg == null || msg.isEmpty) continue;
        for (final src in _imagesFromMsg(msg)) {
          if (seen.add(src)) urls.add(src);
        }
      }
      pagesFetched = page;
      // Stop early once the thread is exhausted.
      final totalPage = (data['response'] as Map?)?['total_page'];
      if (totalPage is num) lastTotalPage = totalPage;
      if (totalPage is num && page >= totalPage) break;
    }

    // The crawl hit [_maxPages] before the thread's own total_page was
    // reached — the image list may be incomplete, so log it clearly (the
    // bound itself is intentional and stays in place).
    if (pagesFetched == _maxPages &&
        lastTotalPage != null &&
        lastTotalPage > _maxPages) {
      debugPrint('[LIHKG] stopped at page $_maxPages of $lastTotalPage — '
          'image list may be incomplete');
    }

    // No throttle seen, and at least one real request was made (an
    // all-cache-hit crawl says nothing about the host) — step the adaptive
    // pacing multiplier back down toward x1.
    if (!sawThrottle && madeAnyRequest) {
      await _rateLimiter.noteCleanFetch(_rateLimiterHost);
    }

    if (urls.isEmpty) {
      throw Exception(
        'No images found in this LIHKG thread.\n'
        'It may be text-only, or LIHKG blocked the request — try opening it in '
        'a browser first.',
      );
    }

    debugPrint('[LIHKG] SERVED BY API: thread=$threadId pages=$pagesFetched '
        'images=${urls.length}');
    return [
      for (var i = 0; i < urls.length; i++)
        MediaItem(
          id: '$i',
          mediaUrl: urls[i],
          thumbnailUrl: urls[i],
          type: MediaItemType.image,
          username: 'lihkg_$threadId',
          itemIndex: i + 1,
        ),
    ];
  }

  /// Backoff before retry number [retryNumber] (1-based) of a 429/503 page
  /// request: an exponential 2s / 4s / 8s schedule with ±20% jitter so
  /// repeated runs don't all retry in lockstep. A `Retry-After` header on
  /// [response] overrides the computed value when it asks for longer, but
  /// the result is always capped at [_maxBackoff] so a hostile or
  /// unreasonable server value can never stall the UI.
  Duration _backoffForRetry(int retryNumber, Response<dynamic>? response) {
    final baseMs = 2000 * pow(2, retryNumber - 1).toInt(); // 2s, 4s, 8s, ...
    final jitter = 0.8 + _random.nextDouble() * 0.4; // ±20%
    var backoff = Duration(milliseconds: (baseMs * jitter).round());

    final retryAfter = _parseRetryAfter(response);
    if (retryAfter != null && retryAfter > backoff) {
      backoff = retryAfter;
    }
    return backoff > _maxBackoff ? _maxBackoff : backoff;
  }

  /// Parses a `Retry-After` response header, which per RFC 9110 is either a
  /// number of seconds or an HTTP-date. Returns null when absent or
  /// unparseable, in which case the caller falls back to the computed
  /// backoff.
  Duration? _parseRetryAfter(Response<dynamic>? response) {
    final value = response?.headers.value('retry-after');
    if (value == null) return null;
    final seconds = int.tryParse(value.trim());
    if (seconds != null) return Duration(seconds: seconds);
    try {
      final date = HttpDate.parse(value);
      final diff = date.difference(DateTime.now().toUtc());
      return diff.isNegative ? Duration.zero : diff;
    } catch (_) {
      return null;
    }
  }

  /// Pull image URLs out of a reply's HTML `msg` fragment.
  ///
  /// `src` is the real full-resolution image (e.g. a `na.cx` upload); LIHKG's
  /// own `data-thumbnail-src="https://i.lih.kg/thumbnail?u=..."` attribute is
  /// a proxy thumbnail and is never read here. `hkgmoji` reaction images use
  /// a relative `/assets/...` src and are excluded by the `/assets/` check
  /// below.
  @visibleForTesting
  static List<String> imagesFromMsgForTesting(String msg) =>
      _imagesFromMsg(msg);

  static List<String> _imagesFromMsg(String msg) {
    final out = <String>[];
    final doc = html_parser.parse(msg);
    for (final img in doc.querySelectorAll('img')) {
      // LIHKG lazy-loads with data-src / data-original; src may be a spinner.
      final src = img.attributes['data-original'] ??
          img.attributes['data-src'] ??
          img.attributes['src'] ??
          '';
      if (src.startsWith('http') && !src.contains('/assets/')) {
        out.add(src);
      }
    }
    return out;
  }
}

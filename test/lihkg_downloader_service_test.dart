import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ig_downloader/services/host_rate_limiter.dart';
import 'package:ig_downloader/services/lihkg_downloader_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Fake [HttpClientAdapter] backing a synthetic LIHKG API. [pageBodies] maps
/// a 1-based page number to the raw JSON string the API_v2 endpoint would
/// return for that page — built by hand here (NOT copied from any real
/// response, which would carry third-party forum usernames/user ids).
class _LihkgApiAdapter implements HttpClientAdapter {
  _LihkgApiAdapter(this.pageBodies);
  final Map<int, String> pageBodies;

  /// Total number of requests actually sent through this adapter — used to
  /// assert an exact "zero HTTP requests" (cache hit / cooldown short-
  /// circuit) rather than inferring it from returned data.
  int requestCount = 0;

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requestCount++;
    final m = RegExp(r'/page/(\d+)').firstMatch(options.path);
    final page = m != null ? int.parse(m.group(1)!) : 1;
    final body = pageBodies[page] ?? jsonEncode({'success': 0});
    return ResponseBody.fromString(
      body,
      200,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }
}

/// A trivial fake clock a test can advance explicitly (e.g. past the cache
/// TTL or a cooldown window) without ever sleeping for real.
class _FakeClock {
  DateTime now = DateTime(2026, 1, 1);
  DateTime call() => now;
  void advance(Duration d) => now = now.add(d);
}

LihkgDownloaderService _serviceFor(
  Map<int, String> pageBodies, {
  _LihkgApiAdapter? adapter,
  HostRateLimiter? rateLimiter,
}) {
  final dio = Dio(BaseOptions(responseType: ResponseType.plain));
  dio.httpClientAdapter = adapter ?? _LihkgApiAdapter(pageBodies);
  // No-op delay so the inter-page pacing pause never makes the test suite
  // actually sleep — the pacing value itself is exercised separately below.
  return LihkgDownloaderService(
    dio: dio,
    delay: (_) async {},
    rateLimiter: rateLimiter,
  );
}

/// One scripted response for a single request to a page: either a 429/503
/// failure (optionally carrying a `Retry-After` header) or a 200 success
/// body. [_FlakyLihkgApiAdapter] replays a list of these per page, in order,
/// so a page can be made to fail N times before succeeding.
class _Attempt {
  const _Attempt.fail(this.failStatus, {this.retryAfterHeader})
      : body = null;
  const _Attempt.success(this.body)
      : failStatus = null,
        retryAfterHeader = null;

  final int? failStatus;
  final String? retryAfterHeader;
  final String? body;
}

/// Fake [HttpClientAdapter] that scripts a sequence of responses per page —
/// used to exercise the 429/503 retry-with-backoff path. Returning a
/// non-2xx status here (rather than throwing directly) matches how Dio
/// actually surfaces a real 429: the adapter just returns the response, and
/// Dio's default `validateStatus` turns it into a `DioException` with
/// `response.statusCode == 429`, exactly like the real device log.
class _FlakyLihkgApiAdapter implements HttpClientAdapter {
  _FlakyLihkgApiAdapter(this.pageAttempts);
  final Map<int, List<_Attempt>> pageAttempts;
  final Map<int, int> _callsSoFar = {};

  /// Total number of requests actually sent — see [_LihkgApiAdapter.requestCount].
  int requestCount = 0;

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requestCount++;
    final m = RegExp(r'/page/(\d+)').firstMatch(options.path);
    final page = m != null ? int.parse(m.group(1)!) : 1;
    final callIndex = _callsSoFar[page] ?? 0;
    _callsSoFar[page] = callIndex + 1;

    final attempts = pageAttempts[page] ?? const [];
    // Once the scripted attempts for a page are exhausted, keep replaying
    // the last one (tests only script as many attempts as they need).
    final attempt = attempts.isEmpty
        ? const _Attempt.success('{"success":0}')
        : attempts[callIndex.clamp(0, attempts.length - 1)];

    if (attempt.failStatus != null) {
      final headers = <String, List<String>>{
        Headers.contentTypeHeader: ['application/json'],
      };
      if (attempt.retryAfterHeader != null) {
        headers['retry-after'] = [attempt.retryAfterHeader!];
      }
      return ResponseBody.fromString('{}', attempt.failStatus!,
          headers: headers);
    }
    return ResponseBody.fromString(attempt.body!, 200, headers: {
      Headers.contentTypeHeader: ['application/json'],
    });
  }
}

LihkgDownloaderService _flakyServiceFor(
  Map<int, List<_Attempt>> pageAttempts, {
  Future<void> Function(Duration)? delay,
  _FlakyLihkgApiAdapter? adapter,
  HostRateLimiter? rateLimiter,
}) {
  final dio = Dio(BaseOptions(responseType: ResponseType.plain));
  dio.httpClientAdapter = adapter ?? _FlakyLihkgApiAdapter(pageAttempts);
  return LihkgDownloaderService(
    dio: dio,
    delay: delay ?? (_) async {},
    rateLimiter: rateLimiter,
  );
}

/// Builds a synthetic api_v2 thread page response with the real shape
/// (`success` / `response.total_page` / `response.item_data[].msg`) but
/// fully invented content.
String _pageJson({
  required List<String> msgs,
  required int totalPage,
}) =>
    jsonEncode({
      'success': 1,
      'response': {
        'total_page': totalPage,
        'item_data': [
          for (final msg in msgs) {'msg': msg},
        ],
      },
    });

void main() {
  setUp(() {
    // HostRateLimiter persists the cooldown/pacing state via
    // SharedPreferences — without a mocked store every test touching it
    // would throw (no platform channel in the test environment).
    SharedPreferences.setMockInitialValues({});
    // Every test that doesn't inject its own HostRateLimiter falls back to
    // LihkgDownloaderService's default, HostRateLimiter.instance — a
    // process-wide singleton (see its doc comment for why). Without this
    // reset its in-memory state (cooldown/pacing/cache/bucket) would leak
    // across tests even though the prefs mock above is reset each time.
    HostRateLimiter.instance.clearForTest();
  });

  group('LihkgDownloaderService.isLihkgUrl', () {
    test('true for lih.kg numeric short link', () {
      expect(LihkgDownloaderService.isLihkgUrl('https://lih.kg/4158154'),
          isTrue);
    });

    test('true for lihkg.com/thread/<id>', () {
      expect(
          LihkgDownloaderService.isLihkgUrl('https://lihkg.com/thread/4158154'),
          isTrue);
    });

    test('true for lihkg.com/thread/<id>/page/<n>', () {
      expect(
        LihkgDownloaderService.isLihkgUrl(
            'https://lihkg.com/thread/4158154/page/3'),
        isTrue,
      );
    });

    test(
        'false for i.lih.kg thumbnail proxy URL — a real trap: it embeds '
        '"lih.kg/" as a substring but is a different subdomain entirely', () {
      expect(
        LihkgDownloaderService.isLihkgUrl(
          'https://i.lih.kg/thumbnail?u=https%3A%2F%2Fna.cx%2Fi%2FBFLiDAk.jpg'
          '&h=25c8974d&s=300',
        ),
        isFalse,
      );
    });

    test('false for an unrelated host', () {
      expect(LihkgDownloaderService.isLihkgUrl('https://example.com/thread/1'),
          isFalse);
      expect(LihkgDownloaderService.isLihkgUrl('https://na.cx/i/BFLiDAk.jpg'),
          isFalse);
    });
  });

  group('LihkgDownloaderService.imagesFromMsgForTesting', () {
    test(
        'real measured markup: src (na.cx) is kept, i.lih.kg thumbnail proxy '
        'is never chosen, hkgmoji /assets/ emoji is excluded', () {
      const msg = '<img src="https://na.cx/i/BFLiDAk.jpg" '
          'data-thumbnail-src="https://i.lih.kg/thumbnail?u=https%3A%2F%2F'
          'na.cx%2Fi%2FBFLiDAk.jpg&h=25c8974d&s=300" />'
          '<img src="/assets/faces/normal/bouncer.gif" class="hkgmoji" />';

      final images = LihkgDownloaderService.imagesFromMsgForTesting(msg);

      expect(images, ['https://na.cx/i/BFLiDAk.jpg']);
    });

    test('data-original lazy-load variant is preferred over a spinner src',
        () {
      const msg = '<img src="https://na.cx/spinner.gif" '
          'data-original="https://na.cx/i/real.jpg" />';

      final images = LihkgDownloaderService.imagesFromMsgForTesting(msg);

      expect(images, ['https://na.cx/i/real.jpg']);
    });

    test('data-src lazy-load variant is preferred over a spinner src', () {
      const msg = '<img src="https://na.cx/spinner.gif" '
          'data-src="https://na.cx/i/real2.jpg" />';

      final images = LihkgDownloaderService.imagesFromMsgForTesting(msg);

      expect(images, ['https://na.cx/i/real2.jpg']);
    });

    test('relative /assets/ src with no http prefix is excluded', () {
      const msg = '<img src="/assets/faces/normal/bouncer.gif" />';

      final images = LihkgDownloaderService.imagesFromMsgForTesting(msg);

      expect(images, isEmpty);
    });
  });

  group('LihkgDownloaderService.fetchItems — thread id extraction', () {
    test('lih.kg numeric short link resolves to the same thread id as the '
        'canonical form', () async {
      final service = _serviceFor({
        1: _pageJson(
          msgs: ['<img src="https://na.cx/i/one.jpg" />'],
          totalPage: 1,
        ),
      });

      final items = await service.fetchItems('https://lih.kg/4158154');

      expect(items, hasLength(1));
      expect(items.single.username, 'lihkg_4158154',
          reason: 'the username is the ledger/dedup key and must stay '
              'lihkg_<threadId>, not the thread title');
    });

    test('lihkg.com/thread/<id>/page/<n> extracts the thread id, ignoring '
        'the deep-link page suffix', () async {
      final service = _serviceFor({
        1: _pageJson(
          msgs: ['<img src="https://na.cx/i/one.jpg" />'],
          totalPage: 1,
        ),
      });

      final items = await service
          .fetchItems('https://lihkg.com/thread/4158154/page/3');

      expect(items, hasLength(1));
      expect(items.single.username, 'lihkg_4158154');
    });

    test('unrecognised URL throws', () async {
      final service = _serviceFor({});
      expect(
        () => service.fetchItems('https://example.com/not-a-thread'),
        throwsA(isA<Exception>()),
      );
    });
  });

  group('LihkgDownloaderService.fetchItems — dedup, ordering, pagination', () {
    test(
        'images are de-duplicated across replies and pages, kept in '
        'first-seen order, and 1-based itemIndex is sequential', () async {
      final service = _serviceFor({
        1: _pageJson(
          msgs: [
            '<img src="https://na.cx/i/AAA.jpg" '
                'data-thumbnail-src="https://i.lih.kg/thumbnail?u=x" />',
            '<img src="https://na.cx/i/BBB.jpg" />',
          ],
          totalPage: 2,
        ),
        2: _pageJson(
          msgs: [
            '<img src="https://na.cx/i/AAA.jpg" />', // duplicate of page 1
            '<img src="https://na.cx/i/CCC.jpg" />',
          ],
          totalPage: 2,
        ),
      });

      final items = await service.fetchItems('https://lihkg.com/thread/999');

      expect(items.map((i) => i.mediaUrl).toList(), [
        'https://na.cx/i/AAA.jpg',
        'https://na.cx/i/BBB.jpg',
        'https://na.cx/i/CCC.jpg',
      ]);
      expect(items.map((i) => i.itemIndex).toList(), [1, 2, 3]);
      expect(items.every((i) => i.username == 'lihkg_999'), isTrue);
    });

    test(
        'the crawl stops at the _maxPages bound (10) even when total_page '
        'declares more pages are available', () async {
      final pageBodies = <int, String>{
        for (var p = 1; p <= 11; p++)
          p: _pageJson(
            msgs: ['<img src="https://na.cx/i/img$p.jpg" />'],
            totalPage: 15,
          ),
      };
      final service = _serviceFor(pageBodies);

      final items = await service.fetchItems('https://lihkg.com/thread/555');

      expect(items, hasLength(10),
          reason: 'page 11 must never be requested — the bound was raised '
              'from 5 to 10, not removed');
      expect(items.last.mediaUrl, 'https://na.cx/i/img10.jpg');
    });
  });

  group('LihkgDownloaderService.fetchItems — 429/503 retry & rate limiting',
      () {
    test(
        '429 then success on retry returns the images without throwing',
        () async {
      final service = _flakyServiceFor({
        1: [
          const _Attempt.fail(429),
          _Attempt.success(_pageJson(
            msgs: ['<img src="https://na.cx/i/one.jpg" />'],
            totalPage: 1,
          )),
        ],
      });

      final items = await service.fetchItems('https://lihkg.com/thread/1');

      expect(items, hasLength(1));
      expect(items.single.mediaUrl, 'https://na.cx/i/one.jpg');
    });

    test(
        '429 on every retry attempt of page 1 (nothing collected yet) '
        'throws the distinct rate-limit message, not the generic '
        '"no images found" one', () async {
      final service = _flakyServiceFor({
        // Initial attempt + 3 retries — all throttled, nothing ever
        // collected.
        1: const [
          _Attempt.fail(429),
          _Attempt.fail(429),
          _Attempt.fail(429),
          _Attempt.fail(429),
        ],
      });

      expect(
        () => service.fetchItems('https://lihkg.com/thread/2'),
        throwsA(
          isA<Exception>().having(
            (e) => e.toString(),
            'message',
            contains(
                'LIHKG is rate-limiting requests right now. Wait a minute '
                'and try again.'),
          ),
        ),
      );
    });

    test(
        '429 exhausted on page 2 after page 1 already returned images '
        'keeps page 1\'s images instead of throwing', () async {
      final service = _flakyServiceFor({
        1: [
          _Attempt.success(_pageJson(
            msgs: ['<img src="https://na.cx/i/p1.jpg" />'],
            totalPage: 2,
          )),
        ],
        2: const [
          _Attempt.fail(429),
          _Attempt.fail(429),
          _Attempt.fail(429),
          _Attempt.fail(429),
        ],
      });

      final items = await service.fetchItems('https://lihkg.com/thread/3');

      expect(items, hasLength(1));
      expect(items.single.mediaUrl, 'https://na.cx/i/p1.jpg');
    });

    test(
        'a Retry-After header longer than the computed backoff is honoured '
        'verbatim (no jitter applied to it)', () async {
      final delays = <Duration>[];
      final service = _flakyServiceFor(
        {
          1: [
            const _Attempt.fail(429, retryAfterHeader: '3'),
            _Attempt.success(_pageJson(
              msgs: ['<img src="https://na.cx/i/one.jpg" />'],
              totalPage: 1,
            )),
          ],
        },
        delay: (d) async {
          delays.add(d);
        },
      );

      final items = await service.fetchItems('https://lihkg.com/thread/4');

      expect(items, hasLength(1));
      // The computed backoff for retry 1 is 2s ± 20% (max 2.4s), always
      // shorter than the 3s Retry-After header, so the header must win —
      // and verbatim, since only the computed backoff is jittered.
      expect(delays, [const Duration(seconds: 3)]);
    });
  });

  group('LihkgDownloaderService.fetchItems — HostRateLimiter cooldown', () {
    test(
        'a fail-fast 429 (Retry-After beyond the 15s cap) is recorded as a '
        "cooldown: an immediate re-share makes ZERO HTTP requests and throws "
        'the countdown message instead of re-triggering the block', () async {
      final adapter = _FlakyLihkgApiAdapter({
        1: const [_Attempt.fail(429, retryAfterHeader: '60')],
      });
      final service = _flakyServiceFor({}, adapter: adapter);

      await expectLater(
        () => service.fetchItems('https://lihkg.com/thread/10'),
        throwsA(isA<Exception>().having(
          (e) => e.toString(),
          'message',
          contains('wait 60s'),
        )),
      );
      expect(adapter.requestCount, 1,
          reason: 'the fail-fast path stops after a single attempt');

      // Immediate re-share of a DIFFERENT thread — the cooldown is per-host
      // (lihkg.com), not per-thread, so it must still short-circuit here.
      await expectLater(
        () => service.fetchItems('https://lihkg.com/thread/11'),
        throwsA(isA<Exception>().having(
          (e) => e.toString(),
          'message',
          allOf(
            contains('LIHKG is rate-limiting requests right now'),
            contains('try again in'),
          ),
        )),
      );
      expect(adapter.requestCount, 1,
          reason: 'the cooldown check happens before any request is sent — '
              'the second call must not touch the network at all');
    });
  });

  group('LihkgDownloaderService.fetchItems — response cache', () {
    test(
        'a re-share of the same thread inside the 15-minute cache TTL makes '
        'ZERO HTTP requests and returns the same items; after the TTL '
        'expires it fetches again', () async {
      final clock = _FakeClock();
      final rateLimiter = HostRateLimiter(now: clock.call, delay: (_) async {});
      final adapter = _LihkgApiAdapter({
        1: _pageJson(
          msgs: ['<img src="https://na.cx/i/one.jpg" />'],
          totalPage: 1,
        ),
      });
      final service =
          _serviceFor({}, adapter: adapter, rateLimiter: rateLimiter);

      final first = await service.fetchItems('https://lihkg.com/thread/20');
      expect(adapter.requestCount, 1);
      expect(first.single.mediaUrl, 'https://na.cx/i/one.jpg');

      final second = await service.fetchItems('https://lihkg.com/thread/20');
      expect(adapter.requestCount, 1,
          reason: 'served entirely from cache — zero HTTP requests');
      expect(second.single.mediaUrl, first.single.mediaUrl);

      // Advance past HostRateLimiter.defaultCacheTtl (15 minutes).
      clock.advance(const Duration(minutes: 15, seconds: 1));

      final third = await service.fetchItems('https://lihkg.com/thread/20');
      expect(adapter.requestCount, 2,
          reason: 'the cache entry expired — the page is fetched again');
      expect(third.single.mediaUrl, first.single.mediaUrl);
    });

    test(
        'a `{"success":0}` response is never cached, so a retry shortly '
        'after still hits the network instead of being stuck on the same '
        'failure for the full TTL', () async {
      final adapter = _FlakyLihkgApiAdapter({
        1: [
          const _Attempt.success('{"success":0}'),
          _Attempt.success(_pageJson(
            msgs: ['<img src="https://na.cx/i/one.jpg" />'],
            totalPage: 1,
          )),
        ],
      });
      final service = _flakyServiceFor({}, adapter: adapter);

      await expectLater(
        () => service.fetchItems('https://lihkg.com/thread/30'),
        throwsA(isA<Exception>().having(
          (e) => e.toString(),
          'message',
          contains('No images found'),
        )),
      );
      expect(adapter.requestCount, 1);

      final items = await service.fetchItems('https://lihkg.com/thread/30');
      expect(adapter.requestCount, 2,
          reason: 'the success:0 response must not have been cached');
      expect(items.single.mediaUrl, 'https://na.cx/i/one.jpg');
    });
  });
}

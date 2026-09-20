import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ig_downloader/services/lihkg_downloader_service.dart';

/// Fake [HttpClientAdapter] backing a synthetic LIHKG API. [pageBodies] maps
/// a 1-based page number to the raw JSON string the API_v2 endpoint would
/// return for that page — built by hand here (NOT copied from any real
/// response, which would carry third-party forum usernames/user ids).
class _LihkgApiAdapter implements HttpClientAdapter {
  _LihkgApiAdapter(this.pageBodies);
  final Map<int, String> pageBodies;

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
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

LihkgDownloaderService _serviceFor(Map<int, String> pageBodies) {
  final dio = Dio(BaseOptions(responseType: ResponseType.plain));
  dio.httpClientAdapter = _LihkgApiAdapter(pageBodies);
  // No-op delay so the inter-page pacing pause never makes the test suite
  // actually sleep — the pacing value itself is exercised separately below.
  return LihkgDownloaderService(dio: dio, delay: (_) async {});
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

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
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
}) {
  final dio = Dio(BaseOptions(responseType: ResponseType.plain));
  dio.httpClientAdapter = _FlakyLihkgApiAdapter(pageAttempts);
  return LihkgDownloaderService(
    dio: dio,
    delay: delay ?? (_) async {},
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
}

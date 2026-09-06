import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ig_downloader/models/media_item.dart';
import 'package:ig_downloader/services/generic_article_downloader_service.dart';

/// Fake [HttpClientAdapter] that always returns [html] with [statusCode],
/// so tests exercise the service's real HTML-parsing logic through the
/// public [GenericArticleDownloaderService.fetchItems] API without ever
/// touching the network.
class _FixtureAdapter implements HttpClientAdapter {
  _FixtureAdapter(this.html, {this.statusCode = 200});
  final String html;
  final int statusCode;

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    return ResponseBody.fromString(
      html,
      statusCode,
      headers: {
        Headers.contentTypeHeader: ['text/html; charset=utf-8'],
      },
    );
  }
}

Dio _dioFor(String html, {int statusCode = 200}) {
  final dio = Dio(BaseOptions(responseType: ResponseType.plain));
  dio.httpClientAdapter = _FixtureAdapter(html, statusCode: statusCode);
  return dio;
}

String _fixture(String name) =>
    File('test/fixtures/$name').readAsStringSync();

/// Minimal synthetic NPF page: just the `#___INITIAL_STATE___` script tag
/// wrapping [state] (a `{"PeeprRoute": ...}` map), with no DOM content at
/// all — used for the review-round edge cases below (reblog trail fallback,
/// wrong-post-id fallback, provider-omitted video), which are hand-built
/// rather than pulled from a real saved page since they target specific NPF
/// shapes rather than a specific real post.
String _npfHtml(Map<String, dynamic> state) => '''
<!DOCTYPE html><html><head><title>Tumblr</title></head><body>
<script type="application/json" id="___INITIAL_STATE___">${jsonEncode(state)}</script>
</body></html>
''';

Map<String, dynamic> _stateWithObjects(List<Map<String, dynamic>> objects) => {
      'PeeprRoute': {
        'initialTimeline': {'objects': objects},
      },
    };

void main() {
  group('Tumblr NPF (___INITIAL_STATE___) — primary path', () {
    test('image post: 3 items, original-dimension URLs, real blog name',
        () async {
      final html = _fixture('tumblr_images_npf.html');
      final service =
          GenericArticleDownloaderService(dio: _dioFor(html));

      final items = await service.fetchItems(
          'https://www.tumblr.com/hitokoma86/826364153165922304?source=share');

      expect(items.length, 3);
      for (final item in items) {
        expect(item.type, MediaItemType.image);
        expect(item.mediaUrl, contains('/s2048x3072/'));
        expect(item.username, 'hitokoma86');
      }
      // Distinct assets, not the same photo three times.
      expect(items.map((i) => i.mediaUrl).toSet().length, 3);
    });

    test(
        'video post: exactly 1 video item, poster as thumbnail, zero images, real blog name',
        () async {
      final html = _fixture('tumblr_video_npf.html');
      final service =
          GenericArticleDownloaderService(dio: _dioFor(html));

      final items = await service.fetchItems(
          'https://www.tumblr.com/nofirecaneverwarmme/825887227304378368?source=share');

      expect(items.length, 1);
      final video = items.single;
      expect(video.type, MediaItemType.video);
      expect(video.mediaUrl,
          'https://64.media.tumblr.com/2087b0c4d6390f09ed70977e98deeb17/5cff472a284c7339-ec/s720/47253194c7a23ad9808ae59658766c4b4da1692f.mov');
      expect(video.thumbnailUrl,
          'https://44.media.tumblr.com/2087b0c4d6390f09ed70977e98deeb17/5cff472a284c7339-ec/s1080x1920_f1/67ae0f6aa40ca0799e9c2ac8f5029d426765338a.jpg');
      expect(video.username, 'nofirecaneverwarmme');
      // No separate image item for the poster frame.
      expect(items.where((i) => i.type == MediaItemType.image), isEmpty);
    });
  });

  group('Tumblr DOM fallback (no NPF script tag)', () {
    test(
        'video extracted, poster suppressed as separate image, avatar junk-filtered',
        () async {
      final html = _fixture('tumblr_video_dom_only.html');
      final service =
          GenericArticleDownloaderService(dio: _dioFor(html));

      final items = await service.fetchItems(
          'https://www.tumblr.com/nofirecaneverwarmme/825887227304378368');

      expect(items.length, 1, reason: 'exactly the video, nothing else');
      final video = items.single;
      expect(video.type, MediaItemType.video);
      expect(video.mediaUrl, contains('47253194c7a23ad9808ae59658766c4b4da1692f.mov'));
      expect(video.thumbnailUrl, contains('67ae0f6aa40ca0799e9c2ac8f5029d426765338a.jpg'));
      expect(video.username, 'nofirecaneverwarmme');
    });
  });

  group('Tumblr blog-name parsing (_siteName, exercised via username)', () {
    // A trivial image-only fixture — enough for the DOM path to yield one
    // item so username can be asserted regardless of pageUrl shape.
    const simpleImageHtml = '''
<!DOCTYPE html><html><head></head><body>
<article><img width="800" height="600" src="https://example-cdn.test/photo.jpg"/></article>
</body></html>
''';

    test('tumblr.com/<blog>/<id> shape', () async {
      final service =
          GenericArticleDownloaderService(dio: _dioFor(simpleImageHtml));
      final items = await service
          .fetchItems('https://www.tumblr.com/nofirecaneverwarmme/825887227304378368');
      expect(items.single.username, 'nofirecaneverwarmme');
    });

    test('<blog>.tumblr.com/post/<id>/<slug> shape', () async {
      final service =
          GenericArticleDownloaderService(dio: _dioFor(simpleImageHtml));
      final items = await service.fetchItems(
          'https://nofirecaneverwarmme.tumblr.com/post/825887227304378368/some-slug');
      expect(items.single.username, 'nofirecaneverwarmme');
    });

    test('non-Tumblr host falls back to host-derived name (unchanged)',
        () async {
      final service =
          GenericArticleDownloaderService(dio: _dioFor(simpleImageHtml));
      final items =
          await service.fetchItems('https://www.example.com/article/1');
      expect(items.single.username, 'example_com');
    });
  });

  group('Existing image-post regression (unaffected by video/NPF changes)',
      () {
    test('plain multi-image post still yields all images', () async {
      const html = '''
<!DOCTYPE html><html><head></head><body>
<article>
<img width="800" height="600" src="https://64.media.tumblr.com/aaa/bbb-1/s1280x1920/img1.jpg"/>
<img width="800" height="600" src="https://64.media.tumblr.com/ccc/ddd-2/s1280x1920/img2.jpg"/>
</article>
</body></html>
''';
      final service = GenericArticleDownloaderService(dio: _dioFor(html));
      final items = await service
          .fetchItems('https://www.tumblr.com/someblog/111111111111');
      expect(items.length, 2);
      expect(items.every((i) => i.type == MediaItemType.image), isTrue);
      expect(items.map((i) => i.mediaUrl).toSet().length, 2);
    });
  });

  group('_dedupeKey — og:image + srcset same-photo-two-sizes bug (item 2)',
      () {
    test('og:image seed and the largest srcset candidate collapse to one item',
        () async {
      // Same Tumblr media asset (hash1/hash2 pair) served by og:image at one
      // size and by the <img srcset>'s largest candidate at another — before
      // the fix these saved as two separate files (same photo, two sizes).
      const html = '''
<!DOCTYPE html><html><head>
<meta property="og:image" content="https://44.media.tumblr.com/c729b5d5255116bde4987a06f90088c8/17e0f45060dbc364-31/s1280x1920/ffc13d51d599d703ecd81231cdf942b93e876e42.jpg"/>
</head><body>
<article>
<img width="1200" height="2000" srcset="https://64.media.tumblr.com/c729b5d5255116bde4987a06f90088c8/17e0f45060dbc364-31/s640x960/1a29bf61f124931e6d653365b32d10edc2cb8fd5.jpg 640w, https://64.media.tumblr.com/c729b5d5255116bde4987a06f90088c8/17e0f45060dbc364-31/s2048x3072/0eeaec99cf1e453d89e56217d5ed846a43f4c1fa.jpg 2048w"/>
</article>
</body></html>
''';
      final service = GenericArticleDownloaderService(dio: _dioFor(html));
      final items = await service
          .fetchItems('https://www.tumblr.com/someblog/222222222222');
      expect(items.length, 1,
          reason:
              'og:image and the srcset\'s largest candidate are the same '
              'underlying photo at two sizes — must collapse to one item');
      // og:image is seeded first, so its variant wins the dedupe; the point
      // of this test is the count (1, not 2), not which size is kept.
      expect(items.single.mediaUrl, contains('/s1280x1920/'));
    });
  });

  group('Tumblr NPF review-round fixes', () {
    test(
        'fix 1: reblog with a non-empty TEXT-ONLY content still falls back '
        'to the trail (not only when content is empty)', () async {
      final state = _stateWithObjects([
        {
          'idString': '999000000001',
          'blogName': 'reblogger',
          'timestamp': 1700000000,
          // Non-empty but has no image/video block of its own — a caption.
          'content': [
            {'type': 'text', 'text': 'look at this'}
          ],
          'trail': [
            {
              'content': [
                {
                  'type': 'image',
                  'media': [
                    {
                      'url':
                          'https://64.media.tumblr.com/aaa/bbb/s2048x3072/orig.jpg',
                      'width': 2048,
                      'height': 3072,
                      'hasOriginalDimensions': true,
                    }
                  ],
                }
              ],
            }
          ],
        }
      ]);
      final service =
          GenericArticleDownloaderService(dio: _dioFor(_npfHtml(state)));
      final items = await service
          .fetchItems('https://www.tumblr.com/reblogger/999000000001');

      expect(items.length, 1);
      expect(items.single.type, MediaItemType.image);
      expect(items.single.mediaUrl, contains('orig.jpg'));
      expect(items.single.username, 'reblogger');
    });

    test(
        'fix 3a: URL id matches a LATER object in a multi-object blob — '
        'returns that object\'s media, not objects[0]\'s', () async {
      final state = _stateWithObjects([
        {
          'idString': '100000000001',
          'blogName': 'blogA',
          'content': [
            {
              'type': 'image',
              'media': [
                {
                  'url': 'https://64.media.tumblr.com/a/a/s2048x3072/a.jpg',
                  'width': 2048,
                  'hasOriginalDimensions': true,
                }
              ],
            }
          ],
        },
        {
          'idString': '100000000002',
          'blogName': 'blogB',
          'content': [
            {
              'type': 'image',
              'media': [
                {
                  'url': 'https://64.media.tumblr.com/b/b/s2048x3072/b.jpg',
                  'width': 2048,
                  'hasOriginalDimensions': true,
                }
              ],
            }
          ],
        },
      ]);
      final service =
          GenericArticleDownloaderService(dio: _dioFor(_npfHtml(state)));
      final items = await service
          .fetchItems('https://www.tumblr.com/blogB/100000000002');

      expect(items.length, 1);
      expect(items.single.mediaUrl, contains('b.jpg'));
      expect(items.single.username, 'blogB');
    });

    test(
        'fix 3b: URL names a post id that is NOT in the blob — must NOT '
        'silently fall back to objects[0] (an unrelated post)', () async {
      final state = _stateWithObjects([
        {
          'idString': '100000000001',
          'blogName': 'blogA',
          'content': [
            {
              'type': 'image',
              'media': [
                {
                  'url': 'https://64.media.tumblr.com/a/a/s2048x3072/a.jpg',
                  'width': 2048,
                  'hasOriginalDimensions': true,
                }
              ],
            }
          ],
        },
      ]);
      // No <img>/<video>/og:* in the DOM either, so if NPF wrongly fell back
      // to objects[0] this would return blogA's photo instead of failing.
      final service =
          GenericArticleDownloaderService(dio: _dioFor(_npfHtml(state)));

      await expectLater(
        () => service
            .fetchItems('https://www.tumblr.com/blogC/999999999999'),
        throwsA(isA<Exception>()),
      );
    });

    test(
        'fix 5: a video block with NO `provider` field is treated as a '
        'native Tumblr video, not skipped', () async {
      final state = _stateWithObjects([
        {
          'idString': '500000000001',
          'blogName': 'videoblog',
          'content': [
            {
              'type': 'video',
              // `provider` deliberately omitted.
              'url': 'https://64.media.tumblr.com/xxx/yyy/rawfile.mov',
              'media': {
                'url':
                    'https://64.media.tumblr.com/xxx/yyy/s720/small.mov',
                'type': 'video/mp4',
                'width': 720,
                'height': 1280,
              },
              'poster': [
                {
                  'url':
                      'https://64.media.tumblr.com/xxx/yyy/s720/poster.jpg',
                  'width': 720,
                  'height': 1280,
                }
              ],
            }
          ],
        },
      ]);
      final service =
          GenericArticleDownloaderService(dio: _dioFor(_npfHtml(state)));
      final items = await service
          .fetchItems('https://www.tumblr.com/videoblog/500000000001');

      expect(items.length, 1);
      expect(items.single.type, MediaItemType.video);
      expect(items.single.mediaUrl, contains('small.mov'));
      expect(items.single.thumbnailUrl, contains('poster.jpg'));
      expect(items.single.username, 'videoblog');
    });

    test(
        'fix 5 regression: an explicit non-Tumblr provider is still skipped',
        () async {
      final state = _stateWithObjects([
        {
          'idString': '500000000002',
          'blogName': 'videoblog',
          'content': [
            {
              'type': 'video',
              'provider': 'youtube',
              'url': 'https://www.youtube.com/watch?v=abc123',
            }
          ],
        },
      ]);
      final service =
          GenericArticleDownloaderService(dio: _dioFor(_npfHtml(state)));

      await expectLater(
        () => service
            .fetchItems('https://www.tumblr.com/videoblog/500000000002'),
        throwsA(isA<Exception>()),
      );
    });
  });
}

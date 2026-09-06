import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ig_downloader/models/media_item.dart';
import 'package:ig_downloader/services/threads_downloader_service.dart';

String _fixture(String name) =>
    File('test/fixtures/$name').readAsStringSync();

void main() {
  // Fixture: a single `data-sjs` block extracted from a real Threads
  // canonical-post-page RESPONSE fetched with the Googlebot UA
  // (https://www.threads.com/@hiuieng/post/Dc8z0glmq8b, 2026-09-07) — the
  // ONLY UA field-verified to get this server-rendered payload; the desktop
  // Chrome UA and facebookexternalhit both get 0 data-sjs post data for the
  // same post (see ThreadsDownloaderService's `_crawlerUA` doc comment). The
  // decoded JSON is Meta's BigPipe payload for the thread view: the target
  // post (a 2-video carousel) PLUS 30 reply posts sharing the same blob —
  // real leak material for the scoping assertions below. Every reply's
  // username/full_name/text has been redacted (see the fixture file's own
  // header comment) — only the target author's username (`hiuieng`) and the
  // media URLs/timestamps under test are untouched. A decoy non-JSON
  // data-sjs block precedes it to exercise the try/catch-skip path.
  const targetShortcode = 'Dc8z0glmq8b';
  // One of the 30 real reply posts embedded in the same data-sjs blob.
  // Field-verified: media_type 19 (text-only reply), no video/image content
  // of its own — used to assert the scoped parser refuses to guess when the
  // requested post has no displayable media, rather than falling back to
  // some other node in the blob.
  const replyShortcodeWithNoMedia = 'Dc827bVD5J-';

  const type101UrlItem0 =
      'https://instagram.fhkg4-1.fna.fbcdn.net/o1/v/t16/f2/m84/AQNAv3iJ0tbQlDw3gIZoI_hbsn9kKiyGRjj0OWmKXrAAtMQHqE1d_vXRex6zMuvOAmeTRIe_rzzCmWccOvsHr99JpavUPqUcECeL-5c.mp4';
  const type101UrlItem1 =
      'https://instagram.fhkg4-1.fna.fbcdn.net/o1/v/t16/f2/m84/AQN6Iq8wT2Kj6KJRmgV34I4KXZCls2eTp9tdlhbTS3R8Ki7BsyonAcsliDWpYFUG4otfvI0BdjIstF5quIyvEr5GMt52keFUrW2EbQk.mp4';

  group('ThreadsDownloaderService.parseDataSjs', () {
    late String html;
    late ThreadsDownloaderService service;

    setUp(() {
      html = _fixture('threads_data_sjs.html');
      service = ThreadsDownloaderService();
    });

    test(
        'target post: returns both carousel videos, scoped to the exact '
        'shortcode, with no reply/related media leaking in', () {
      final items = service.parseDataSjs(html, targetShortcode, 'threads');

      // Scoping: exactly the 2 slides of THIS post — not the 30+ replies'
      // worth of content also present in the same data-sjs blob.
      expect(items, hasLength(2));

      for (final item in items) {
        expect(item.type, MediaItemType.video,
            reason: 'both carousel slides are videos');
        expect(item.mediaUrl.split('?').first, endsWith('.mp4'));
        expect(item.username, 'hiuieng');
        expect(item.postTimestamp, 1788706859); // the post's taken_at
      }

      // Each returned URL matches the real `type: 101` rendition of its
      // carousel slide (mediaUrl starts with, since the CDN URL carries a
      // long query string this test doesn't hardcode in full).
      final mediaUrls = items.map((i) => i.mediaUrl.split('?').first).toSet();
      expect(
        mediaUrls,
        {type101UrlItem0.split('?').first, type101UrlItem1.split('?').first},
      );
    });

    test(
        'never guesses: a real post in the same blob with no media returns '
        'empty rather than falling back to an unrelated node', () {
      final items =
          service.parseDataSjs(html, replyShortcodeWithNoMedia, 'threads');
      expect(items, isEmpty);
    });

    test('unknown shortcode (not present anywhere in the blob) returns empty',
        () {
      final items = service.parseDataSjs(html, 'ZZZZZZZZZZZ', 'threads');
      expect(items, isEmpty);
    });

    test(
        'image-only node (has image_versions2, no/empty video_versions) '
        'classifies as image, not video', () {
      // Pull a real image URL straight out of the fixture (one of the
      // target carousel item's poster-frame candidates, CDN path
      // t51.71878-15) rather than hardcoding one, so this stays correct if
      // the fixture is ever regenerated. Handles both escaped (`\/`) and
      // plain (`/`) JSON slash encoding.
      final urlMatch = RegExp(r'"url":"(https:[^"]*t51\.71878-15[^"]*\.jpg[^"]*)"')
          .firstMatch(html);
      expect(urlMatch, isNotNull,
          reason: 'fixture should contain at least one real image URL');
      final imageUrl = urlMatch!.group(1)!.replaceAll(r'\/', '/');

      // Regression guard for the field-verified bug (2026-09-07): the
      // data-sjs schema's carousel sub-items omit `media_type` entirely, so
      // a video was misclassified as its own poster image whenever
      // classification relied on `media_type == 2` alone. This node has NO
      // `media_type` key and an explicitly empty `video_versions` list —
      // it must classify as an image, never a video.
      final node = <String, dynamic>{
        'image_versions2': {
          'candidates': [
            {'url': imageUrl, 'width': 640, 'height': 492},
          ],
        },
        'video_versions': <Map<String, dynamic>>[],
      };

      final item = service.itemFromNodeForTesting(node, 'threads', null, 1);
      expect(item, isNotNull);
      expect(item!.type, MediaItemType.image);
      expect(item.mediaUrl, imageUrl);
    });
  });
}

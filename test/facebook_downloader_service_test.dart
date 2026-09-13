import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ig_downloader/models/media_item.dart';
import 'package:ig_downloader/services/facebook_downloader_service.dart';

String _fixture(String name) =>
    File('test/fixtures/$name').readAsStringSync();

void main() {
  // Fixture: a hand-built (never a real page capture) `data-sjs` JSON block
  // reproducing the shape Facebook serves for a `/posts/<id>/` photo album on
  // the authenticated desktop page — verified against two real logged-in
  // page dumps on 2026-09-14 (see CLAUDE.md's Facebook fix task for the
  // field notes; the dumps themselves were never committed to this repo).
  //
  // Root cause this fixes: Facebook serves og:type=video.other to the bot UA
  // for plain photo albums, and an unscoped video-URL regex over the full
  // authenticated page then matches an unrelated Reels-rail video ~1MB away
  // from the actual post — hiding the whole photo album behind a wrong
  // video. The fixture's <head> deliberately sets og:type=video.other (like
  // the real pages) to prove the story parser ignores it entirely, and
  // includes a FULLY SYNTHETIC decoy sibling post (different post_id/fbids,
  // placeholder URLs — not derived from any real post) plus a synthetic
  // unscoped `progressive_url` to prove strict post_id scoping.
  const targetPostId = '1522550336585519';
  const decoyFbid1 = '9000000000000001';
  const decoyFbid2 = '9000000000000002';
  const decoyPostId = '9999999999999999';

  late String html;
  late FacebookDownloaderService service;

  setUp(() {
    html = _fixture('facebook_post_story.html');
    service = FacebookDownloaderService();
  });

  group('FacebookDownloaderService.parseStoryForTesting — real post fixture',
      () {
    test(
        '4 photos returned (scoped to the real post_id), all viewer_image '
        'URIs, decoy fbids/post excluded, no video, username from actors[0], '
        'date from creation_time', () {
      final items = service.parseStoryForTesting(html, targetPostId);

      expect(items, hasLength(4));

      for (final item in items) {
        expect(item.username, 'HKACGer',
            reason: 'actors[0].url last path segment');
        expect(item.postTimestamp, 1788685140,
            reason: "the post's own creation_time, not DateTime.now()");
      }

      // Every returned URL is the full-size `viewer_image.uri` rendition for
      // one of the 4 real photos in this post's `all_subattachments` — pulled
      // straight from the fixture (rather than hardcoded) for the 4 real
      // fbids so this stays correct if the fixture is regenerated.
      const realFbids = [
        '1522548893252330',
        '1522548909918995',
        '1522548876585665',
        '1522548943252325',
      ];
      final expectedUrls = <String>{};
      for (final fbid in realFbids) {
        final m = RegExp(
                '"id":\\s*"$fbid",\\s*"image":.*?"viewer_image":\\s*\\{"uri":\\s*"([^"]+)"')
            .firstMatch(html);
        expect(m, isNotNull,
            reason: 'fixture should contain a viewer_image for $fbid');
        expectedUrls.add(m!.group(1)!);
      }
      expect(items.map((i) => i.mediaUrl).toSet(), expectedUrls);

      // Decoy sibling post (different post_id, different fbids, sharing the
      // same data-sjs blob) must never leak into the scoped result.
      for (final item in items) {
        expect(item.mediaUrl, isNot(contains(decoyFbid1)));
        expect(item.mediaUrl, isNot(contains(decoyFbid2)));
      }
    });

    test(
        'og:type=video.other in <head> with Photo-only attachments -> zero '
        'video items (regression guard for the 2026-09-14 bug: og:type must '
        'never classify /posts/ pages — only the attachments themselves do)',
        () {
      expect(html, contains('og:type" content="video.other"'),
          reason: 'the fixture must actually carry the misleading og:type '
              'for this regression test to mean anything');

      final items = service.parseStoryForTesting(html, targetPostId);

      expect(items, isNotEmpty);
      expect(items.any((i) => i.type == MediaItemType.video), isFalse);
      expect(items.every((i) => i.type == MediaItemType.image), isTrue);
    });

    test('unknown post_id (not present anywhere in the blob) returns empty',
        () {
      final items = service.parseStoryForTesting(html, 'ZZZZZZZZZZZZZZZZZ');
      expect(items, isEmpty);
    });

    test(
        'the decoy sibling post_id alone resolves to its own (different) '
        'photos, never the target post\'s', () {
      final items = service.parseStoryForTesting(html, decoyPostId);
      expect(items, hasLength(2));
      expect(
        items.map((i) => i.mediaUrl).toSet(),
        {
          RegExp('"id":\\s*"$decoyFbid1",\\s*"image":.*?"viewer_image":\\s*\\{"uri":\\s*"([^"]+)"')
              .firstMatch(html)!
              .group(1)!,
          RegExp('"id":\\s*"$decoyFbid2",\\s*"image":.*?"viewer_image":\\s*\\{"uri":\\s*"([^"]+)"')
              .firstMatch(html)!
              .group(1)!,
        },
      );
    });
  });

  group('FacebookDownloaderService.parseStoryForTesting — photo URL fallback '
      'order (synthetic minimal fixtures)', () {
    test('viewer_image present: used over image.uri', () {
      const syntheticHtml = '''
<script type="application/json" data-sjs>{"post_id":"2000000000000001","creation_time":1700000001,"actors":[{"url":"https://www.facebook.com/testpage","name":"Test Page"}],"attachments":[{"styles":{"attachment":{"all_subattachments":{"count":1,"nodes":[{"media":{"__typename":"Photo","id":"2000000000000002","image":{"uri":"https://scontent.example.fna.fbcdn.net/thumb.jpg"},"viewer_image":{"uri":"https://scontent.example.fna.fbcdn.net/full.jpg"}}}]}}}}]}</script>
''';
      final items =
          service.parseStoryForTesting(syntheticHtml, '2000000000000001');
      expect(items, hasLength(1));
      expect(items.single.mediaUrl,
          'https://scontent.example.fna.fbcdn.net/full.jpg');
    });

    test('viewer_image missing: falls back to image.uri', () {
      const syntheticHtml = '''
<script type="application/json" data-sjs>{"post_id":"2000000000000003","creation_time":1700000002,"actors":[{"url":"https://www.facebook.com/testpage","name":"Test Page"}],"attachments":[{"styles":{"attachment":{"all_subattachments":{"count":1,"nodes":[{"media":{"__typename":"Photo","id":"2000000000000004","image":{"uri":"https://scontent.example.fna.fbcdn.net/thumb-only.jpg"}}}]}}}}]}</script>
''';
      final items =
          service.parseStoryForTesting(syntheticHtml, '2000000000000003');
      expect(items, hasLength(1));
      expect(items.single.mediaUrl,
          'https://scontent.example.fna.fbcdn.net/thumb-only.jpg');
    });

    test(
        'both viewer_image and image missing: falls back to the anonymous '
        'lookaside crawler URL by fbid', () {
      const syntheticHtml = '''
<script type="application/json" data-sjs>{"post_id":"2000000000000005","creation_time":1700000003,"actors":[{"url":"https://www.facebook.com/testpage","name":"Test Page"}],"attachments":[{"styles":{"attachment":{"all_subattachments":{"count":1,"nodes":[{"media":{"__typename":"Photo","id":"2000000000000006"}}]}}}}]}</script>
''';
      final items =
          service.parseStoryForTesting(syntheticHtml, '2000000000000005');
      expect(items, hasLength(1));
      expect(
        items.single.mediaUrl,
        'https://lookaside.fbsbx.com/lookaside/crawler/media/'
        '?media_id=2000000000000006',
      );
    });
  });

  group('FacebookDownloaderService username fallback order', () {
    test('actors[0].name used when actors[0].url is absent', () {
      const syntheticHtml = '''
<script type="application/json" data-sjs>{"post_id":"2000000000000007","creation_time":1700000004,"actors":[{"name":"家家美樂地"}],"attachments":[{"styles":{"attachment":{"all_subattachments":{"count":1,"nodes":[{"media":{"__typename":"Photo","id":"2000000000000008","viewer_image":{"uri":"https://scontent.example.fna.fbcdn.net/x.jpg"}}}]}}}}]}</script>
''';
      final items =
          service.parseStoryForTesting(syntheticHtml, '2000000000000007');
      expect(items, hasLength(1));
      expect(items.single.username, '家家美樂地');
    });

    test('og:url path segment used when no actors are present at all', () {
      const syntheticHtml = '''
<script type="application/json" data-sjs>{"post_id":"2000000000000009","creation_time":1700000005,"attachments":[{"styles":{"attachment":{"all_subattachments":{"count":1,"nodes":[{"media":{"__typename":"Photo","id":"2000000000000010","viewer_image":{"uri":"https://scontent.example.fna.fbcdn.net/x.jpg"}}}]}}}}]}</script>
''';
      final items = service.parseStoryForTesting(
        syntheticHtml,
        '2000000000000009',
        ogUrl: 'https://www.facebook.com/ccmelody.acg/posts/2000000000000009/',
      );
      expect(items, hasLength(1));
      expect(items.single.username, 'ccmelody.acg');
    });

    // Regression guards added 2026-09-14 (code review): _usernameFromStory
    // used to take the LAST path segment of actors[0].url unconditionally,
    // which breaks on Facebook's two "no vanity username" profile URL
    // shapes below — both must fall through past the bad segment.
    test(
        'actors[0].url = facebook.com/people/<Name>/<numericId>/ -> the '
        'Name segment, not the trailing numeric id', () {
      const syntheticHtml = '''
<script type="application/json" data-sjs>{"post_id":"2000000000000011","creation_time":1700000006,"actors":[{"url":"https://www.facebook.com/people/Jane-Doe/100012345678901","name":"Jane Doe"}],"attachments":[{"styles":{"attachment":{"all_subattachments":{"count":1,"nodes":[{"media":{"__typename":"Photo","id":"2000000000000012","viewer_image":{"uri":"https://scontent.example.fna.fbcdn.net/x.jpg"}}}]}}}}]}</script>
''';
      final items =
          service.parseStoryForTesting(syntheticHtml, '2000000000000011');
      expect(items, hasLength(1));
      expect(items.single.username, 'Jane-Doe');
    });

    test(
        'actors[0].url = facebook.com/profile.php?id=… -> falls back to '
        'actors[0].name, not the literal string "profile.php"', () {
      const syntheticHtml = '''
<script type="application/json" data-sjs>{"post_id":"2000000000000013","creation_time":1700000007,"actors":[{"url":"https://www.facebook.com/profile.php?id=100012345678902","name":"John Smith"}],"attachments":[{"styles":{"attachment":{"all_subattachments":{"count":1,"nodes":[{"media":{"__typename":"Photo","id":"2000000000000014","viewer_image":{"uri":"https://scontent.example.fna.fbcdn.net/x.jpg"}}}]}}}}]}</script>
''';
      final items =
          service.parseStoryForTesting(syntheticHtml, '2000000000000013');
      expect(items, hasLength(1));
      expect(items.single.username, 'John Smith');
    });
  });

  group('FacebookDownloaderService.parseStoryForTesting — Video attachment '
      '(synthetic — no real /posts/ video capture exists)', () {
    test(
        'attachments[].media.__typename == "Video" with playable_url/'
        'browser_native_hd_url inside the node -> exactly one video item '
        'with the right URL; a decoy Video node elsewhere (different id, '
        'outside this post\'s node) is never picked up', () {
      const syntheticHtml = '''
<script type="application/json" data-sjs>{"post_id":"3000000000000001","creation_time":1700000008,"actors":[{"url":"https://www.facebook.com/testpage","name":"Test Page"}],"attachments":[{"media":{"__typename":"Video","id":"3000000000000002","playable_url":"https://scontent.example.fna.fbcdn.net/real-video.mp4","browser_native_hd_url":"https://scontent.example.fna.fbcdn.net/should-not-win-hd.mp4"}}],"decoy_elsewhere_on_page":{"post_id":"9999999999999997","attachments":[{"media":{"__typename":"Video","id":"9999999999999998","playable_url":"https://scontent.example.fna.fbcdn.net/decoy-video.mp4"}}]}}</script>
''';
      final items =
          service.parseStoryForTesting(syntheticHtml, '3000000000000001');

      expect(items, hasLength(1));
      expect(items.single.type, MediaItemType.video);
      expect(items.single.mediaUrl,
          'https://scontent.example.fna.fbcdn.net/real-video.mp4',
          reason: 'playable_url must win over browser_native_hd_url — see '
              '_videoUrlKeys ordering');
    });
  });
}

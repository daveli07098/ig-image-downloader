import 'package:flutter_test/flutter_test.dart';
import 'package:ig_downloader/services/shared_text_url.dart';

void main() {
  group('extractFirstUrl', () {
    test('title-then-URL share text extracts just the URL', () {
      expect(
        extractFirstUrl('測試標題 https://example.com/abc'),
        'https://example.com/abc',
      );
    });

    test('URL on a second line is found', () {
      expect(
        extractFirstUrl('baby梓有無資格做新一代連登女神啊？\nhttps://lih.kg/4158154'),
        'https://lih.kg/4158154',
      );
    });

    test('a bare URL is returned unchanged', () {
      expect(
        extractFirstUrl('https://example.com/abc'),
        'https://example.com/abc',
      );
    });

    test('trailing CJK/ASCII punctuation is stripped', () {
      expect(extractFirstUrl('看這個 https://example.com/abc。'),
          'https://example.com/abc');
      expect(extractFirstUrl('(see this) https://example.com/abc)'),
          'https://example.com/abc');
      expect(extractFirstUrl('https://example.com/abc,'),
          'https://example.com/abc');
    });

    test('a trailing slash is kept, not stripped as punctuation', () {
      expect(extractFirstUrl('https://example.com/abc/'),
          'https://example.com/abc/');
    });

    test('a query string with & is preserved intact', () {
      expect(
        extractFirstUrl('title https://example.com/x?rdid=1&x=1'),
        'https://example.com/x?rdid=1&x=1',
      );
    });

    test('text with no URL at all returns null', () {
      expect(extractFirstUrl('just some plain title text'), isNull);
    });

    test(
        'when several URLs are present, the first one a known platform '
        'matcher recognises wins, even if it is not the first URL in the '
        'text', () {
      expect(
        extractFirstUrl(
          'see https://example.com/unrelated and also '
          'https://lih.kg/4158154 for the real thread',
        ),
        'https://lih.kg/4158154',
      );
    });

    test(
        'a caller-supplied isKnownPlatform matcher is used instead of the '
        'built-in platform list', () {
      expect(
        extractFirstUrl(
          'see https://example.com/a and https://example.org/b',
          isKnownPlatform: (u) => u.contains('example.org'),
        ),
        'https://example.org/b',
      );
    });

    test('falls back to the first URL when none match a known platform', () {
      expect(
        extractFirstUrl('https://example.com/a and https://example.org/b'),
        'https://example.com/a',
      );
    });
  });
}

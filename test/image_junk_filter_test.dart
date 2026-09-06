import 'package:flutter_test/flutter_test.dart';
import 'package:ig_downloader/services/image_junk_filter.dart';

// See CLAUDE.md's Tumblr fix task item 6: `isJunkElement`'s `alt`-based
// matching used to reuse the full [junkMarkers] list, which includes generic
// words ("icon", "logo", "pixel", "sprite") that legitimately show up in real
// art-post alt text — Tumblr especially — silently dropping real images.
void main() {
  group('isJunkElement alt restriction', () {
    test('unambiguous alt markers still flag junk', () {
      expect(isJunkElement(url: 'https://example.com/a.jpg', alt: 'Avatar'),
          isTrue);
      expect(
          isJunkElement(url: 'https://example.com/a.jpg', alt: 'gravatar photo'),
          isTrue);
      expect(
          isJunkElement(url: 'https://example.com/a.jpg', alt: 'site favicon'),
          isTrue);
    });

    test('generic markers in alt text no longer flag real content', () {
      // These would have been (wrongly) dropped before the fix.
      expect(
        isJunkElement(
          url: 'https://64.media.tumblr.com/abc/def/s1280x1920/art.jpg',
          alt: 'pixel art icon commission',
        ),
        isFalse,
      );
      expect(
        isJunkElement(
          url: 'https://64.media.tumblr.com/abc/def/s1280x1920/art.jpg',
          alt: 'sprite sheet WIP, logo redesign',
        ),
        isFalse,
      );
    });

    test('full marker matching is preserved for class/id', () {
      expect(
        isJunkElement(
          url: 'https://example.com/photo.jpg',
          className: 'avatar-image',
        ),
        isTrue,
      );
      expect(
        isJunkElement(
          url: 'https://example.com/photo.jpg',
          id: 'site-logo',
        ),
        isTrue,
      );
      // Generic marker in class should still be caught (URL/class/id keep
      // the full list — only `alt` was narrowed).
      expect(
        isJunkElement(
          url: 'https://example.com/photo.jpg',
          className: 'tracking-pixel',
        ),
        isTrue,
      );
    });

    test('URL-based filtering is unchanged', () {
      expect(isJunkUrl('https://example.com/spacer.gif'), isTrue);
      expect(isJunkUrl('https://example.com/logo/icon.svg'), isTrue);
      expect(isJunkUrl('https://example.com/real-photo.jpg'), isFalse);
    });
  });
}

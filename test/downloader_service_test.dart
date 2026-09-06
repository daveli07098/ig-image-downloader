import 'package:flutter_test/flutter_test.dart';
import 'package:ig_downloader/models/media_item.dart';
import 'package:ig_downloader/services/downloader_service.dart';

// See CLAUDE.md's Tumblr fix task item 4: DownloaderService.downloadItem used
// to force every image to .jpg/image-jpeg and every video to .mp4/video-mp4,
// regardless of the media URL's own extension — a GIF saved as .jpg will not
// animate. DownloaderService.extensionAndMime exposes the pure
// (ext, mime) derivation logic (normally private) for direct unit testing,
// since exercising it through downloadItem would require real network +
// filesystem + platform-channel access.
void main() {
  MediaItem imageItem(String url) => MediaItem(
        id: '0',
        mediaUrl: url,
        type: MediaItemType.image,
        username: 'test',
      );
  MediaItem videoItem(String url) => MediaItem(
        id: '0',
        mediaUrl: url,
        type: MediaItemType.video,
        username: 'test',
      );

  group('extensionAndMime — Tumblr real-extension cases', () {
    test('.gif image keeps .gif / image/gif (would not animate as .jpg)', () {
      final r = DownloaderService.extensionAndMime(
          imageItem('https://64.media.tumblr.com/abc/def/s500x750/x.gif'));
      expect(r.ext, 'gif');
      expect(r.mime, 'image/gif');
    });

    test('.mov video keeps .mov / video/quicktime', () {
      final r = DownloaderService.extensionAndMime(
          videoItem('https://64.media.tumblr.com/abc/def/s720/x.mov'));
      expect(r.ext, 'mov');
      expect(r.mime, 'video/quicktime');
    });

    test('.pnj (PNG-in-JPEG) saves as real .jpg / image/jpeg, not .pnj', () {
      final r = DownloaderService.extensionAndMime(imageItem(
          'https://64.media.tumblr.com/abc/def/s200x200u_c1/x.pnj'));
      expect(r.ext, 'jpg');
      expect(r.mime, 'image/jpeg');
    });
  });

  group('extensionAndMime — cross-platform scope (item 2 follow-up)',
      () {
    test('a .webp image CDN URL now keeps .webp / image/webp — intentional, '
        'not Tumblr-only', () {
      final r = DownloaderService.extensionAndMime(
          imageItem('https://scontent.cdninstagram.com/v/t51/photo.webp'));
      expect(r.ext, 'webp');
      expect(r.mime, 'image/webp');
    });

    test('a no-extension image URL still defaults to .jpg / image/jpeg', () {
      final r = DownloaderService.extensionAndMime(imageItem(
          'https://scontent.cdninstagram.com/v/t51.29350-15/12345_n?_nc_ht=x'));
      expect(r.ext, 'jpg');
      expect(r.mime, 'image/jpeg');
    });

    test('a no-extension video URL still defaults to .mp4 / video/mp4', () {
      final r = DownloaderService.extensionAndMime(
          videoItem('https://video.cdninstagram.com/v/t50.2886-16/12345_n'));
      expect(r.ext, 'mp4');
      expect(r.mime, 'video/mp4');
    });

    test(
        "a video item whose URL happens to end '.jpg' does not adopt an "
        'image extension — kind mismatch falls back to the video default',
        () {
      final r = DownloaderService.extensionAndMime(
          videoItem('https://example.cdn.test/thumbnail_frame.jpg'));
      expect(r.ext, 'mp4');
      expect(r.mime, 'video/mp4');
    });
  });
}

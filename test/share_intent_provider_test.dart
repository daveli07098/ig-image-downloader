import 'package:flutter_test/flutter_test.dart';
import 'package:ig_downloader/providers/share_intent_provider.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';

// Constructing a SharedUrlNotifier triggers real ReceiveSharingIntent
// platform-channel calls (getMediaStream/getInitialMedia), which aren't
// mocked in a plain unit test — so this exercises the pure extraction step,
// SharedUrlNotifier.urlFromMedia, directly instead, per the brief's escape
// hatch for when wiring a SharedMediaFile end-to-end is awkward.
void main() {
  group('SharedUrlNotifier.urlFromMedia', () {
    test('accepts a title-prefixed LIHKG share (the field-confirmed bug)',
        () {
      final files = [
        SharedMediaFile(
          path: '測試標題 https://lih.kg/4158154',
          type: SharedMediaType.text,
        ),
      ];

      expect(SharedUrlNotifier.urlFromMedia(files), 'https://lih.kg/4158154');
    });

    test('accepts a bare URL unchanged', () {
      final files = [
        SharedMediaFile(
          path: 'https://instagram.com/p/abc123/',
          type: SharedMediaType.text,
        ),
      ];

      expect(SharedUrlNotifier.urlFromMedia(files),
          'https://instagram.com/p/abc123/');
    });

    test('ignores the share when no URL is present in the text', () {
      final files = [
        SharedMediaFile(path: 'just some title text', type: SharedMediaType.text),
      ];

      expect(SharedUrlNotifier.urlFromMedia(files), isNull);
    });

    test('returns null for an empty file list', () {
      expect(SharedUrlNotifier.urlFromMedia(const []), isNull);
    });
  });
}

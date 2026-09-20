import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';
import 'dart:async';

import '../services/shared_text_url.dart';

/// Provides the latest Instagram or X (Twitter) URL shared from another app.
/// Returns null when no URL has been received yet.
final sharedUrlProvider =
    StateNotifierProvider<SharedUrlNotifier, String?>((ref) {
  return SharedUrlNotifier();
});

class SharedUrlNotifier extends StateNotifier<String?> {
  SharedUrlNotifier() : super(null) {
    _init();
  }

  late final StreamSubscription<List<SharedMediaFile>> _sub;

  void _init() {
    // Handle URL shared while app is already in foreground
    _sub = ReceiveSharingIntent.instance.getMediaStream().listen(
      _handleMedia,
      onError: (_) {},
    );

    // Handle URL that launched/opened the app from share sheet
    ReceiveSharingIntent.instance.getInitialMedia().then(_handleMedia);
  }

  void _handleMedia(List<SharedMediaFile> files) {
    final url = urlFromMedia(files);
    if (url != null) {
      state = url;
    }
  }

  /// Extracts the URL to use as [state] from a share/media payload, applying
  /// the same title-prefixed-share handling as [_handleMedia].
  ///
  /// Exposed for testing: constructing a [SharedUrlNotifier] triggers real
  /// `ReceiveSharingIntent` platform-channel calls via [_init], so tests
  /// exercise this pure extraction step directly instead.
  @visibleForTesting
  static String? urlFromMedia(List<SharedMediaFile> files) {
    if (files.isEmpty) return null;
    final text = files.first.path; // receive_sharing_intent puts text in path
    // Share sheets (LIHKG, Tumblr, Facebook, ...) often send the post title
    // followed by the link rather than a bare URL, so pull the URL out of
    // the text instead of validating the raw text itself.
    return extractFirstUrl(text);
  }

  void consume() => state = null;

  @override
  void dispose() {
    _sub.cancel();
    super.dispose();
  }
}

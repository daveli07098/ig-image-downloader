import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';
import 'dart:async';

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
    if (files.isEmpty) return;
    final text = files.first.path; // receive_sharing_intent puts text in path
    if (text.contains('instagram.com') ||
        text.contains('x.com/') ||
        text.contains('twitter.com/') ||
        text.contains('funnynews-media.com') ||
        text.contains('funnymedianews.com') ||
        text.contains('funestnews.com')) {
      state = text;
    }
  }

  void consume() => state = null;

  @override
  void dispose() {
    _sub.cancel();
    super.dispose();
  }
}

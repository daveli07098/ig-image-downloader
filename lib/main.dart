import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'app.dart';
import 'services/dev_logger.dart';

/// True in kDebugMode, OR when built with `--dart-define=DEV_MODE=true`.
/// Use the dart-define flag to enable the overlay in release builds:
///   fvm flutter build apk --release --dart-define=DEV_MODE=true
const _devMode =
    bool.fromEnvironment('DEV_MODE', defaultValue: kDebugMode);

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  // In dev mode (debug or --dart-define=DEV_MODE=true), intercept debugPrint
  // so every log line appears in the in-app DevLogOverlay as well as logcat.
  if (_devMode) {
    final origPrint = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) {
      origPrint(message, wrapWidth: wrapWidth);
      if (message != null && message.isNotEmpty) {
        DevLogger.instance.add(message);
      }
    };
  }

  runApp(
    const ProviderScope(
      child: IgDownloaderApp(),
    ),
  );
}

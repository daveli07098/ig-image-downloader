import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'app.dart';
import 'services/dev_logger.dart';
import 'services/rate_guard_service.dart';

/// True in kDebugMode, OR when built with `--dart-define=DEV_MODE=true`.
/// Use the dart-define flag to enable the overlay in release builds:
///   fvm flutter build apk --release --dart-define=DEV_MODE=true
const _devMode =
    bool.fromEnvironment('DEV_MODE', defaultValue: kDebugMode);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Set up the isolate communication port used by the download foreground
  // service. Must run before any startService/updateService call.
  FlutterForegroundTask.initCommunicationPort();

  // Load the persisted Instagram request budget / cooldown before any download
  // path can run, so a cooldown survives an app restart.
  await RateGuard.instance.init();

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

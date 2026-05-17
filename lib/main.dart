import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'app.dart';
import 'services/dev_logger.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  // In debug builds, intercept debugPrint so every log line appears in the
  // in-app DevLogOverlay as well as the system logcat.
  if (kDebugMode) {
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

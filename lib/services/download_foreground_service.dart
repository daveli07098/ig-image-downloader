import 'dart:io';

import 'package:flutter_foreground_task/flutter_foreground_task.dart';

/// Foreground-service entry point (runs in its own isolate).
///
/// The actual download pipeline lives in the main isolate
/// ([DownloadQueueNotifier]). This handler is intentionally a no-op — its only
/// job is to exist so Android keeps a foreground service alive, which in turn
/// keeps the app process running (and exempt from background network throttling
/// and the cached-app freezer) while the queue drains. Must be a top-level
/// function annotated for AOT so it can be used as the service callback.
@pragma('vm:entry-point')
void downloadServiceCallback() {
  FlutterForegroundTask.setTaskHandler(_DownloadTaskHandler());
}

class _DownloadTaskHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {}

  @override
  void onRepeatEvent(DateTime timestamp) {}

  @override
  Future<void> onDestroy(DateTime timestamp) async {}
}

/// Thin wrapper that drives a "Downloading…" foreground service so the queue
/// keeps running when the app is minimised.
///
/// Android-only: on iOS every call is a no-op (iOS suspends background apps and
/// has no equivalent foreground service — downloads there only continue while
/// the app is in the foreground).
class DownloadForegroundService {
  DownloadForegroundService._();

  static const _channelId = 'ig_downloader_downloads';
  static const _serviceId = 451;

  static bool _initialized = false;
  static bool _running = false;

  static bool get isAndroid => Platform.isAndroid;

  static void _ensureInit() {
    if (_initialized) return;
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: _channelId,
        channelName: 'Downloads',
        channelDescription: 'Keeps downloads running when the app is in the background.',
        onlyAlertOnce: true,
      ),
      iosNotificationOptions: const IOSNotificationOptions(),
      foregroundTaskOptions: ForegroundTaskOptions(
        // No periodic callback — the main isolate does the work.
        eventAction: ForegroundTaskEventAction.nothing(),
        allowWakeLock: true,
        allowWifiLock: true,
      ),
    );
    _initialized = true;
  }

  /// Start the foreground service (or update it if already running) with the
  /// given notification text. Requests the Android 13+ notification permission
  /// on first use.
  static Future<void> start({
    required String title,
    required String text,
  }) async {
    if (!isAndroid) return;
    _ensureInit();

    if (_running) {
      await update(title: title, text: text);
      return;
    }

    // Android 13+ needs runtime POST_NOTIFICATIONS for the service notification.
    final perm = await FlutterForegroundTask.checkNotificationPermission();
    if (perm != NotificationPermission.granted) {
      await FlutterForegroundTask.requestNotificationPermission();
    }

    await FlutterForegroundTask.startService(
      serviceId: _serviceId,
      notificationTitle: title,
      notificationText: text,
      callback: downloadServiceCallback,
    );
    _running = true;
  }

  /// Update the notification text (e.g. progress) while the service runs.
  static Future<void> update({
    required String title,
    required String text,
  }) async {
    if (!isAndroid || !_running) return;
    await FlutterForegroundTask.updateService(
      notificationTitle: title,
      notificationText: text,
    );
  }

  /// Stop the foreground service and dismiss its notification.
  static Future<void> stop() async {
    if (!isAndroid || !_running) return;
    await FlutterForegroundTask.stopService();
    _running = false;
  }
}

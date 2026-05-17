import 'package:flutter/foundation.dart';

/// A single captured log entry.
class LogEntry {
  final DateTime time;
  final String message;
  LogEntry(this.message) : time = DateTime.now();
}

/// In-app debug log sink — only populated in kDebugMode.
/// Hooked into [debugPrint] at app startup so every service log appears here.
class DevLogger extends ChangeNotifier {
  static final DevLogger instance = DevLogger._();
  DevLogger._();

  static const _maxEntries = 500;

  final List<LogEntry> _entries = [];
  List<LogEntry> get entries => List.unmodifiable(_entries);

  /// Set by callers (e.g. HomeScreen) when a new fetch starts.
  /// The DevLogOverlay reads this on the next rebuild and auto-opens.
  bool openRequested = false;

  /// Clear the log and request the overlay to auto-open.
  /// Call this whenever a new media fetch begins.
  void startNewSession() {
    _entries.clear();
    openRequested = true;
    notifyListeners();
  }

  void add(String message) {
    _entries.add(LogEntry(message));
    if (_entries.length > _maxEntries) {
      _entries.removeRange(0, _entries.length - _maxEntries);
    }
    notifyListeners();
  }

  void clear() {
    _entries.clear();
    notifyListeners();
  }
}

import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/settings_service.dart';

// ── Model ────────────────────────────────────────────────────────────────────

class AppSettings {
  final bool wifiOnly;

  const AppSettings({this.wifiOnly = false});

  AppSettings copyWith({bool? wifiOnly}) =>
      AppSettings(wifiOnly: wifiOnly ?? this.wifiOnly);
}

// ── Provider ─────────────────────────────────────────────────────────────────

final settingsProvider =
    StateNotifierProvider<SettingsNotifier, AppSettings>(
  (ref) => SettingsNotifier(),
);

// ── Notifier ─────────────────────────────────────────────────────────────────

class SettingsNotifier extends StateNotifier<AppSettings> {
  SettingsNotifier() : super(const AppSettings()) {
    _load();
  }

  /// Load persisted settings on startup.
  Future<void> _load() async {
    final wifiOnly = await SettingsService.getWifiOnly();
    state = state.copyWith(wifiOnly: wifiOnly);
  }

  /// Toggle the WiFi-only download restriction and persist the value.
  Future<void> setWifiOnly(bool value) async {
    await SettingsService.setWifiOnly(value);
    state = state.copyWith(wifiOnly: value);
  }
}

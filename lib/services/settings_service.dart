import 'package:shared_preferences/shared_preferences.dart';

/// Persists user preferences using SharedPreferences.
class SettingsService {
  static const _keyWifiOnly = 'wifi_only_download';

  /// Whether downloads should only proceed over Wi-Fi. Defaults to false.
  static Future<bool> getWifiOnly() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_keyWifiOnly) ?? false;
  }

  static Future<void> setWifiOnly(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyWifiOnly, value);
  }
}

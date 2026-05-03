import 'package:shared_preferences/shared_preferences.dart';

/// Persists the Instagram `sessionid` cookie so it survives app restarts.
/// The cookie is injected into every Dio request via [DownloaderService].
class SessionService {
  SessionService._();

  static const _key = 'ig_sessionid';

  static Future<String?> getSessionId() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_key);
  }

  static Future<void> saveSessionId(String sessionId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, sessionId);
  }

  static Future<void> clearSession() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key);
  }

  static Future<bool> isLoggedIn() async {
    final sid = await getSessionId();
    return sid != null && sid.isNotEmpty;
  }
}

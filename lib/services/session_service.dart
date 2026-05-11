import 'package:shared_preferences/shared_preferences.dart';

/// Supported login platforms.
enum LoginPlatform { instagram, x }

/// Persists session cookies for multiple platforms so they survive app restarts.
/// The relevant cookie is injected into Dio requests via [DownloaderService].
class SessionService {
  SessionService._();

  static const _keys = {
    LoginPlatform.instagram: 'ig_sessionid',
    LoginPlatform.x: 'x_auth_token',
  };

  static Future<String?> getSessionId(LoginPlatform platform) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_keys[platform]!);
  }

  static Future<void> saveSessionId(LoginPlatform platform, String sessionId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keys[platform]!, sessionId);
  }

  static Future<void> clearSession(LoginPlatform platform) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_keys[platform]!);
  }

  static Future<bool> isLoggedIn(LoginPlatform platform) async {
    final sid = await getSessionId(platform);
    return sid != null && sid.isNotEmpty;
  }
}

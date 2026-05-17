import 'package:shared_preferences/shared_preferences.dart';

/// Supported login platforms.
enum LoginPlatform { instagram, x, facebook }

/// Persists session cookies for multiple platforms so they survive app restarts.
/// The relevant cookie is injected into Dio requests via [DownloaderService].
class SessionService {
  SessionService._();

  static const _keys = {
    LoginPlatform.instagram: 'ig_sessionid',
    LoginPlatform.x: 'x_auth_token',
    // Facebook stores the entire cookie string (c_user + xs + datr etc.)
    // rather than a single named value because all three are needed together.
    LoginPlatform.facebook: 'fb_cookies',
  };

  static const _usernameKeys = {
    LoginPlatform.instagram: 'ig_username',
    LoginPlatform.x: 'x_username',
    LoginPlatform.facebook: 'fb_username',
  };

  // Threads session captured separately by navigating to threads.com after IG login.
  // threads.com uses a different cookie domain from instagram.com even though it
  // shares the same account — Meta requires a threads-specific session cookie.
  static const _threadsSessionKey = 'threads_sessionid';

  static Future<String?> getThreadsSessionId() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_threadsSessionKey);
  }

  static Future<void> saveThreadsSessionId(String value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_threadsSessionKey, value);
  }

  static Future<String?> getSessionId(LoginPlatform platform) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_keys[platform]!);
  }

  static Future<void> saveSessionId(LoginPlatform platform, String sessionId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keys[platform]!, sessionId);
  }

  static Future<String?> getUsername(LoginPlatform platform) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_usernameKeys[platform]!);
  }

  static Future<void> saveUsername(LoginPlatform platform, String username) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_usernameKeys[platform]!, username);
  }

  static Future<void> clearSession(LoginPlatform platform) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_keys[platform]!);
    await prefs.remove(_usernameKeys[platform]!); // also clear stored username
    // IG logout also clears the Threads session (always captured together)
    if (platform == LoginPlatform.instagram) {
      await prefs.remove(_threadsSessionKey);
    }
  }

  static Future<bool> isLoggedIn(LoginPlatform platform) async {
    final sid = await getSessionId(platform);
    return sid != null && sid.isNotEmpty;
  }
}

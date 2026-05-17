import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';
import '../services/session_service.dart';

/// Per-platform login configuration.
class _PlatformConfig {
  final String label;
  final String loginUrl;
  final String cookieDomain;
  final String cookieName;
  /// URL patterns that indicate the user is still on the login flow (not done yet).
  final List<String> loginFlowPatterns;
  /// If true, stores the entire raw cookie string rather than just the named cookie.
  /// Use for platforms like Facebook where several cookies are needed together.
  final bool storeFullCookies;

  const _PlatformConfig({
    required this.label,
    required this.loginUrl,
    required this.cookieDomain,
    required this.cookieName,
    required this.loginFlowPatterns,
    this.storeFullCookies = false,
  });
}

const _configs = {
  LoginPlatform.instagram: _PlatformConfig(
    label: 'Instagram',
    loginUrl: 'https://www.instagram.com/accounts/login/',
    cookieDomain: 'https://www.instagram.com',
    cookieName: 'sessionid',
    loginFlowPatterns: ['/accounts/login/', '/accounts/emailsignup/'],
  ),
  LoginPlatform.x: _PlatformConfig(
    label: 'X (Twitter)',
    loginUrl: 'https://x.com/i/flow/login',
    cookieDomain: 'https://x.com',
    cookieName: 'auth_token',
    loginFlowPatterns: ['/i/flow/login', '/i/flow/signup', 'twitter.com/login', 'x.com/login'],
  ),
  LoginPlatform.facebook: _PlatformConfig(
    label: 'Facebook',
    loginUrl: 'https://www.facebook.com/login/',
    cookieDomain: 'https://www.facebook.com',
    // Detect login completion by the presence of the c_user cookie (user ID).
    // The full cookie string (c_user + xs + datr etc.) is stored so requests
    // can be made with the complete auth header.
    cookieName: 'c_user',
    loginFlowPatterns: [
      'facebook.com/login',
      'facebook.com/checkpoint',
      '/login/',
      '/login?',
    ],
    storeFullCookies: true,
  ),
};

/// Full-screen platform login via an in-app WebView.
/// Pass [platform] to configure which site is loaded and which session
/// cookie is captured.  The HttpOnly cookie is read via a native
/// MethodChannel because JS document.cookie cannot access it.
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key, required this.platform});

  final LoginPlatform platform;

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  late final WebViewController _webController;
  late final _PlatformConfig _cfg;
  bool _loading = true;
  bool _captured = false;

  @override
  void initState() {
    super.initState();
    _cfg = _configs[widget.platform]!;
    _webController = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(NavigationDelegate(
        onPageStarted: (_) => setState(() => _loading = true),
        onPageFinished: (url) async {
          setState(() => _loading = false);
          await _tryCaptureSession(url);
        },
      ))
      ..loadRequest(Uri.parse(_cfg.loginUrl));
  }

  static const _cookieChannel = MethodChannel('ig_downloader/cookies');

  Future<void> _tryCaptureSession(String url) async {
    if (_captured) return;
    // Stay on login pages until the user actually completes login.
    if (_cfg.loginFlowPatterns.any((p) => url.contains(p))) return;

    // Read cookies via native Android CookieManager MethodChannel.
    // This is the only reliable way to get HttpOnly cookies like sessionid /
    // auth_token — JS document.cookie and WebViewCookieManager both fail.
    final rawCookies = await _readRawCookiesFromNative(_cfg.cookieDomain);
    debugPrint('[Login/${_cfg.label}] cookies after redirect to $url: '
        '${rawCookies != null ? 'FOUND' : 'NOT FOUND'}');

    if (rawCookies == null || rawCookies.isEmpty) return;

    // For platforms that need the full cookie string (e.g. Facebook), store
    // it whole.  For others, extract just the named cookie value.
    String? token;
    if (_cfg.storeFullCookies) {
      // Only proceed if the sentinel cookie (e.g. c_user) is present —
      // that confirms the user has actually completed login.
      final hasSentinel = rawCookies
          .split(';')
          .any((part) => part.trim().startsWith('${_cfg.cookieName}='));
      if (hasSentinel) token = rawCookies;
    } else {
      for (final part in rawCookies.split(';')) {
        final kv = part.trim().split('=');
        if (kv.length >= 2 && kv[0].trim() == _cfg.cookieName) {
          token = kv.sublist(1).join('=').trim();
          break;
        }
      }
    }

    if (token != null && token.isNotEmpty) {
      _captured = true;
      await SessionService.saveSessionId(widget.platform, token);
      // Fetch username NOW, while the WebView is still alive (before pop).
      // We intentionally do NOT make extra HTTP requests to Instagram — the
      // x-ig-app-id API call we removed was triggering automated-behaviour warnings.
      try {
        final username = await _fetchUsernameFromPage(token);
        if (username != null && username.isNotEmpty) {
          await SessionService.saveUsername(widget.platform, username);
        }
      } catch (e) {
        debugPrint('[Login/${_cfg.label}] username fetch failed: $e');
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Logged in to ${_cfg.label} — unlocked!')),
        );
        Navigator.of(context).pop(true);
      }
    }
  }

  // ── Username resolution ────────────────────────────────────────────────

  Future<String?> _fetchUsernameFromPage(String token) async {
    switch (widget.platform) {
      case LoginPlatform.instagram:
        return _fetchIgUsernameFromWebView();
      case LoginPlatform.x:
        return _fetchXUsername(token);
      case LoginPlatform.facebook:
        return _extractFbUserId(token);
    }
  }

  /// Reads the Instagram username from the already-loaded WebView page via JS.
  /// NO extra HTTP requests are made — the previous x-ig-app-id API call was
  /// triggering Instagram's automated-behaviour detection.
  Future<String?> _fetchIgUsernameFromWebView() async {
    try {
      final result = await _webController.runJavaScriptReturningResult(r'''
        (function() {
          try {
            var s = document.getElementById('__NEXT_DATA__');
            if (s) {
              var d = JSON.parse(s.textContent);
              var v = d && d.props && d.props.pageProps && d.props.pageProps.viewer;
              if (v && v.username) return v.username;
            }
          } catch(e) {}
          return '';
        })()
      ''');
      final str = result.toString().replaceAll('"', '').trim();
      return (str.isEmpty || str == 'null') ? null : str;
    } catch (e) {
      debugPrint('[Login] IG username from WebView JS failed: $e');
      return null;
    }
  }

  /// Calls the X/Twitter API to get the logged-in screen name.
  /// Requires both auth_token and ct0 (CSRF) cookies from the WebView.
  Future<String?> _fetchXUsername(String authToken) async {
    try {
      final rawCookies = await _readRawCookiesFromNative('https://x.com');
      String? ct0;
      if (rawCookies != null) {
        for (final part in rawCookies.split(';')) {
          final kv = part.trim().split('=');
          if (kv.length >= 2 && kv[0].trim() == 'ct0') {
            ct0 = kv.sublist(1).join('=').trim();
            break;
          }
        }
      }
      if (ct0 == null) return null;
      final dio = Dio(BaseOptions(
        connectTimeout: const Duration(seconds: 10),
        receiveTimeout: const Duration(seconds: 10),
        headers: {
          'User-Agent':
              'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) '
              'AppleWebKit/537.36 (KHTML, like Gecko) '
              'Chrome/124.0.0.0 Safari/537.36',
          'Cookie': 'auth_token=$authToken; ct0=$ct0',
          'x-csrf-token': ct0,
          // X's public bearer token (same across all web clients)
          'Authorization':
              'Bearer AAAAAAAAAAAAAAAAAAAAANRILgAAAAAAnNwIzUejRCOuH5E6I8xnZz4puTs'
              '%3D1Zv7ttfk8LF81IUq16cHjhLTvJu4FA33AGWWjCpTnA',
        },
      ));
      final resp = await dio.get<Map<String, dynamic>>(
        'https://api.x.com/1.1/account/verify_credentials.json',
        queryParameters: {'include_entities': 'false', 'skip_status': 'true'},
      );
      return resp.data?['screen_name'] as String?;
    } catch (e) {
      debugPrint('[Login] X username fetch failed: $e');
      return null;
    }
  }

  /// Extracts the Facebook numeric user ID (c_user) from the stored cookie string.
  String? _extractFbUserId(String cookieString) {
    for (final part in cookieString.split(';')) {
      final kv = part.trim().split('=');
      if (kv.length >= 2 && kv[0].trim() == 'c_user') {
        return kv[1].trim(); // numeric Facebook user ID
      }
    }
    return null;
  }

  Future<String?> _readRawCookiesFromNative(String domain) async {
    try {
      final raw = await _cookieChannel.invokeMethod<String>(
        'getCookie',
        {'url': domain},
      );
      return (raw != null && raw.isNotEmpty) ? raw : null;
    } catch (e) {
      debugPrint('[Login/${_cfg.label}] Cookie channel error: $e');
      return null;
    }
  }

  Future<void> _logout() async {
    await SessionService.clearSession(widget.platform);
    final cookieManager = WebViewCookieManager();
    await cookieManager.clearCookies();
    _captured = false;
    await _webController.loadRequest(Uri.parse(_cfg.loginUrl));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('${_cfg.label} Login'),
        actions: [
          TextButton(
            onPressed: _logout,
            child: const Text('Logout'),
          ),
        ],
      ),
      body: Stack(
        children: [
          WebViewWidget(controller: _webController),
          if (_loading)
            const Center(child: CircularProgressIndicator()),
        ],
      ),
    );
  }
}

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
    loginFlowPatterns: [
      '/accounts/login/',
      '/accounts/emailsignup/',
      '/accounts/onetap/',          // "Save login info" interstitial
      '/accounts/password/',        // Password reset flow
      '/accounts/suspended',        // Suspended account page
      '/accounts/integrity',        // Integrity check
      '/accounts/update_risky',     // "Update risky contact point" challenge
      '/accounts/seamless_login',   // Seamless login redirect
      '/challenge/',                // Generic security challenge
      'challenge_context',          // Challenge context URL param
      '/two_factor',                // 2FA entry
      '/verify/',                   // Verification steps
      'security_check',             // Security check page
    ],
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
      // Android WebView includes "wv" in the User-Agent, which Instagram's
      // security challenge page (update_risky_contactpoint) detects and
      // immediately rejects by redirecting to a new challenge — which also
      // detects "wv" — creating an 18-deep redirect chain that ends in
      // ERR_TOO_MANY_REDIRECTS.  Use a real Chrome Mobile UA (no "wv") so
      // Instagram treats the WebView as a regular Chrome browser session.
      ..setUserAgent(
        'Mozilla/5.0 (Linux; Android 14; SM-S9280) '
        'AppleWebKit/537.36 (KHTML, like Gecko) '
        'Chrome/136.0.0.0 Mobile Safari/537.36',
      )
      ..setNavigationDelegate(NavigationDelegate(
        // Facebook (and IG/X) try to hand the login off to their native app via
        // a custom scheme (e.g. fb…://login_via_app/?…). A WebView can't load a
        // non-web scheme, so it dies with ERR_UNKNOWN_URL_SCHEME. Keep the user
        // in the web flow — which is the only place we can read the session
        // cookie — by allowing http/https/about and blocking everything else.
        onNavigationRequest: (request) {
          final scheme = Uri.tryParse(request.url)?.scheme.toLowerCase() ?? '';
          if (scheme == 'http' || scheme == 'https' || scheme == 'about') {
            return NavigationDecision.navigate;
          }
          return NavigationDecision.prevent;
        },
        onPageStarted: (_) => setState(() => _loading = true),
        onPageFinished: (url) async {
          setState(() => _loading = false);
          await _tryCaptureSession(url);
        },
        onWebResourceError: (error) {
          // Catch ERR_TOO_MANY_REDIRECTS before Chrome shows its error page.
          // IG's challenge page (update_risky_contactpoint) detects WebView
          // via JS APIs and redirects to a new challenge each time, creating
          // an 18-deep chain.  Stop the loop and guide the user.
          if ((error.isForMainFrame ?? true) &&
              (error.errorType == WebResourceErrorType.redirectLoop ||
                  error.description.toLowerCase().contains('redirect'))) {
            _handleRedirectLoop();
          }
        },
      ))
      ..loadRequest(Uri.parse(_cfg.loginUrl));
  }

  static const _cookieChannel = MethodChannel('ig_downloader/cookies');

  Future<void> _tryCaptureSession(String url) async {
    if (_captured) return;
    // Skip: we navigated here to stop a redirect loop (handled by _handleRedirectLoop).
    if (url.startsWith('about:')) return;
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
      try {
        final username = await _fetchUsernameFromPage(token);
        if (username != null && username.isNotEmpty) {
          await SessionService.saveUsername(widget.platform, username);
        }
      } catch (e) {
        debugPrint('[Login/${_cfg.label}] username fetch failed: $e');
      }
      // For Instagram: Meta's login flow sometimes sets threads.com cookies in
      // Android's CookieManager as a side-effect (cross-domain auth). Try to
      // read them directly — no WebView navigation, no risk of redirect loops.
      if (widget.platform == LoginPlatform.instagram) {
        try {
          final threadsCookies =
              await _readRawCookiesFromNative('https://www.threads.com');
          if (threadsCookies != null && threadsCookies.isNotEmpty) {
            for (final part in threadsCookies.split(';')) {
              final kv = part.trim().split('=');
              if (kv.length >= 2 && kv[0].trim() == 'sessionid') {
                final ts = kv.sublist(1).join('=').trim();
                if (ts.isNotEmpty) {
                  await SessionService.saveThreadsSessionId(ts);
                  debugPrint('[Login/IG] Threads session captured from existing cookies');
                }
                break;
              }
            }
          } else {
            debugPrint('[Login/IG] Threads session: no cookies found (skipping)');
          }
        } catch (e) {
          debugPrint('[Login/IG] Threads cookie check failed: $e');
        }
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Logged in to ${_cfg.label} — unlocked!')),
        );
        Navigator.of(context).pop(true);
      }
    }
  }

  // ── Redirect loop recovery ────────────────────────────────────────────

  /// Called when ERR_TOO_MANY_REDIRECTS fires on the main frame.
  /// Captures the session from current cookies (before navigating away),
  /// stops the loop by loading about:blank, shows an explanatory dialog,
  /// then closes the login screen cleanly.
  Future<void> _handleRedirectLoop() async {
    if (_captured) return;

    // Try to save the IG session that was set before the challenge fired.
    bool sessionSaved = false;
    try {
      final rawCookies = await _readRawCookiesFromNative(_cfg.cookieDomain);
      if (rawCookies != null) {
        for (final part in rawCookies.split(';')) {
          final kv = part.trim().split('=');
          if (kv.length >= 2 && kv[0].trim() == _cfg.cookieName) {
            final token = kv.sublist(1).join('=').trim();
            if (token.isNotEmpty) {
              _captured = true;
              await SessionService.saveSessionId(widget.platform, token);
              sessionSaved = true;
              debugPrint('[Login/${_cfg.label}] session captured before redirect loop abort');
            }
            break;
          }
        }
      }
    } catch (e) {
      debugPrint('[Login/${_cfg.label}] redirect loop: cookie read failed: $e');
    }

    // Stop the redirect chain.
    await _webController.loadRequest(Uri.parse('about:blank'));

    if (!mounted) return;

    // Show dialog and AWAIT it — so Navigator.pop below runs after OK is tapped,
    // not while the dialog is still the top route.
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('Instagram Security Check Required'),
        content: const Text(
          'Instagram needs you to verify your account, but this '
          'verification cannot complete inside the app browser.\n\n'
          'Please:\n'
          '1. Open Instagram in Chrome on this device\n'
          '2. Log in and complete the verification there\n'
          '3. Come back here and log in again',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('OK'),
          ),
        ],
      ),
    );

    // Dialog dismissed — now close the login screen.
    if (mounted) Navigator.of(context).pop(sessionSaved);
  }

  // ── Threads session capture (runs after IG login) ──────────────────────
  // Threads session is read directly from Android's CookieManager after IG
  // login completes. Meta's auth flow sometimes sets threads.com cookies as a
  // side-effect. We do NOT navigate the WebView to threads.com — that causes
  // cross-domain auth redirects back through instagram.com which can collide
  // with any pending IG security challenge and trigger ERR_TOO_MANY_REDIRECTS.

  // ── Username resolution ────────────────────────────────────────────────

  Future<String?> _fetchUsernameFromPage(String token) async {
    switch (widget.platform) {
      case LoginPlatform.instagram:
        return _fetchIgUsernameFromWebView();
      case LoginPlatform.x:
        return _fetchXUsername(token);
      case LoginPlatform.facebook:
        return _fetchFbUsername(token);
    }
  }

  /// Reads the Instagram username from the already-loaded WebView page via JS.
  /// NO extra HTTP requests are made — the previous x-ig-app-id API call was
  /// triggering Instagram's automated-behaviour detection.
  /// Falls back to a one-time private API call only if JS yields nothing
  /// (e.g. Instagram changes their page structure).
  Future<String?> _fetchIgUsernameFromWebView() async {
    // ── Try 1: read from __NEXT_DATA__ in the already-loaded page ──────────
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
      if (str.isNotEmpty && str != 'null') return str;
    } catch (e) {
      debugPrint('[Login] IG username WebView JS failed: $e');
    }

    // ── Fallback: one-time private API call (only if JS failed) ────────────
    // Risk is low — this fires at most once per login session, never per-download.
    // Including x-ig-app-id here is intentional: the Instagram web app sends it
    // on every page load. We only avoided it in per-download API calls.
    try {
      final sessionId = await SessionService.getSessionId(LoginPlatform.instagram);
      if (sessionId == null) return null;
      final dio = Dio(BaseOptions(
        connectTimeout: const Duration(seconds: 10),
        receiveTimeout: const Duration(seconds: 10),
        headers: {
          'User-Agent':
              'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) '
              'AppleWebKit/537.36 (KHTML, like Gecko) '
              'Chrome/124.0.0.0 Safari/537.36',
          'Cookie': 'sessionid=$sessionId',
          'x-ig-app-id': '936619743392459',
        },
      ));
      // Use the public-facing profile redirect — requires x-ig-app-id on web.
      final resp = await dio.get<Map<String, dynamic>>(
        'https://www.instagram.com/api/v1/accounts/current_user/',
        queryParameters: {'edit': 'true'},
      );
      final user = resp.data?['user'] as Map<String, dynamic>?;
      return user?['username'] as String?;
    } catch (e) {
      debugPrint('[Login] IG username API fallback failed: $e');
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

  /// Resolves the Facebook display name/username by following the /me redirect
  /// with the authenticated session. Falls back to null ("Logged in" shown) if
  /// the user has no custom username (profile.php?id=... redirect).
  Future<String?> _fetchFbUsername(String cookieString) async {
    try {
      final dio = Dio(BaseOptions(
        connectTimeout: const Duration(seconds: 10),
        receiveTimeout: const Duration(seconds: 15),
        followRedirects: true,
        maxRedirects: 5,
        headers: {
          'User-Agent':
              'Mozilla/5.0 (Linux; Android 14; SM-S928B) AppleWebKit/537.36 '
              '(KHTML, like Gecko) Chrome/124.0.0.0 Mobile Safari/537.36',
          'Cookie': cookieString,
          'Accept-Language': 'en-US,en;q=0.9',
        },
      ));
      final resp = await dio.get<String>('https://www.facebook.com/me');
      final finalUrl = resp.realUri.toString();
      // /me redirects to /<username> or /profile.php?id=<numeric>
      final m =
          RegExp(r'facebook\.com/([^/?#]+)').firstMatch(finalUrl);
      final slug = m?.group(1);
      // Reject numeric-only slugs (no custom username set) and profile.php
      if (slug != null &&
          slug != 'me' &&
          !slug.startsWith('profile.php') &&
          !RegExp(r'^\d+$').hasMatch(slug)) {
        return slug;
      }
    } catch (e) {
      debugPrint('[Login/FB] Username fetch failed: $e');
    }
    return null; // show "Logged in" when no custom username available
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

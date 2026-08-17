import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';
import '../services/rate_guard_service.dart';
import '../services/session_service.dart';
import '../services/webview_user_agent.dart';

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

/// Lower-cased substrings that appear on Instagram's "action blocked" /
/// rate-limit / "try again later" interstitials. When any of these is present
/// on the loaded page we treat the session as *blocked*: we keep the in-app
/// browser open (instead of auto-closing) and surface an "open in browser"
/// escape hatch so the user can clear the block on the real Chrome session.
///
/// Context: when this IG account is also signed in from another app (e.g. the
/// Instagram app itself), Meta's security mechanism forces a password refresh /
/// re-verification and shows an "open the Instagram app, try again later"
/// block — which cannot be cleared inside the WebView. Detecting it lets the
/// user bail out to a full browser rather than getting stuck in a retry loop.
const _igBlockSignals = <String>[
  'we restrict certain activity',
  'blocked this action',
  'action blocked',
  'try again later',
  'please wait a few minutes',
  'open the instagram app',
  'we limit how often',
  "you're temporarily blocked",
];

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

  /// Last fully-loaded URL — used as the target when the user taps
  /// "Open in browser" so the external Chrome session lands on the same page.
  String _currentUrl = '';

  /// True when Instagram has shown a block / "try again later" interstitial.
  /// While blocked we do NOT auto-close the login screen — we keep the in-app
  /// browser open and show the escape-hatch banner so the user can act.
  bool _blocked = false;

  /// The specific block phrase detected (shown to the user for context).
  String? _blockText;



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
      ..setUserAgent(kRealChromeMobileUA)
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
          setState(() {
            _loading = false;
            _currentUrl = url;
          });
          // Check for an Instagram block / "try again later" interstitial.
          // If blocked, keep the in-app browser open (no auto-pop) and let the
          // banner offer the "open in browser" escape hatch. If not blocked,
          // proceed exactly as before: capture the session and go back.
          final block = await _detectBlock();
          if (block != null) {
            // Login may already have succeeded before the *action* was blocked,
            // so still try to save the session — but silently, without popping.
            await _tryCaptureSession(url, autoPop: false);
            _enterBlockedState(block);
            return;
          }
          if (_blocked) setState(() => _blocked = false); // block cleared
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

  Future<void> _tryCaptureSession(String url, {bool autoPop = true}) async {
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
      // A fresh Instagram session invalidates any RateGuard cooldown that was
      // tripped against the OLD session (most importantly a login_required
      // auth wall — waiting it out was pointless, re-login is the fix).
      if (widget.platform == LoginPlatform.instagram) {
        await RateGuard.instance.onSessionRefreshed();
      }
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
        // When blocked we keep the screen open so the user can clear the block
        // in a real browser; the session is saved but we don't pop yet.
        if (autoPop) Navigator.of(context).pop(true);
      }
    }
  }

  // ── Block detection & escape hatch ─────────────────────────────────────

  /// Scans the loaded page for an Instagram block / "try again later" message.
  /// Returns the matched phrase, or null when the page looks normal. Only runs
  /// for Instagram — other platforms have no equivalent interstitial here.
  Future<String?> _detectBlock() async {
    if (widget.platform != LoginPlatform.instagram) return null;
    try {
      final result = await _webController.runJavaScriptReturningResult(r'''
        (function() {
          try {
            var t = (document.body && document.body.innerText
                ? document.body.innerText : '').toLowerCase();
            var s = [
              'we restrict certain activity',
              'blocked this action',
              'action blocked',
              'try again later',
              'please wait a few minutes',
              'open the instagram app',
              'we limit how often',
              "you're temporarily blocked"
            ];
            for (var i = 0; i < s.length; i++) {
              if (t.indexOf(s[i]) > -1) return s[i];
            }
            return '';
          } catch (e) { return ''; }
        })()
      ''');
      final str = result.toString().replaceAll('"', '').trim();
      if (str.isEmpty || str == 'null') return null;
      // Defensive: make sure the returned value is actually one of our signals
      // (some WebViews wrap JS results oddly).
      return _igBlockSignals.contains(str) ? str : null;
    } catch (e) {
      debugPrint('[Login/${_cfg.label}] block detect failed: $e');
      return null;
    }
  }

  /// Switch the screen into the "blocked" state: keep the WebView visible and
  /// show the banner with the "open in browser" escape hatch.
  void _enterBlockedState(String phrase) {
    if (!mounted) return;
    setState(() {
      _blocked = true;
      _blockText = phrase;
      _loading = false;
    });
  }

  /// Opens the current page in the device's real browser (Chrome), where the
  /// user can complete the security re-verification that the in-app WebView
  /// can't. Mirrors the working launch pattern in download_job_tile.dart.
  Future<void> _openInExternalBrowser() async {
    // about:blank (e.g. after a redirect-loop stop) isn't useful externally —
    // fall back to the platform login URL so Chrome lands somewhere sensible.
    final target = (_currentUrl.isEmpty || _currentUrl.startsWith('about:'))
        ? _cfg.loginUrl
        : _currentUrl;
    try {
      final ok = await launchUrl(
        Uri.parse(target),
        mode: LaunchMode.externalApplication,
      );
      if (!ok && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not open a browser')),
        );
      }
    } catch (e) {
      debugPrint('[Login/${_cfg.label}] external browser launch failed: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not open a browser')),
        );
      }
    }
  }

  /// Reloads the login page to retry after the user has cleared the block in
  /// their browser. Clears the blocked banner.
  Future<void> _retryLogin() async {
    setState(() {
      _blocked = false;
      _blockText = null;
      _loading = true;
    });
    await _webController.loadRequest(Uri.parse(_cfg.loginUrl));
  }

  // ── Redirect loop recovery ────────────────────────────────────────────

  /// Called when ERR_TOO_MANY_REDIRECTS fires on the main frame.
  /// Captures the session from current cookies (before navigating away),
  /// stops the loop by loading about:blank, then drops into the blocked state
  /// so the user can verify in a real browser and retry.
  Future<void> _handleRedirectLoop() async {
    if (_captured) return;

    // Try to save the IG session that was set before the challenge fired.
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
              // Same as _tryCaptureSession: a new session stales any active
              // RateGuard cooldown tripped against the old one.
              if (widget.platform == LoginPlatform.instagram) {
                await RateGuard.instance.onSessionRefreshed();
              }
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

    // A redirect loop is Instagram's security challenge blocking the WebView.
    // Rather than force-closing the screen, drop into the same blocked state as
    // a content block: keep the screen open and surface the "open in browser"
    // escape hatch so the user can verify in real Chrome, then retry. (The IG
    // session, if it was set before the challenge fired, is already saved.)
    _enterBlockedState('security check required');
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
          // Always-available escape hatch: open the current page in the real
          // browser (Chrome), where security challenges that the WebView can't
          // complete will work.
          IconButton(
            icon: const Icon(Icons.open_in_browser),
            tooltip: 'Open in browser',
            onPressed: _openInExternalBrowser,
          ),
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
          if (_blocked) _buildBlockedBanner(context),
        ],
      ),
    );
  }

  /// Bottom banner shown when Instagram blocks the login/action. Keeps the
  /// in-app browser visible and offers the escape hatch (open in real browser),
  /// a retry, and a way to leave with whatever session was captured.
  Widget _buildBlockedBanner(BuildContext context) {
    final theme = Theme.of(context);
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: Material(
        elevation: 8,
        color: theme.colorScheme.surfaceContainerHighest,
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.block, color: theme.colorScheme.error, size: 20),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Instagram blocked this action',
                        style: theme.textTheme.titleSmall,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  'Instagram is showing a security/"try again later" block '
                  '("${_blockText ?? 'blocked'}") that can\'t be cleared inside '
                  'this in-app browser. Open the page in your real browser, '
                  'complete any verification, then come back and retry.',
                  style: theme.textTheme.bodySmall,
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    FilledButton.icon(
                      onPressed: _openInExternalBrowser,
                      icon: const Icon(Icons.open_in_browser, size: 18),
                      label: const Text('Open in browser'),
                    ),
                    OutlinedButton.icon(
                      onPressed: _retryLogin,
                      icon: const Icon(Icons.refresh, size: 18),
                      label: const Text('Retry'),
                    ),
                    TextButton(
                      onPressed: () => Navigator.of(context).pop(_captured),
                      child: const Text('Close'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

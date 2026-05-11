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

  const _PlatformConfig({
    required this.label,
    required this.loginUrl,
    required this.cookieDomain,
    required this.cookieName,
    required this.loginFlowPatterns,
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
    final token = await _readCookieFromNative(_cfg.cookieDomain, _cfg.cookieName);
    debugPrint('[Login/${_cfg.label}] ${_cfg.cookieName} after redirect to $url: '
        '${token != null ? 'FOUND' : 'NOT FOUND'}');

    if (token != null && token.isNotEmpty) {
      _captured = true;
      await SessionService.saveSessionId(widget.platform, token);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Logged in to ${_cfg.label} — unlocked!')),
        );
        Navigator.of(context).pop(true);
      }
    }
  }

  Future<String?> _readCookieFromNative(String domain, String cookieName) async {
    try {
      final raw = await _cookieChannel.invokeMethod<String>(
        'getCookie',
        {'url': domain},
      );
      if (raw == null || raw.isEmpty) return null;
      for (final part in raw.split(';')) {
        final kv = part.trim().split('=');
        if (kv.length >= 2 && kv[0].trim() == cookieName) {
          return kv.sublist(1).join('=').trim();
        }
      }
    } catch (e) {
      debugPrint('[Login/${_cfg.label}] Cookie channel error: $e');
    }
    return null;
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

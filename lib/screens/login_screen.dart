import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';
import '../services/session_service.dart';

/// Full-screen Instagram login via an in-app WebView.
/// When the user completes login, we extract their `sessionid` cookie
/// using the native WebView cookie manager (required because Instagram
/// sets sessionid as HttpOnly — JS document.cookie cannot read it).
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  late final WebViewController _controller;
  bool _loading = true;
  bool _captured = false;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(NavigationDelegate(
        onPageStarted: (_) => setState(() => _loading = true),
        onPageFinished: (url) async {
          setState(() => _loading = false);
          await _tryCaptureSession(url);
        },
      ))
      ..loadRequest(Uri.parse('https://www.instagram.com/accounts/login/'));
  }

  static const _cookieChannel = MethodChannel('ig_downloader/cookies');

  Future<void> _tryCaptureSession(String url) async {
    if (_captured) return;
    // Stay on login page until the user actually completes login
    if (url.contains('/accounts/login/') || url.contains('/accounts/emailsignup/')) return;

    // Read cookies via native Android CookieManager MethodChannel.
    // This is the only reliable way to get HttpOnly cookies like sessionid
    // — JS document.cookie and WebViewCookieManager.getCookies() both fail.
    final sessionId = await _readSessionIdFromNative();
    debugPrint('[Login] sessionid after redirect to $url: ${sessionId != null ? 'FOUND' : 'NOT FOUND'}');

    if (sessionId != null && sessionId.isNotEmpty) {
      _captured = true;
      await SessionService.saveSessionId(sessionId);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Logged in — private posts unlocked!')),
        );
        Navigator.of(context).pop(true);
      }
    }
  }

  Future<String?> _readSessionIdFromNative() async {
    try {
      final raw = await _cookieChannel.invokeMethod<String>(
        'getCookie',
        {'url': 'https://www.instagram.com'},
      );
      if (raw == null || raw.isEmpty) return null;
      for (final part in raw.split(';')) {
        final kv = part.trim().split('=');
        if (kv.length >= 2 && kv[0].trim() == 'sessionid') {
          return kv.sublist(1).join('=').trim();
        }
      }
    } catch (e) {
      debugPrint('[Login] Cookie channel error: $e');
    }
    return null;
  }

  Future<void> _logout() async {
    await SessionService.clearSession();
    final cookieManager = WebViewCookieManager();
    await cookieManager.clearCookies();
    _captured = false;
    await _controller.loadRequest(
      Uri.parse('https://www.instagram.com/accounts/login/'),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Instagram Login'),
        actions: [
          TextButton(
            onPressed: _logout,
            child: const Text('Logout'),
          ),
        ],
      ),
      body: Stack(
        children: [
          WebViewWidget(controller: _controller),
          if (_loading)
            const Center(child: CircularProgressIndicator()),
        ],
      ),
    );
  }
}

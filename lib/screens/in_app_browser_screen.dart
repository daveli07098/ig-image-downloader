import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';
import '../services/webview_user_agent.dart';

/// A lightweight in-app browser for previewing a platform's pages *after* login.
///
/// The WebView shares Android's CookieManager with the login WebView, so the
/// already-captured session makes this load as the logged-in user — letting the
/// user scroll their Instagram/X/Facebook feed without leaving the app. It is
/// read-only-ish: there is no cookie capture here (that's the LoginScreen's job),
/// just navigation, refresh, back, and an "open in external browser" hatch.
class InAppBrowserScreen extends StatefulWidget {
  const InAppBrowserScreen({
    super.key,
    required this.initialUrl,
    required this.title,
  });

  /// The page to open first (e.g. https://www.instagram.com/).
  final String initialUrl;

  /// AppBar title (e.g. "Instagram").
  final String title;

  @override
  State<InAppBrowserScreen> createState() => _InAppBrowserScreenState();
}

class _InAppBrowserScreenState extends State<InAppBrowserScreen> {
  late final WebViewController _controller;
  bool _loading = true;
  String _currentUrl = '';

  @override
  void initState() {
    super.initState();
    _currentUrl = widget.initialUrl;
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      // Match the login WebView's real-Chrome UA (no "wv") so Instagram doesn't
      // treat us as an automated WebView and throw a challenge.
      ..setUserAgent(kRealChromeMobileUA)
      ..setNavigationDelegate(NavigationDelegate(
        // Keep the user in the web flow: allow only web schemes, block native
        // app handoffs (e.g. fb…://, intent://) that a WebView can't load.
        onNavigationRequest: (request) {
          final scheme = Uri.tryParse(request.url)?.scheme.toLowerCase() ?? '';
          if (scheme == 'http' || scheme == 'https' || scheme == 'about') {
            return NavigationDecision.navigate;
          }
          return NavigationDecision.prevent;
        },
        onPageStarted: (_) => setState(() => _loading = true),
        onPageFinished: (url) => setState(() {
          _loading = false;
          _currentUrl = url;
        }),
      ))
      ..loadRequest(Uri.parse(widget.initialUrl));
  }

  Future<void> _openExternally() async {
    final target =
        (_currentUrl.isEmpty || _currentUrl.startsWith('about:'))
            ? widget.initialUrl
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
      debugPrint('[InAppBrowser] external launch failed: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Reload',
            onPressed: () => _controller.reload(),
          ),
          IconButton(
            icon: const Icon(Icons.open_in_browser),
            tooltip: 'Open in external browser',
            onPressed: _openExternally,
          ),
        ],
      ),
      body: Stack(
        children: [
          WebViewWidget(controller: _controller),
          if (_loading)
            const LinearProgressIndicator(minHeight: 2),
        ],
      ),
    );
  }
}

import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'js_challenge_detector.dart';
import 'webview_user_agent.dart';

/// Re-fetches [url] through a real, JS-enabled WebView so a JS-based anti-bot
/// challenge (e.g. Automattic's hashcash gate on Tumblr) gets to run and clear
/// naturally, then returns the resulting rendered DOM as an HTML string.
///
/// Deliberately does NOT compute the hashcash proof-of-work in Dart — the
/// WebView must solve it by executing the page's own JS. This is intentional;
/// do not "optimize" it away.
///
/// The WebView stays invisible while the challenge is expected to clear on
/// its own (polled every ~1s). If it hasn't cleared within [timeout], a
/// visible screen is surfaced so the user can complete it manually (e.g. tap
/// an "I am human" checkbox); the WebView keeps polling and the future
/// completes once the DOM clears. The user can cancel at any time via the
/// close button, which throws.
Future<String> fetchRenderedHtml(
  BuildContext context,
  String url, {
  Duration timeout = const Duration(seconds: 20),
}) async {
  final result = await _pushWebViewFetcher(context, url, timeout: timeout);
  return result.html;
}

/// Like [fetchRenderedHtml], but also returns the WebView's final URL
/// (`WebViewController.currentUrl()`, read once the DOM has settled) —
/// [finalUrl] is null only if reading it failed. Used by
/// [ThreadsDownloaderService] to resolve a `/share/`/`/t/` short link's
/// canonical URL when that can only be discovered by actually rendering the
/// page (e.g. it needs the logged-in cookie jar this WebView shares with the
/// rest of the app, via the Android CookieManager). [fetchRenderedHtml]
/// keeps its original signature/behavior unchanged for its existing caller.
Future<({String html, String? finalUrl})> fetchRenderedHtmlWithUrl(
  BuildContext context,
  String url, {
  Duration timeout = const Duration(seconds: 20),
}) {
  return _pushWebViewFetcher(context, url, timeout: timeout);
}

Future<({String html, String? finalUrl})> _pushWebViewFetcher(
  BuildContext context,
  String url, {
  required Duration timeout,
}) async {
  final result = await Navigator.of(context, rootNavigator: true)
      .push<({String html, String? finalUrl})>(
    MaterialPageRoute(
      builder: (_) => _WebViewHtmlFetcherScreen(url: url, timeout: timeout),
      fullscreenDialog: true,
    ),
  );
  if (result == null) {
    throw Exception('Cancelled while verifying the page.');
  }
  return result;
}

/// Decodes a `runJavaScriptReturningResult` value. Android wraps the returned
/// string in a JSON string literal (quoted + escaped); iOS returns the raw
/// string as-is. Only decode when it actually looks JSON-string-quoted so
/// both platforms end up with real HTML, not an escaped blob.
String _decodeJsResult(Object result) {
  final raw = result.toString();
  if (raw.startsWith('"') && raw.endsWith('"')) {
    try {
      return jsonDecode(raw) as String;
    } catch (_) {
      // Fall through to the raw string below.
    }
  }
  return raw;
}

class _WebViewHtmlFetcherScreen extends StatefulWidget {
  const _WebViewHtmlFetcherScreen({required this.url, required this.timeout});

  final String url;
  final Duration timeout;

  @override
  State<_WebViewHtmlFetcherScreen> createState() =>
      _WebViewHtmlFetcherScreenState();
}

class _WebViewHtmlFetcherScreenState
    extends State<_WebViewHtmlFetcherScreen> {
  late final WebViewController _controller;
  Timer? _pollTimer;
  DateTime? _pageLoadedAt;
  bool _revealed = false; // becomes true once the timeout is hit
  bool _busy = false; // guards against overlapping polls
  bool _resolving = false; // guards against popping twice

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      // Same real Chrome Mobile UA as login_screen.dart / in_app_browser_screen.dart
      // — no "wv" token, so the anti-bot challenge treats this as a normal browser.
      ..setUserAgent(kRealChromeMobileUA)
      ..setNavigationDelegate(NavigationDelegate(
        // Mirror the login/in-app-browser guard: allow only web schemes, block
        // native app handoffs a WebView can't load.
        onNavigationRequest: (request) {
          final scheme = Uri.tryParse(request.url)?.scheme.toLowerCase() ?? '';
          if (scheme == 'http' || scheme == 'https' || scheme == 'about') {
            return NavigationDecision.navigate;
          }
          return NavigationDecision.prevent;
        },
        onPageFinished: (_) {
          // Guard against a late callback firing after the screen was closed
          // (e.g. the user cancels before first load) — otherwise this would
          // start a Timer.periodic that dispose() never had a chance to
          // cancel, ticking forever for the life of the process.
          if (!mounted) return;
          _pageLoadedAt = DateTime.now();
          _startPolling();
        },
      ))
      ..loadRequest(Uri.parse(widget.url));
  }

  void _startPolling() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(seconds: 1), (_) => _poll());
  }

  Future<void> _poll() async {
    if (_busy || _resolving || !mounted) return;
    _busy = true;
    try {
      final result = await _controller.runJavaScriptReturningResult(
        'document.documentElement.outerHTML',
      );
      // Re-check mounted immediately after the await — the screen may have
      // been popped (user cancelled / navigated away) while this was in
      // flight. Without this, _finish()'s Navigator.pop or the setState
      // below throws a setState-after-dispose that the catch below would
      // silently swallow.
      if (!mounted) return;
      final html = _decodeJsResult(result);

      // This screen only ever runs once a challenge is already suspected (see
      // generic_article_downloader_service.dart), so WEAK signals are trusted
      // here too — pass wasForbidden: true.
      if (!looksLikeJsChallenge(html, wasForbidden: true)) {
        // Read the WebView's current URL BEFORE popping — needed by callers
        // that resolve a redirect/short-link via the rendered page (see
        // fetchRenderedHtmlWithUrl); best-effort only, null on failure so a
        // read error here can never block returning the HTML itself.
        String? finalUrl;
        try {
          finalUrl = await _controller.currentUrl();
        } catch (e) {
          debugPrint('[WebViewHtmlFetcher] currentUrl() failed: $e');
        }
        if (!mounted) return;
        _finish(html, finalUrl);
        return;
      }

      // Still challenged — reveal the WebView once the timeout elapses so the
      // user can clear it manually (e.g. tap "I am human"). Polling continues
      // indefinitely after that; there's no second timeout.
      final loadedAt = _pageLoadedAt;
      if (!_revealed &&
          loadedAt != null &&
          DateTime.now().difference(loadedAt) > widget.timeout) {
        setState(() => _revealed = true);
      }
    } catch (e) {
      debugPrint('[WebViewHtmlFetcher] poll failed (will retry): $e');
    } finally {
      _busy = false;
    }
  }

  void _finish(String html, String? finalUrl) {
    if (_resolving || !mounted) return;
    _resolving = true;
    _pollTimer?.cancel();
    Navigator.of(context).pop((html: html, finalUrl: finalUrl));
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_revealed ? 'Verify to continue' : 'Loading…'),
        leading: IconButton(
          icon: const Icon(Icons.close),
          tooltip: 'Cancel',
          onPressed: () => Navigator.of(context).pop(), // pop(null) → cancel
        ),
      ),
      body: Stack(
        children: [
          // Kept mounted (so the WebView keeps running and can be polled)
          // even while invisible — only painted once the challenge needs the
          // user's help.
          Visibility(
            visible: _revealed,
            maintainState: true,
            maintainAnimation: true,
            maintainSize: true,
            child: WebViewWidget(controller: _controller),
          ),
          if (!_revealed)
            const Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(),
                  SizedBox(height: 12),
                  Text('Verifying page…'),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

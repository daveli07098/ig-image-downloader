import 'dart:async';
import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/download_queue_provider.dart';
import '../providers/settings_provider.dart';
import '../providers/share_intent_provider.dart';
import '../services/dev_logger.dart';
import '../services/rate_guard_service.dart';
import '../services/session_service.dart';
import '../widgets/download_job_tile.dart';
import '../models/download_job.dart';
import 'login_screen.dart';
import 'in_app_browser_screen.dart';
import 'selection_screen.dart';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();
  bool _igLoggedIn = false;
  bool _xLoggedIn = false;
  bool _fbLoggedIn = false;
  String? _igUsername;
  String? _xUsername;
  String? _fbUsername;

  // Used to read WebView cookies (e.g. X's ct0 CSRF token) for on-demand
  // username resolution without requiring a re-login.
  static const _cookieChannel = MethodChannel('ig_downloader/cookies');

  @override
  void initState() {
    super.initState();
    _refreshLoginState();
  }

  Future<void> _refreshLoginState() async {
    final ig = await SessionService.isLoggedIn(LoginPlatform.instagram);
    final x = await SessionService.isLoggedIn(LoginPlatform.x);
    final fb = await SessionService.isLoggedIn(LoginPlatform.facebook);
    var igUser = ig ? await SessionService.getUsername(LoginPlatform.instagram) : null;
    var xUser = x ? await SessionService.getUsername(LoginPlatform.x) : null;
    var fbUserRaw = fb ? await SessionService.getUsername(LoginPlatform.facebook) : null;

    // Resolve usernames on-demand for sessions that predate username storage
    // (logged in before this feature was added). Saves result so this only
    // fires once per platform — subsequent app opens use the cached value.
    if (ig && igUser == null) {
      igUser = await _resolveIgUsername();
      if (igUser != null) await SessionService.saveUsername(LoginPlatform.instagram, igUser);
    }
    if (x && xUser == null) {
      xUser = await _resolveXUsername();
      if (xUser != null) await SessionService.saveUsername(LoginPlatform.x, xUser);
    }
    if (fb && fbUserRaw == null) {
      fbUserRaw = await _resolveFbUsername();
      if (fbUserRaw != null) await SessionService.saveUsername(LoginPlatform.facebook, fbUserRaw);
    }

    // Filter out numeric-only IDs saved by older versions (c_user cookie value)
    final fbUser = (fbUserRaw != null && RegExp(r'^\d+$').hasMatch(fbUserRaw))
        ? null
        : fbUserRaw;
    if (mounted) setState(() {
      _igLoggedIn = ig; _xLoggedIn = x; _fbLoggedIn = fb;
      _igUsername = igUser; _xUsername = xUser; _fbUsername = fbUser;
    });
  }

  Future<String?> _resolveIgUsername() async {
    try {
      final sessionId = await SessionService.getSessionId(LoginPlatform.instagram);
      if (sessionId == null) return null;

      // Primary: i.instagram.com private API — most reliable, doesn't require
      // additional cookies beyond sessionid.
      try {
        final apiDio = Dio(BaseOptions(
          connectTimeout: const Duration(seconds: 10),
          receiveTimeout: const Duration(seconds: 10),
          headers: {
            'User-Agent':
                'Instagram 219.0.0.12.117 Android (26/8.0.0; 480dpi; 1080x1920; '
                'OnePlus; ONEPLUS A3010; OnePlus3T; qcom; en_US; 314665256)',
            'X-IG-App-ID': '936619743392459',
            'Cookie': 'sessionid=$sessionId',
            'Accept': 'application/json',
            'Accept-Language': 'en-US',
          },
        ));
        final resp = await apiDio.get<dynamic>(
            'https://i.instagram.com/api/v1/accounts/current_user/');
        final username =
            (resp.data as Map?)?['user']?['username'] as String?;
        if (username != null && username.isNotEmpty) {
          debugPrint('[Home] IG resolve via private API => $username');
          return username;
        }
      } catch (e) {
        debugPrint('[Home] IG private API resolve failed: $e');
      }

      // Fallback: HTML scraping of instagram.com
      final dio = Dio(BaseOptions(
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(seconds: 15),
        headers: {
          'User-Agent': 'Mozilla/5.0 (Linux; Android 13; Pixel 6) AppleWebKit/537.36 '
              '(KHTML, like Gecko) Chrome/124.0.0.0 Mobile Safari/537.36',
          'Cookie': 'sessionid=$sessionId',
          'Accept-Language': 'en-US,en;q=0.9',
        },
      ));
      for (final url in [
        'https://www.instagram.com/',
        'https://www.instagram.com/accounts/edit/',
      ]) {
        final resp = await dio.get<String>(url);
        final finalPath = resp.realUri.path;
        final html = resp.data ?? '';
        debugPrint('[Home] IG resolve: $url => ${resp.realUri} '
            '${html.length}b __NEXT_DATA__:${html.contains("__NEXT_DATA__")} '
            '_sharedData:${html.contains("_sharedData")}');
        if (finalPath.contains('/accounts/login') || finalPath.contains('/challenge')) {
          continue; // try next URL
        }
        // Strategy 1: __NEXT_DATA__ (Next.js SSR)
        final ndMatch = RegExp(
                r'<script id="__NEXT_DATA__"[^>]*>({.+?})</script>',
                dotAll: true)
            .firstMatch(html);
        if (ndMatch != null) {
          try {
            final data = jsonDecode(ndMatch.group(1)!) as Map<String, dynamic>;
            final pProps = (data['props'] as Map?)?['pageProps'] as Map? ?? {};
            debugPrint('[Home] IG resolve: pageProps keys=${pProps.keys.take(10).toList()}');
            for (final key in ['viewer', 'user', 'currentUser', 'loggedInUser', 'form']) {
              final obj = pProps[key];
              if (obj is Map && obj['username'] is String) return obj['username'] as String;
            }
            final gql = (data['data'] as Map?)?['viewer'];
            if (gql is Map && gql['username'] is String) return gql['username'] as String;
          } catch (e) {
            debugPrint('[Home] IG resolve: __NEXT_DATA__ parse: $e');
          }
        }
        // Strategy 2: window._sharedData (older IG pages)
        final sdMatch =
            RegExp(r'window\._sharedData\s*=\s*({.+?});\s*</script>').firstMatch(html);
        if (sdMatch != null) {
          try {
            final data = jsonDecode(sdMatch.group(1)!) as Map<String, dynamic>;
            final viewer = (data['config'] as Map?)?['viewer'];
            if (viewer is Map && viewer['username'] is String) return viewer['username'] as String;
          } catch (e) {
            debugPrint('[Home] IG resolve: _sharedData parse: $e');
          }
        }
        // Strategy 3: broad regex — safer on edit page where first username
        // should be the logged-in user, not another user from the feed.
        if (url.contains('/accounts/edit')) {
          final m = RegExp(r'"username"\s*:\s*"([a-zA-Z0-9._]{2,30})"').firstMatch(html);
          if (m != null) {
            debugPrint('[Home] IG resolve: broad regex => ${m.group(1)}');
            return m.group(1);
          }
        }
      }
      return null;
    } catch (e) {
      debugPrint('[Home] IG username resolve: $e');
      return null;
    }
  }

  Future<String?> _resolveXUsername() async {
    try {
      final authToken = await SessionService.getSessionId(LoginPlatform.x);
      if (authToken == null) return null;
      final raw = await _cookieChannel.invokeMethod<String>(
          'getCookie', {'url': 'https://x.com'});
      String? ct0;
      if (raw != null) {
        for (final part in raw.split(';')) {
          final kv = part.trim().split('=');
          if (kv.length >= 2 && kv[0].trim() == 'ct0') {
            ct0 = kv.sublist(1).join('=').trim();
            break;
          }
        }
      }
      debugPrint('[Home] X resolve: ct0 present=${ct0 != null}');
      if (ct0 == null) return null;

      final apiHeaders = {
        'User-Agent': 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) '
            'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36',
        'Cookie': 'auth_token=$authToken; ct0=$ct0',
        'x-csrf-token': ct0,
        'Authorization': 'Bearer AAAAAAAAAAAAAAAAAAAAANRILgAAAAAAnNwIzUejRCOuH5E6I8xnZz4puTs'
            '%3D1Zv7ttfk8LF81IUq16cHjhLTvJu4FA33AGWWjCpTnA',
      };
      final apiDio = Dio(BaseOptions(
        connectTimeout: const Duration(seconds: 10),
        receiveTimeout: const Duration(seconds: 10),
        headers: apiHeaders,
      ));

      // Try settings.json (returns screen_name; fewer deprecation issues than
      // verify_credentials which now 404s on all known X/Twitter API hosts)
      for (final endpoint in [
        'https://api.twitter.com/1.1/account/settings.json',
        'https://api.twitter.com/1.1/account/verify_credentials.json',
      ]) {
        try {
          final r = await apiDio.get<Map<String, dynamic>>(endpoint,
              queryParameters: {'include_entities': 'false', 'skip_status': 'true'});
          final name = r.data?['screen_name'] as String?;
          debugPrint('[Home] X resolve: $endpoint → $name');
          if (name != null) return name;
        } catch (e) {
          debugPrint('[Home] X resolve: $endpoint failed: $e');
        }
      }

      // Last resort: fetch x.com/home HTML and scan for screen_name
      try {
        final htmlDio = Dio(BaseOptions(
          connectTimeout: const Duration(seconds: 15),
          receiveTimeout: const Duration(seconds: 15),
          headers: {
            'User-Agent': 'Mozilla/5.0 (Linux; Android 13; Pixel 6) AppleWebKit/537.36 '
                '(KHTML, like Gecko) Chrome/124.0.0.0 Mobile Safari/537.36',
            'Cookie': 'auth_token=$authToken; ct0=$ct0',
            'Accept-Language': 'en-US,en;q=0.9',
          },
        ));
        final resp = await htmlDio.get<String>('https://x.com/home');
        final path = resp.realUri.path;
        final html = resp.data ?? '';
        debugPrint('[Home] X resolve: home page $path ${html.length} bytes');
        if (!path.contains('/login') && !path.contains('/i/flow')) {
          final m =
              RegExp(r'"screen_name"\s*:\s*"([A-Za-z0-9_]{1,50})"').firstMatch(html);
          if (m != null) return m.group(1);
        }
      } catch (e) {
        debugPrint('[Home] X resolve: home page failed: $e');
      }
      return null;
    } catch (e) {
      debugPrint('[Home] X username resolve: $e');
      return null;
    }
  }

  Future<String?> _resolveFbUsername() async {
    try {
      final cookies = await SessionService.getSessionId(LoginPlatform.facebook);
      if (cookies == null) return null;
      final dio = Dio(BaseOptions(
        connectTimeout: const Duration(seconds: 10),
        receiveTimeout: const Duration(seconds: 15),
        followRedirects: true,
        maxRedirects: 8,
        headers: {
          'User-Agent': 'Mozilla/5.0 (Linux; Android 14; SM-S928B) AppleWebKit/537.36 '
              '(KHTML, like Gecko) Chrome/124.0.0.0 Mobile Safari/537.36',
          'Cookie': cookies,
          'Accept-Language': 'en-US,en;q=0.9',
        },
      ));
      final resp = await dio.get<String>('https://www.facebook.com/me');
      final finalUrl = resp.realUri.toString();
      debugPrint('[Home] FB resolve: final URL = $finalUrl');
      // Match first path segment from any facebook domain
      final m = RegExp(r'facebook\.com/([^/?#\s]+)').firstMatch(finalUrl);
      final slug = m?.group(1);
      debugPrint('[Home] FB resolve: slug = $slug');
      const skipSlugs = {
        'me', 'login', 'checkpoint', 'recover', 'home', 'r.php',
        'ajax', 'dialog', 'sharer', 'unsupportedbrowser', 'privacy',
      };
      if (slug != null &&
          !skipSlugs.contains(slug.toLowerCase()) &&
          !slug.startsWith('profile.php') &&
          !RegExp(r'^\d+$').hasMatch(slug)) {
        return slug;
      }
      // Fallback: scan page HTML for a username JSON field
      final html = resp.data ?? '';
      final hm = RegExp(r'"username"\s*:\s*"([a-zA-Z0-9.]{3,60})"').firstMatch(html);
      if (hm != null) {
        debugPrint('[Home] FB resolve: HTML match => ${hm.group(1)}');
        return hm.group(1);
      }
    } catch (e) {
      debugPrint('[Home] FB username resolve: $e');
    }
    return null;
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _openSelection(String url) {
    final trimmed = url.trim();
    if (!trimmed.startsWith('http://') && !trimmed.startsWith('https://')) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter a valid URL')),
      );
      return;
    }
    _controller.clear();
    _focusNode.unfocus();
    // Clear the dev log and signal the overlay to auto-open so the fetch
    // logs are visible immediately when the SelectionScreen appears.
    DevLogger.instance.startNewSession();
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => SelectionScreen(igUrl: trimmed),
      ),
    );
  }

  Future<void> _pasteFromClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text ?? '';
    if (text.isNotEmpty) {
      _controller.text = text;
      _openSelection(text);
    }
  }

  /// Opens the Instagram login screen from the RateGuard banner's "Log in"
  /// action (shown when a `login_required` auth wall tripped the block).
  /// A successful capture auto-clears the cooldown inside the login flow
  /// (RateGuard.onSessionRefreshed) — this only refreshes the home screen's
  /// login flags afterwards.
  Future<void> _reloginInstagram() async {
    final result = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => const LoginScreen(platform: LoginPlatform.instagram),
      ),
    );
    if (result == true) await _refreshLoginState();
  }

  Future<void> _showAccountsSheet(BuildContext context) async {
    await showModalBottomSheet<void>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      // StatefulBuilder so the sheet can rebuild itself after a logout/login —
      // otherwise the open modal keeps showing stale login flags until it's
      // closed and reopened (the parent setState doesn't reach the modal tree).
      builder: (_) => StatefulBuilder(
        builder: (_, setSheetState) => _AccountsSheet(
          igLoggedIn: _igLoggedIn,
          xLoggedIn: _xLoggedIn,
          fbLoggedIn: _fbLoggedIn,
          igUsername: _igUsername,
          xUsername: _xUsername,
          fbUsername: _fbUsername,
          onLogin: (platform) async {
            final nav = Navigator.of(context);
            nav.pop();
            final result = await nav.push<bool>(
              MaterialPageRoute(
                builder: (_) => LoginScreen(platform: platform),
              ),
            );
            if (result == true) await _refreshLoginState();
          },
          // Open the platform's site in the in-app browser, signed in with the
          // captured session, so the user can preview/scroll their feed.
          onOpen: (platform) {
            final nav = Navigator.of(context);
            nav.pop(); // close the accounts sheet first
            const homeUrls = {
              LoginPlatform.instagram: 'https://www.instagram.com/',
              LoginPlatform.x: 'https://x.com/home',
              LoginPlatform.facebook: 'https://www.facebook.com/',
            };
            const labels = {
              LoginPlatform.instagram: 'Instagram',
              LoginPlatform.x: 'X',
              LoginPlatform.facebook: 'Facebook',
            };
            nav.push(
              MaterialPageRoute(
                builder: (_) => InAppBrowserScreen(
                  initialUrl: homeUrls[platform]!,
                  title: labels[platform]!,
                ),
              ),
            );
          },
          onLogout: (platform) async {
            final messenger = ScaffoldMessenger.of(context);
            await SessionService.clearSession(platform);
            await _refreshLoginState(); // refresh parent flags first…
            setSheetState(() {});       // …then rebuild the open sheet with them
            if (!mounted) return;
            const labels = {LoginPlatform.instagram: 'Instagram', LoginPlatform.x: 'X', LoginPlatform.facebook: 'Facebook'};
            messenger.showSnackBar(
              SnackBar(
                content: Text('Logged out of ${labels[platform]}'),
                duration: const Duration(seconds: 2),
              ),
            );
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Auto-open SelectionScreen when a URL arrives from the share sheet
    ref.listen<String?>(sharedUrlProvider, (_, url) {
      if (url != null) {
        ref.read(sharedUrlProvider.notifier).consume();
        _openSelection(url);
      }
    });

    final jobs = ref.watch(downloadQueueProvider);
    final settings = ref.watch(settingsProvider);
    final hasFinished = jobs.any(
      (j) => j.status == JobStatus.done || j.status == JobStatus.error,
    );

    return Scaffold(
      appBar: AppBar(
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.download_rounded,
                color: Theme.of(context).colorScheme.primary),
            const SizedBox(width: 8),
            const Flexible(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('IG Downloader', overflow: TextOverflow.ellipsis),
                  Text(
                    'v1.1.0.15',
                    style: TextStyle(fontSize: 11, fontWeight: FontWeight.w400),
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          // Multi-platform accounts button
          IconButton(
            icon: Icon(
              (_igLoggedIn || _xLoggedIn || _fbLoggedIn)
                  ? Icons.account_circle
                  : Icons.account_circle_outlined,
              color: (_igLoggedIn || _xLoggedIn || _fbLoggedIn)
                  ? Theme.of(context).colorScheme.primary
                  : null,
            ),
            tooltip: 'Accounts',
            onPressed: () => _showAccountsSheet(context),
          ),
          // Wi-Fi only toggle
          IconButton(
            icon: Icon(
              settings.wifiOnly ? Icons.wifi : Icons.wifi_off,
              color: settings.wifiOnly
                  ? Theme.of(context).colorScheme.primary
                  : Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.4),
            ),
            tooltip: settings.wifiOnly
                ? 'Wi-Fi only: ON — tap to allow mobile data'
                : 'Wi-Fi only: OFF — tap to restrict to Wi-Fi',
            onPressed: () {
              final next = !settings.wifiOnly;
              ref.read(settingsProvider.notifier).setWifiOnly(next);
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(
                    next
                        ? 'Wi-Fi only mode enabled'
                        : 'Wi-Fi only mode disabled',
                  ),
                  duration: const Duration(seconds: 2),
                ),
              );
            },
          ),
          if (hasFinished)
            TextButton.icon(
              onPressed: () =>
                  ref.read(downloadQueueProvider.notifier).clearFinished(),
              icon: const Icon(Icons.clear_all),
              label: const Text('Clear done'),
            ),
        ],
      ),
      body: Column(
        children: [
          // ── URL input bar ────────────────────────────────────────────────
          _UrlInputBar(
            controller: _controller,
            focusNode: _focusNode,
            onSubmit: _openSelection,
            onPaste: _pasteFromClipboard,
          ),

          // ── Instagram request-budget reminder ────────────────────────────
          // Amber as you near the hourly limit, red (with live countdown) when
          // throttled or flagged. Hidden entirely while there's ample budget.
          _RateGuardBanner(onRelogin: _reloginInstagram),

          // ── Logged-in accounts status bar ────────────────────────────────
          if (_igLoggedIn || _xLoggedIn || _fbLoggedIn)
            _AccountStatusBar(
              igLoggedIn: _igLoggedIn,
              xLoggedIn: _xLoggedIn,
              fbLoggedIn: _fbLoggedIn,
              igUsername: _igUsername,
              xUsername: _xUsername,
              fbUsername: _fbUsername,
              onTap: () => _showAccountsSheet(context),
            ),

          // ── Share hint ───────────────────────────────────────────────────
          if (jobs.isEmpty) const _EmptyHint(),

          // ── Download queue ───────────────────────────────────────────────
          Expanded(
            child: ListView.separated(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              itemCount: jobs.length,
              separatorBuilder: (_, __) => const SizedBox(height: 8),
              itemBuilder: (context, index) {
                final job = jobs[jobs.length - 1 - index]; // newest on top
                return DownloadJobTile(
                  job: job,
                  onRetry: () =>
                      ref.read(downloadQueueProvider.notifier).retry(job.id),
                  onRemove: () =>
                      ref.read(downloadQueueProvider.notifier).remove(job.id),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

// ── URL input bar widget ────────────────────────────────────────────────────

class _UrlInputBar extends StatelessWidget {
  const _UrlInputBar({
    required this.controller,
    required this.focusNode,
    required this.onSubmit,
    required this.onPaste,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final void Function(String) onSubmit;
  final VoidCallback onPaste;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(16),
      color: cs.surfaceContainerHighest.withValues(alpha: 0.4),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: controller,
              focusNode: focusNode,
              decoration: InputDecoration(
                  hintText: 'Paste Instagram, X, or any article URL…',
                prefixIcon: const Icon(Icons.link),
                suffixIcon: IconButton(
                  icon: const Icon(Icons.clear),
                  onPressed: controller.clear,
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                filled: true,
              ),
              keyboardType: TextInputType.url,
              textInputAction: TextInputAction.go,
              onSubmitted: onSubmit,
            ),
          ),
          const SizedBox(width: 8),
          // Paste button
          FilledButton.icon(
            onPressed: onPaste,
            icon: const Icon(Icons.content_paste_rounded),
            label: const Text('Paste'),
          ),
        ],
      ),
    );
  }
}

// ── Empty state ─────────────────────────────────────────────────────────────

class _EmptyHint extends StatelessWidget {
  const _EmptyHint();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Expanded(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(vertical: 32, horizontal: 24),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
            Icon(Icons.share_outlined, size: 72, color: cs.primary),
            const SizedBox(height: 16),
            Text(
              'Share from Instagram or X',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 8),
            Text(
              'Instagram: open a post, Reel, or IGTV,\ntap ⋯ → Share → IG Downloader\n\nX (Twitter): tap Share → IG Downloader\n\nPick which photos/videos to save.',
              textAlign: TextAlign.center,
              style: Theme.of(context)
                  .textTheme
                  .bodyMedium
                  ?.copyWith(color: cs.onSurfaceVariant),
            ),
            const SizedBox(height: 24),
            const Text('— or —'),
            const SizedBox(height: 8),
            Text(
              'Paste a URL manually above',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ],
        ),
      ),
    ));
  }
}

// ── Logged-in account status bar ────────────────────────────────────────────

class _AccountStatusBar extends StatelessWidget {
  const _AccountStatusBar({
    required this.igLoggedIn,
    required this.xLoggedIn,
    required this.fbLoggedIn,
    this.igUsername,
    this.xUsername,
    this.fbUsername,
    required this.onTap,
  });

  final bool igLoggedIn;
  final bool xLoggedIn;
  final bool fbLoggedIn;
  final String? igUsername;
  final String? xUsername;
  final String? fbUsername;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    final chips = <Widget>[];
    void addChip(IconData icon, bool loggedIn, String? username, String fallback) {
      if (!loggedIn) return;
      chips.add(Padding(
        padding: const EdgeInsets.only(right: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 13, color: cs.primary),
            const SizedBox(width: 3),
            Text(
              username != null ? '@$username' : fallback,
              style: Theme.of(context)
                  .textTheme
                  .labelSmall
                  ?.copyWith(color: cs.primary, fontWeight: FontWeight.w600),
            ),
          ],
        ),
      ));
    }

    addChip(Icons.camera_alt_outlined, igLoggedIn, igUsername, 'Instagram');
    addChip(Icons.close, xLoggedIn, xUsername, 'X');
    addChip(Icons.facebook_rounded, fbLoggedIn, fbUsername, 'Facebook');

    return InkWell(
      onTap: onTap,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        decoration: BoxDecoration(
          color: cs.primary.withValues(alpha: 0.06),
          border: Border(
            bottom: BorderSide(
              color: cs.outlineVariant.withValues(alpha: 0.5),
              width: 0.5,
            ),
          ),
        ),
        child: Row(
          children: [
            Icon(Icons.account_circle_outlined, size: 13, color: cs.primary),
            const SizedBox(width: 6),
            ...chips,
            const Spacer(),
            Icon(Icons.chevron_right, size: 14, color: cs.primary.withValues(alpha: 0.6)),
          ],
        ),
      ),
    );
  }
}

// ── Accounts bottom sheet ───────────────────────────────────────────────────

class _AccountsSheet extends StatelessWidget {
  const _AccountsSheet({
    required this.igLoggedIn,
    required this.xLoggedIn,
    required this.fbLoggedIn,
    this.igUsername,
    this.xUsername,
    this.fbUsername,
    required this.onLogin,
    required this.onLogout,
    required this.onOpen,
  });

  final bool igLoggedIn;
  final bool xLoggedIn;
  final bool fbLoggedIn;
  final String? igUsername;
  final String? xUsername;
  final String? fbUsername;
  final void Function(LoginPlatform) onLogin;
  final void Function(LoginPlatform) onLogout;
  final void Function(LoginPlatform) onOpen;

  static const _platforms = [
    (platform: LoginPlatform.instagram, label: 'Instagram', icon: Icons.camera_alt_outlined),
    (platform: LoginPlatform.x, label: 'X (Twitter)', icon: Icons.close /* X logo closest built-in */),
    (platform: LoginPlatform.facebook, label: 'Facebook', icon: Icons.facebook_rounded),
  ];

  @override
  Widget build(BuildContext context) {
    final loggedIn = {
      LoginPlatform.instagram: igLoggedIn,
      LoginPlatform.x: xLoggedIn,
      LoginPlatform.facebook: fbLoggedIn,
    };
    final usernames = {
      LoginPlatform.instagram: igUsername,
      LoginPlatform.x: xUsername,
      LoginPlatform.facebook: fbUsername,
    };
    final cs = Theme.of(context).colorScheme;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Accounts', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              'Log in to access private content',
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: cs.onSurfaceVariant),
            ),
            const SizedBox(height: 16),
            for (final p in _platforms) ...[
              _PlatformRow(
                icon: p.icon,
                label: p.label,
                isLoggedIn: loggedIn[p.platform]!,
                username: usernames[p.platform],
                onLogin: () => onLogin(p.platform),
                onLogout: () => onLogout(p.platform),
                onOpen: () => onOpen(p.platform),
              ),
              if (p != _platforms.last) const Divider(height: 1),
            ],
          ],
        ),
      ),
    );
  }
}

class _PlatformRow extends StatelessWidget {
  const _PlatformRow({
    required this.icon,
    required this.label,
    required this.isLoggedIn,
    this.username,
    required this.onLogin,
    required this.onLogout,
    required this.onOpen,
  });

  final IconData icon;
  final String label;
  final bool isLoggedIn;
  final String? username;
  final VoidCallback onLogin;
  final VoidCallback onLogout;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(
        children: [
          Icon(icon, size: 28, color: cs.onSurface),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: Theme.of(context).textTheme.bodyLarge),
                Text(
                  isLoggedIn
                      ? (username != null ? '@$username' : 'Logged in')
                      : 'Not logged in',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: isLoggedIn ? cs.primary : cs.onSurfaceVariant,
                      ),
                ),
              ],
            ),
          ),
          if (isLoggedIn) ...[
            // Open the platform in the in-app browser (signed in) to preview pages.
            IconButton(
              onPressed: onOpen,
              icon: const Icon(Icons.open_in_new),
              tooltip: 'Open in app',
              visualDensity: VisualDensity.compact,
            ),
            const SizedBox(width: 4),
            OutlinedButton(
              onPressed: onLogout,
              child: const Text('Logout'),
            ),
          ] else
            FilledButton(
              onPressed: onLogin,
              child: const Text('Login'),
            ),
        ],
      ),
    );
  }
}

// ── Instagram request-budget reminder banner ────────────────────────────────

/// Heading banner reflecting [RateGuard]: amber as the hourly Instagram request
/// budget runs low, red (with a live countdown) when throttled or flagged by
/// Instagram. Renders nothing while there's ample budget. Drives a 1 s ticker
/// so the budget recovers and any cooldown counts down on screen in real time.
class _RateGuardBanner extends StatefulWidget {
  const _RateGuardBanner({required this.onRelogin});

  /// Opens the Instagram login screen — the actionable remedy when the block
  /// was tripped by a `login_required` auth wall (expired session). Provided
  /// by the parent so the login flags on the home screen refresh afterwards.
  final Future<void> Function() onRelogin;

  @override
  State<_RateGuardBanner> createState() => _RateGuardBannerState();
}

class _RateGuardBannerState extends State<_RateGuardBanner> {
  Timer? _ticker;

  /// True while a manual "Check now" probe is in flight, so the affordance
  /// can't be double-tapped into spamming Instagram.
  bool _checkingNow = false;

  @override
  void initState() {
    super.initState();
    RateGuard.instance.listenable.addListener(_onChange);
    // Recompute every second so the rolling window recovers and any cooldown
    // countdown updates without the user touching anything.
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      RateGuard.instance.refresh();
      // Fire a reprobe attempt every tick while a challenge cooldown is
      // active — this does NOT mean Instagram gets hit every second:
      // maybeReprobe() enforces its own 5-minute floor internally and only
      // ever performs the actual network call once that's elapsed, so this
      // is just a cheap timestamp check the other 299 times out of 300.
      if (RateGuard.instance.status.isChallenge) {
        RateGuard.instance.maybeReprobe();
      }
      if (mounted) setState(() {});
    });
  }

  void _onChange() {
    if (!mounted) return;
    // A successful reprobe (ticker-driven or manual) clears the cooldown via
    // clearChallengeCooldown(early: true), which lands here through the
    // listenable. Surface it once as a reminder rather than a second ticker.
    if (RateGuard.instance.consumeEarlyRecovery()) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
              'Instagram access recovered — downloads re-enabled.'),
        ),
      );
    }
    setState(() {});
  }

  Future<void> _checkNow() async {
    if (_checkingNow) return;
    setState(() => _checkingNow = true);
    // force: true bypasses the 5-minute min-interval for this one tap only —
    // it does NOT bypass the "must actually be in a challenge cooldown"
    // guard inside maybeReprobe(), so it can't be used to probe Instagram
    // outside a cooldown.
    final recovered = await RateGuard.instance.maybeReprobe(force: true);
    if (!mounted) return;
    setState(() => _checkingNow = false);
    // On recovery, _onChange already showed the reminder via listenable —
    // avoid a duplicate SnackBar. Only report the "still blocked" outcome.
    if (!recovered && RateGuard.instance.status.isChallenge) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Still blocked by Instagram — try again shortly.'),
        ),
      );
    }
  }

  /// Unconditionally clears the cooldown after an explicit confirmation.
  /// Unlike "Check now" this bypasses the evidence requirement (no probe),
  /// so the dialog spells out the trade-off: if Instagram is genuinely still
  /// blocking, the very next request simply re-trips the block.
  Future<void> _resetCooldown() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Reset the pause?'),
        content: const Text(
          'This clears the pause without checking Instagram first. If '
          'Instagram is genuinely still blocking, the next download will '
          'simply re-trigger it.\n\n'
          '"Check now" is the recommended option — it verifies access has '
          'actually recovered before clearing.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Reset anyway'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await RateGuard.instance.clearChallengeCooldown();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Pause reset — downloads re-enabled.')),
    );
  }

  @override
  void dispose() {
    _ticker?.cancel();
    RateGuard.instance.listenable.removeListener(_onChange);
    super.dispose();
  }

  /// Shared compact styling for the banner's inline action buttons.
  ButtonStyle _actionStyle(Color fg) => TextButton.styleFrom(
        foregroundColor: fg,
        minimumSize: const Size(0, 0),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        visualDensity: VisualDensity.compact,
      );

  String _countdown(DateTime until) {
    final secs = until.difference(DateTime.now()).inSeconds.clamp(0, 1 << 31);
    final h = secs ~/ 3600;
    final m = (secs % 3600) ~/ 60;
    final s = secs % 60;
    if (h > 0) return '${h}h ${m}m';
    if (m > 0) return '${m}m ${s.toString().padLeft(2, '0')}s';
    return '${s}s';
  }

  @override
  Widget build(BuildContext context) {
    final status = RateGuard.instance.status;
    if (status.level == RateLevel.ok) return const SizedBox.shrink();

    final cs = Theme.of(context).colorScheme;
    final blocked = status.level == RateLevel.blocked;

    final Color bg;
    final Color fg;
    final IconData icon;
    final String text;

    if (blocked) {
      bg = cs.errorContainer;
      fg = cs.onErrorContainer;
      final left = status.blockedUntil != null
          ? ' — retry in ${_countdown(status.blockedUntil!)}'
          : '';
      if (status.needsRelogin) {
        // Auth wall (login_required): the stored session was rejected —
        // waiting changes nothing, so the copy points straight at re-login
        // instead of the "clear any prompt, then wait" advice below.
        icon = Icons.lock_person_rounded;
        text =
            'Instagram session expired — the saved login was rejected, so '
            'waiting won\'t help. Log in again to restore full downloads. '
            'Public posts may still download.';
      } else if (status.isChallenge) {
        icon = Icons.gpp_maybe_rounded;
        // Only the authenticated (logged-in) request path is paused here —
        // public posts can still download via the HTML-scrape fallback, so
        // "limited" is more accurate than "paused" (which implied nothing
        // would download at all).
        //
        // Surface WHY Instagram pushed back (recorded — and persisted — by
        // RateGuard when the block tripped) so the block is diagnosable from
        // the banner alone; null for blocks that predate reason tracking.
        final cause = status.challengeReason != null
            ? ' Cause: ${status.challengeReason!.label}.'
            : '';
        text =
            'Instagram flagged automated activity.$cause Logged-in requests '
            'are limited — open the Instagram app, clear any prompt, then '
            'wait$left. Public posts may still download.';
      } else {
        icon = Icons.timer_rounded;
        text =
            'Hourly Instagram request limit reached (${status.limit}/hr). '
            'Paused to avoid automation detection$left.';
      }
    } else {
      // warn
      bg = const Color(0xFFFFE0B2); // amber 100
      fg = const Color(0xFF7A4F01);
      icon = Icons.speed_rounded;
      text =
          'Slow down — ${status.usedLastHour}/${status.limit} Instagram '
          'requests this hour. Pause a bit to avoid automation detection.';
    }

    return Container(
      width: double.infinity,
      color: bg,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          Icon(icon, size: 20, color: fg),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                  color: fg, fontSize: 12.5, fontWeight: FontWeight.w500),
            ),
          ),
          // Manual recovery actions — only meaningful during an Instagram
          // challenge cooldown; the plain hourly-budget block always clears
          // on the timer alone, so there's nothing for a probe to check.
          // Stacked vertically so two actions don't squeeze the message text.
          if (status.isChallenge) ...[
            const SizedBox(width: 8),
            Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                // Primary action depends on the cause: an expired session is
                // fixed by logging in again (probing with the dead session is
                // pointless — a successful login auto-clears the pause), every
                // other cause gets the evidence-based recovery check.
                if (status.needsRelogin)
                  TextButton(
                    onPressed: () => widget.onRelogin(),
                    style: _actionStyle(fg),
                    child: const Text('Log in',
                        style: TextStyle(fontSize: 12.5)),
                  )
                else if (_checkingNow)
                  Padding(
                    padding: const EdgeInsets.all(6),
                    child: SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: fg),
                    ),
                  )
                else
                  TextButton(
                    onPressed: _checkNow,
                    style: _actionStyle(fg),
                    child: const Text('Check now',
                        style: TextStyle(fontSize: 12.5)),
                  ),
                // Escape hatch: unconditional clear, guarded by a confirmation
                // dialog because it bypasses the recovery evidence the actions
                // above gather first.
                TextButton(
                  onPressed: _resetCooldown,
                  style: _actionStyle(fg),
                  child:
                      const Text('Reset', style: TextStyle(fontSize: 12.5)),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

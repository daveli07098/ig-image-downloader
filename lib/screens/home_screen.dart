import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/download_queue_provider.dart';
import '../providers/settings_provider.dart';
import '../providers/share_intent_provider.dart';
import '../services/dev_logger.dart';
import '../services/session_service.dart';
import '../widgets/download_job_tile.dart';
import '../models/download_job.dart';
import 'login_screen.dart';
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

  Future<void> _showAccountsSheet(BuildContext context) async {
    await showModalBottomSheet<void>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => _AccountsSheet(
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
          if (result == true) _refreshLoginState();
        },
        onLogout: (platform) async {
          final messenger = ScaffoldMessenger.of(context);
          await SessionService.clearSession(platform);
          _refreshLoginState();
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
                    'v1.0.0.49',
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
  });

  final bool igLoggedIn;
  final bool xLoggedIn;
  final bool fbLoggedIn;
  final String? igUsername;
  final String? xUsername;
  final String? fbUsername;
  final void Function(LoginPlatform) onLogin;
  final void Function(LoginPlatform) onLogout;

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
  });

  final IconData icon;
  final String label;
  final bool isLoggedIn;
  final String? username;
  final VoidCallback onLogin;
  final VoidCallback onLogout;

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
          isLoggedIn
              ? OutlinedButton(
                  onPressed: onLogout,
                  child: const Text('Logout'),
                )
              : FilledButton(
                  onPressed: onLogin,
                  child: const Text('Login'),
                ),
        ],
      ),
    );
  }
}

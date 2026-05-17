import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/download_queue_provider.dart';
import '../providers/settings_provider.dart';
import '../providers/share_intent_provider.dart';
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

  @override
  void initState() {
    super.initState();
    _refreshLoginState();
  }

  Future<void> _refreshLoginState() async {
    final ig = await SessionService.isLoggedIn(LoginPlatform.instagram);
    final x = await SessionService.isLoggedIn(LoginPlatform.x);
    final fb = await SessionService.isLoggedIn(LoginPlatform.facebook);
    final igUser = ig ? await SessionService.getUsername(LoginPlatform.instagram) : null;
    final xUser = x ? await SessionService.getUsername(LoginPlatform.x) : null;
    final fbUser = fb ? await SessionService.getUsername(LoginPlatform.facebook) : null;
    if (mounted) setState(() {
      _igLoggedIn = ig; _xLoggedIn = x; _fbLoggedIn = fb;
      _igUsername = igUser; _xUsername = xUser; _fbUsername = fbUser;
    });
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
                    'v1.0.0.17',
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

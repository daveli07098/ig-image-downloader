import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/download_queue_provider.dart';
import '../providers/settings_provider.dart';
import '../providers/share_intent_provider.dart';
import '../services/ig_url_parser.dart';
import '../widgets/download_job_tile.dart';
import '../models/download_job.dart';
import 'selection_screen.dart';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _openSelection(String url) {
    final trimmed = url.trim();
    if (!IgUrlParser.isInstagramUrl(trimmed)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter a valid Instagram URL')),
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
          children: [
            Icon(Icons.download_rounded,
                color: Theme.of(context).colorScheme.primary),
            const SizedBox(width: 8),
            const Text('IG Downloader'),
          ],
        ),
        actions: [
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
                hintText: 'Paste Instagram URL…',
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
              'Share from Instagram',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 8),
            Text(
              'Open a post, Reel, or IGTV in Instagram,\ntap ⋯ → Share → IG Downloader\n\nPick which photos/videos to save.',  
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

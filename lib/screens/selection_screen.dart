import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/media_item.dart';
import '../providers/download_queue_provider.dart';
import '../services/downloader_service.dart';

// Provider: async-fetch all items for a given IG URL
final _mediaItemsProvider =
    FutureProvider.family<List<MediaItem>, String>((ref, url) {
  return DownloaderService().fetchItems(url);
});

/// Shows all media items in an IG post as a preview grid.
/// User can select which items to download, then tap the download button.
class SelectionScreen extends ConsumerStatefulWidget {
  const SelectionScreen({super.key, required this.igUrl});

  final String igUrl;

  @override
  ConsumerState<SelectionScreen> createState() => _SelectionScreenState();
}

class _SelectionScreenState extends ConsumerState<SelectionScreen> {
  // Track which item IDs are selected (default: all selected)
  final Set<String> _selectedIds = {};
  bool _initialised = false;

  void _initSelection(List<MediaItem> items) {
    if (_initialised) return;
    _selectedIds.addAll(items.map((i) => i.id));
    _initialised = true;
  }

  void _toggleItem(String id) {
    setState(() {
      if (_selectedIds.contains(id)) {
        _selectedIds.remove(id);
      } else {
        _selectedIds.add(id);
      }
    });
  }

  void _toggleAll(List<MediaItem> items) {
    setState(() {
      if (_selectedIds.length == items.length) {
        _selectedIds.clear();
      } else {
        _selectedIds.addAll(items.map((i) => i.id));
      }
    });
  }

  void _startDownload(List<MediaItem> items) {
    final selected = items.where((i) => _selectedIds.contains(i.id)).toList();
    if (selected.isEmpty) return;

    ref.read(downloadQueueProvider.notifier).enqueueItems(widget.igUrl, selected);
    Navigator.of(context).pop(); // go back to HomeScreen queue
  }

  @override
  Widget build(BuildContext context) {
    final asyncItems = ref.watch(_mediaItemsProvider(widget.igUrl));
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Select media'),
        actions: [
          asyncItems.whenOrNull(
            data: (items) => TextButton(
              onPressed: () => _toggleAll(items),
              child: Text(
                _selectedIds.length == items.length
                    ? 'Deselect all'
                    : 'Select all',
              ),
            ),
          ) ?? const SizedBox.shrink(),
        ],
      ),
      body: asyncItems.when(
        loading: () => const _LoadingView(),
        error: (err, _) => _ErrorView(
          error: err.toString(),
          onRetry: () => ref.invalidate(_mediaItemsProvider(widget.igUrl)),
        ),
        data: (items) {
          _initSelection(items);
          return Column(
            children: [
              // ── URL banner ──────────────────────────────────────────────
              Container(
                width: double.infinity,
                  color: cs.surfaceContainerHighest.withValues(alpha: 0.5),
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Text(
                  widget.igUrl,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: cs.onSurfaceVariant),
                ),
              ),

              // ── Media grid ─────────────────────────────────────────────
              Expanded(
                child: GridView.builder(
                  padding: const EdgeInsets.all(12),
                  gridDelegate:
                      const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 2,
                    crossAxisSpacing: 10,
                    mainAxisSpacing: 10,
                  ),
                  itemCount: items.length,
                  itemBuilder: (context, index) {
                    final item = items[index];
                    final isSelected = _selectedIds.contains(item.id);
                    return _MediaCard(
                      item: item,
                      isSelected: isSelected,
                      onTap: () => _toggleItem(item.id),
                    );
                  },
                ),
              ),

              // ── Download button ─────────────────────────────────────────
              SafeArea(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                  child: SizedBox(
                    width: double.infinity,
                    height: 52,
                    child: FilledButton.icon(
                      onPressed: _selectedIds.isEmpty
                          ? null
                          : () => _startDownload(items),
                      icon: const Icon(Icons.download_rounded),
                      label: Text(
                        _selectedIds.isEmpty
                            ? 'Select at least one'
                            : 'Download ${_selectedIds.length} item${_selectedIds.length == 1 ? '' : 's'}',
                      ),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

// ── Media card (thumbnail + selection overlay) ──────────────────────────────

class _MediaCard extends StatelessWidget {
  const _MediaCard({
    required this.item,
    required this.isSelected,
    required this.onTap,
  });

  final MediaItem item;
  final bool isSelected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isSelected ? cs.primary : Colors.transparent,
            width: 3,
          ),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: Stack(
            fit: StackFit.expand,
            children: [
              // ── Thumbnail ──────────────────────────────────────────────
              if (item.thumbnailUrl != null)
                Image.network(
                  item.thumbnailUrl!,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => _PlaceholderThumbnail(item: item),
                )
              else
                _PlaceholderThumbnail(item: item),

              // ── Video badge ────────────────────────────────────────────
              if (item.isVideo)
                Positioned(
                  bottom: 8,
                  left: 8,
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                    decoration: BoxDecoration(
                      color: Colors.black54,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.play_circle_fill_rounded,
                            color: Colors.white, size: 14),
                        SizedBox(width: 3),
                        Text('Video',
                            style: TextStyle(color: Colors.white, fontSize: 11)),
                      ],
                    ),
                  ),
                ),

              // ── Selection overlay ──────────────────────────────────────
              if (isSelected)
                Container(
                  color: cs.primary.withValues(alpha: 0.18),
                ),

              // ── Checkmark ─────────────────────────────────────────────
              Positioned(
                top: 8,
                right: 8,
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 150),
                  child: isSelected
                      ? CircleAvatar(
                          key: const ValueKey('checked'),
                          radius: 13,
                          backgroundColor: cs.primary,
                          child: const Icon(Icons.check_rounded,
                              color: Colors.white, size: 16),
                        )
                      : CircleAvatar(
                          key: const ValueKey('unchecked'),
                          radius: 13,
                          backgroundColor: Colors.black38,
                          child: const Icon(Icons.circle_outlined,
                              color: Colors.white70, size: 16),
                        ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PlaceholderThumbnail extends StatelessWidget {
  const _PlaceholderThumbnail({required this.item});
  final MediaItem item;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Icon(
        item.isVideo ? Icons.video_file_rounded : Icons.image_rounded,
        size: 48,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    );
  }
}

// ── Loading / error states ───────────────────────────────────────────────────

class _LoadingView extends StatelessWidget {
  const _LoadingView();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircularProgressIndicator(),
          SizedBox(height: 16),
          Text('Fetching media from Instagram…'),
        ],
      ),
    );
  }
}

/// Classifies a raw error string into a handling tier so the UI can show
/// the right indicator, banner text, and cooldown duration for each case.
/// loginRequired = our custom "redirected to login" throw (session/private post)
/// redirectLoop  = Dio's 10-hop RedirectException
enum _ErrorKind { apiRateLimit, loginRequired, redirectLoop, generic }

class _ErrorView extends StatefulWidget {
  const _ErrorView({required this.error, required this.onRetry});
  final String error;
  final VoidCallback onRetry;

  @override
  State<_ErrorView> createState() => _ErrorViewState();
}

class _ErrorViewState extends State<_ErrorView> {
  late final _ErrorKind _kind;

  // Cooldown seconds before the retry button appears. Tuned per error kind:
  //   apiRateLimit  → 5 min  (IG hourly quota needs breathing room)
  //   loginRequired → 30 s   (user must re-login; no point waiting longer)
  //   redirectLoop  → 60 s   (true Dio 10-hop; transient server issue)
  //   generic       → 30 s   (transient error; quick retry is fine)
  late final int _totalCooldown;
  late int _remaining;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _kind = _classifyError(widget.error);
    _totalCooldown = switch (_kind) {
      _ErrorKind.apiRateLimit  => 300,
      _ErrorKind.loginRequired => 30,
      _ErrorKind.redirectLoop  => 60,
      _ErrorKind.generic       => 30,
    };
    _remaining = _totalCooldown;
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() {
        if (_remaining > 0) _remaining--;
      });
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  /// Maps an error string to its handling tier.
  /// Check the more-specific "redirected to login" phrase BEFORE the generic
  /// "redirect" check, so our custom throw and Dio's exception are distinct.
  static _ErrorKind _classifyError(String error) {
    final e = error.toLowerCase();
    if (e.contains('redirected to login') || e.contains('session has expired')) {
      return _ErrorKind.loginRequired;
    }
    if (e.contains('redirect')) return _ErrorKind.redirectLoop;
    if (e.contains('429') ||
        e.contains('rate') ||
        (e.contains('400') && (e.contains('wait') || e.contains('many')))) {
      return _ErrorKind.apiRateLimit;
    }
    return _ErrorKind.generic;
  }

  String get _kindLabel => switch (_kind) {
    _ErrorKind.apiRateLimit  => 'IG API rate limit (~200/hr)',
    _ErrorKind.loginRequired => 'Login required',
    _ErrorKind.redirectLoop  => 'Redirect loop (10-hop limit)',
    _ErrorKind.generic       => 'Download error',
  };

  IconData get _kindIcon => switch (_kind) {
    _ErrorKind.apiRateLimit  => Icons.timer_outlined,
    _ErrorKind.loginRequired => Icons.lock_outline_rounded,
    _ErrorKind.redirectLoop  => Icons.sync_problem_rounded,
    _ErrorKind.generic       => Icons.error_outline_rounded,
  };

  String? get _bannerText => switch (_kind) {
    _ErrorKind.apiRateLimit =>
      'Instagram limits private API calls to ~200 per hour per session. '
      'Waiting lets the hourly quota reset before retrying.',
    _ErrorKind.loginRequired =>
      'This post may be private, or your Instagram session has expired. '
      'Re-login from the Accounts tab and try again.',
    _ErrorKind.redirectLoop =>
      'The request hit Instagram\'s 10-redirect limit — likely a temporary '
      'server issue. Retry in a moment.',
    _ErrorKind.generic => null,
  };

  /// Formats seconds as "Xm Ys" when ≥ 60 s, otherwise "Xs".
  static String _formatTime(int s) {
    if (s >= 60) {
      final m = s ~/ 60;
      final r = s % 60;
      return '${m}m ${r.toString().padLeft(2, '0')}s';
    }
    return '${s}s';
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final canRetry = _remaining == 0;
    final banner = _bannerText;

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // ── Error kind indicator chip ─────────────────────────────────
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: cs.errorContainer.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(20),
                border:
                    Border.all(color: cs.error.withValues(alpha: 0.3)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(_kindIcon, size: 14, color: cs.error),
                  const SizedBox(width: 4),
                  Text(
                    _kindLabel,
                    style: TextStyle(
                      fontSize: 12,
                      color: cs.error,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),

            Icon(Icons.error_outline_rounded, size: 56, color: cs.error),
            const SizedBox(height: 16),
            Text(
              'Could not load media',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(
              widget.error,
              textAlign: TextAlign.center,
              style: TextStyle(color: cs.onSurfaceVariant, fontSize: 13),
            ),

            // ── Error-specific info banner ────────────────────────────────
            if (banner != null) ...[
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 12, vertical: 10),
                decoration: BoxDecoration(
                  color: cs.errorContainer.withValues(alpha: 0.35),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.info_outline_rounded,
                        size: 16, color: cs.onErrorContainer),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        banner,
                        style: TextStyle(
                            fontSize: 12, color: cs.onErrorContainer),
                      ),
                    ),
                  ],
                ),
              ),
            ],

            const SizedBox(height: 24),

            // ── Countdown ring → retry button ────────────────────────────
            if (!canRetry) ...[
              Stack(
                alignment: Alignment.center,
                children: [
                  SizedBox(
                    width: 72,
                    height: 72,
                    child: CircularProgressIndicator(
                      value: _remaining / _totalCooldown,
                      strokeWidth: 5,
                      backgroundColor:
                          cs.outline.withValues(alpha: 0.2),
                    ),
                  ),
                  Text(
                    // Show "Xm" inside the ring when ≥ 60 s, else raw seconds.
                    _remaining >= 60
                        ? '${_remaining ~/ 60}m'
                        : '$_remaining',
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                'Retry in ${_formatTime(_remaining)}',
                style:
                    TextStyle(fontSize: 13, color: cs.onSurfaceVariant),
              ),
            ] else
              FilledButton.icon(
                onPressed: widget.onRetry,
                icon: const Icon(Icons.refresh_rounded),
                label: const Text('Try again'),
              ),
          ],
        ),
      ),
    );
  }
}

import 'package:flutter/material.dart';
import '../models/download_job.dart';

class DownloadJobTile extends StatelessWidget {
  const DownloadJobTile({
    super.key,
    required this.job,
    required this.onRetry,
    required this.onRemove,
  });

  final DownloadJob job;
  final VoidCallback onRetry;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Progress bar (shown while downloading) ───────────────────────
          if (job.status == JobStatus.downloading)
            LinearProgressIndicator(
              value: job.progress > 0 ? job.progress : null,
              minHeight: 3,
            ),

          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              children: [
                // Thumbnail or type badge
                _Thumbnail(job: job),
                const SizedBox(width: 12),

                // URL + progress text
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        job.url,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                      const SizedBox(height: 4),
                      _StatusText(job: job),
                    ],
                  ),
                ),
                const SizedBox(width: 8),

                // Actions
                _ActionButton(job: job, onRetry: onRetry, onRemove: onRemove),
              ],
            ),
          ),

          // Error detail
          if (job.status == JobStatus.error && job.errorMsg != null)
            Container(
              width: double.infinity,
              color: cs.errorContainer,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Text(
                job.errorMsg!,
                style: TextStyle(
                  color: cs.onErrorContainer,
                  fontSize: 12,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// ── Thumbnail widget ─────────────────────────────────────────────────────────

class _Thumbnail extends StatelessWidget {
  const _Thumbnail({required this.job});
  final DownloadJob job;

  @override
  Widget build(BuildContext context) {
    final thumbUrl = job.item.thumbnailUrl;
    if (thumbUrl != null) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Stack(
          children: [
            Image.network(
              thumbUrl,
              width: 52,
              height: 52,
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => _fallback(context),
            ),
            if (job.item.isVideo)
              const Positioned(
                bottom: 2, right: 2,
                child: Icon(Icons.play_circle_fill_rounded,
                    color: Colors.white, size: 16),
              ),
          ],
        ),
      );
    }
    return _fallback(context);
  }

  Widget _fallback(BuildContext context) {
    return _TypeBadge(type: job.mediaType, isVideo: job.item.isVideo);
  }
}

// ── Type badge / icon ────────────────────────────────────────────────────────

class _TypeBadge extends StatelessWidget {
  const _TypeBadge({required this.type, this.isVideo});
  final IgMediaType type;
  final bool? isVideo;

  @override
  Widget build(BuildContext context) {
    final (icon, color) = switch (type) {
      IgMediaType.reel => (Icons.video_library_rounded, Colors.purple),
      IgMediaType.story => (Icons.auto_stories_rounded, Colors.orange),
      IgMediaType.igtv => (Icons.live_tv_rounded, Colors.deepPurple),
      IgMediaType.post => isVideo == true
          ? (Icons.video_file_rounded, Colors.teal)
          : (Icons.image_rounded, Colors.teal),
      IgMediaType.unknown => (Icons.help_outline_rounded, Colors.grey),
    };

    return Container(
      width: 44,
      height: 44,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Icon(icon, color: color, size: 24),
    );
  }
}

// ── Status text ──────────────────────────────────────────────────────────────

class _StatusText extends StatelessWidget {
  const _StatusText({required this.job});
  final DownloadJob job;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return switch (job.status) {
      JobStatus.pending => Row(children: [
          SizedBox(
            width: 12,
            height: 12,
            child: CircularProgressIndicator(strokeWidth: 2, color: cs.primary),
          ),
          const SizedBox(width: 6),
          const Text('Waiting…', style: TextStyle(fontSize: 12)),
        ]),
      JobStatus.downloading => Text(
          'Downloading ${(job.progress * 100).toStringAsFixed(0)}%',
          style: TextStyle(fontSize: 12, color: cs.primary),
        ),
      JobStatus.done => Row(children: [
          Icon(Icons.check_circle_rounded, size: 14, color: Colors.green),
          const SizedBox(width: 4),
          const Text('Saved to gallery',
              style: TextStyle(fontSize: 12, color: Colors.green)),
        ]),
      JobStatus.error => Row(children: [
          Icon(Icons.error_outline_rounded, size: 14, color: cs.error),
          const SizedBox(width: 4),
          Text('Failed', style: TextStyle(fontSize: 12, color: cs.error)),
        ]),
    };
  }
}

// ── Action button ────────────────────────────────────────────────────────────

class _ActionButton extends StatelessWidget {
  const _ActionButton({
    required this.job,
    required this.onRetry,
    required this.onRemove,
  });

  final DownloadJob job;
  final VoidCallback onRetry;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    return switch (job.status) {
      JobStatus.pending || JobStatus.downloading => IconButton(
          icon: const Icon(Icons.close),
          onPressed: onRemove,
          tooltip: 'Cancel',
        ),
      JobStatus.done => IconButton(
          icon: const Icon(Icons.delete_outline),
          onPressed: onRemove,
          tooltip: 'Remove',
        ),
      JobStatus.error => Row(children: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            onPressed: onRetry,
            tooltip: 'Retry',
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            onPressed: onRemove,
            tooltip: 'Remove',
          ),
        ]),
    };
  }
}

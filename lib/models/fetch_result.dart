import 'media_item.dart';

/// Why Strategy 0 (the authenticated Instagram private API — the only
/// strategy guaranteed to serve the FULL post) could not serve a fetch.
/// Recorded by [DownloaderService] when the lossy Strategy B fallback ends up
/// serving instead, so the UI can warn that the result may be incomplete
/// (field-verified failure mode: Strategy B returned 1 item for a genuine
/// 4-slide carousel with no error — silent data loss).
enum DegradedReason {
  /// No Instagram session — the user never logged in, so Strategy 0 was
  /// never attempted.
  notLoggedIn,

  /// A RateGuard cooldown (challenge/checkpoint/429 or the hourly budget)
  /// blocked the private API for this fetch.
  blockedByCooldown,

  /// The stored session was rejected by Instagram (`login_required` auth
  /// wall) — re-login is the remedy.
  authInvalid,

  /// Strategy 0 was attempted but failed or returned nothing, for a reason
  /// other than a RateGuard block.
  strategy0Failed,
}

/// The outcome of a media fetch: the extracted items plus quality metadata.
///
/// [degradedReason] is non-null when the items were served by a LOSSY
/// fallback (Instagram Strategy B) while the full-quality strategy was
/// unavailable — the list may then be incomplete (e.g. only the first image
/// of a carousel). Non-Instagram platforms and full-quality Instagram
/// strategies (A / 0 / Stories) always produce a non-degraded result.
class FetchResult {
  const FetchResult({required this.items, this.degradedReason});

  /// The downloadable media items extracted from the shared URL.
  final List<MediaItem> items;

  /// Why the full-quality strategy could not serve, or null when the result
  /// is trustworthy as-is.
  final DegradedReason? degradedReason;

  /// True when the item list may silently be missing media (see class doc).
  bool get isDegraded => degradedReason != null;
}

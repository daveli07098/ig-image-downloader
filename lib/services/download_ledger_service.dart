import 'dart:collection';
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/media_item.dart';

/// Persisted record of every [MediaItem] that has ever been successfully
/// downloaded, keyed in a way that is STABLE and date-independent so it keeps
/// working across the exact failure mode that broke the old file-exists dedup:
/// Facebook/Threads/LIHKG stamp `postTimestamp` with "now" at fetch time
/// (see their downloader services), so re-downloading the same post on a
/// later day used to produce a different filename and a genuine duplicate
/// file. The ledger key deliberately omits the date for this reason — do not
/// add one back without also fixing those three services.
///
/// Used by [SelectionScreen] to hide already-downloaded items from the
/// selection grid entirely (the user's explicit choice over a "mark as
/// saved" badge), and by [DownloaderService.downloadItem] to record new
/// downloads (and backfill pre-existing files it finds on disk).
///
/// A singleton (mirroring [RateGuard]/[SessionService]) so the same in-memory
/// set is shared by the selection screen's filter and the downloader, which
/// is constructed outside Riverpod.
class DownloadLedgerService {
  DownloadLedgerService._();
  static final DownloadLedgerService instance = DownloadLedgerService._();

  static const _prefsKey = 'download_ledger_v1';

  /// Hard cap on stored entries so a long-lived install can't grow this
  /// SharedPreferences value unboundedly. Oldest entries are evicted first
  /// once the cap is hit — see [record].
  static const int _maxEntries = 5000;

  // Insertion-ordered so eviction can cheaply drop the oldest entry (the
  // first element) once [_maxEntries] is exceeded, while still giving O(1)
  // membership checks via the underlying Set.
  final LinkedHashSet<String> _keys = LinkedHashSet<String>();

  bool _loaded = false;

  /// Loads persisted state. Call once at app startup before any selection
  /// screen or download can run (mirrors [RateGuard.init]).
  Future<void> init() async {
    if (_loaded) return;
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKey);
    if (raw != null) {
      try {
        final list = (jsonDecode(raw) as List).cast<String>();
        _keys.addAll(list);
      } catch (_) {
        // Corrupt payload — start clean rather than crash.
      }
    }
    _loaded = true;
  }

  /// Ledger key for [item]: username + a date-independent hash of the media
  /// URL path. Reuses [MediaItem.hashMediaUrl] rather than re-deriving the
  /// polynomial hash so the two can never drift apart.
  static String _keyFor(MediaItem item) =>
      '${item.username}_${MediaItem.hashMediaUrl(item.mediaUrl)}';

  /// True when [item] has already been downloaded (in this ledger).
  bool contains(MediaItem item) => _keys.contains(_keyFor(item));

  /// Records [item] as downloaded and persists immediately so a crash right
  /// after a download can't lose the entry. Also used to backfill the ledger
  /// when [DownloaderService.downloadItem] finds a matching file already on
  /// disk from before the ledger existed.
  Future<void> record(MediaItem item) async {
    final key = _keyFor(item);
    // Already recorded — nothing to do, and re-inserting would be a no-op
    // for a LinkedHashSet anyway (it wouldn't move to the end).
    if (_keys.contains(key)) return;
    _keys.add(key);
    // Evict oldest entries first once over the cap.
    while (_keys.length > _maxEntries) {
      _keys.remove(_keys.first);
    }
    await _persist();
  }

  /// Clears the entire ledger (e.g. a future "reset dedup" setting).
  Future<void> clear() async {
    _keys.clear();
    await _persist();
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsKey, jsonEncode(_keys.toList()));
  }
}

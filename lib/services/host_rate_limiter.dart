import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Client-side rate-limit protection shared by scraped (non-account-bearing)
/// hosts. Keyed by a host string (e.g. `'lihkg.com'`) so Tumblr/Facebook can
/// adopt this later without a new class, but as of this writing it is wired
/// up to LIHKG only — see [LihkgDownloaderService].
///
/// Four independent mechanisms, all keyed by host:
///  1. A **persisted cooldown** ([noteThrottled] / [cooldownRemaining]) so a
///     429 survives an app restart, and a fresh share doesn't immediately
///     re-trigger (and extend) the same block.
///  2. An in-memory rolling-window **token bucket** ([awaitSlot]) capping
///     request volume regardless of what the server does or doesn't say.
///  3. A persisted **adaptive pacing multiplier** ([pace]) that widens the
///     caller's own inter-request delay after a throttle, and decays it back
///     down after a clean fetch.
///  4. A small in-memory, TTL'd **response cache** ([cached] / [store]) so
///     re-sharing the same content doesn't refetch it.
///
/// Everything persisted is a small scalar (a timestamp, a multiplier index)
/// — never a response body, never anything user-identifying. The response
/// cache itself is in-memory only and never touches disk.
class HostRateLimiter {
  HostRateLimiter({
    DateTime Function()? now,
    Future<void> Function(Duration)? delay,
  })  : _now = now ?? DateTime.now,
        _delay = delay ?? ((d) => Future.delayed(d));

  /// Shared long-lived instance for production use. `LihkgDownloaderService`
  /// is constructed fresh per share (see `DownloaderService.fetchItems`), so
  /// the cooldown/bucket/cache state needs a home that outlives one call —
  /// mirroring `RateGuard.instance`'s existing singleton-accessor pattern in
  /// rate_guard_service.dart, which solves the exact same problem for
  /// Instagram. Tests should construct their own instance instead, with
  /// injected `now`/`delay`, so cases never share state or sleep for real.
  static final HostRateLimiter instance = HostRateLimiter();

  final DateTime Function() _now;
  final Future<void> Function(Duration) _delay;

  // ---------------------------------------------------------------------
  // 1. Persisted cooldown.
  // ---------------------------------------------------------------------

  static const _cooldownKeyPrefix = 'host_rate_cooldown_';
  static const _paceKeyPrefix = 'host_rate_pace_';

  /// Cooldown length used when [noteThrottled] isn't given a `Retry-After`
  /// value at all. Chosen as a middle ground: long enough to actually break
  /// an immediate-retry loop (the field-observed failure mode), short enough
  /// not to lock a user out over a single ambiguous response.
  static const Duration defaultCooldown = Duration(seconds: 30);

  /// However hostile a `Retry-After` header is, never persist a cooldown
  /// longer than this — mirrors `LihkgDownloaderService._maxBackoff`'s "never
  /// let a Retry-After stall the UI" philosophy, extended to the persisted
  /// cooldown so a pathological header (e.g. `Retry-After: 86400`) can't
  /// lock a host out across restarts for a day.
  static const Duration maxCooldown = Duration(minutes: 15);

  /// Adaptive pacing multiplier ladder — doubles/halves one notch at a time
  /// rather than a continuous value, so it's easy to reason about and to
  /// persist as a small integer index.
  static const List<int> _paceSteps = [1, 2, 4];

  final Map<String, int> _cooldownUntilMs = {};
  final Map<String, int> _paceStepIndex = {};

  bool _loaded = false;

  /// Loads every persisted `host_rate_*` key into memory. Idempotent and
  /// cheap after the first call — mirrors `RateGuard.init()`'s "call once
  /// before any API path runs" convention, except every public method here
  /// also calls it defensively so callers (and tests) can't forget it.
  Future<void> init() async {
    if (_loaded) return;
    final prefs = await SharedPreferences.getInstance();
    for (final key in prefs.getKeys()) {
      if (key.startsWith(_cooldownKeyPrefix)) {
        final host = key.substring(_cooldownKeyPrefix.length);
        final v = prefs.getInt(key);
        if (v != null) _cooldownUntilMs[host] = v;
      } else if (key.startsWith(_paceKeyPrefix)) {
        final host = key.substring(_paceKeyPrefix.length);
        final v = prefs.getInt(key);
        if (v != null) _paceStepIndex[host] = v;
      }
    }
    _loaded = true;
  }

  /// Time left on [host]'s active cooldown, or null when there isn't one.
  /// Callers MUST check this before sending anything. Synchronous by design
  /// (see class doc) — call [init] first so persisted state is loaded.
  Duration? cooldownRemaining(String host) {
    final untilMs = _cooldownUntilMs[host];
    if (untilMs == null) return null;
    final remainingMs = untilMs - _now().millisecondsSinceEpoch;
    if (remainingMs <= 0) {
      // Expired — clear it so a later noteThrottled() starts from "no
      // cooldown" rather than the never-shrinks max() below carrying a
      // stale value forward.
      _cooldownUntilMs.remove(host);
      return null;
    }
    return Duration(milliseconds: remainingMs);
  }

  /// Records that [host] just throttled us (429/503), and bumps the pacing
  /// multiplier up one notch (capped at x4). [retryAfter] is the parsed
  /// `Retry-After` header when present; falls back to [defaultCooldown].
  Future<void> noteThrottled(String host, {Duration? retryAfter}) async {
    await init();

    final nowMs = _now().millisecondsSinceEpoch;
    final requested = retryAfter ?? defaultCooldown;
    final capped = requested > maxCooldown ? maxCooldown : requested;
    final candidateUntilMs = nowMs + capped.inMilliseconds;
    final existingUntilMs = _cooldownUntilMs[host];
    // Never let a later, shorter Retry-After shrink an already-active
    // cooldown — take whichever is furthest out.
    final newUntilMs = existingUntilMs != null && existingUntilMs > candidateUntilMs
        ? existingUntilMs
        : candidateUntilMs;

    final currentStep = _paceStepIndex[host] ?? 0;
    final nextStep =
        currentStep < _paceSteps.length - 1 ? currentStep + 1 : currentStep;

    // Check-await-write discipline: update the in-memory maps synchronously,
    // BEFORE the `await` below, so a concurrent cooldownRemaining()/pace()
    // call can never observe stale (pre-throttle) state while the persist
    // round-trips. Same pattern as rate_guard_service.dart's
    // awaitCallSlot() — see its doc comment for the two bugs this discipline
    // was added to fix.
    _cooldownUntilMs[host] = newUntilMs;
    _paceStepIndex[host] = nextStep;

    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('$_cooldownKeyPrefix$host', newUntilMs);
    await prefs.setInt('$_paceKeyPrefix$host', nextStep);
  }

  /// Records a fetch of [host] that completed without ever being throttled,
  /// stepping the pacing multiplier back down one notch toward x1. A no-op
  /// (and no persistence write) once already at the floor.
  Future<void> noteCleanFetch(String host) async {
    await init();
    final currentStep = _paceStepIndex[host] ?? 0;
    if (currentStep == 0) return;
    final nextStep = currentStep - 1;
    _paceStepIndex[host] = nextStep; // synchronous update before the await.
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('$_paceKeyPrefix$host', nextStep);
  }

  /// Applies [host]'s current adaptive-pacing multiplier to a caller-chosen
  /// [base] delay (e.g. the existing inter-page jitter). Synchronous by
  /// design (see class doc) — call [init] first so persisted state is
  /// loaded.
  Duration pace(String host, Duration base) {
    final step = _paceStepIndex[host] ?? 0;
    return base * _paceSteps[step];
  }

  // ---------------------------------------------------------------------
  // 2. Token bucket — max [maxRequestsPerWindow] requests per rolling
  //    [window], in-memory only.
  // ---------------------------------------------------------------------

  static const int maxRequestsPerWindow = 20;
  static const Duration window = Duration(seconds: 60);

  /// Epoch-ms timestamps of the requests currently "inside" the rolling
  /// window per host — a sliding-window log capped at [maxRequestsPerWindow]
  /// entries.
  final Map<String, List<int>> _slotTimestampsMs = {};

  /// Reserves a request slot for [host], waiting if the rolling-window
  /// budget is currently spent. Reserves the slot **synchronously, before
  /// any `await`** — this is the same check-await-write discipline as
  /// rate_guard_service.dart's `awaitCallSlot()` (the correct precedent for
  /// this exact class of bug: two check-await-write races of this shape
  /// were shipped and fixed earlier in this codebase). Without it, a burst
  /// of concurrent callers could all read "budget available" before any of
  /// them writes a reservation, and all pass at once.
  Future<void> awaitSlot(String host) async {
    final nowMs = _now().millisecondsSinceEpoch;
    final slots = _slotTimestampsMs.putIfAbsent(host, () => <int>[]);

    // Drop slots whose window has already elapsed relative to real "now".
    slots.removeWhere((t) => nowMs - t >= window.inMilliseconds);

    Duration wait;
    if (slots.length < maxRequestsPerWindow) {
      // Budget available — reserve immediately, no wait.
      wait = Duration.zero;
      slots.add(nowMs);
    } else {
      // Budget spent: the next slot frees up when the OLDEST reserved slot's
      // window elapses. Reserve that future slot now, synchronously, so a
      // sibling call made in the same burst sees it already taken.
      slots.sort();
      final earliestMs = slots.removeAt(0);
      final readyAtMs = earliestMs + window.inMilliseconds;
      wait = readyAtMs > nowMs
          ? Duration(milliseconds: readyAtMs - nowMs)
          : Duration.zero;
      slots.add(readyAtMs > nowMs ? readyAtMs : nowMs);
    }

    if (wait > Duration.zero) {
      debugPrint('[HostRateLimiter] $host: request budget spent, waiting '
          '${wait.inMilliseconds}ms — mirrors RateGuard.awaitCallSlot\'s '
          'pacing log');
      await _delay(wait);
    }
  }

  // ---------------------------------------------------------------------
  // 3. Response cache — small, in-memory, TTL'd, bounded. Never persisted.
  // ---------------------------------------------------------------------

  static const Duration defaultCacheTtl = Duration(minutes: 15);
  static const int maxCacheEntries = 50;

  final Map<String, _CacheEntry> _cache = {};

  /// Returns the cached value for [key] if present and not expired, else
  /// null (and evicts the entry if it has expired).
  T? cached<T>(String key) {
    final entry = _cache[key];
    if (entry == null) return null;
    if (_now().millisecondsSinceEpoch >= entry.expiresAtMs) {
      _cache.remove(key);
      return null;
    }
    return entry.value as T;
  }

  /// Stores [value] under [key] for [ttl] (default [defaultCacheTtl]).
  /// Bounded at [maxCacheEntries]; the oldest entry (by insertion order) is
  /// evicted once the bound is exceeded.
  void store<T>(String key, T value, {Duration ttl = defaultCacheTtl}) {
    // Re-inserting an existing key must move it to the end of the
    // (insertion-ordered) map so "evict oldest" evicts by insertion order,
    // not by the key's original first-ever insertion.
    _cache.remove(key);
    _cache[key] =
        _CacheEntry(value, _now().millisecondsSinceEpoch + ttl.inMilliseconds);
    while (_cache.length > maxCacheEntries) {
      _cache.remove(_cache.keys.first);
    }
  }

  // ---------------------------------------------------------------------
  // Test support.
  // ---------------------------------------------------------------------

  /// Resets ALL in-memory and loaded-from-prefs state, for test isolation.
  /// Does not touch anything already persisted to SharedPreferences.
  @visibleForTesting
  void clearForTest() {
    _cooldownUntilMs.clear();
    _paceStepIndex.clear();
    _slotTimestampsMs.clear();
    _cache.clear();
    _loaded = false;
  }
}

class _CacheEntry {
  _CacheEntry(this.value, this.expiresAtMs);
  final dynamic value;
  final int expiresAtMs;
}

import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Severity of the current rate situation, used to pick the banner colour/copy.
enum RateLevel {
  /// Plenty of budget left — no banner.
  ok,

  /// Approaching the hourly budget — show an amber "slow down" reminder.
  warn,

  /// Budget spent or Instagram flagged us — block calls and show a red banner.
  blocked,
}

/// Immutable snapshot of the rate situation, surfaced to the UI.
@immutable
class RateGuardStatus {
  const RateGuardStatus({
    required this.usedLastHour,
    required this.limit,
    required this.warnAt,
    required this.blockedUntil,
    required this.isChallenge,
  });

  /// Authenticated private-API calls made in the trailing 60 minutes.
  final int usedLastHour;

  /// Conservative hourly cap (well under Instagram's ~200/hr quota).
  final int limit;

  /// Threshold at which the amber reminder appears.
  final int warnAt;

  /// Instant until which calls are blocked, or null when not blocked.
  /// Set either by spending the hourly budget (auto-clears as calls age out)
  /// or by Instagram pushing back (a fixed multi-hour cooldown).
  final DateTime? blockedUntil;

  /// True when [blockedUntil] was set by an Instagram challenge/checkpoint/429,
  /// as opposed to merely exhausting our self-imposed hourly budget.
  final bool isChallenge;

  int get remaining => (limit - usedLastHour).clamp(0, limit);

  RateLevel get level {
    if (blockedUntil != null) return RateLevel.blocked;
    if (usedLastHour >= warnAt) return RateLevel.warn;
    return RateLevel.ok;
  }

  bool get isBlocked => level == RateLevel.blocked;

  @override
  bool operator ==(Object other) =>
      other is RateGuardStatus &&
      other.usedLastHour == usedLastHour &&
      other.limit == limit &&
      other.warnAt == warnAt &&
      other.blockedUntil == blockedUntil &&
      other.isChallenge == isChallenge;

  @override
  int get hashCode =>
      Object.hash(usedLastHour, limit, warnAt, blockedUntil, isChallenge);
}

/// Thrown when an authenticated Instagram call is refused locally because the
/// hourly budget is spent or a challenge cooldown is active. The message is
/// phrased so [SelectionScreen]'s error classifier routes it to the rate-limit
/// tier and the user gets a clear, actionable explanation.
class RateLimitException implements Exception {
  RateLimitException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Guards the authenticated Instagram private API (`i.instagram.com`) — the
/// metered, account-attributed surface that triggers "automated behaviour"
/// flags. Counts calls in a rolling hour window, blocks once a conservative
/// budget is spent, and enforces a hard cooldown when Instagram pushes back.
///
/// State is persisted so the budget and any cooldown survive app restarts —
/// closing and reopening the app must not reset a cooldown Instagram imposed.
///
/// A singleton (mirroring [SessionService]) because the rate budget is a single
/// device-wide fact and must be shared by every code path that hits the API,
/// including [DownloaderService] which is constructed outside Riverpod.
class RateGuard {
  RateGuard._();
  static final RateGuard instance = RateGuard._();

  // ── Tuning ───────────────────────────────────────────────────────────────
  /// Hourly cap on authenticated private-API calls. Instagram tolerates ~200/hr
  /// per session; we stay far below so a single human downloading one-by-one
  /// effectively never hits it, while runaway/automated bursts get caught.
  static const int hourlyLimit = 80;

  /// Amber-reminder threshold (75% of the budget).
  static const int warnAt = 60;

  /// Rolling window the budget is measured over.
  static const Duration window = Duration(hours: 1);

  /// Cooldown imposed when Instagram returns a challenge/checkpoint/429.
  /// Long and deliberate: hammering through a soft flag is what escalates it.
  static const Duration challengeCooldown = Duration(hours: 2);

  static const _callsKey = 'rate_api_call_ts';
  static const _cooldownKey = 'rate_challenge_until';

  /// Epoch-ms timestamps of recent authenticated calls (trimmed to [window]).
  final List<int> _callTs = [];

  /// Epoch-ms until which an Instagram-imposed cooldown is active, or null.
  int? _challengeUntilMs;

  /// Reactive handle the UI listens to for live banner updates.
  final ValueNotifier<RateGuardStatus> listenable =
      ValueNotifier<RateGuardStatus>(const RateGuardStatus(
    usedLastHour: 0,
    limit: hourlyLimit,
    warnAt: warnAt,
    blockedUntil: null,
    isChallenge: false,
  ));

  bool _loaded = false;

  /// Loads persisted state. Call once at app startup before any API path runs.
  Future<void> init() async {
    if (_loaded) return;
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_callsKey);
    if (raw != null) {
      try {
        final list = (jsonDecode(raw) as List).cast<num>();
        _callTs
          ..clear()
          ..addAll(list.map((e) => e.toInt()));
      } catch (_) {
        // Corrupt payload — start clean rather than crash.
      }
    }
    final until = prefs.getInt(_cooldownKey);
    if (until != null) _challengeUntilMs = until;
    _loaded = true;
    _recompute();
  }

  /// Current snapshot (also drives [listenable]).
  RateGuardStatus get status => listenable.value;

  /// Throws [RateLimitException] when an authenticated call must not proceed.
  /// Call immediately before hitting `i.instagram.com`.
  void assertCanCall() {
    _recompute();
    final s = listenable.value;
    if (!s.isBlocked) return;
    if (s.isChallenge) {
      throw RateLimitException(
        'Instagram flagged automated activity and we paused requests to keep '
        'your account safe. Open the Instagram app, clear any prompt, then wait '
        '— this resets in ${_friendly(s.blockedUntil!)}.',
      );
    }
    throw RateLimitException(
      'Hourly request limit reached (${s.limit}/hr) to avoid Instagram\'s '
      'automated-behaviour detection. Try again in ${_friendly(s.blockedUntil!)}.',
    );
  }

  /// Records one authenticated private-API call against the hourly budget.
  /// Persisted immediately so a crash mid-session can't lose the count.
  Future<void> recordApiCall() async {
    _callTs.add(DateTime.now().millisecondsSinceEpoch);
    _recompute();
    await _persist();
  }

  /// Trips the hard cooldown after Instagram returns a challenge/checkpoint/429.
  Future<void> triggerChallengeCooldown() async {
    _challengeUntilMs =
        DateTime.now().add(challengeCooldown).millisecondsSinceEpoch;
    _recompute();
    await _persist();
  }

  /// Re-evaluates the window (used by the banner's 1 s ticker so the budget
  /// recovers and any cooldown clears on screen without a manual refresh).
  void refresh() => _recompute();

  // ── internals ──────────────────────────────────────────────────────────────

  void _recompute() {
    final now = DateTime.now();
    final cutoff = now.subtract(window).millisecondsSinceEpoch;
    _callTs.removeWhere((ts) => ts < cutoff);

    // Clear an expired challenge cooldown.
    if (_challengeUntilMs != null && _challengeUntilMs! <= now.millisecondsSinceEpoch) {
      _challengeUntilMs = null;
    }

    final used = _callTs.length;
    DateTime? blockedUntil;
    var isChallenge = false;

    if (_challengeUntilMs != null) {
      blockedUntil = DateTime.fromMillisecondsSinceEpoch(_challengeUntilMs!);
      isChallenge = true;
    } else if (used >= hourlyLimit && _callTs.isNotEmpty) {
      // Budget spent — unblocks when the oldest call ages out of the window.
      blockedUntil =
          DateTime.fromMillisecondsSinceEpoch(_callTs.first).add(window);
    }

    final next = RateGuardStatus(
      usedLastHour: used,
      limit: hourlyLimit,
      warnAt: warnAt,
      blockedUntil: blockedUntil,
      isChallenge: isChallenge,
    );
    if (next != listenable.value) listenable.value = next;
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_callsKey, jsonEncode(_callTs));
    if (_challengeUntilMs != null) {
      await prefs.setInt(_cooldownKey, _challengeUntilMs!);
    } else {
      await prefs.remove(_cooldownKey);
    }
  }

  /// Human-readable "in 5 min" / "in 1 h 12 min" from now until [until].
  static String _friendly(DateTime until) {
    final secs = until.difference(DateTime.now()).inSeconds;
    if (secs <= 0) return 'a moment';
    if (secs < 60) return '${secs}s';
    final mins = (secs / 60).ceil();
    if (mins < 60) return '$mins min';
    final h = mins ~/ 60;
    final m = mins % 60;
    return m == 0 ? '${h}h' : '${h}h ${m}min';
  }
}

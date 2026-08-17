import 'dart:async';
import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'session_service.dart';

/// Severity of the current rate situation, used to pick the banner colour/copy.
enum RateLevel {
  /// Plenty of budget left — no banner.
  ok,

  /// Approaching the hourly budget — show an amber "slow down" reminder.
  warn,

  /// Budget spent or Instagram flagged us — block calls and show a red banner.
  blocked,
}

/// Which specific Instagram pushback signal tripped a challenge cooldown.
/// Recorded (and persisted) alongside the cooldown so a block that outlives
/// the session can still be diagnosed after the fact.
enum PushbackReason {
  /// HTTP 429 Too Many Requests.
  http429('http429', 'Rate limited (HTTP 429)'),

  /// Body contained `checkpoint_required` — account-level security wall.
  checkpointRequired(
      'checkpoint_required', 'Security check requested (checkpoint_required)'),

  /// Body contained `challenge_required` — challenge/verification wall.
  challengeRequired(
      'challenge_required', 'Security check requested (challenge_required)'),

  /// Body contained `login_required` — session rejected / login wall.
  loginRequired('login_required', 'Login required (login_required)'),

  /// Body contained `please wait a few minutes` — soft temporary throttle.
  pleaseWait('please_wait', 'Temporary throttle ("please wait a few minutes")');

  const PushbackReason(this.code, this.label);

  /// Stable machine-readable code (used for persistence and logs).
  final String code;

  /// Short human-readable cause for banners and diagnostics.
  final String label;

  /// Inverse of [code] for restoring a persisted reason; null if unknown.
  static PushbackReason? fromCode(String? code) {
    if (code == null) return null;
    for (final r in PushbackReason.values) {
      if (r.code == code) return r;
    }
    return null;
  }
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
    this.challengeReason,
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

  /// The specific signal that tripped the challenge cooldown, or null when
  /// not in a challenge cooldown (or the reason predates this field).
  final PushbackReason? challengeReason;

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
      other.isChallenge == isChallenge &&
      other.challengeReason == challengeReason;

  @override
  int get hashCode => Object.hash(
      usedLastHour, limit, warnAt, blockedUntil, isChallenge, challengeReason);
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

  /// Minimum spacing between recovery-probe attempts, enforced independently
  /// of the hourly call budget and persisted so it survives a restart. This
  /// guarantees the probe can NEVER itself contribute to a fresh automation
  /// flag by re-checking Instagram too often while a cooldown is active —
  /// the whole point of probing is to detect recovery without becoming the
  /// thing that re-triggers the block.
  static const Duration probeMinInterval = Duration(minutes: 5);

  // User-agent / app-id for the lightweight probe request. Duplicated from
  // DownloaderService's private-API constants rather than imported from it
  // (mirrors ThreadsDownloaderService's existing convention of keeping its
  // own copy) — RateGuard must not depend on DownloaderService, which already
  // depends on RateGuard, to avoid a import cycle.
  static const _probeUA =
      'Instagram 219.0.0.12.117 Android (26/8.0.0; 480dpi; 1080x1920; '
      'OnePlus; ONEPLUS A3010; OnePlus3T; qcom; en_US; 314665256)';
  static const _probeAppId = '936619743392459';

  static const _callsKey = 'rate_api_call_ts';
  static const _cooldownKey = 'rate_challenge_until';
  static const _lastProbeKey = 'rate_last_probe_ts';
  // Diagnostics for the active cooldown — persisted so a block that outlives
  // the session (the common case, cooldowns run for hours) stays explainable.
  static const _reasonKey = 'rate_challenge_reason';
  static const _httpStatusKey = 'rate_challenge_http_status';
  static const _trippedAtKey = 'rate_challenge_at';

  /// Epoch-ms timestamps of recent authenticated calls (trimmed to [window]).
  final List<int> _callTs = [];

  /// Epoch-ms until which an Instagram-imposed cooldown is active, or null.
  int? _challengeUntilMs;

  /// Why the active cooldown was tripped (null when no cooldown, or when the
  /// persisted state predates reason tracking).
  PushbackReason? _challengeReason;

  /// HTTP status of the response that tripped the active cooldown, or null.
  int? _challengeHttpStatus;

  /// Epoch-ms at which the active cooldown was tripped, or null.
  int? _challengeAtMs;

  /// Epoch-ms of the last recovery-probe attempt, or null if none yet.
  int? _lastProbeMs;

  /// One-shot flag set when a cooldown was lifted by a successful reprobe
  /// (Instagram recovered before the fixed timer ran out) rather than by the
  /// timer simply expiring. The UI reads this via [consumeEarlyRecovery] to
  /// decide whether to show the "access recovered" reminder.
  bool _earlyRecoveryPending = false;

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
    _challengeReason = PushbackReason.fromCode(prefs.getString(_reasonKey));
    _challengeHttpStatus = prefs.getInt(_httpStatusKey);
    _challengeAtMs = prefs.getInt(_trippedAtKey);
    _lastProbeMs = prefs.getInt(_lastProbeKey);
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
  /// [reason] and [statusCode] record WHICH signal matched and what Instagram
  /// returned, so the block can be diagnosed later — including after an app
  /// restart (both are persisted with the cooldown).
  Future<void> triggerChallengeCooldown(
      {PushbackReason? reason, int? statusCode}) async {
    final now = DateTime.now();
    _challengeUntilMs = now.add(challengeCooldown).millisecondsSinceEpoch;
    _challengeReason = reason;
    _challengeHttpStatus = statusCode;
    _challengeAtMs = now.millisecondsSinceEpoch;
    debugPrint('[RateGuard] Cooldown STARTED: '
        'reason=${reason?.code ?? 'unknown'} http=${statusCode ?? '-'} '
        'until=${now.add(challengeCooldown)}');
    _recompute();
    await _persist();
  }

  /// Re-evaluates the window (used by the banner's 1 s ticker so the budget
  /// recovers and any cooldown clears on screen without a manual refresh).
  void refresh() => _recompute();

  /// Lifts an active challenge cooldown immediately. [early] marks the lift
  /// as evidence-based recovery (a successful [maybeReprobe]) rather than the
  /// fixed timer expiring, which sets the one-shot [consumeEarlyRecovery] flag
  /// the UI uses to show a reminder.
  Future<void> clearChallengeCooldown({bool early = false}) async {
    if (_challengeUntilMs == null) return; // nothing to clear
    // Distinguish evidence-based early recovery (probe succeeded) from an
    // explicit clear, so field logs show whether auto-recovery actually works.
    debugPrint('[RateGuard] Cooldown CLEARED '
        '(${early ? 'early — recovery probe succeeded' : 'explicit clear'}): '
        'was reason=${_challengeReason?.code ?? 'unknown'} '
        'http=${_challengeHttpStatus ?? '-'} tripped=${_trippedAtString()}');
    _challengeUntilMs = null;
    _clearChallengeMeta();
    if (early) _earlyRecoveryPending = true;
    _recompute();
    await _persist();
  }

  /// Returns true exactly once per early-recovery event, then resets. The UI
  /// calls this from its existing change listener to decide whether to show
  /// the "Instagram access recovered" reminder.
  bool consumeEarlyRecovery() {
    if (!_earlyRecoveryPending) return false;
    _earlyRecoveryPending = false;
    return true;
  }

  /// While a challenge cooldown is active, makes ONE lightweight authenticated
  /// probe to check whether Instagram access has actually recovered, so the
  /// banner can clear as soon as it's true rather than waiting out the full
  /// fixed [challengeCooldown]. Fails closed: the cooldown is left untouched
  /// on pushback, a network error, or any ambiguous result — it is only ever
  /// lifted by a clean response.
  ///
  /// [force] bypasses [probeMinInterval] for a manual "Check now" tap; it does
  /// NOT bypass the "only probe while actually blocked" check, so it can't be
  /// used to spam Instagram outside a cooldown.
  ///
  /// Returns true when the probe found access recovered (and lifted the
  /// cooldown), false otherwise (still blocked, throttled, no session, or a
  /// transport error).
  Future<bool> maybeReprobe({bool force = false}) async {
    _recompute();
    if (!listenable.value.isChallenge) return false; // nothing to probe

    final now = DateTime.now().millisecondsSinceEpoch;
    if (!force &&
        _lastProbeMs != null &&
        now - _lastProbeMs! < probeMinInterval.inMilliseconds) {
      return false; // too soon since the last probe — never hammer Instagram
    }

    final sessionId =
        await SessionService.getSessionId(LoginPlatform.instagram);
    if (sessionId == null) return false; // can't probe without a session

    // Record the attempt (and persist it) BEFORE the network call so a crash
    // or timeout still counts against the min-interval — the guarantee is
    // "at most one probe per interval attempted", not "per interval succeeded".
    _lastProbeMs = now;
    await _persist();

    try {
      // A standalone Dio instance scoped to this single request — RateGuard
      // intentionally does not share DownloaderService's client to keep the
      // two services decoupled (see the UA/app-id comment above).
      final probeDio = Dio(BaseOptions(
        connectTimeout: const Duration(seconds: 10),
        receiveTimeout: const Duration(seconds: 15),
        headers: {
          'User-Agent': _probeUA,
          'X-IG-App-ID': _probeAppId,
          'X-IG-Capabilities': '3brTvwE=',
          'Accept-Language': 'en-US',
          'Accept': 'application/json',
        },
      ));
      // accounts/current_user/ is the lightest authenticated endpoint that
      // still surfaces a challenge/checkpoint wall — unlike media/info/ it
      // needs no target post, so RateGuard (which has no shortcode/media ID
      // context) can call it standalone. Deliberately NOT recorded via
      // recordApiCall(): it's a single call every 5+ minutes at most, far
      // below the hourly budget's purpose of catching runaway bursts, and
      // counting it would falsely eat into a budget the user's own actions
      // didn't spend.
      final resp = await probeDio.get<String>(
        'https://i.instagram.com/api/v1/accounts/current_user/?edit=true',
        options: Options(headers: {'Cookie': 'sessionid=$sessionId'}),
      );
      final body = (resp.data ?? '').toLowerCase();
      if (isPushback(resp.statusCode, body)) {
        return false; // still flagged — leave the cooldown untouched
      }
      await clearChallengeCooldown(early: true);
      return true;
    } on DioException catch (_) {
      // Covers non-2xx responses (incl. a genuine 429/challenge) and network
      // failures alike — either way this is not clean evidence of recovery,
      // so fail closed and leave the cooldown exactly as it was.
      return false;
    } catch (_) {
      return false;
    }
  }

  // ── internals ──────────────────────────────────────────────────────────────

  void _recompute() {
    final now = DateTime.now();
    final cutoff = now.subtract(window).millisecondsSinceEpoch;
    _callTs.removeWhere((ts) => ts < cutoff);

    // Clear an expired challenge cooldown.
    if (_challengeUntilMs != null && _challengeUntilMs! <= now.millisecondsSinceEpoch) {
      // Timer ran out with no early recovery — log it so field data can show
      // how often the recovery probe beats the fixed timer (or never fires).
      debugPrint('[RateGuard] Cooldown CLEARED (timer expiry — no early '
          'recovery): was reason=${_challengeReason?.code ?? 'unknown'} '
          'http=${_challengeHttpStatus ?? '-'} tripped=${_trippedAtString()}');
      _challengeUntilMs = null;
      _clearChallengeMeta();
      // Fire-and-forget: _recompute must stay synchronous (it runs on a 1 s
      // UI ticker); the removed keys just need to land eventually.
      unawaited(_persist());
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
      challengeReason: isChallenge ? _challengeReason : null,
    );
    if (next != listenable.value) listenable.value = next;
  }

  /// Drops the diagnostic metadata tied to a (now cleared) cooldown.
  void _clearChallengeMeta() {
    _challengeReason = null;
    _challengeHttpStatus = null;
    _challengeAtMs = null;
  }

  /// The active cooldown's trip time as a log-friendly string.
  String _trippedAtString() => _challengeAtMs == null
      ? 'unknown'
      : DateTime.fromMillisecondsSinceEpoch(_challengeAtMs!).toString();

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_callsKey, jsonEncode(_callTs));
    if (_challengeUntilMs != null) {
      await prefs.setInt(_cooldownKey, _challengeUntilMs!);
    } else {
      await prefs.remove(_cooldownKey);
    }
    if (_lastProbeMs != null) {
      await prefs.setInt(_lastProbeKey, _lastProbeMs!);
    }
    // Cooldown diagnostics live and die with the cooldown itself.
    if (_challengeReason != null) {
      await prefs.setString(_reasonKey, _challengeReason!.code);
    } else {
      await prefs.remove(_reasonKey);
    }
    if (_challengeHttpStatus != null) {
      await prefs.setInt(_httpStatusKey, _challengeHttpStatus!);
    } else {
      await prefs.remove(_httpStatusKey);
    }
    if (_challengeAtMs != null) {
      await prefs.setInt(_trippedAtKey, _challengeAtMs!);
    } else {
      await prefs.remove(_trippedAtKey);
    }
  }

  /// True when an `i.instagram.com` response indicates Instagram is pushing
  /// back on automation: a 429 (too many requests) or a challenge/checkpoint/
  /// login wall — which Instagram returns with either an error status OR a
  /// 200 carrying a `"status":"fail"` body. Treated as a hard signal to back
  /// off, since hammering through it is what escalates a soft flag.
  ///
  /// Shared by [DownloaderService] (which trips [triggerChallengeCooldown] on
  /// a real request) and [maybeReprobe] (which relies on it to tell a clean
  /// recovery from a still-blocked probe) so the two never drift apart.
  static bool isPushback(int? statusCode, String lowerBody) =>
      pushbackReason(statusCode, lowerBody) != null;

  /// Like [isPushback], but returns WHICH signal matched (or null when the
  /// response is clean) so callers can record and surface the actual cause.
  /// Checked in escalation order: the explicit 429 wins over body markers,
  /// and the harder account walls win over the soft "please wait" throttle.
  static PushbackReason? pushbackReason(int? statusCode, String lowerBody) {
    if (statusCode == 429) return PushbackReason.http429;
    if (lowerBody.contains('checkpoint_required')) {
      return PushbackReason.checkpointRequired;
    }
    if (lowerBody.contains('challenge_required')) {
      return PushbackReason.challengeRequired;
    }
    if (lowerBody.contains('login_required')) {
      return PushbackReason.loginRequired;
    }
    if (lowerBody.contains('please wait a few minutes')) {
      return PushbackReason.pleaseWait;
    }
    return null;
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

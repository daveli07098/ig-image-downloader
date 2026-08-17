import 'dart:async';
import 'dart:convert';
import 'dart:math';
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

  /// True when this signal is an AUTHENTICATION failure — the stored session
  /// itself was rejected — rather than automation/throttling pushback.
  /// `login_required` is the only pure auth wall: waiting changes nothing
  /// (the session is still invalid at the end of any cooldown; field-verified
  /// — a 2 h login_required cooldown even survived a re-login) and the remedy
  /// is re-login. `checkpoint_required`/`challenge_required` stay on the
  /// automation ladder: they flag the ACCOUNT (clearing them needs user action
  /// inside Instagram, not just a fresh session) and retrying through them is
  /// exactly what escalates a soft flag into a real block. `http429` and
  /// `please_wait` are unambiguous throttling.
  bool get isAuthFailure => this == PushbackReason.loginRequired;

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

  /// True when the active block is an AUTH wall ([PushbackReason.isAuthFailure])
  /// — the session expired and the actionable remedy is re-login, not waiting.
  /// The banner uses this to swap "wait it out" copy for a "Log in" action.
  bool get needsRelogin => isChallenge && (challengeReason?.isAuthFailure ?? false);

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

  /// Base cooldown imposed when Instagram returns a challenge/checkpoint/429.
  /// Long and deliberate: hammering through a soft flag is what escalates it.
  /// Repeat trips escalate exponentially — see [triggerChallengeCooldown].
  static const Duration challengeCooldown = Duration(hours: 2);

  /// Ceiling for an escalated challenge cooldown (2h → 4h → 8h → 16h → 24h).
  static const Duration maxChallengeCooldown = Duration(hours: 24);

  /// Short pause for AUTH failures ([PushbackReason.isAuthFailure], i.e.
  /// `login_required`): the SESSION is invalid, not the automation budget, so
  /// the escalating ladder above is the wrong tool — waiting hours changes
  /// nothing because the session is still dead at the end. This is only long
  /// enough to stop a broken session from being retried in a tight loop; the
  /// real remedy is re-login, which clears it instantly ([onSessionRefreshed]),
  /// as does a successful recovery probe.
  static const Duration authCooldown = Duration(minutes: 10);

  /// Clean-time window that resets the backoff level to 0 (base 2 h again).
  /// "Clean" is measured from the instant the previous cooldown LIFTED — not
  /// from when it was tripped — so the mandatory cooldown itself can never
  /// consume the window. (Measuring from the trip made the ladder self-defeat
  /// at its own cap: a 24 h cooldown guaranteed the next possible trip was
  /// ≥ 24 h after the last one, so level 4 always reset instead of pinning.)
  /// A trip before this much genuinely-unblocked time has passed escalates
  /// instead. Survives app restarts — the level and the cooldown-end instant
  /// are persisted.
  static const Duration escalationResetAfter = Duration(hours: 24);

  /// Minimum spacing between successive authenticated private-API media calls.
  /// Back-to-back bursts are a strong automation signal even well inside the
  /// hourly budget; combined with [callSpacingJitterMaxMs] the effective gap
  /// is ~3–5 s. Enforced in-memory only ([awaitCallSlot]) — a cold app start
  /// is inherently spaced already, so persisting this would add nothing.
  static const Duration minCallSpacing = Duration(seconds: 3);

  /// Upper bound (exclusive of +1) of the random jitter added on top of
  /// [minCallSpacing], so consecutive calls never fire at a fixed cadence —
  /// perfectly regular intervals are themselves an automation tell.
  static const int callSpacingJitterMaxMs = 2000;

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
  static const _sessionFpKey = 'rate_challenge_session_fp';
  // Backoff escalation state. Unlike the cooldown diagnostics above (which
  // live and die with the active cooldown), these must SURVIVE the cooldown
  // clearing — escalation is decided by comparing the next trip against the
  // previous one, which by definition happens after the previous cooldown
  // is gone.
  static const _escalationLevelKey = 'rate_escalation_level';
  static const _lastTripKey = 'rate_last_trip_ts';
  static const _cooldownEndedKey = 'rate_cooldown_ended_ts';

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

  /// Fingerprint (hash + length — NEVER the value) of the Instagram session
  /// that an AUTH-wall cooldown tripped against, or null. Compared against
  /// the session a later probe succeeds with, so field logs can answer
  /// whether `login_required` can occur transiently on a still-valid session
  /// (probe clears with the session UNCHANGED) or only ever means the session
  /// died (cleared after it was REPLACED). Persisted with the other cooldown
  /// diagnostics; the fingerprint is one-way, so persisting/logging it never
  /// exposes the session itself.
  String? _challengeSessionFp;

  /// Epoch-ms of the last recovery-probe attempt, or null if none yet.
  int? _lastProbeMs;

  /// Consecutive-trip escalation level: 0 = first trip (base [challengeCooldown]),
  /// each repeat trip within [escalationResetAfter] doubles the cooldown up to
  /// [maxChallengeCooldown]. Persisted so escalation survives restarts.
  int _escalationLevel = 0;

  /// Epoch-ms of the most recent cooldown trip EVER. Distinct from
  /// [_challengeAtMs] (`rate_challenge_at`), which is cleared with the active
  /// cooldown — this one persists across clears. Used only to distinguish a
  /// first-ever trip (level 0) from a repeat; the escalate-vs-reset decision
  /// itself compares against [_cooldownEndedMs].
  int? _lastTripMs;

  /// Epoch-ms at which the most recent cooldown ENDED (timer expiry uses the
  /// scheduled end, an early/explicit clear uses the clear instant). Persists
  /// across clears: the NEXT trip measures its clean period from here, so
  /// only genuinely-unblocked time counts toward [escalationResetAfter] —
  /// never the mandatory cooldown itself. Null before the first cooldown has
  /// ever ended (including legacy persisted state predating this field).
  int? _cooldownEndedMs;

  /// Epoch-ms before which the next authenticated media call may not fire —
  /// the in-memory reservation cursor for [awaitCallSlot]. Not persisted:
  /// spacing is an anti-burst measure within a running session.
  int _nextCallSlotMs = 0;

  /// Jitter source for [awaitCallSlot].
  final Random _spacingRng = Random();

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
    _challengeSessionFp = prefs.getString(_sessionFpKey);
    _lastProbeMs = prefs.getInt(_lastProbeKey);
    _escalationLevel = prefs.getInt(_escalationLevelKey) ?? 0;
    _lastTripMs = prefs.getInt(_lastTripKey);
    _cooldownEndedMs = prefs.getInt(_cooldownEndedKey);
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
      if (s.needsRelogin) {
        // Auth wall: waiting is NOT the remedy — the session stays invalid
        // however long the pause runs. Point the user at re-login instead.
        throw RateLimitException(
          'Your Instagram session expired — Instagram rejected the saved '
          'login. Waiting won\'t fix this: open Accounts and log in to '
          'Instagram again to restore full downloads.',
        );
      }
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

  /// Delays — never fails — until this call's reserved pacing slot, so
  /// successive authenticated media calls cannot fire back-to-back. Each call
  /// waits at least [minCallSpacing] (plus 0–[callSpacingJitterMaxMs] ms of
  /// random jitter) after the previous one; the first call after an idle gap
  /// proceeds immediately.
  ///
  /// The slot is reserved SYNCHRONOUSLY (before any await) so concurrent
  /// callers queue behind one another instead of all measuring from the same
  /// "now" and bursting together after a single shared wait. Implementation is
  /// a plain timer — no locks, so it cannot deadlock, and being async it never
  /// blocks the UI thread.
  Future<void> awaitCallSlot() async {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final jitterMs = _spacingRng.nextInt(callSpacingJitterMaxMs + 1);
    final slotMs = _nextCallSlotMs > nowMs ? _nextCallSlotMs : nowMs;
    _nextCallSlotMs = slotMs + minCallSpacing.inMilliseconds + jitterMs;
    final waitMs = slotMs - nowMs;
    if (waitMs > 0) {
      debugPrint('[RateGuard] Pacing: waiting ${waitMs}ms before private-API call');
      await Future<void>.delayed(Duration(milliseconds: waitMs));
    }
  }

  /// Trips the hard cooldown after Instagram returns a challenge/checkpoint/429.
  /// [reason] and [statusCode] record WHICH signal matched and what Instagram
  /// returned, so the block can be diagnosed later — including after an app
  /// restart (both are persisted with the cooldown).
  ///
  /// Repeat trips escalate exponentially, doubling the cooldown (2h → 4h →
  /// 8h → 16h, capped at [maxChallengeCooldown]) — coming back at the same
  /// fixed 2 h after every flag is exactly the persistence pattern that turns
  /// a soft flag into a real block. The level resets to the base 2 h only
  /// after [escalationResetAfter] of GENUINELY UNBLOCKED time, measured from
  /// when the previous cooldown lifted ([_cooldownEndedMs]) — never from the
  /// trip itself, so a long cooldown cannot count as its own clean period.
  ///
  /// AUTH failures ([PushbackReason.isAuthFailure]) bypass the ladder
  /// entirely: they get the short [authCooldown] and never touch the
  /// escalation state, because they say nothing about automation pressure —
  /// only that the session died and the user must log in again.
  Future<void> triggerChallengeCooldown(
      {PushbackReason? reason, int? statusCode}) async {
    final now = DateTime.now();
    final nowMs = now.millisecondsSinceEpoch;
    final isAuth = reason?.isAuthFailure ?? false;
    // Drop any fingerprint from a previous cooldown — only an AUTH trip
    // records one (below), and a stale value would mislabel the next clear.
    _challengeSessionFp = null;
    final Duration cooldown;
    if (isAuth) {
      // Session rejected — an authentication problem, not automation
      // pushback. Short anti-hammer pause only; the ladder's level and
      // clean-time clock stay untouched. (The session fingerprint for this
      // trip is captured below, AFTER the block state is written.)
      cooldown = authCooldown;
    } else {
      if (_lastTripMs == null) {
        _escalationLevel = 0; // first trip ever — base cooldown
      } else {
        // Clean time runs from the previous cooldown's END. Because trips are
        // gated by assertCanCall(), a new trip can only happen after that end,
        // so this is always ≥ 0 — and, unlike measuring from the trip, it is
        // independent of the cooldown's own length: even the 24 h cap cannot
        // satisfy the reset window by itself. Legacy state persisted before
        // _cooldownEndedMs existed falls back to the old trip-time comparison
        // for this one decision, then self-heals.
        final cleanSinceMs = _cooldownEndedMs ?? _lastTripMs!;
        if (nowMs - cleanSinceMs >= escalationResetAfter.inMilliseconds) {
          _escalationLevel = 0; // a real clean day since the block lifted — reset
        } else {
          _escalationLevel++; // re-flagged too soon after recovering — escalate
        }
      }
      cooldown = _cooldownForLevel(_escalationLevel);
      _lastTripMs = nowMs;
    }
    // The block state is written SYNCHRONOUSLY — everything from the top of
    // this method to here contains no await (same pattern as awaitCallSlot's
    // slot reservation), so once a trip begins no other task in the event
    // loop can observe "not blocked". An await before these writes would open
    // a window during which a concurrent caller's assertCanCall() still sees
    // _challengeUntilMs == null and slips another authenticated request
    // through to Instagram exactly when the block should already be in force.
    _challengeUntilMs = now.add(cooldown).millisecondsSinceEpoch;
    _challengeReason = reason;
    _challengeHttpStatus = statusCode;
    _challengeAtMs = nowMs;
    debugPrint('[RateGuard] Cooldown STARTED: '
        'reason=${reason?.code ?? 'unknown'} http=${statusCode ?? '-'} '
        '${isAuth ? 'auth-wall duration=${cooldown.inMinutes}min' : 'level=$_escalationLevel duration=${cooldown.inHours}h'} '
        'until=${now.add(cooldown)}');
    _recompute();
    if (isAuth) {
      // Fingerprint (never the value) the session this auth wall tripped
      // against, so a later probe success can log whether the wall cleared on
      // the SAME session (login_required was transient) or only after the
      // user replaced it. Captured AFTER the block state above so the await
      // inside getSessionId can never delay the block taking effect.
      // Best-effort: a read failure just loses the log distinction, never
      // the cooldown itself.
      String? fp;
      try {
        final sid =
            await SessionService.getSessionId(LoginPlatform.instagram);
        fp = sid == null ? null : sessionFingerprint(sid);
      } catch (_) {
        fp = null;
      }
      // Record it only if the cooldown set above is still active — a
      // concurrent clear during the await already dropped the metadata, and
      // resurrecting the fingerprint would persist it with no cooldown.
      if (_challengeUntilMs != null) _challengeSessionFp = fp;
    }
    await _persist();
  }

  /// Escalated cooldown duration: [challengeCooldown] × 2^level, capped at
  /// [maxChallengeCooldown] (2h, 4h, 8h, 16h, 24h, 24h, …).
  static Duration _cooldownForLevel(int level) {
    var ms = challengeCooldown.inMilliseconds;
    for (var i = 0; i < level; i++) {
      ms *= 2;
      if (ms >= maxChallengeCooldown.inMilliseconds) {
        return maxChallengeCooldown;
      }
    }
    return Duration(milliseconds: ms);
  }

  /// Re-evaluates the window (used by the banner's 1 s ticker so the budget
  /// recovers and any cooldown clears on screen without a manual refresh).
  void refresh() => _recompute();

  /// Lifts an active challenge cooldown immediately. [early] marks the lift
  /// as evidence-based recovery (a successful [maybeReprobe] or a clean
  /// authenticated call, see [noteAuthenticatedSuccess]) rather than the
  /// fixed timer expiring, which sets the one-shot [consumeEarlyRecovery] flag
  /// the UI uses to show a reminder. [cause] overrides the default log label
  /// so field logs show WHICH evidence lifted the block.
  Future<void> clearChallengeCooldown({bool early = false, String? cause}) async {
    if (_challengeUntilMs == null) return; // nothing to clear
    // Distinguish evidence-based early recovery (probe succeeded) from an
    // explicit clear, so field logs show whether auto-recovery actually works.
    debugPrint('[RateGuard] Cooldown CLEARED '
        '(${cause ?? (early ? 'early — recovery probe succeeded' : 'explicit clear')}): '
        'was reason=${_challengeReason?.code ?? 'unknown'} '
        'http=${_challengeHttpStatus ?? '-'} tripped=${_trippedAtString()}');
    // The clean period toward an escalation reset starts NOW — the cooldown
    // was lifted early, so unblocked time genuinely begins at this instant.
    // Auth-wall cooldowns live outside the ladder entirely (they never bumped
    // its state on trip), so clearing one must not move its clock either.
    if (!(_challengeReason?.isAuthFailure ?? false)) {
      _cooldownEndedMs = DateTime.now().millisecondsSinceEpoch;
    }
    _challengeUntilMs = null;
    _clearChallengeMeta();
    if (early) _earlyRecoveryPending = true;
    _recompute();
    await _persist();
  }

  /// Call after any SUCCESSFUL authenticated call to `i.instagram.com` — a
  /// clean response is definitional proof the premise of any active block is
  /// gone (stronger evidence than the synthetic probe, which hits a different
  /// endpoint). Clears an active challenge cooldown — including the
  /// `login_required` auth state, which a working authenticated call directly
  /// disproves. Idempotent no-op when nothing is set.
  Future<void> noteAuthenticatedSuccess() async {
    if (_challengeUntilMs == null) return; // nothing to clear — common case
    debugPrint('[RateGuard] Cleared by successful authenticated call');
    await clearChallengeCooldown(
        early: true, cause: 'successful authenticated call');
  }

  /// Call after a NEW Instagram session is successfully captured (login flow).
  ///
  /// A fresh session unconditionally invalidates the premise of an AUTH-wall
  /// cooldown (`login_required` — field-verified: the old behaviour let a 2 h
  /// cooldown survive a re-login, refusing the private API on a perfectly
  /// valid session), so that state is cleared outright.
  ///
  /// Genuine throttle/automation cooldowns (429 / please_wait / checkpoint /
  /// challenge) are NOT blind-cleared and the escalation ladder is left
  /// untouched: a fresh cookie does not disprove a 429 — the flag is on the
  /// account/device pressure, not the session. Instead this fires an
  /// immediate evidence-based reprobe ([maybeReprobe] `force: true`, which
  /// fails closed and is ladder-neutral) and lets the result decide.
  Future<void> onSessionRefreshed() async {
    if (_challengeUntilMs == null) return; // no active cooldown — nothing to do
    if (_challengeReason?.isAuthFailure ?? false) {
      debugPrint('[RateGuard] Cooldown CLEARED (new session captured — '
          'auth wall disproven): was reason=${_challengeReason?.code} '
          'http=${_challengeHttpStatus ?? '-'} tripped=${_trippedAtString()}');
      _challengeUntilMs = null;
      _clearChallengeMeta();
      _recompute();
      await _persist();
      return;
    }
    // Throttle (or unknown-reason) cooldown: probe instead of clearing.
    // Fire-and-forget so the login flow isn't held hostage by a network call;
    // an eventual probe success clears via clearChallengeCooldown(early:true).
    debugPrint('[RateGuard] New session captured during a '
        '${_challengeReason?.code ?? 'unknown'} cooldown — NOT clearing '
        '(a fresh cookie does not disprove throttling); forcing a reprobe');
    unawaited(maybeReprobe(force: true));
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
  /// lifted by a clean response. Ladder-neutral by construction: a failed
  /// probe never calls [triggerChallengeCooldown], so probing can never
  /// deepen the very block it is checking.
  ///
  /// Runs for EVERY challenge-cooldown flavour — throttle/automation walls
  /// AND the `login_required` auth state — using the currently stored cookie.
  /// A probe success while in the auth state clears it, and logs whether the
  /// session was UNCHANGED since the wall tripped (login_required was
  /// transient on a still-valid session) or REPLACED by a re-login in the
  /// meantime — compared by fingerprint only, never the value.
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

    // Reserve the probe slot SYNCHRONOUSLY — before any await — mirroring
    // awaitCallSlot's reservation pattern. Otherwise two concurrent callers
    // (the home-screen 1 s ticker racing a probe-then-proceed fetch) could
    // both pass the interval check above before either records the attempt,
    // firing TWO real probes in one interval. Reserving up front also keeps
    // a later crash or timeout counted against the min-interval — the
    // guarantee is "at most one probe per interval attempted", not "per
    // interval succeeded".
    final prevProbeMs = _lastProbeMs;
    _lastProbeMs = now;

    final sessionId =
        await SessionService.getSessionId(LoginPlatform.instagram);
    if (sessionId == null) {
      // No probe was actually attempted — roll the reservation back so a
      // missing session doesn't lock probing out for a full interval. Only
      // rolled back while OUR reservation is still the latest one: a
      // concurrent force-caller may have re-reserved during the await, and
      // its slot must survive (so the rollback can never reopen the race).
      if (_lastProbeMs == now) _lastProbeMs = prevProbeMs;
      return false; // can't probe without a session
    }

    // Persist the reservation made above BEFORE the network call (the
    // in-memory write already guards concurrent callers in this isolate;
    // persisting makes it survive a restart mid-probe).
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
      // For an AUTH wall, record whether the session the probe just succeeded
      // with is the SAME one the wall tripped against — answered by
      // fingerprint (hash + length, never the value). UNCHANGED means
      // login_required occurred transiently on a still-valid session;
      // REPLACED means a re-login happened in between. Logged BEFORE the
      // clear because clearing drops the recorded fingerprint with the rest
      // of the cooldown metadata.
      if (_challengeReason?.isAuthFailure ?? false) {
        final trippedFp = _challengeSessionFp;
        final probeFp = sessionFingerprint(sessionId);
        final verdict = trippedFp == null
            ? 'UNKNOWN (no fingerprint recorded at trip)'
            : (probeFp == trippedFp ? 'UNCHANGED' : 'REPLACED');
        debugPrint('[RateGuard] AUTH cleared — session $verdict '
            '(fingerprint ${trippedFp ?? '-'} → $probeFp)');
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
      // Clean period starts at the SCHEDULED end, not at whenever _recompute
      // happened to notice — the account was unblocked from that instant even
      // if the app sat closed past it, and that idle time is genuinely clean.
      // Auth-wall cooldowns are outside the ladder — don't move its clock.
      if (!(_challengeReason?.isAuthFailure ?? false)) {
        _cooldownEndedMs = _challengeUntilMs;
      }
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
    _challengeSessionFp = null;
  }

  /// One-way fingerprint of a session value for log-only comparison: a short
  /// polynomial hash plus the length (e.g. `a3b2c1/43ch`). NEVER the session
  /// itself, and not reversible — safe to persist and to print. Two equal
  /// fingerprints ⇒ same session for all practical logging purposes; the
  /// value cannot be recovered from it.
  static String sessionFingerprint(String sessionId) {
    var h = 0;
    for (final c in sessionId.codeUnits) {
      h = ((h * 31) + c) & 0xFFFFFF;
    }
    return '${h.toRadixString(16).padLeft(6, '0')}/${sessionId.length}ch';
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
    // Backoff escalation state — outlives any individual cooldown by design
    // (see the key comments). A stale level is harmless: the reset-vs-escalate
    // decision at the next trip compares against _cooldownEndedMs anyway.
    // The null branches keep the persisted state consistent with memory: any
    // future path that nulls a ladder field must not have a restart resurrect
    // the old value. (onSessionRefreshed used to blind-reset the ladder here;
    // it no longer does — throttle history now survives a re-login.)
    await prefs.setInt(_escalationLevelKey, _escalationLevel);
    if (_lastTripMs != null) {
      await prefs.setInt(_lastTripKey, _lastTripMs!);
    } else {
      await prefs.remove(_lastTripKey);
    }
    if (_cooldownEndedMs != null) {
      await prefs.setInt(_cooldownEndedKey, _cooldownEndedMs!);
    } else {
      await prefs.remove(_cooldownEndedKey);
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
    // One-way session fingerprint (hash+length) — not a secret; see
    // sessionFingerprint. Lives and dies with the auth-wall cooldown.
    if (_challengeSessionFp != null) {
      await prefs.setString(_sessionFpKey, _challengeSessionFp!);
    } else {
      await prefs.remove(_sessionFpKey);
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

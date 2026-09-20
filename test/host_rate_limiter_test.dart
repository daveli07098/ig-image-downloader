import 'package:flutter_test/flutter_test.dart';
import 'package:ig_downloader/services/host_rate_limiter.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A small mutable clock, advanced explicitly by tests so nothing here ever
/// sleeps for real. Matches the injectable-clock/injectable-delay pattern
/// [LihkgDownloaderService]'s own tests already use for `delay`.
class _FakeClock {
  DateTime now = DateTime(2026, 1, 1);
  DateTime call() => now;
  void advance(Duration d) => now = now.add(d);
}

/// Records every delay requested instead of actually waiting. Deliberately
/// does NOT advance the fake clock — the clock only moves when a test calls
/// [_FakeClock.advance] explicitly, so a burst of concurrent callers is
/// exercised at a single fixed instant (real "sleeping" doesn't rewind time
/// for a synchronous reservation, and conflating the two would corrupt the
/// very race window these tests are trying to exercise).
class _FakeDelay {
  final List<Duration> requested = [];

  Future<void> call(Duration d) async {
    requested.add(d);
  }
}

const _host = 'lihkg.com';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('HostRateLimiter — cooldown', () {
    test('cooldownRemaining is null before any throttle', () async {
      final limiter = HostRateLimiter(now: _FakeClock().call);
      await limiter.init();
      expect(limiter.cooldownRemaining(_host), isNull);
    });

    test('noteThrottled with a Retry-After sets a matching cooldown',
        () async {
      final clock = _FakeClock();
      final limiter = HostRateLimiter(now: clock.call);

      await limiter.noteThrottled(_host, retryAfter: const Duration(seconds: 60));

      final remaining = limiter.cooldownRemaining(_host);
      expect(remaining, isNotNull);
      expect(remaining!.inSeconds, 60);
    });

    test('cooldown counts down as the clock advances, and expires', () async {
      final clock = _FakeClock();
      final limiter = HostRateLimiter(now: clock.call);
      await limiter.noteThrottled(_host, retryAfter: const Duration(seconds: 10));

      clock.advance(const Duration(seconds: 4));
      expect(limiter.cooldownRemaining(_host)!.inSeconds, 6);

      clock.advance(const Duration(seconds: 10));
      expect(limiter.cooldownRemaining(_host), isNull);
    });

    test('a later, shorter Retry-After never shrinks an active cooldown',
        () async {
      final clock = _FakeClock();
      final limiter = HostRateLimiter(now: clock.call);
      await limiter.noteThrottled(_host, retryAfter: const Duration(seconds: 60));
      await limiter.noteThrottled(_host, retryAfter: const Duration(seconds: 5));

      expect(limiter.cooldownRemaining(_host)!.inSeconds, 60);
    });

    test('a pathological Retry-After is capped at HostRateLimiter.maxCooldown',
        () async {
      final clock = _FakeClock();
      final limiter = HostRateLimiter(now: clock.call);
      await limiter.noteThrottled(_host,
          retryAfter: const Duration(hours: 24));

      expect(limiter.cooldownRemaining(_host), HostRateLimiter.maxCooldown);
    });

    test('missing Retry-After falls back to HostRateLimiter.defaultCooldown',
        () async {
      final clock = _FakeClock();
      final limiter = HostRateLimiter(now: clock.call);
      await limiter.noteThrottled(_host);

      expect(limiter.cooldownRemaining(_host), HostRateLimiter.defaultCooldown);
    });

    test(
        'persists across a fresh limiter instance (survives an app restart)',
        () async {
      final clockA = _FakeClock();
      final limiterA = HostRateLimiter(now: clockA.call);
      await limiterA.noteThrottled(_host, retryAfter: const Duration(seconds: 45));

      // A brand new instance, as if the app had been restarted — same wall
      // clock (mocked SharedPreferences store is what's shared, not the
      // limiter object).
      final clockB = _FakeClock();
      final limiterB = HostRateLimiter(now: clockB.call);
      await limiterB.init();

      final remaining = limiterB.cooldownRemaining(_host);
      expect(remaining, isNotNull);
      expect(remaining!.inSeconds, 45);
    });
  });

  group('HostRateLimiter — response cache', () {
    test('a stored value is returned by cached() before its TTL', () {
      final clock = _FakeClock();
      final limiter = HostRateLimiter(now: clock.call);

      limiter.store('k', {'a': 1});
      clock.advance(const Duration(minutes: 14));

      expect(limiter.cached<Map<String, int>>('k'), {'a': 1});
    });

    test('an entry expires after its TTL and is evicted on read', () {
      final clock = _FakeClock();
      final limiter = HostRateLimiter(now: clock.call);

      limiter.store('k', 'v', ttl: const Duration(minutes: 15));
      clock.advance(const Duration(minutes: 15, seconds: 1));

      expect(limiter.cached<String>('k'), isNull);
    });

    test('bounded at 50 entries — the oldest is evicted first', () {
      final clock = _FakeClock();
      final limiter = HostRateLimiter(now: clock.call);

      for (var i = 0; i < HostRateLimiter.maxCacheEntries; i++) {
        limiter.store('k$i', i);
      }
      // One more pushes the total past the bound.
      limiter.store('kNew', 999);

      expect(limiter.cached<int>('k0'), isNull,
          reason: 'the first-ever inserted entry should have been evicted');
      expect(limiter.cached<int>('kNew'), 999);
      expect(
          limiter.cached<int>('k${HostRateLimiter.maxCacheEntries - 1}'), 49);
    });
  });

  group('HostRateLimiter — token bucket', () {
    test(
        'the 21st request inside the 60s window waits, and reservation '
        'happens synchronously so a concurrent burst never oversubscribes',
        () async {
      final clock = _FakeClock();
      final delay = _FakeDelay();
      final limiter = HostRateLimiter(now: clock.call, delay: delay.call);

      // Fire a burst of 25 concurrent callers WITHOUT awaiting individually
      // — if the reservation weren't synchronous, several of these could
      // all observe "budget available" and all pass with zero wait.
      final futures = [
        for (var i = 0; i < 25; i++) limiter.awaitSlot(_host),
      ];
      await Future.wait(futures);

      // awaitSlot only ever calls the injected delay when it actually has to
      // wait (a zero-wait pass returns immediately without touching it), so
      // `requested` holds exactly the overflow calls.
      expect(delay.requested, hasLength(5),
          reason: 'exactly 5 of the 25 should have to wait at all');
      expect(delay.requested, everyElement(HostRateLimiter.window),
          reason: 'all 20 budget-consuming slots were reserved at the same '
              'instant, so each overflow request waits the full window');
    });

    test('capacity frees up once the window has elapsed', () async {
      final clock = _FakeClock();
      final delay = _FakeDelay();
      final limiter = HostRateLimiter(now: clock.call, delay: delay.call);

      for (var i = 0; i < HostRateLimiter.maxRequestsPerWindow; i++) {
        await limiter.awaitSlot(_host);
      }
      // Full budget consumed with no waiting yet — awaitSlot only calls the
      // injected delay when it actually has to wait.
      expect(delay.requested, isEmpty);

      clock.advance(HostRateLimiter.window + const Duration(seconds: 1));

      await limiter.awaitSlot(_host);
      expect(delay.requested, isEmpty,
          reason: 'the whole first batch has aged out of the window, so '
              'this next request passes immediately with no wait');
    });
  });

  group('HostRateLimiter — adaptive pacing', () {
    test('pace() returns the base delay unchanged with no history', () {
      final limiter = HostRateLimiter(now: _FakeClock().call);
      const base = Duration(milliseconds: 900);
      expect(limiter.pace(_host, base), base);
    });

    test('multiplier doubles after a throttle, capped at x4', () async {
      final limiter = HostRateLimiter(now: _FakeClock().call);
      const base = Duration(milliseconds: 900);

      await limiter.noteThrottled(_host, retryAfter: const Duration(seconds: 1));
      expect(limiter.pace(_host, base), base * 2);

      await limiter.noteThrottled(_host, retryAfter: const Duration(seconds: 1));
      expect(limiter.pace(_host, base), base * 4);

      await limiter.noteThrottled(_host, retryAfter: const Duration(seconds: 1));
      expect(limiter.pace(_host, base), base * 4,
          reason: 'capped at x4, does not keep climbing');
    });

    test('multiplier steps back down one notch per clean fetch', () async {
      final limiter = HostRateLimiter(now: _FakeClock().call);
      const base = Duration(milliseconds: 900);

      await limiter.noteThrottled(_host, retryAfter: const Duration(seconds: 1));
      await limiter.noteThrottled(_host, retryAfter: const Duration(seconds: 1));
      expect(limiter.pace(_host, base), base * 4);

      await limiter.noteCleanFetch(_host);
      expect(limiter.pace(_host, base), base * 2);

      await limiter.noteCleanFetch(_host);
      expect(limiter.pace(_host, base), base);

      await limiter.noteCleanFetch(_host);
      expect(limiter.pace(_host, base), base,
          reason: 'floor is x1, does not go below it');
    });

    test('pacing multiplier persists across a fresh limiter instance',
        () async {
      final limiterA = HostRateLimiter(now: _FakeClock().call);
      await limiterA.noteThrottled(_host, retryAfter: const Duration(seconds: 1));

      final limiterB = HostRateLimiter(now: _FakeClock().call);
      await limiterB.init();

      const base = Duration(milliseconds: 900);
      expect(limiterB.pace(_host, base), base * 2);
    });
  });
}

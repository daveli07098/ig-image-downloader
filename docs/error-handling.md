# Error Handling & Rate-Limit Mechanism

> Last updated: 2026-05-19

This document describes how the app classifies download errors, what each
visual indicator means, and the realistic limits that drive the cooldown
timers.

---

## Error classification

Every failed download is fed through `_classifyError()` in
`lib/screens/selection_screen.dart`. The raw error string is matched against
known patterns in priority order:

| Priority | Matches | Tier (`_ErrorKind`) |
|---|---|---|
| 1 | string contains `"redirect"` | `redirectLoop` |
| 2 | contains `"429"`, `"rate"`, or (`"400"` + `"wait"`/`"many"`) | `apiRateLimit` |
| 3 | everything else | `generic` |

Redirect errors take priority because the string `"Redirect limit exceeded"`
would otherwise be caught by the `"400"` branch (both contain substrings that
overlap), and they require a completely different user action.

---

## Visual indicators

Each tier renders its own indicator chip, banner, and countdown:

### `redirectLoop` — Redirect loop (10-hop limit)

- **Icon**: `sync_problem`
- **Chip label**: "Redirect loop (10-hop limit)"
- **Banner**: "Instagram redirected more than 10 times — your session may have
  expired. Try re-logging in from the Accounts tab, then retry."
- **Cooldown**: **2 minutes** (120 s)

#### What this means

Dio is configured with `maxRedirects: 10`. If a URL chains more than 10
HTTP 3xx responses without reaching a final page, Dio throws
`RedirectException: Redirect limit exceeded`.

**This is NOT an API rate limit.** It is a per-request hop counter. The most
common causes on Instagram:

| Cause | Explanation |
|---|---|
| Session cookie on embed URL | `embed/captioned/` is a public iframe endpoint. Sending `sessionid` causes IG to redirect toward an "authenticated" variant. Without the full cookie suite (`csrftoken`, `mid`, `ds_user_id`) the redirect never converges. **Fixed in v1.0.0.46: embed is now fetched without any cookie.** |
| Expired session | IG redirects authenticated requests to `/accounts/login/`, which redirects back to the original URL — infinite loop. Re-logging in resolves this. |
| Post deleted or made private | IG can redirect post URLs to the profile or to login when the content is no longer accessible. |

The 2-minute cooldown gives time to open the Accounts tab and refresh the
session before retrying.

---

### `apiRateLimit` — IG API rate limit (~200/hr)

- **Icon**: `timer`
- **Chip label**: "IG API rate limit (~200/hr)"
- **Banner**: "Instagram limits private API calls to ~200 per hour per
  session. Waiting lets the hourly quota reset before retrying."
- **Cooldown**: **5 minutes** (300 s)

#### What this means

Strategy 0 (`i.instagram.com/api/v1/media/<id>/info/`) is Instagram's
**private mobile API** — the same endpoint used by the Instagram and Threads
apps. Instagram does not publish an official rate limit, but observed behaviour
points to roughly **200 requests per session per rolling hour**.

| Indicator in response | Meaning |
|---|---|
| HTTP 400 from `i.instagram.com` | Request rejected — could be bad format OR throttling |
| HTTP 429 | Explicit rate-limit response (rare on private API, more common on Graph API) |
| `"rate"` / `"wait"` / `"many"` in error body | Instagram's throttle message |

The 5-minute cooldown is a practical back-off, not the full hourly reset.
After 5 minutes, retrying typically succeeds if the burst was moderate. If
the quota is fully exhausted (200+ calls in one hour), subsequent retries
will continue to fail until the rolling window clears (~60 minutes from the
first throttled call).

**Safe usage**: The private API is called at most once per user-initiated
download. Normal usage (a few dozen downloads per session) stays well within
the limit. Rapid automated retries can exhaust the quota.

---

### `generic` — Download error

- **Icon**: `error_outline`
- **Chip label**: "Download error"
- **Banner**: none
- **Cooldown**: **30 seconds** (30 s)

Covers network timeouts, HTTP 404 / 403, JSON parse failures, and any other
error that does not match the two tiers above.

---

## Countdown format

| Remaining | Display in ring | Label below ring |
|---|---|---|
| ≥ 60 s | `Xm` (minutes) | `Retry in Xm YYs` |
| < 60 s | raw seconds | `Retry in Xs` |

---

## Instagram download strategy waterfall

Understanding the strategy order helps interpret which limit was hit:

```
Strategy 0  │ i.instagram.com private API
            │ Requires: sessionId cookie (IG login)
            │ Returns:  full carousel, original resolution
            │ Limit:    ~200 req/hr per session
            ↓ (fails with HTTP 400/429 → fall through)

Strategy A  │ /embed/captioned/ page
            │ Requires: nothing — public iframe endpoint, NO cookie sent
            │ Returns:  __additionalDataLoaded JSON (single/carousel)
            │ Limit:    no auth, uses 10-hop redirect budget per request
            ↓ (no JSON found, or redirect loop → fall through)

Strategy B  │ Main post page HTML (with session cookie if available)
            │ Requires: public post OR valid session for private
            │ Returns:  og:image / SharedData JSON
            │ Limit:    10-hop redirect budget; session redirect loops
            │           → rethrown as human-readable login-expired error
```

---

## Facebook download strategy waterfall

```
Strategy 0  │ Bot UA (facebookexternalhit) OG tag fetch
            │ Returns:  1 og:image (always), 1 og:video if video post
            ↓

Strategy A  │ JSON extraction on bot UA HTML
            │ Returns:  any scontent/fbcdn "uri"/"src"/"url" matches
            ↓

Strategy B  │ mbasic.facebook.com fetch
            │ Phase 1: photo-link-anchored (<a href="/photo…">) → trusted
            │ Phase 2: broad <img> scan  (only if phase1Count == 0)
            ↓

Strategy C  │ Auth carousel supplement (desktop Chrome UA + FB cookies)
            │ Triggers when: phase1Count == 0  OR  total images < 5
            │ Validation: _nc_cat CDN bucket fingerprint from first image
            │ Returns:  full carousel image set from React SPA JSON
```

---

## Threads download strategy waterfall

```
Strategy 0  │ i.instagram.com private API (IG or Threads app-id)
            │ Requires: igSessionId or threadsSessionId
            │ Returns:  full carousel
            ↓ (HTTP 400 → fall through)

Strategy A  │ Desktop Chrome UA → threads.com HTML
            │ A1: __NEXT_DATA__ SSR JSON (carousel_media array)
            │ A2: CDN URL regex — t51.2885-15 (images), t50.2886-16 (video)
            │     Both patterns use [^"]+ to match JSON-encoded https:\/\/
            │     Broader scontent/cdninstagram fallback if CDN path changed
            ↓ (login wall or empty SSR → fall through)

Strategy B  │ facebookexternalhit bot UA → OG tags
            │ Returns:  1 og:image (always) — Threads never puts all
            │           carousel images in OG meta
```

---

## Version history of this mechanism

| Version | Change |
|---|---|
| v1.0.0.43 | Added 60 s countdown timer to the error view |
| v1.0.0.44 | Fixed Threads CDN regex (`[^"\\]+` → `[^"]+`, `https://` → `https`) |
| v1.0.0.45 | Per-error indicator chip + banner + typed cooldown (redirect: 2 min, rate: 5 min, generic: 30 s) |
| v1.0.0.45 | FB carousel: `phase1Count` + `_nc_cat` fingerprint validation |
| v1.0.0.46 | IG embed: removed session cookie to prevent redirect loop |

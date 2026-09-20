# Changelog

## [2026-09-20] — Session: LIHKG support + share-sheet URL extraction

### Fixed
- fix(share): a share whose text was not JUST a URL was dropped in silence — share sheets send the post title followed by the link, and both the share provider and the paste handler required the text to *start with* a scheme. Sharing "<title> <link>" produced no fetch attempt at all, on every platform ([4f2a4e9])
- fix(lihkg): LIHKG never worked — `LihkgDownloaderService` existed and its API approach was correct, but `downloader_service.dart` never imported or called it, so every link fell through to the generic article scraper and hit LIHKG's empty React shell ([4f2a4e9])
- fix(lihkg): 429/503 is now reported honestly ("LIHKG is rate-limiting requests right now") instead of the misleading "no images found", with 2s/4s/8s jittered backoff, `Retry-After` honoured, and images from earlier pages kept ([4f2a4e9], [b8286e8])
- fix(ui): the paste hint truncated to "Paste Instagram…" though the app handles Threads, Facebook, Tumblr and LIHKG too — now "Paste any post or thread link…" ([b8286e8])

### Added
- feat(lihkg): `lih.kg/<id>` short links. Hosts are parsed with `Uri`, not substring-matched, because post markup carries `i.lih.kg/thumbnail?u=…` (the thumbnail proxy) which must never be mistaken for a thread link nor downloaded in place of the full image ([4f2a4e9])
- feat(share): `shared_text_url.extractFirstUrl` pulls the first link out of shared or pasted text, preferring a URL a platform matcher recognises and trimming trailing ASCII/CJK punctuation without eating a trailing slash or query string ([4f2a4e9])
- test: suites for URL extraction, the share provider's handler, and LIHKG parsing/pagination/rate-limit handling ([4f2a4e9])

### Known
- Pages are spaced 700-1200 ms apart and the 10-page bound stays (logged when it truncates), so a long thread yields a bounded set of images.
- Rapid repeated fetches from one IP will still trip LIHKG's rate limit; the app now says so plainly rather than claiming the thread is empty.

## [2026-09-14] — Session: Facebook /posts/ photo albums

### Fixed
- fix(facebook): `/posts/<id>/` photo albums returned an unrelated Reel plus one thumbnail — Facebook serves `og:type=video.other` for photo posts, which sent them down the video path where an unscoped `progressive_url` regex matched a Reels-rail video on the logged-in page; mbasic (the old photo enumerator) is login-walled even with the cookie ([2849a0e])

### Added
- feat(facebook): scoped story-JSON parser — decodes the `data-sjs` block containing `"post_id":"<id>"`, takes `all_subattachments.nodes[].media.viewer_image` (full size) with `image` and the anonymous `lookaside.fbsbx.com` crawler URL as fallbacks; video classified only from the post's own attachments; username from `actors[0].url`; date from `creation_time` ([2849a0e])
- test: hand-built Facebook story fixture with synthetic decoys (no session page content) ([2849a0e])

### Changed
- Facebook filenames/ledger keys: `facebook_*` → `<page>_*` (e.g. `HKACGer_*`). Previously downloaded Facebook posts appear as new once.

### Known
- Facebook still has no RateGuard; `[Home] FB username resolve: 400` on cold start is unchanged.
- No real `/posts/` VIDEO fixture exists yet — that branch is covered by a synthetic test only.

## [2026-09-07] — Session: Threads + Tumblr video/image extraction

### Added
- feat(tumblr): parse the `___INITIAL_STATE___` NPF JSON as the primary Tumblr path — community-labelled posts return an empty shell (no `<img>`, no `og:image`) that DOM scraping can never see; images pick the `hasOriginalDimensions` variant, videos use `media.url` with the poster as thumbnail, reblogs fall back to `trail[].content` ([51c889d])
- feat(generic): `og:video` and `<video>/<source>` extraction in the generic article scraper, which had no video handling at all ([51c889d])
- feat(threads): parse `data-sjs` post JSON fetched with a Googlebot UA — the only UA Meta server-renders it for; scoped to the node whose `code` matches the shortcode ([4e8e56c])
- feat(threads): resolve `/share/<code>` and `/t/<code>` links via `realUri`; login-gated posts resolve through the threads.com cookie or the in-app WebView (shared CookieManager) before the authenticated API ([4e8e56c])
- feat(webview): `fetchRenderedHtmlWithUrl` returns the WebView's final URL alongside the HTML ([4e8e56c])
- test: fixtures + unit tests for Tumblr NPF/DOM parsing, Threads data-sjs scoping, junk filter, and extension/MIME derivation ([51c889d], [4e8e56c])

### Fixed
- fix(tumblr): video posts produced only the poster frame as a "photo" ([51c889d])
- fix(tumblr): real blog name instead of `tumblr_com`; dedupe key strips the `/sWxH[_fN]/` size segment so a poster and its video, or one photo at two sizes, no longer save twice ([51c889d])
- fix(tumblr): plain fetch uses `kRealChromeMobileUA` — the hashcash 403 was UA-gated (desktop 403, mobile 200 from the same IP); WebView solver kept as fallback ([51c889d])
- fix(download): saved files keep their real extension/MIME (`.mov/.gif/.png/.webp`) instead of forced `.jpg`/`.mp4`; `.pnj` maps to `.jpg` ([51c889d])
- fix(junk-filter): `alt`-text matching narrowed to avatar/gravatar/favicon so art posts captioned "pixel"/"sprite"/"logo" are kept ([51c889d])
- fix(threads): `/share/` video posts came back as the `og:image` poster with a play badge — `__NEXT_DATA__`, `t50.2886-16`, `t51.2885-15` and `og:video` all verified dead ([4e8e56c])
- fix(threads): the login page's `rsrc.php` logo was downloaded as "the image" for login-gated posts; `error=` redirects and `static.cdninstagram.com` OG images are never items, with a clear "not available without logging in" error ([4e8e56c])
- fix(threads): the `i.instagram.com` fallback was outside RateGuard — same endpoint the Instagram path protects, called unguarded up to 3× per fetch ([4e8e56c])
- fix(threads): quality pickers replace `.first`; mixed carousels keep their photos; `video_versions` presence classifies video when `media_type` is absent ([4e8e56c])
- fix(queue): download-stage failures are now logged, not only shown on a deletable job tile ([4e8e56c])
- fix(threads): the WebView resolution could pick an unrelated post from the logged-in feed when a share link hit the login gate; a post code is now accepted only from the WebView's final URL or canonical tag, gate hits raise the "not available" error, the WebView is reached through SelectionScreen's cancellable callback, and a 45s hard deadline / main-frame error pops it on its own ([516a83e])

### Changed
- Filenames/ledger keys: `tumblr_com_*` → `<blog>_*`, `threads_*` → `<handle>_*`. Previously downloaded Tumblr/Threads posts appear as new once.

### Known
- A normal Threads download now makes zero authenticated calls; the authenticated API runs only for login-gated posts, under RateGuard.
- `[Home] FB username resolve: 400` on every cold start is a speculative `facebook.com/me` call that never persists — unrelated to the shared URL, unfixed.

## [2026-08-18] — Session: Tumblr support, avatar filtering, dedup & IG flag recovery

### Added
- feat(downloader): WebView fallback for pages behind a JavaScript anti-bot challenge. Tumblr post pages are served by Automattic's hashcash gate — HTTP 403 whose body is "Checking your browser… Javascript required", with a SHA-256 proof-of-work POSTed to `/__challenge` and a short-lived `_hcc` cookie — which a plain `Dio.get()` can never satisfy. Such pages are now re-fetched through a real `WebViewController` so the page's own JS solves the challenge, then the rendered DOM is scraped. Stays invisible while polling; if it can't clear within 20s it reveals the WebView so the user can tap "I am human" ([eb8408d])
- feat(downloader): direct media URLs (`.jpg/.jpeg/.png/.webp/.gif/.mp4/.mov`) download as-is instead of being fed to the HTML article parser, which previously tried to parse raw image bytes as a page and failed with "No downloadable images found" ([eb8408d])
- feat(dedup): `download_ledger_service` — a SharedPreferences-backed record of what has been downloaded, keyed on `username + hash(mediaUrl)` and deliberately **date-independent**. Already-downloaded items are filtered out of the selection grid entirely; a fully-filtered post shows "All N items already downloaded" rather than an empty grid, which would be indistinguishable from a failed scrape. Capped at 5000 keys, oldest evicted ([d629342])
- feat(rateguard): the Instagram challenge cooldown can now end early. `maybeReprobe()` makes one lightweight authenticated probe per 5 minutes and clears the block only on a confirmed clean response — failing closed on pushback or any network error. Adds a "Check now" banner action and a reminder SnackBar on early recovery ([dbb819b])

### Fixed
- fix(filters): profile icons and avatars were downloaded as post media from Tumblr and Facebook. Three causes: junk detection inspected only the URL string and discarded the `<img>` element's `class`/`id`/`alt`; the size gate read only the `width`/`height` attributes and **silently no-opped when both were absent** (normal for Tumblr's lazy-loaded markup), so a 32×32 avatar passed ungated; and no content selector matched Tumblr, so the scan scope fell back to the whole `<body>` including the header avatar. Added shared `image_junk_filter`, attribute-aware detection, a size gate that falls back to inline `style` → URL size hints → a `WxH` filename pattern, and Tumblr-aware selectors ([dbb819b])
- fix(dedup): dedup relied on `filenameBase` matching, but that embeds a date and Facebook/Threads/LIHKG stamp `postTimestamp: now` on every fetch — so re-downloading a post on a later day produced a genuine duplicate file. It also only ran at download time, so duplicates still filled the grid. The date-independent ledger fixes both without renaming anything already on disk ([d629342])
- fix(downloader): genuine non-challenge 403s (paywall, geo-block, IP ban) kept their clear "Failed to load page (403)" error instead of having the error page HTML-parsed as content — which could otherwise scrape a branded "access denied" graphic and present it as downloadable media ([eb8408d])
- fix(ui): the media-items provider is now `autoDispose` with a cancellation guard, so a fetch abandoned mid-flight can no longer pop a verification WebView over an unrelated screen ([eb8408d])

### Changed
- refactor(services): extracted the real-Chrome mobile UA into one `kRealChromeMobileUA` constant (was duplicated across `login_screen`, `in_app_browser_screen`); extracted `isPushback()` into `RateGuard` so it is shared rather than duplicated; extracted `MediaItem.hashMediaUrl` so the ledger and `filenameBase` share one hash and cannot drift; collapsed Facebook's four copy-pasted junk blacklists into the shared helper ([eb8408d], [dbb819b], [d629342])
- refactor(ui): the challenge banner now says logged-in requests are *limited* rather than *paused*. The block only ever gated the private-API Dio path — `_fetchIgItems` swallows the rate-limit exception and falls through to HTML-scraping strategies that never consulted `RateGuard`, so public posts kept downloading while the banner claimed otherwise ([dbb819b])

### Changed — Instagram rate-limit strategy (later in the same session)
- fix(instagram): try the cookie-less embed path **before** the private API. Every download previously hit `i.instagram.com` with the session cookie attached first — the exact surface Meta polices for automation — even though Strategy A (`/embed/captioned/`) uses the *identical* `_extractFromSlides`/`_bestImageUrl` extractor and sends no cookie. New order is A (embed) → 0 (private API) → B (main page). Strategy 0 stays **second, not last**, because private-account posts can only be served by it; B goes last because it sets no `postTimestamp` (so `filenameBase` silently stamps today's date) and often degrades username to `unknown`. The Stories branch is untouched — URL-gated and still login-required ([f59abd9])
- feat(rateguard): pace authenticated calls at 3s + 0–2s jitter. They previously fired back-to-back, which is a stronger automation signal than the request volume itself. The slot is reserved synchronously before the await, so concurrent callers queue serially rather than all waking together after one shared delay ([f59abd9])
- feat(rateguard): escalate repeat challenge cooldowns 2h → 4h → 8h → 16h → 24h (capped) instead of a flat 2h ([f59abd9])
- feat(downloader): thin-embed guard — fall through to the private API only on positive evidence that the payload was truncated (Instagram declared more slides than it delivered), never merely because a post legitimately has one image ([f59abd9])
- fix(rateguard): measure the backoff clean period from cooldown **end**, not from the trip. Trips are gated by `assertCanCall()`, so a new trip can only land after the cooldown clears — and with `escalationResetAfter == maxChallengeCooldown` (both 24h), a level-4 trip always satisfied the reset test. The clean window was consumed by the mandatory cooldown itself rather than by good behaviour, so a chronically flagged account cycled 2h→4h→8h→16h→24h→2h forever instead of staying pinned at the cap. Legacy state without the new key falls back to the old comparison once, then self-heals ([6304020])
- fix(downloader): the thin-embed guard escalated on extraction misses, not just truncation — a complete carousel containing an ad slide with no `image_versions2` would hit the private API on every fetch, spending exactly the account risk the reorder exists to avoid ([6304020])
- feat(queue): retain 30 finished jobs in history, up from 10. Active jobs are never pruned; history beyond the old cap was already discarded and cannot be recovered ([2cfc84a])

### Fixed — Instagram auth vs throttling (verified on device)
- fix(rateguard): `login_required` is an **authentication** failure, not automation throttling, and no longer enters the escalating cooldown ladder. Field evidence: a block tripped with `reason=login_required http=403` while the stored session was present but invalidated by Instagram; the user logged out and back in, and **the 2h cooldown survived the re-login** — so the app kept refusing the private API despite a fresh valid session, fell through to Strategy B, and returned 1 item for a genuine 4-slide carousel. Waiting cannot fix a dead cookie. It now gets a 10-minute anti-hammer cooldown, a "Log in" banner action, and auto-clears when a new session is captured ([ed7b854])
- feat(rateguard): a confirmed **Reset** action on the banner, as requested. It deliberately does not reset the escalation ladder, so an override that re-trips still escalates correctly ([ed7b854])
- feat(rateguard): `noteAuthenticatedSuccess()` — any clean authenticated response clears the block. A real success is stronger evidence than a probe against a different endpoint ([8d07b52])
- feat(downloader): **probe-then-proceed** — when Strategy 0 is blocked and the 5-minute floor has elapsed, the probe runs inline and the same request continues into Strategy 0 if it clears, so the recovering request returns full quality instead of the degraded fallback. Deliberately *not* a real trial call: a failed trial re-enters the pushback branch and would bump the app's own escalation ladder (2h→4h→8h) through its own recovery attempts ([8d07b52])
- feat(ui): `FetchResult` + `DegradedReason` — the selection screen now warns when Strategy B served while Strategy 0 was unavailable, naming the cause. Previously this was silent: 1 of 4 carousel images with no error at all. Non-blocking, since one image may be all the user wants ([8d07b52])
- fix(rateguard): a re-login no longer forgives prior 429 escalation history — a fresh cookie does not disprove a rate limit, so throttle cooldowns force a reprobe and let evidence decide, while the auth wall clears outright ([8d07b52])
- fix(rateguard): closed two check-await-write races. `triggerChallengeCooldown` had gained an `await` *before* `_challengeUntilMs` was assigned, so a concurrent `assertCanCall()` could slip another authenticated request through at exactly the moment the block should have taken force; `maybeReprobe` reserved its interval slot only after its await, so two callers could both probe. Both now reserve synchronously, following the pattern `awaitCallSlot()` already used ([742dd11])

### Notes
- The in-app browser is unaffected by the Instagram block by design: it is a WebView against ordinary `www.instagram.com` using the OS cookie jar, with no reference to `RateGuard`, while the block gates only Dio calls to the account-attributed `i.instagram.com` private API.
- **Verified on real traffic this session:** Tumblr downloads succeed through the WebView challenge path; auto-recovery cleared a live `login_required` block via the probe (`Cooldown CLEARED (early — recovery probe succeeded)`); and the private API then returned all 4 carousel slides where Strategy B had returned 1.
- **KNOWN BROKEN — Strategy A is dead.** `/embed/captioned/` no longer contains `window.__additionalDataLoaded` (confirmed on device, both user-agents, every attempt), so the cookie-less path never serves and every Instagram fetch escalates to the authenticated private API. This is the root cause of the flagging; the work above makes it recoverable and visible, not absent. Replacing Strategy A is the highest-value next task.
- Field diagnosis aid: `[IG] Strategy order: …` and `[IG] SERVED BY Strategy A/0/B` now appear in logcat per fetch. If Strategy A serves most downloads, the account is barely being touched; constant escalation to Strategy 0 means the embed path is not carrying its weight and the reorder needs revisiting.
- Still unverified against live traffic: whether `carousel_media_count` is reliably present in real embed payloads (if absent on a truncated carousel the guard fails open, silently yielding fewer slides), and whether the pacing/backoff actually reduce challenge frequency — that is an empirical claim about Meta's detection.
- **Untested on device at time of writing.** All four features pass `flutter analyze` at baseline and compile, but none has been exercised against live traffic. Specifically unverified: whether an invisible WebView keeps executing JS on Android (it may need the manual reveal path), and whether the `accounts/current_user/` probe endpoint behaves as assumed against a live Instagram block.
- CLAUDE.md's storage section is inaccurate: files land in a flat `Download/ig_downloader/` (no dated subfolders), `gal` is declared but never imported (Android uses a native MediaScanner channel), and iOS has no gallery-save step at all.

## [2026-06-23] — Session: v1.1 — login block detection & browser escape hatch

### Added
- feat(login): detect Instagram block / "try again later" / "open the Instagram app" interstitials on the login WebView. On each page load the page text is scanned for known block phrases; when one is found the in-app browser is **kept open** (instead of auto-closing) and a bottom banner explains the block and offers next steps. Context: when this IG account is also signed in from another app, Meta forces a re-verification / password refresh that can't be cleared inside a WebView ([3ba776f])
- feat(login): "Open in browser" button — both an always-available AppBar action and a prominent button in the blocked banner — launches the current page in the real device browser (Chrome) via `url_launcher` `externalApplication`, where the security challenge can actually be completed. Banner also has Retry (reloads login) and Close (leaves with any captured session) ([3ba776f])

- feat(ui): in-app browser to preview platform pages after login. Each logged-in account row in the Accounts sheet has an "open in app" button that opens that platform's site (instagram.com / x.com / facebook.com) inside a new `InAppBrowserScreen` WebView, signed in via the shared session cookies — scroll/preview the feed without leaving the app (real-Chrome UA, web-only nav guard, reload + open-external actions) ([8e4f66a])

### Changed
- refactor(login): a redirect-loop security challenge (`ERR_TOO_MANY_REDIRECTS`) now routes into the same blocked-banner state instead of showing a one-shot dialog and force-closing the screen — the session (if set before the challenge) is still saved, but the user stays in control with the browser escape hatch. `_tryCaptureSession` gained an `autoPop` flag so a session can be saved silently without dismissing the screen while blocked ([3ba776f])
- chore(release): bump to v1.1.0 ([3ba776f]); build v1.1.0.1 adds the in-app browser ([8e4f66a])

### Maintenance
- chore(scripts): `bump-build.sh` now auto-builds + installs on the connected device by default (was gated behind `--build`); logic extracted into reusable `scripts/build-install.sh`, `--no-build` opts out, no device → release APK only ([37cebdd])
- fix(scripts): device detection reads `targetPlatform` (newer Flutter dropped `platformType`), which had caused the build to fall back to apk-only instead of installing ([4416c7a])

## [2026-06-13] — Session: Open author profile feed

### Added
- feat(ui): each download tile now has a second button (person icon) that opens the author's Instagram **profile feed** — `instagram.com/<username>` from `MediaItem.username` — giving the scrollable, newest-first post feed. The existing button still opens the exact post. Instagram exposes no deep link that lands on a post *within* a scrollable feed (and an app can't drive IG to scroll/jump after launch), so this profile entry point — where a recent post sits near the top, one tap into the scrollable feed — is the closest achievable. Profile button shows only for IG media with a known username ([5be1d94])

## [2026-06-13] — Session: Fix dead-page deep link

### Fixed
- fix(deeplink): the "Open post" button opened a blank/dead page because `instagram://media?id=<id>` is effectively deprecated in modern Instagram (and since the launch reported success, the https fallback never ran). Reverted to launching the original https permalink with `externalApplication` — the IG app intercepts it via App Links / Universal Links and shows the post in a scrollable feed under the active account, falling back to the browser when IG isn't installed ([400b954])
- chore: removed the now-unused shortcode→media-id helpers and the `instagram` scheme entries in AndroidManifest `<queries>` / iOS `LSApplicationQueriesSchemes` ([400b954])

### Notes
- The repeated "login reset" was caused by two one-time uninstalls during this session (the manual `flutter install`, then the debug→release keystore switch). With stable release signing now in place, `adb install -r` updates keep accounts/history/settings — login persists across builds.

## [2026-06-13] — Session: Fix Facebook login WebView crash

### Fixed
- fix(login): Facebook login dropped onto a `net::ERR_UNKNOWN_URL_SCHEME` error page because the login page redirects to a native-app handoff custom scheme (`…://login_via_app/?…`) that a WebView can't load. The login WebView had no `onNavigationRequest`; added one that allows only `http`/`https`/`about` and blocks other schemes, keeping the user in the web flow where the session cookie (`c_user`) is captured. Applies to Instagram/X/Facebook ([7c064e5])

## [2026-06-13] — Session: Stable release signing (keep app data across builds)

### Changed
- build(android): release builds are now signed with a dedicated release keystore loaded from `android/key.properties` (gitignored), instead of the debug key. A debug-key signature is volatile — any change (new machine, regenerated `debug.keystore`) forced an uninstall on update, which wiped **all** persisted data: logged-in accounts/sessions, download history (`job_queue_v2`), and settings. With a stable keystore, `adb install -r` performs true in-place updates that keep that data, and the app is Play-Store-ready. Falls back to the debug key when `key.properties` is absent (CI / other devs) ([c4ab4b8])

### Notes
- Download history was already persisted to SharedPreferences and survives app restarts; the data loss on upgrades was caused by uninstall-on-signature-mismatch, not by missing persistence.
- Keystore lives outside the repo at `~/.android-keystores/ig-downloader-release.jks` — **must be backed up**; losing it means no future updates can be signed with the same key.

## [2026-06-13] — Session: Open-post deep link into the Instagram app

### Changed
- feat(deeplink): the "Open original post" button now deep-links straight onto the post inside the Instagram app via `instagram://media?id=<numericId>`, where IG shows the timestamp and the user can scroll to the posts before/after it; falls back to the https link (IG app via app links, else browser) when IG isn't installed or the URL carries no shortcode (stories/unknown). Note: IG exposes no way for a third party to switch the logged-in account, so the post renders under whichever account is active in the IG app ([0fd8637])

### Added
- feat(ig_url_parser): `shortcodeToMediaId` (BigInt decode over IG's URL-safe base64 alphabet) + `instagramAppUri()` builder for post/reel/IGTV URLs ([0fd8637])

### Maintenance
- chore(platform): AndroidManifest `<queries>` + iOS `LSApplicationQueriesSchemes` for the `instagram` scheme so `url_launcher` resolves the deep link on Android 11+ / iOS ([0fd8637])

## [2026-06-13] — Session: Instagram automation-flag avoidance (request budget + cooldown)

### Added
- feat(ratelimit): `RateGuard` service — a persistent rolling-hour budget (80 calls/hr, warn at 60) over the authenticated `i.instagram.com` private API, the metered surface that triggers Instagram's "automated behaviour" flags. Counts every metadata call, blocks once the budget is spent, and persists state so the budget survives app restarts ([7ba952a])
- feat(ratelimit): hard cooldown (2 h) when Instagram pushes back — a 429 or a `checkpoint_required` / `challenge_required` / `login_required` body trips it; the cooldown is persisted so reopening the app can't reset it ([7ba952a])
- feat(ui): heading reminder banner — amber "slow down" as the hourly budget runs low, red with a live countdown when throttled or flagged (open the IG app, clear the prompt, wait); hidden while there's ample budget ([7ba952a])

### Changed
- feat(download): authenticated private-API calls are now gated before they fire; when blocked, public posts still fall back to the cookie-less embed path so downloads keep working without touching the flagged surface ([7ba952a])
- feat(ui): selection-screen error classifier routes the new flag/limit messages to the rate-limit tier (5-min cooldown UI) ([7ba952a])

## [2026-06-13] — Session: v1.0.1 big upgrade (icon, history, background downloads)

### Added
- feat(icon): new app icon — Instagram-style gradient + white download glyph; full Android adaptive + iOS icon set generated via `flutter_launcher_icons` (source art + `scripts/gen_icon.py`)
- feat(ui): "Open original post" button on each download tile — jumps back to the original IG/X/Facebook link in its native app (browser fallback) via `url_launcher`
- feat(download): foreground service (`flutter_foreground_task`) keeps the download queue running with a persistent "Downloading…" notification when the app is backgrounded

### Changed
- feat(history): history now keeps the most recent 10 finished (done/error) jobs regardless of age, instead of pruning everything older than 1 hour

### Fixed
- fix(android): `MainActivity` launch mode `singleTop` → `singleTask` (+ empty `taskAffinity`) so re-shares no longer pile up duplicate app cards in the Recents screen
- fix(download): false "already downloaded — skipped" — downloads now write to a `.part` temp file and atomically rename on success, so a background process-kill no longer leaves a partial file at the final path that gets skipped forever; zero-byte leftovers are re-fetched and empty downloads error instead of reporting success
- fix(queue): no more lost queue items — persistence is now serialised + coalesced (latest state always wins, stale snapshots can't overwrite newer ones) and `remove`/`clearFinished` now persist, so removed/cleared/added jobs stay correct across restarts

### Maintenance
- chore: bump to v1.0.1.0 — build counter now resets to 0 on each minor/sub-version bump
- chore(android): derive a monotonic versionCode from semver in `build.gradle.kts` so the resettable display counter never blocks installs as a downgrade

## [2026-05-29] — Session: Facebook login + IG session reuse for Threads

### Added
- feat(auth): `LoginPlatform.facebook` enum + `fb_cookies` key in `SessionService` ([566ebbe])
- feat(auth): Facebook WebView login screen config (`storeFullCookies=true`, `c_user` sentinel) ([566ebbe])
- feat(auth): Facebook login/logout button in accounts sheet on `HomeScreen` ([566ebbe])
- feat(auth): `ThreadsDownloaderService.fetchItems` now accepts `igSessionId` — injects `sessionid` cookie into both Dio clients ([566ebbe])
- feat(auth): `FacebookDownloaderService.fetchItems` now accepts `fbCookies` — injects full cookie string into Dio client ([566ebbe])
- feat(auth): `DownloaderService` reads stored IG session for Threads, FB cookies for Facebook, and passes them to the respective service ([566ebbe])

## [2026-04-26] — Session: Initial Flutter mobile draft

### Added
- chore: bootstrap agent files — Copilot instructions + vscode settings ([7072a39])
- feat(project): Flutter mobile app draft — Android + iOS share intent downloader ([TBD])
  - `pubspec.yaml` with all dependencies (riverpod, dio, gal, receive_sharing_intent, html)
  - `lib/main.dart` + `lib/app.dart` — app entry point and Material 3 theming
  - `lib/models/download_job.dart` — DownloadJob model (id, url, mediaType, status, progress)
  - `lib/providers/download_queue_provider.dart` — Riverpod StateNotifier job queue
  - `lib/providers/share_intent_provider.dart` — listens for URLs from iOS/Android share sheet
  - `lib/services/ig_url_parser.dart` — regex-based IG URL type detection
  - `lib/services/downloader_service.dart` — HTML scraping (og:video/og:image) + Dio download
  - `lib/screens/home_screen.dart` — main UI with URL input bar and download queue list
  - `lib/widgets/download_job_tile.dart` — per-job card with progress, status, retry/remove
  - `android/app/src/main/AndroidManifest.xml` — ACTION_SEND intent-filter for share sheet
  - `ios/Runner/Info.plist.additions.xml` — photo library + ATS + share extension guide
  - `README.md` — project overview and getting started instructions

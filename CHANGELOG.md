# Changelog

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

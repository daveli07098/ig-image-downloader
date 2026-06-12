# Changelog

## [2026-06-13] — Session: v1.0.1 big upgrade (icon, history, background downloads)

### Added
- feat(icon): new app icon — Instagram-style gradient + white download glyph; full Android adaptive + iOS icon set generated via `flutter_launcher_icons` (source art + `scripts/gen_icon.py`)
- feat(ui): "Open original post" button on each download tile — jumps back to the original IG/X/Facebook link in its native app (browser fallback) via `url_launcher`
- feat(download): foreground service (`flutter_foreground_task`) keeps the download queue running with a persistent "Downloading…" notification when the app is backgrounded

### Changed
- feat(history): history now keeps the most recent 10 finished (done/error) jobs regardless of age, instead of pruning everything older than 1 hour

### Fixed
- fix(android): `MainActivity` launch mode `singleTop` → `singleTask` (+ empty `taskAffinity`) so re-shares no longer pile up duplicate app cards in the Recents screen

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

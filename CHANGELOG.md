# Changelog

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

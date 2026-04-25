# IG Downloader

A Flutter mobile app (Android + iOS) that receives Instagram URLs via the system
share sheet and downloads photos, videos, Reels, and IGTV to your device gallery.

## How it works

```
Instagram app → Share → IG Downloader
       ↓
receive_sharing_intent captures the URL
       ↓
IgUrlParser.detect() identifies type (post / reel / story / igtv)
       ↓
DownloaderService fetches the IG page HTML
extracts og:video or og:image meta tag → direct media URL
       ↓
Dio downloads file to temp dir
       ↓
gal saves to device gallery
```

## Project structure

```
lib/
  main.dart                           App entry point
  app.dart                            MaterialApp + theming
  models/
    download_job.dart                 DownloadJob model (id, url, status, progress)
  providers/
    download_queue_provider.dart      Riverpod StateNotifier — job queue
    share_intent_provider.dart        Listens for URLs from share sheet
  services/
    ig_url_parser.dart                Detects IG URL type via regex
    downloader_service.dart           Fetches page, extracts & downloads media
  screens/
    home_screen.dart                  Main UI
  widgets/
    download_job_tile.dart            Per-job card (progress, status, actions)
```

## Getting started

1. **Install Flutter** — https://docs.flutter.dev/get-started/install/macos
2. Run `flutter create . --org com.daveli.igdownloader --platforms android,ios`
3. Run `flutter pub get`
4. For Android: the `AndroidManifest.xml` in this repo already contains the
   share intent-filter — merge it with the generated one.
5. For iOS: follow the Share Extension setup in `ios/Runner/Info.plist.additions.xml`.
6. Run the app: `flutter run`

## Limitations (draft)

- **Public content only** — Instagram blocks anonymous page fetching for private  
  accounts. Stories from private accounts will fail.
- `yt-dlp` is not available on mobile; the downloader uses open-graph HTML scraping  
  which may break if Instagram changes their page structure.
- Stories (`/stories/...`) are typically behind auth — a login flow is needed for  
  full Story support.

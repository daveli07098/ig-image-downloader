# ig-image-downloader — Architecture & Flow

> Flutter mobile app (Android / iOS) that receives Instagram URLs via the system
> share sheet, lets the user preview and pick media items, then downloads them
> permanently to a dated folder and to the device gallery.

---

## 1. User Flow

```mermaid
flowchart TD
    A([User taps Share in Instagram]) --> B[Android/iOS share sheet]
    B --> C[receive_sharing_intent fires]
    C --> D{Is it an Instagram URL?}
    D -- No --> E([Ignored / dismissed])
    D -- Yes --> F[sharedUrlProvider emits URL]
    F --> G[HomeScreen opens SelectionScreen]

    G --> H[DownloaderService.fetchItems]
    H --> I[HTTP GET Instagram page HTML]
    I --> J[Parse og:video + og:image meta tags]
    J --> K{Media found?}
    K -- No --> L([Error snackbar])
    K -- Yes --> M[2-col thumbnail grid, all pre-selected]

    M --> N{User adjusts selection}
    N --> O[Tap 'Download N items']
    O --> P[enqueueItems → DownloadQueueNotifier]
    P --> Q([SelectionScreen pops — back to HomeScreen])
    Q --> R[DownloadJobTile list shows live progress]
```

---

## 2. Download Pipeline

```mermaid
sequenceDiagram
    participant UI as HomeScreen / Tile
    participant Provider as DownloadQueueNotifier
    participant Svc as DownloaderService
    participant Storage as StorageService
    participant Dio as Dio (HTTP)
    participant Gal as gal (Gallery)
    participant FS as Device File System

    UI->>Provider: enqueueItems(igUrl, selectedItems)
    Provider->>Provider: create DownloadJob (status=pending)
    Provider->>Provider: _run(jobId)

    Provider->>Svc: downloadItem(item, onProgress)
    Svc->>Storage: getOrCreateSaveDir()
    Storage->>FS: mkdir Downloads/IG Downloader/YYYY-MM-DD/
    Storage-->>Svc: Directory

    Svc->>Dio: download(mediaUrl → saveDir/filename)
    Dio-->>FS: write bytes (streaming)
    Dio->>Svc: onReceiveProgress callback
    Svc->>Provider: onProgress(0.0 … 1.0)
    Provider->>UI: status=downloading, progress %

    Svc->>Gal: putImage/putVideo(savePath)
    Gal-->>Svc: saved to Photos/Gallery app

    Svc-->>Provider: return savePath
    Provider->>Provider: job.copyWith(status=done, outputPath=savePath)
    Provider->>UI: rebuild tile — show path + Open button
```

---

## 3. Architecture Layers

```mermaid
graph TB
    subgraph Screens
        HS[HomeScreen]
        SS[SelectionScreen]
    end

    subgraph Widgets
        TL[DownloadJobTile]
    end

    subgraph Providers["Providers (Riverpod)"]
        SP[sharedUrlProvider<br/>StateNotifier&lt;String?&gt;]
        QP[downloadQueueProvider<br/>StateNotifier&lt;List&lt;DownloadJob&gt;&gt;]
        MP[_mediaItemsProvider<br/>FutureProvider.family]
    end

    subgraph Services
        DS[DownloaderService<br/>fetchItems · downloadItem]
        ST[StorageService<br/>getOrCreateSaveDir · displayLabel]
        UP[IgUrlParser<br/>detect · isInstagramUrl]
    end

    subgraph Models
        DJ[DownloadJob<br/>id · url · item · status · outputPath]
        MI[MediaItem<br/>id · mediaUrl · thumbnailUrl · type]
    end

    subgraph External
        RX[receive_sharing_intent]
        DIO[Dio]
        GAL[gal]
        OFX[open_filex]
        PP[path_provider]
    end

    RX --> SP
    SP --> HS
    HS --> SS
    SS --> MP
    MP --> DS
    DS --> DIO
    DS --> ST
    ST --> PP
    DS --> GAL

    HS --> QP
    QP --> DS
    QP --> DJ
    DJ --> MI

    HS --> TL
    TL --> OFX
    TL --> ST
```

---

## 4. State Machine — DownloadJob

```mermaid
stateDiagram-v2
    [*] --> pending : enqueueItems()

    pending --> downloading : _run() starts
    downloading --> done : downloadItem() succeeds\noutputPath stored
    downloading --> error : exception thrown

    error --> pending : retry()
    done --> [*] : remove() / clearFinished()
    error --> [*] : remove()
    pending --> [*] : remove() (cancel)
```

---

## 5. Directory Structure

```
ig-image-downloader/
├── lib/
│   ├── main.dart                   # entry point, ProviderScope
│   ├── app.dart                    # MaterialApp, theme (M3, Instagram pink)
│   ├── models/
│   │   ├── media_item.dart         # MediaItem, MediaItemType
│   │   └── download_job.dart       # DownloadJob, JobStatus, IgMediaType
│   ├── services/
│   │   ├── ig_url_parser.dart      # URL type detection (regex)
│   │   ├── downloader_service.dart # HTML scrape + download via Dio
│   │   └── storage_service.dart   # persistent save-dir resolution
│   ├── providers/
│   │   ├── share_intent_provider.dart
│   │   └── download_queue_provider.dart
│   ├── screens/
│   │   ├── home_screen.dart        # queue list + URL input
│   │   └── selection_screen.dart  # thumbnail grid + pick UI
│   └── widgets/
│       └── download_job_tile.dart  # per-job card with open-file button
├── android/
│   └── app/src/main/AndroidManifest.xml   # ACTION_SEND intent-filter
├── ios/
│   └── Runner/Info.plist           # photo library perms, ATS
├── docs/
│   └── architecture.md            # ← this file
└── .github/
    └── copilot-instructions.md    # agent instructions
```

---

## 6. Key Design Decisions

| Decision | Choice | Reason |
|---|---|---|
| Media extraction | HTML og: meta scraping | No API key needed; works for public posts |
| Download engine | Dio (direct HTTP) | Mobile-first; yt-dlp not available on Android/iOS |
| Gallery save | gal | Cross-platform (Android MediaStore + iOS Photos) |
| Persistent folder | `Downloads/IG Downloader/YYYY-MM-DD/` | User-visible; survives app uninstall on Android |
| State management | Riverpod StateNotifier | No global singletons; explicit provider graph |
| URL handling | receive_sharing_intent | Listens to Android ACTION_SEND / iOS share extension |

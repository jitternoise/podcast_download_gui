# Podcast Downloader

A native macOS app for finding podcasts, subscribing to their RSS feeds, and
downloading episodes to a folder of your choosing.

- **Search** the Apple Podcasts directory by name, host, or topic — or paste any
  RSS feed URL directly.
- **Subscribe** to shows; the app keeps track of their episodes and can
  automatically download new ones each time it refreshes.
- **Download** individual episodes or an entire back catalog, with a concurrent
  download queue and per-episode progress.
- **Organised storage** — you pick one master folder, and every podcast gets
  its own sub-folder named after the show:

  ```
  ~/Downloads/Podcasts/
  ├── Some Podcast/
  │   ├── 2026-09-01 - Episode 42.mp3
  │   └── 2026-09-08 - Episode 43.mp3
  └── Another Show/
      └── 2026-08-30 - Pilot.m4a
  ```

## Requirements

- macOS 14 (Sonoma) or later
- Xcode 15+ command-line tools (for building)

## Building

```bash
scripts/build_app.sh
open "build/Podcast Downloader.app"
```

For development you can also run the app straight from the package:

```bash
swift run
```

## Project layout

```
Package.swift                     Swift Package Manager manifest
Resources/Info.plist              Bundle metadata used by build_app.sh
scripts/build_app.sh              Builds and packages the .app
Sources/PodcastDownloader/
  PodcastDownloaderApp.swift      @main entry point, menu commands, settings scene
  Models/                         Podcast, Episode, DownloadItem
  Services/
    AppModel.swift                Glue between settings, library and downloads
    AppSettings.swift             Master folder + concurrency (UserDefaults)
    Library.swift                 Subscriptions & episode cache (JSON on disk)
    FeedParser.swift              RSS 2.0 + iTunes-extension parser
    PodcastSearchService.swift    Apple Podcasts search API client
    DownloadManager.swift         URLSession download queue
  Views/                          SwiftUI screens
```

## Where data lives

| What | Where |
|------|-------|
| Downloaded audio | Master folder (default `~/Downloads/Podcasts`, change in **Settings ⌘,**) |
| Subscriptions & episode cache | `~/Library/Application Support/PodcastDownloader/library.json` |
| Preferences | `UserDefaults` |

## Tests

```bash
swift test
```

`FeedParserTests` are pure unit tests. `NetworkTests` hit the real Apple search
API and download one episode into a temp folder; they skip themselves when offline.

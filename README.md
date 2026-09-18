# Podcast Downloader

<img src="Resources/AppIcon-preview.png" width="128" alt="App icon">

A native macOS app for finding podcasts, subscribing to their RSS feeds, and
downloading episodes to a folder of your choosing.

- **Search** the Apple Podcasts directory by name, host, or topic (results
  appear as you type) — or paste an RSS feed URL, a show's web page, or an
  Apple Podcasts link. `feed://` and `podcast://` links from Safari open here
  too, as do links dropped onto the window. Subscriptions can be imported
  from and exported to OPML (File menu).
- **Subscribe** to shows; the app keeps track of their episodes and can
  automatically download new ones each time it refreshes. Feeds are refreshed
  automatically — at launch, after the Mac wakes, when the app comes to the
  front, and periodically while it stays open — but no more often than the
  interval you choose in Settings (default: once an hour). Refresh All (⌘R)
  always checks immediately. Pasting a show's web page instead of its feed
  works too, as long as the page links to its RSS feed.
- **Latest Episodes** — the newest episodes across every subscription, newest
  first, so you can see what's new without clicking through each show.
- **Episode lists** can be searched, filtered (all / downloaded / unplayed) and
  sorted; they show what's played, what's in progress and how much is left.
  Arrow keys move, Return plays, Delete trashes a download, Space
  pauses/resumes. Right-click for show notes, Mark as Played, Delete Download.
- **Download** individual episodes or an entire back catalog, with a concurrent
  download queue and per-episode progress. Downloads keep the Mac from idle-
  sleeping, survive a lost Wi-Fi connection or a lid-close by resuming where
  they stopped, and quitting warns you if any are still running. Files are
  stored exactly as the host served them — never transcoded — and verified:
  a transfer shorter than the server announced is retried rather than kept,
  a web page served in place of audio is rejected, files are staged as
  `.part` until complete, and each file is named for the format its bytes
  actually are (a `.mp3` URL that serves AAC becomes `.m4a`).
- **Built-in player** — double-click an episode to play it in the player bar at
  the bottom of the window: play/pause, skip back/forward (5–60 s, your
  choice), scrubber, chapters when the file has them, playback speed
  (0.75×–2×, remembered), volume, and the AirPlay / output picker. It remembers
  where you left off in each episode, continues with the next downloaded
  episode of the show when one ends (optional), has a sleep timer, pauses when
  the Mac sleeps or your headphones disconnect, and works with the keyboard
  media keys, AirPods and Control Center's Now Playing (with artwork). Click
  the title in the player bar (or ⌘L) to jump to the episode. If an episode
  isn't downloaded yet, it's fetched first and starts playing automatically.
  "Open in External App" is in the right-click menu if you'd rather use Music
  or another player.
- **Mini player** — the ⤡ button on the player bar (or ⇧⌘M) fades the main
  window out and shows a small always-movable player with artwork, scrubber,
  and transport controls; pin it to keep it above other windows and follow you
  across Spaces and full-screen apps. It remembers where you put it. ⤢ (or
  closing the mini window) fades the full window back in exactly as you left
  it — selection, scroll position and all. The Dock icon shows how many
  downloads are running and its menu has play/pause and skip.
- **One folder, always** — you pick a single master folder and every podcast
  gets its own sub-folder named after the show. Change the folder in Settings
  and the app moves your podcast folders there (anything else in the old
  folder is left alone). The app follows the folder if you rename or move it
  in Finder, and tells you if it can't be found — on an unplugged drive, say —
  rather than quietly starting a second library. The Downloads tab shows
  exactly what's in that folder.

  ```
  ~/Music/Podcasts/
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
scripts/make_icon.swift           Regenerates Resources/AppIcon.icns
Sources/PodcastDownloader/
  PodcastDownloaderApp.swift      @main entry point, menu commands, settings scene
  Models/                         Podcast, Episode, DownloadItem
  Services/
    AppModel.swift                Glue between settings, library and downloads
    AppSettings.swift             Master folder + concurrency (UserDefaults)
    Library.swift                 Subscriptions & episode cache (JSON on disk)
    LibraryFolder.swift           Scans / relocates the master folder
    RefreshPolicy.swift           Throttle for automatic feed refreshes
    FeedParser.swift              RSS 2.0 + iTunes-extension parser
    PodcastSearchService.swift    Apple Podcasts search API client
    DownloadManager.swift         URLSession download queue
    Player.swift                  AVPlayer-based audio player + media keys
    WindowMode.swift              Full window <-> mini player switching
  Views/                          SwiftUI screens
```

## Where data lives

| What | Where |
|------|-------|
| Downloaded audio | Master folder (default `~/Music/Podcasts`; an existing `~/Downloads/Podcasts` from earlier versions is kept; change in **Settings ⌘,**) |
| Subscriptions & episode cache | `~/Library/Application Support/PodcastDownloader/library.json` (download locations stored relative to the master folder; the previous session's copy is kept as `library.json.bak`, and a file that can't be read is set aside as `library.json.corrupt-…` rather than overwritten) |
| Preferences | `UserDefaults` |

## Keyboard shortcuts

| Action | Shortcut |
|---|---|
| Play / Pause | Space (when not typing), ⌥⌘P, or the keyboard's play key |
| Back / forward | ⌥⌘← / ⌥⌘→ |
| Next / previous episode | ⇧⌘→ / ⇧⌘← |
| Go to now playing | ⌘L |
| Stop | ⌥⌘S |
| Play selected episode / delete its download | Return / ⌫ |
| Mini player / full window | ⇧⌘M |
| Refresh all subscriptions | ⌘R |
| Settings | ⌘, |

To try the app without touching your real library and settings, point it at
a scratch folder:

```bash
PODCAST_DATA_DIR=/tmp/podcast-scratch swift run
```

## Tests

```bash
swift test
```

Everything runs offline against temp folders, a silent player and an
in-memory feed loader. `PlayerTests` and `WindowModeTests` need a logged-in
GUI session (they drive a real `AVPlayer` and real windows) and skip
themselves otherwise. `NetworkTests` hit the real Apple search API and
download one episode; they only run when asked:

```bash
PODCAST_NETWORK_TESTS=1 swift test --filter NetworkTests
```

CI (`.github/workflows/ci.yml`) builds, runs the headless tests and packages
the universal `.app` on every push.

## Distributing to other Macs

`scripts/build_app.sh` produces a universal (Apple Silicon + Intel) app with an
ad-hoc signature, which runs on the Mac that built it. To hand it to other
Macs without Gatekeeper refusing it, sign with a Developer ID and notarize —
the script prints the commands. The app is not sandboxed; it reads and writes
the folder you choose directly and keeps a bookmark to it, so an App Store
build would need the sandbox and security-scoped bookmarks added first.

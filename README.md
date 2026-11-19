# We UI (`weui.koplugin`)

A paper-style interface for KOReader, optimized for Kindle e-ink devices, with integrated
WeRead (微信读书) and Z-Library book sources.

## What's new in v1.5.3

- Local library scans yield between directory entries and books, reuse each
  metadata snapshot, and exclude KOReader's program and settings directories.
  Pages that do not need the library skip scanning; sleep screens reuse a
  completed local snapshot.
- Buffered WeRead foreground requests run in cancellable subprocesses with
  bounded timeouts. Book-detail covers load on demand, while UI callbacks and
  cookie persistence stay in the parent process.
- Failed cover workers stop repeated refresh attempts. Running extraction jobs
  are polled without repainting the whole page each second.
- Book groups, import, WeRead refresh, filtering and sorting use monochrome
  action icons; long-press an icon for its label. Group and WeRead menu rows
  retain their icons. The WeRead corner menu has six entries, with additional
  tools in a submenu.
- Automated regression includes slow storage, slow HTTP, request cancellation
  and cover worker failures. Native Mac/SDL checks are supporting evidence;
  Kindle hardware validation remains separate.

## What's new in v1.5.2

- Z-Library search and result pages keep the Paper bottom bar, including empty
  results, rotation and navigation changes.
- **More → Z-Library account and proxy** provides a visible login entry. Account
  credentials are saved locally, with passwords preserved exactly as entered.
- WeRead shelves use uniform book icons to avoid loading remote covers while
  browsing. Book details still load covers.
- Calendar and week/month/year statistics switch within the same Paper page.
  New local books refresh their covers automatically, and shelf cards use
  consistent title and progress positions.
- Marking a book private immediately locks and refreshes the visible library.
  The Chinese system collection name is **待读**.
- Download management shows persisted WeRead task history, progress, filters,
  cancellation, retry/resume and reading actions. Returning from the reader
  preserves the selected filter and page.

## Upgrade layout refresh (v1.5.1)

- The first restart after upgrading refreshes Paper's home renderer, five
  navigation tabs, bar dimensions and UI text scaling. This fixes legacy
  settings that could select the old home layout or enlarge text on Kindle.
- Previous display values are backed up in
  `settings/weui/weui_settings.lua` under `weui_paper_layout_backup_v1`.
  Accounts, books, groups, privacy settings, notes, progress, statistics and
  network/download preferences are preserved.
- The refresh runs once per layout revision. Subsequent restarts and updates
  with the same revision keep any new display preferences.

## Paper features (v1.5.0)

- Five main pages: reading room, bookshelf, notes, statistics and more.
  Book titles, authors, reading percentages and progress bars share one layout;
  bookshelf filter underlines follow the center of their text.
- Create and manage local groups through **Bookshelf → Book groups** (书籍分组).
  Long-press a book and choose **Set book groups** (设置书籍分组) to add or
  remove it. Groups use KOReader collections; deleting a group keeps its files.
- WeRead 1.7.0 reader services, resumable chapter downloads, optional prefetch,
  external annotations and progress synchronization.
- Custom sleep screens and a combined WeUI/KOReader update page.
- Legacy module layouts remain stored for later use. Release packages contain
  runtime files and third-party licenses, with development previews and test
  fixtures excluded.

## WeRead reader features

WeRead uses the reader services from `finlater/weread.koplugin` 1.7.0;
the pinned source and license attribution are in [weread/UPSTREAM.md](weread/UPSTREAM.md).
The paper bookshelf supports online groups, reading/download filters, cover
and list layouts, offline snapshots and continuous list browsing. Book details
offer single, selected and full-book downloads. Full downloads retain verified
chapter checkpoints after cancellation and resume when requested again.

Open **More → Download management** to view and manage saved WeRead tasks.
Interrupted tasks can resume their selected chapters after a restart.
Clearing finished tasks keeps downloaded book files.

Open **WeRead → Settings → Download settings → Chapter prefetch** to enable
next-chapter downloads. Annotation prefetch is a separate opt-in and requires
both switches. It downloads reusable source data in a background process;
matching positions in the current EPUB remains an explicit reader action.

In a reflowable book, use **Underlines and thoughts management** to choose
chapters, correct chapter mappings, resume matching or bind a local book through
WeRead search. External annotations use separate SQLite/XPointer projections;
the original EPUB and KOReader's own annotations remain independent. Thought
popup position, dimensions, font and edge-tap handling are configurable.
PDF/DjVu annotation matching is not supported by the upstream implementation.

Progress synchronization maps the current file and chapter into WeRead's
chapter UID, offset and overall percentage. Automatic pulls, uploads and
reading reports are disabled by default; enable them in settings when wanted.

## Installation

### From a release (recommended)

1. Download the single `weui.koplugin.zip` from the latest [Releases](../../releases).
   Z-Library is already embedded in WeUI; it is not a second KOReader plugin.
2. Unzip it into your KOReader `plugins/` directory so that you end up with:
   ```
   koreader/plugins/weui.koplugin/_meta.lua
   koreader/plugins/weui.koplugin/zlibrary/api.lua
   ```
3. Delete any old standalone `koreader/plugins/zlibrary.koplugin/` directory,
   restart KOReader, and enable only WeUI in
   `Menu → Tools → More tools → Plugin management`.

### Embedded Z-Library

WeUI vendors the compatible Z-Library implementation from
[`zlibrary.koplugin`](https://github.com/ZlibraryKO/zlibrary.koplugin) under its
own `zlibrary/` module directory. Z-Library therefore
appears inside the existing `We UI` settings menu and as an optional action in
the existing navigation-bar customization list; it is not added to the default
six-button bar.

When upgrading from the old two-plugin layout, WeUI migrates an optional
`zlibrary_credentials.lua` into its own directory and retires the standalone
`zlibrary.koplugin/` directory. The credentials file is device-local and is
never included in release archives.

The WeUI bottom bar remains visible on Z-Library's main browser, search-result,
and similar-book pages. Z-Library keeps its own page controls immediately above
the bar, even when WeUI's global navigation pager is enabled. Book details,
downloads, credentials, and settings remain focused modal dialogs.

When Z-Library has no download directory configured yet, WeUI initializes it
to KOReader's current Library root (`home_dir`). A directory selected later in
Z-Library settings is treated as a user preference and is never overwritten.

Downloads that require an account open the Z-Library credentials window after
the book-details dialog has closed. The same window is always available from
`We UI → Z-Library Account`. Detail actions use the same 24 px monochrome SVG
icons and 40 px icon column as the WeRead download interface.

Book downloads normally run in a cancellable subprocess. If Kindle cannot
start that process under temporary memory pressure, WeUI safely falls back to
an in-process download. Empty links, malformed results and crashed workers are
reported separately with retry support instead of as an unknown error.

Z-Library API requests use a bounded health-aware mirror pool by default. DNS
failures, timeouts, server errors, redirect loops, invalid API responses and
browser-check pages temporarily cool down the affected address and retry at
most two alternatives. Authentication failures, quota responses and other
normal 4xx replies never trigger a switch. The selected address is temporary
and does not overwrite the user's preferred base URL. Disable this behavior at
`Z-Library → Settings → Automatic server failover`.

Streaming cover and book bodies are never replayed on another mirror after a
transfer begins. When the Z-Library-only proxy is enabled, mirror retries stay
inside the same fail-closed proxy transport.

#### Z-Library-only proxy

Open **More → Z-Library proxy** in the paper interface (or
`We UI → Z-Library Proxy` in the native menu) to route every Z-Library request through an
independent proxy. This covers sign-in, search, covers, book downloads, mirror
discovery, and favorites.

- Supported addresses: `http://host:port` (HTTP CONNECT for HTTPS) and
  `socks5://host:port` / `socks5h://host:port` (remote target DNS).
- Optional HTTP Basic and SOCKS5 username/password authentication.
- Strict failure behavior: when enabled, an invalid or unavailable proxy
  blocks the Z-Library request; it never falls back to a direct connection.
- The setting is scoped to Z-Library by default. WeRead, KOReader updates,
  OPDS, and other network features keep their existing network route. We UI's
  own package downloader can opt in separately under its update settings.
- Proxy passwords are stored as plain text in the local We UI settings file and
  are masked in the interface and omitted from logs.

On Kindle, `127.0.0.1` refers to the Kindle itself. For Clash or another proxy
running on a computer, phone, or router, use that device's LAN IP and enable LAN
access. Using an IP address also avoids a local DNS lookup for the proxy host.

#### Paper sleep screens and updates

**More → Custom sleep screen** offers recent reading, seven-day reading
statistics, and a minimal monthly calendar, with a full-screen preview.
Snapshots use local data, hide private book titles and covers even while the
in-app privacy session is unlocked, and do not run refresh timers or network
requests while sleeping. KOReader keeps control of suspend/resume, gesture
unlock, delayed dismissal, and e-ink refreshes. Choose **Follow KOReader
settings** to return to its existing sleep-screen configuration.

**More → System updates** checks WeUI and, on supported devices, KOReader.
It also exposes KOReader's update channel/server and WeUI's update URL/proxy
settings. Unsupported devices display an explanation. Update checks lead to
the existing release information and installation confirmation.

### From source

```sh
git clone https://github.com/<owner>/weui.koplugin.git \
  ~/.koreader/plugins/weui.koplugin
```
Then restart KOReader. (Replace `<owner>` with this repository's owner.)

## Updates

The plugin has a built-in OTA updater (`weui_updater.lua`) that checks this
repository's GitHub Releases for a newer version and, when found, downloads
the single `weui.koplugin.zip` over the existing WeUI plugin directory. The
embedded Z-Library module is updated together with WeUI.

- **Manual:** `Menu → … → Check for Updates`.
- **Automatic:** enable the auto-check option in the plugin settings. It runs
  once on startup (24 h throttle) and only when the network is already online.

Manual checks use KOReader's connected-interface state instead of its external
Internet probe. This avoids false "turn on Wi-Fi" prompts on connected Kindles
when that probe is unreachable, including on some mainland China networks.

Version checks try the GitHub Releases API and two jsDelivr metadata edges with
a 10-second block timeout and 20-second total timeout per source. They do not
depend on `raw.githubusercontent.com`, which is frequently unreachable on
mainland networks. Release downloads use a 30-second block timeout, a 180-second
total timeout, and one automatic retry. If the Z-Library proxy is enabled and
configured, a failed direct check or download automatically retries through it.
Enabling `Use Z-Library proxy for We UI updates` forces version checks, HTTPS
redirects, and package downloads through the proxy from the first request.
Other KOReader traffic keeps its original route.

The installed version is read from `_meta.lua`; releases are tagged `vX.Y.Z`.

## Disclaimer

This project is for personal learning and technical research only, not for
commercial use. All consequences arising from the use of this project
(including but not limited to account bans, data loss, etc.) are borne by the
user. The project author assumes no responsibility. Please comply with WeRead's
user agreement and applicable laws and regulations.

This is an unofficial project. It is not affiliated with, endorsed by, or
sponsored by WeRead, Tencent, or KOReader. All product names and trademarks
belong to their respective owners.

## License

- The We UI plugin code is licensed under the MIT License — see
  [`LICENSE`](LICENSE).
- The integrated WeRead integration code is licensed under the GNU Affero
  General Public License v3 — see [`LICENSE.weread`](LICENSE.weread) and
  [`NOTICE.weread`](NOTICE.weread).
- The embedded Z-Library source remains under AGPL-3.0; see
  [`LICENSE.zlibrary`](LICENSE.zlibrary).
- `fonts/NotoEmoji-Regular.ttf` is licensed under the SIL Open Font License
  1.1 — see [`fonts/NotoEmoji-OFL.txt`](fonts/NotoEmoji-OFL.txt).
- `fonts/PaperSong.ttf` is licensed under the SIL Open Font License
  1.1 — see [`fonts/PaperSong-OFL.txt`](fonts/PaperSong-OFL.txt).

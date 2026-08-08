# We UI (`weui.koplugin`)

A We UI for KOReader with integrated WeRead (微信读书) and Z-Library book
sources without changing the classic WeUI home and library layout.

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

#### Z-Library-only proxy

Open `We UI → Z-Library Proxy` to route every Z-Library request through an
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

Release downloads use a 30-second block timeout, a 180-second total timeout,
and one automatic retry. On networks where GitHub Release assets are not
reachable directly, enable `Use Z-Library proxy for update downloads`; every
HTTPS redirect in the asset download remains inside the configured HTTP
CONNECT or SOCKS5 tunnel. Version checks and all other KOReader traffic keep
their original route.

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
  1.1 — see [`fonts/LICENSE`](fonts/LICENSE).

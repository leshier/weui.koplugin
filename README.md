# We UI (`weui.koplugin`)

A We UI for KOReader with integrated WeRead (微信读书) bookshelf, search,
download, and reading support.

## Installation

### From a release (recommended)

1. Download `weui.koplugin.zip` from the latest [Releases](../../releases).
2. Unzip it into your KOReader `plugins/` directory so that you end up with:
   ```
   koreader/plugins/weui.koplugin/_meta.lua
   ```
3. Restart KOReader and enable the plugin in
   `Menu → Tools → More tools → Plugin management`.

### From source

```sh
git clone https://github.com/<owner>/weui.koplugin.git \
  ~/.koreader/plugins/weui.koplugin
```
Then restart KOReader. (Replace `<owner>` with this repository's owner.)

## Updates

The plugin has a built-in OTA updater (`weui_updater.lua`) that checks this
repository's GitHub Releases for a newer version and, when found, downloads
`weui.koplugin.zip` and installs it over the existing plugin directory.

- **Manual:** `Menu → … → Check for Updates`.
- **Automatic:** enable the auto-check option in the plugin settings. It runs
  once on startup (24 h throttle) and only when the network is already online.

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
- `fonts/NotoEmoji-Regular.ttf` is licensed under the SIL Open Font License
  1.1 — see [`fonts/LICENSE`](fonts/LICENSE).

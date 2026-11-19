# Kindle Paperwhite 4 QA

This directory contains the repeatable KOReader runtime QA used before a WeUI
release. It runs with an isolated `KO_HOME`, a 1072 x 1448 viewport, 300 DPI,
Chinese UI, grayscale rendering, fake connected Wi-Fi, and a disposable sample
library. It never reads or writes the operator's normal KOReader settings.

The paper interface has a separate native suite:

```sh
sh scripts/qa/run_paper_qa.sh
python3 scripts/qa/run_paper_upgrade_qa.py
```

`WEUI_PAPER_RESPONSIVENESS_ONLY=1 sh scripts/qa/run_paper_qa.sh` exercises
5 ms filesystem delays throughout a cold scan, an 800 ms buffered HTTP request,
native dismissal of a 3-second request, cover worker launch failure and native
action/menu icons. `responsiveness.tsv` records the initial scan and input
latencies. The library yields between entries with an 8 ms work budget;
buffered foreground HTTP runs through KOReader's cancellable subprocess
mechanism. Runtime/settings trees are excluded, and settings/cookies remain
parent-owned. Downloads retain the native streaming worker.

It uses a new temporary `KO_HOME` for each run, original sample books and a
separate SQLite database. It covers the five main pages, secondary sources,
notes and export, reading goals, portrait/landscape layout, and opening a real
book before returning to the shelf with refreshed progress. Privacy coverage
includes the More entry, first-time password setup, wrong/empty passwords,
password changes, private collections, authenticated private reading, automatic
relock and timer cancellation, immediate note masking, private viewer closure,
and refusing exports from stale records while locked.

The upgrade runner seeds a v1.5.0 profile before plugin initialization, including
old renderer selection, 150% scaling and preloaded navigation/dimension caches.
It renders the five pages at 600×800/167 DPI, 758×1024/212 DPI,
1072×1448/300 DPI and 1236×1648/300 DPI, checks the display backup and retained
accounts/collections/privacy/notes/progress/statistics, then restarts each
profile to verify that newly selected display preferences are not reset.
Use `--archive dist/weui.koplugin.zip` to run these checks on a release package.

Shortcut coverage includes native paper bottom sheets for favorites, history and
goals; aliases from More, statistics and Recent/All; real collection membership;
history pagination; goal draft save/cancel and validation; private group relock;
and opening a real reader from history before returning to the reading room.
The goal main sheet follows the annual design, with monthly/daily settings in
the annual picker; input cancellation and returning to the main sheet are tested.
Local book deletion covers native confirmation, cancellation, failed deletion,
collection/history/import cleanup, and private-book authentication and relocking.
Sixty sheet open/close cycles assert that the original page and window count
are restored.

Local import now exercises More → Sources → the paper file picker, folder
navigation, visible/hardware back, cancel, real file selection and duplicate
imports. Reader returns exercise the actual File browser tab after the native
menu builds, Home, Close, repeated book opens, document reloads, collection and
history page restoration, shelf query/sort restoration, and explicit tab
navigation. Z-Library directory reading uses the same picker and restores its
directory history. Native statistics remain enabled; the fixture schema matches
KOReader's column order, and a backed-up migration preserves existing book IDs
and reading durations. Reader class patches are checked for idempotence and
native function restoration on teardown.

WeRead coverage includes cached details without Wi-Fi or login, restoring EPUB
paths, chapter and full-text pagination, download confirmation/cancellation,
notes/highlights/reviews/similar books, shelf sorting, late-request cancellation,
download refresh timer cleanup, and reading cached content in native ReaderUI.
The default run uses deterministic API responses.

Paper polish coverage checks Chinese system groups, Z-Library login and saved
credentials, identical Paper navigation pixels on search/results/empty pages,
rotation and tab taps, icon-only WeRead shelves, inline calendar period changes
and leap-year boundaries, automatic cover extraction after import, immediate
privacy masking, and download filters/cancellation with reader-return state.
The native WeRead feature runner also reloads persisted download history and
resumes the original chapter checkpoints.

The current upstream reader services and the WeUI adapters have separate gates:

```sh
python3 scripts/qa/run_weread_specs.py
python3 -m unittest discover -s scripts/qa/weread_mock -p 'test_*.py'
python3 scripts/qa/run_weread_features.py
```

The first runs 70 pinned service specifications. Standalone plugin integration,
metadata and updater tests are excluded because WeUI supplies those components.
The native feature runner starts a loopback HTTP fixture and actual KOReader
with a fresh `KO_HOME`. It verifies the real decoder, streamed images, footnotes,
download cancellation/checkpoints/resume/queue, paper settings/groups/filters/
continuous browsing/selection, prefetch promotion, chapter mapping, annotation
worker cancellation/resume/offline reuse, long-thought popups, precise progress
HTTP payloads, source EPUB and native annotation preservation, and SQLite
integrity. It reuses the pinned native annotation regression with a WeUI-specific
bootstrap. Synthetic cloud writes stay on the mock service. Results and PNGs are
saved under the printed `weui-weread-features.*/evidence` directory.

To additionally test the current logged-in account:

```sh
WEUI_PAPER_ONLINE_AUTH="$HOME/Library/Application Support/koreader-weui-test/settings/weread.lua" \
sh scripts/qa/run_paper_qa.sh
```

Only authentication fields are read from that profile into the disposable test
settings. Downloads and caches stay in the test home. The live stages fetch the
shelf, metadata/progress, notes, highlights, reviews and catalog, download one
chapter as EPUB, open it in ReaderUI and verify offline details. Reading reports
and progress uploads are disabled in the disposable profile. The source login
and its settings are preserved; credentials are never written to test summaries.

The suite performs 100 measured page switches after 25 warm-up switches.
It also exercises all paper tool entries: proxy editors/save/cancel/validation,
enable/disable/probe/help/clear, update checks and nested channel/server choices,
all three sleep-screen previews, empty/private states, landscape, native
suspend/resume from More and ReaderUI, delayed dismissal, gesture unlock, and
extra e-ink flashes. Use `WEUI_PAPER_TOOLS_ONLY=1` for the focused tool suite.

For slower visual verification, dwell two seconds at each stage and capture
every actual SDL render, including paints inside callbacks and subprocess waits:

```sh
WEUI_PAPER_SLOW=1 WEUI_PAPER_DWELL=2 WEUI_PAPER_TRACE=1 \
sh scripts/qa/run_paper_qa.sh
```

Slow mode omits the two rapid navigation stress loops. `refreshes.tsv` records
visible widgets and refresh modes; `frames/` contains every rendered frame.
Unexpected native FileManager frames during paper returns fail the suite.
`WEUI_PAPER_OPEN_TRACE_ONLY=1` restricts it to reading/open/return reproduction.
`WEUI_PAPER_FILES_TRACE_ONLY=1` covers More → Sources → Import and its returns.
The suite also verifies the native directory readability flag on cache misses,
cache hits and failed enumeration, and checks that return snapshots are freed.

On macOS, `02-native-input-regression` runs the real Input polling loop and
GestureDetector with a scripted OS event source. It reproduces the SDL clock
mismatch, checks 100ms taps and 650ms holds against the native 500ms timer,
preserves relative timestamps within a batch, and accepts upstream timestamps
that already use the UI clock. It also sends the native SDL wheel event through
UIManager and checks paper pagination, burst limiting and direction reversal.

To use the local SOCKS5 service on `127.0.0.1:10808`:

```sh
python3 scripts/qa/run_proxy_live.py
```

It checks the Z-Library probe, API health, actual HTTPS content, unavailable
proxy behavior, zero direct target connections and restoration of global HTTP.
It uses a fresh temporary home and transmits no account credentials.

Run the actual LuaSocket/LuaSec and Z-Library API against a loopback SOCKS5
server with no external network access:

```sh
python3 scripts/qa/run_proxy_loopback.py
```

This checks every network API with anonymous and RFC1929-authenticated SOCKS5,
TLS, remote DNS, streaming downloads, cross-host redirects and fail-closed
errors. It records SOCKS5 CONNECT frames and origin requests without credentials.

`stress.tsv` records native repaint latency and retained Lua memory;
`process.tsv` samples process CPU and RSS; `stages.tsv` includes each stage's
elapsed time (including its scheduled 100 ms paint delay), Lua memory and window
count. Native PNGs, logs and `results.tsv` are written under
`/tmp/weui-paper-qa.*/artifacts/`. Both native runners reject failed rows or a
missing suite-completion row even when KOReader returns exit code zero.

For interactive testing with an independent, persistent profile:

```sh
sh scripts/qa/run_manual_test.sh
```

The default profile is `~/Library/Application Support/koreader-weui-test`.
Its first launch creates nine original sample books, notes, favorites, a custom
collection, reading history and statistics. Subsequent launches preserve edits
and deletions. Long-press a local book and choose **删除书籍** to test the native
confirmation. Settings, accounts and downloads use this profile's separate
`KO_HOME`; no ordinary profile is copied. `logs/stdout.log` and `logs/stderr.log`
capture debug output. Set `WEUI_MANUAL_HOME` to choose another fresh profile.
The installed macOS app allows one instance, so quit a running ordinary KOReader
before switching profiles. The launcher rejects that case instead of silently
reusing the ordinary profile.

Run:

```sh
scripts/qa/run_kpw4_full_qa.sh
```

For a headless release run with the real update endpoint enabled:

```sh
SDL_VIDEODRIVER=offscreen WEUI_QA_EMULATE_W=1072 \
WEUI_QA_EMULATE_H=1448 WEUI_QA_LIVE_UPDATE=1 \
scripts/qa/run_kpw4_full_qa.sh
```

Run the deterministic release gate separately with:

```sh
scripts/run_tests.sh
```

Artifacts are written to a new `/tmp/weui-kpw4-fullqa.*/artifacts` directory by
default. Override that root with `WEUI_QA_HOME=/absolute/path`.

The automated suite covers startup, home, library, private-book masking, the
settings hierarchy and persistence, About metadata, onboarding, recent books,
WeRead and offline management, Z-Library Chinese UI/search/account/details, the
reader, and customized sleep-screen rendering. Network failure/retry and unsafe
update-package paths are covered by the deterministic tests in `scripts/test_*.lua`.

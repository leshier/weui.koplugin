# Kindle Paperwhite 4 QA

This directory contains the repeatable KOReader runtime QA used before a WeUI
release. It runs with an isolated `KO_HOME`, a 1072 x 1448 viewport, 300 DPI,
Chinese UI, grayscale rendering, fake connected Wi-Fi, and a disposable sample
library. It never reads or writes the operator's normal KOReader settings.

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

Artifacts are written to `/tmp/weui-kpw4-fullqa/artifacts` by default. Override
that root with `WEUI_QA_HOME=/absolute/path`.

The automated suite covers startup, home, library, private-book masking, the
settings hierarchy and persistence, About metadata, onboarding, recent books,
WeRead and offline management, Z-Library Chinese UI/search/account/details, the
reader, and customized sleep-screen rendering. Network failure/retry and unsafe
update-package paths are covered by the deterministic tests in `scripts/test_*.lua`.

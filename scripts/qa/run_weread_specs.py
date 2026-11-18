#!/usr/bin/env python3
"""Run vendored service specs against WeUI's source in a disposable directory."""
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
LUA = os.environ.get("LUA_BIN", "/Applications/KOReader.app/Contents/koreader/luajit")
# These specs require the standalone root entry point/integration/updater.
# WeUI keeps its own implementations, covered by its existing regressions.
EXCLUDED = {
    "plugin_load_spec.lua", "plugin_composition_spec.lua", "ui_integrations_spec.lua",
    "updater_spec.lua", "updater_ui_spec.lua",
}
with tempfile.TemporaryDirectory(prefix="weui-weread-specs.") as work:
    work = Path(work)
    (work / "weread").symlink_to(ROOT / "weread", target_is_directory=True)
    (work / "spec").symlink_to(ROOT / "weread/spec", target_is_directory=True)
    specs = sorted(path for path in (ROOT / "weread/spec").glob("*_spec.lua") if path.name not in EXCLUDED)
    for spec in specs:
        print(f"==> {spec.name}", flush=True)
        subprocess.run([LUA, str(spec)], cwd=work, check=True)
    print(f"All {len(specs)} vendored WeRead service specs passed.", flush=True)

"""Exercise the actual API transport through 127.0.0.1:10808, without credentials."""
import os
from pathlib import Path
import subprocess
import tempfile

repo = Path(__file__).resolve().parents[2]
runtime = Path(os.environ.get("KOREADER_DIR", "/Applications/KOReader.app/Contents/koreader"))
root = Path(tempfile.mkdtemp(prefix="weui-proxy-live."))
(root / "settings/weui").mkdir(parents=True)
env = dict(os.environ, KO_HOME=str(root), WEUI_PROXY_ROOT=str(root), WEUI_PROXY_REPO=str(repo))
with (root / "run.log").open("w") as log:
    run = subprocess.run(
        [str(runtime / "luajit"), str(repo / "scripts/qa/proxy_live_client.lua")],
        cwd=runtime, env=env, stdout=log, stderr=subprocess.STDOUT,
    )
print(f"Live proxy QA root: {root}")
results = root / "results.tsv"
if results.exists():
    print(results.read_text(), end="")
raise SystemExit(run.returncode)

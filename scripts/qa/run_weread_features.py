#!/usr/bin/env python3
"""Run actual KOReader, HTTP decoder, workers and SQLite in a disposable home."""
import argparse
import os
from pathlib import Path
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import threading
import zipfile

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / "scripts/qa/weread_mock"))
from mock_weread import MockServer


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--runtime", default="/Applications/KOReader.app/Contents/koreader")
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--reader-only", action="store_true", help="Run the focused native reader flows")
    mode.add_argument("--features-only", action="store_true", help="Run the focused shelf/settings/download flows")
    args = parser.parse_args()
    root = Path(tempfile.mkdtemp(prefix="weui-weread-features."))
    home, evidence = root / "profile", root / "evidence"
    for name in ("cache", "data", "patches", "plugins", "settings/weui", "library"):
        (home / name).mkdir(parents=True)
    evidence.mkdir()
    fixture = REPO / "scripts/qa/fixtures"
    shutil.copy(fixture / "settings.reader.lua", home)
    shutil.copy(fixture / "weui_settings.lua", home / "settings/weui")
    shutil.copy(fixture / "1-kpw4-profile.lua", home / "patches/2-kpw4-profile.lua")
    shutil.copy(fixture / "2-weread-feature-qa.lua", home / "patches")
    (home / "plugins/weui.koplugin").symlink_to(REPO, target_is_directory=True)
    server = MockServer(port=0, log_path=evidence / "http.jsonl")
    port = server.server_address[1]
    (home / "settings/weread-environment.lua").write_text(
        f'return {{ enabled=true, host="127.0.0.1", port={port} }}\n')
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    env = dict(os.environ, KO_HOME=str(home), WEUI_WEREAD_QA_ROOT=str(root),
               EMULATE_READER_W="536", EMULATE_READER_H="724", EMULATE_READER_DPI="300")
    if args.reader_only:
        env["WEUI_WEREAD_READER_ONLY"] = "1"
    if args.features_only:
        env["WEUI_WEREAD_FEATURES_ONLY"] = "1"
    print(f"WeRead feature QA root: {root}", flush=True)
    try:
        with (evidence / "koreader.log").open("w") as log:
            run = subprocess.run(
                [sys.executable, str(REPO / "scripts/qa/monitor_runtime.py"),
                 str(Path(args.runtime) / "luajit"), str(Path(args.runtime) / "reader.lua"),
                 str(evidence)], env=env, stdout=log, stderr=subprocess.STDOUT, timeout=480)
        marker = evidence / "suite.pass"
        if run.returncode or not marker.exists():
            print((evidence / "koreader.log").read_text()[-14000:])
            return 1
        # Validate actual produced ZIPs rather than only trusting the task state.
        epubs = list(home.rglob("*.epub"))
        assert epubs, "no EPUB artifacts"
        for path in epubs:
            with zipfile.ZipFile(path) as archive:
                assert archive.testzip() is None
                assert archive.read("mimetype") == b"application/epub+zip"
                assert "META-INF/container.xml" in archive.namelist()
        databases = list(home.rglob("*.db")) + list(home.rglob("*.sqlite3"))
        for path in databases:
            # Normal handles let SQLite recreate WAL shared-memory files after
            # the native process exits. Only the integrity query is issued.
            connection = sqlite3.connect(str(path))
            try:
                assert connection.execute("PRAGMA integrity_check").fetchone() == ("ok",), path.name
            finally:
                connection.close()
        print(marker.read_text(), end="")
        print(f"PASS: {len(epubs)} EPUB archives, CRC/mimetype/container")
        print(f"PASS: {len(databases)} SQLite databases, integrity_check")
        return 0
    finally:
        server.shutdown()
        server.server_close()


if __name__ == "__main__":
    raise SystemExit(main())

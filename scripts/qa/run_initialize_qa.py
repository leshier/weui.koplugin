"""Test the initialization archive, restart and repeated installation in native KOReader."""
import argparse
import os
from pathlib import Path
import shutil
import sqlite3
import subprocess
import tempfile
import zipfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--archive", type=Path, required=True)
args = parser.parse_args()
repo = Path(__file__).resolve().parents[2]
runtime = Path(os.environ.get("KOREADER_DIR", "/Applications/KOReader.app/Contents/koreader"))
fixtures = repo / "scripts/qa/fixtures"
root = Path(tempfile.mkdtemp(prefix="weui-initialize-qa."))
for name in ("plugins", "patches", "settings/weui", "settings/simpleui", "settings/lershierui",
             "library", "cache/zlibrary", "weread/cache", "weread/external-annotations", "artifacts"):
    (root / name).mkdir(parents=True, exist_ok=True)
shutil.copy(fixtures / "settings.reader.lua", root)
shutil.copy(fixtures / "1-kpw4-profile.lua", root / "patches/2-kpw4-profile.lua")
shutil.copy(fixtures / "2-initialize-qa.lua", root / "patches")
old_reader = (root / "settings.reader.lua").read_text().replace(
    '["start_with"] = "homescreen_weui",',
    '["start_with"] = "homescreen_weui",\n'
    '["weui_bad_legacy"] = {broken=true}, ["simpleui_bad_legacy"] = "old",')
(root / "settings.reader.lua").write_text(old_reader)
(root / "settings.reader.lua.old").write_text(old_reader)
# Any accidental LuaSettings read, including fallback, leaves visible evidence.
broken = f'local f=assert(io.open("{root}/legacy-executed","w")); f:close(); return "bad setting"\n'
for file in ("weui/weui_settings.lua", "simpleui/sui_settings.lua", "lershierui/lershierui_settings.lua",
             "weread.lua", "weread-environment.lua", "zlibrary.lua"):
    path = root / "settings" / file
    path.write_text(broken)
    Path(str(path) + ".old").write_text(broken)
(root / "cache/zlibrary/_runtime_cache.lua").write_text(broken)
(root / "weread/cache/keep.epub").write_bytes(b"retained EPUB fixture")
(root / "library/book.txt").write_text("保留书籍、笔记、阅读进度。\n" * 100)
(root / "library/book.sdr").mkdir()
(root / "library/book.sdr/metadata.txt.lua").write_text(
    'return {percent_finished=0.42,annotations={{note="keep note",pageno=2}}}\n')
(root / "settings/collection.lua").write_text(
    f'return {{Keep={{{{file="{root}/library/book.txt",order=1}},settings={{order=1}}}}}}\n')
db = sqlite3.connect(root / "weread/library-old-fixture.db")
db.execute("CREATE TABLE legacy(value)")
db.commit()
db.close()
stats = sqlite3.connect(root / "settings/statistics.sqlite3")
stats.execute("CREATE TABLE initialize_preservation_check(value)")
stats.execute("INSERT INTO initialize_preservation_check VALUES(42)")
stats.commit()
stats.close()
(root / "weread/external-annotations/legacy.db").write_bytes(b"broken SQLite")
# Old class tables can be discovered before or after WeUI's class is loaded.
for name in ("simpleui", "lershierui", "weread", "zlibrary"):
    directory = root / f"plugins/{name}.koplugin"
    directory.mkdir()
    (directory / "_meta.lua").write_text(f'return {{fullname="{name}",description="old fixture"}}\n')
    (directory / "main.lua").write_text(
        'return require("ui/widget/container/widgetcontainer"):extend{init=function() '
        f'local f=assert(io.open("{root}/legacy-plugin-executed","w")); f:close() end}}\n')
(root / "plugins/zlibrary.koplugin/zlibrary_credentials.lua").write_text(broken)


def install():
    with zipfile.ZipFile(args.archive) as archive:
        assert archive.testzip() is None
        assert all(name.startswith("weui.koplugin/") and ".." not in Path(name).parts
                   for name in archive.namelist())
        archive.extractall(root / "plugins")


print(f"Initialization QA: {root}", flush=True)
install()
env = dict(os.environ, KO_HOME=str(root), WEUI_INITIALIZE_QA_ROOT=str(root),
           SDL_VIDEODRIVER="offscreen", EMULATE_READER_W="1072",
           EMULATE_READER_H="1448", EMULATE_READER_DPI="300")
for phase in ("initialize", "restart", "reinstall"):
    if phase == "reinstall":
        install()
    env["WEUI_INITIALIZE_QA_PHASE"] = phase
    log_path = root / f"artifacts/{phase}.log"
    with log_path.open("w") as log:
        run = subprocess.run([str(runtime / "luajit"), str(runtime / "reader.lua")],
                             cwd=runtime, env=env, stdout=log, stderr=subprocess.STDOUT, timeout=60)
    assert run.returncode == 0 and (root / f"artifacts/{phase}.pass").is_file(), log_path.read_text()[-8000:]
    print((root / f"artifacts/{phase}.pass").read_text().strip(), flush=True)
assert len(list((root / "settings").glob(".weui-initialize-backup-*"))) == 1, "reset ran more than once"
assert not (root / "weread/library-old-fixture.db").exists()
assert not (root / "weread/external-annotations/legacy.db").exists()
assert not (root / "legacy-executed").exists()
assert "startup: ready" in (root / "settings/weui-initialize.log").read_text()
with sqlite3.connect(root / "settings/statistics.sqlite3") as stats:
    assert stats.execute("SELECT value FROM initialize_preservation_check").fetchone() == (42,)
    assert stats.execute("PRAGMA integrity_check").fetchone() == ("ok",)
print("INITIALIZE_NATIVE_QA_OK: clean install, restart, reinstall, blank login, native data retained")

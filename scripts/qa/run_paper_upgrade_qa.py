"""Exercise a legacy upgrade and second startup at four Kindle screen sizes."""
import argparse
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import zipfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--archive", type=Path, help="Test a release ZIP instead of the working tree")
args = parser.parse_args()
repo = Path(__file__).resolve().parents[2]
runtime = Path(os.environ.get("KOREADER_DIR", "/Applications/KOReader.app/Contents/koreader"))
fixtures = repo / "scripts/qa/fixtures"
dimensions = ((600, 800, 167), (758, 1024, 212), (1072, 1448, 300), (1236, 1648, 300))
for width, height, dpi in dimensions:
    root = Path(tempfile.mkdtemp(prefix=f"weui-upgrade-{width}x{height}."))
    for directory in ("plugins", "patches", "settings/weui", "library", "downloads", "cache", "data", "artifacts"):
        (root / directory).mkdir(parents=True, exist_ok=True)
    shutil.copy(fixtures / "settings.reader.lua", root)
    shutil.copy(fixtures / "weui_settings.lua", root / "settings/weui")
    shutil.copy(fixtures / "1-kpw4-profile.lua", root / "patches/2-kpw4-profile.lua")
    shutil.copy(fixtures / "2-paper-upgrade-qa.lua", root / "patches/2-paper-upgrade-qa.lua")
    shutil.copy(fixtures / "paper_stats.lua", root / "patches")
    if args.archive:
        with zipfile.ZipFile(args.archive) as archive:
            assert archive.testzip() is None, "release ZIP is corrupt"
            assert all(name.startswith("weui.koplugin/") and ".." not in Path(name).parts
                       for name in archive.namelist()), "unexpected archive path"
            archive.extractall(root / "plugins")
    else:
        (root / "plugins/weui.koplugin").symlink_to(repo, target_is_directory=True)
    (root / "library/upgrade-book.txt").write_text(
        ("旧配置升级测试\n保留书籍、分组、笔记和阅读进度。\n" * 100), encoding="utf-8"
    )
    env = dict(os.environ, KO_HOME=str(root), WEUI_PAPER_UPGRADE_QA_ROOT=str(root),
               SDL_VIDEODRIVER="offscreen", EMULATE_READER_W=str(width),
               EMULATE_READER_H=str(height), EMULATE_READER_DPI=str(dpi))
    print(f"Upgrade QA {width}×{height}, {dpi} DPI: {root}", flush=True)
    for restart in (False, True):
        phase = "restart" if restart else "upgrade"
        env["WEUI_PAPER_UPGRADE_RESTART"] = "1" if restart else "0"
        log_path = root / f"artifacts/{phase}.log"
        with log_path.open("w") as log:
            result = subprocess.run(
                [str(runtime / "luajit"), str(runtime / "reader.lua")],
                cwd=runtime, env=env, stdout=log, stderr=subprocess.STDOUT, timeout=60,
            )
        assert result.returncode == 0 and (root / f"artifacts/{phase}.pass").is_file(), log_path.read_text()[-6000:]
        print((root / f"artifacts/{phase}.pass").read_text().strip(), flush=True)
print("PAPER_UPGRADE_QA_OK: all four dimensions, real profile upgrade and restart")

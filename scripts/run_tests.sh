#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

if [ -n "${LUA_BIN:-}" ]; then
    LUA_RUNTIME=$LUA_BIN
elif command -v luajit >/dev/null 2>&1; then
    LUA_RUNTIME=$(command -v luajit)
elif [ -x /Applications/KOReader.app/Contents/koreader/luajit ]; then
    LUA_RUNTIME=/Applications/KOReader.app/Contents/koreader/luajit
elif command -v lua5.1 >/dev/null 2>&1; then
    LUA_RUNTIME=$(command -v lua5.1)
else
    echo "LuaJIT or Lua 5.1 is required" >&2
    exit 1
fi

echo "Lua runtime: $LUA_RUNTIME"

find . -type f -name '*.lua' \
    -not -path './.git/*' -not -path './dist/*' -not -path './stage/*' \
    | LC_ALL=C sort | while IFS= read -r file; do
        TARGET_LUA=$file "$LUA_RUNTIME" -e \
            'local path = assert(os.getenv("TARGET_LUA")); assert(loadfile(path))'
    done

test_count=0
for test_file in scripts/test_*.lua; do
    "$LUA_RUNTIME" "$test_file"
    test_count=$((test_count + 1))
done
echo "Lua regression tests: $test_count passed"

if command -v msgfmt >/dev/null 2>&1; then
    find l10n -type f -name 'koreader.po' | LC_ALL=C sort \
        | while IFS= read -r po_file; do
            msgfmt --check --check-format -o /dev/null "$po_file"
        done
    echo "gettext catalog validation: passed"
else
    echo "gettext catalog validation: skipped (msgfmt unavailable)"
fi

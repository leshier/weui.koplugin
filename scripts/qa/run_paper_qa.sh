#!/bin/sh
# Uses a separate KO_HOME. The user's books, accounts and statistics are untouched.
set -eu
repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
koreader_dir=${KOREADER_DIR:-/Applications/KOReader.app/Contents/koreader}
qa_root=$(mktemp -d /tmp/weui-paper-qa.XXXXXX)
mkdir -p "$qa_root/artifacts" "$qa_root/cache" "$qa_root/data" "$qa_root/patches" \
    "$qa_root/plugins" "$qa_root/settings/weui" "$qa_root/library"
cp "$repo_dir/scripts/qa/fixtures/settings.reader.lua" "$qa_root/settings.reader.lua"
cp "$repo_dir/scripts/qa/fixtures/weui_settings.lua" "$qa_root/settings/weui/weui_settings.lua"
cp "$repo_dir/scripts/qa/fixtures/1-kpw4-profile.lua" "$qa_root/patches/2-kpw4-profile.lua"
cp "$repo_dir/scripts/qa/fixtures/2-paper-qa.lua" "$qa_root/patches/2-paper-qa.lua"
ln -s "$repo_dir" "$qa_root/plugins/weui.koplugin"
printf 'Paper QA root: %s\n' "$qa_root"
status=0
KO_HOME="$qa_root" WEUI_PAPER_QA_ROOT="$qa_root" \
    EMULATE_READER_W=536 EMULATE_READER_H=724 EMULATE_READER_DPI=300 \
    python3 "$repo_dir/scripts/qa/monitor_runtime.py" \
    "$koreader_dir/luajit" "$koreader_dir/reader.lua" "$qa_root/artifacts" \
    >"$qa_root/artifacts/koreader.log" 2>&1 || status=$?
cat "$qa_root/artifacts/results.tsv"
awk -F '\t' '$1 == "FAIL" { failed = 1 } $1 == "PASS" && $2 == "suite" { complete = 1 }
    END { exit failed || !complete }' "$qa_root/artifacts/results.tsv" || status=1
exit "$status"

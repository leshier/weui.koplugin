#!/bin/sh
set -eu

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
koreader_dir=${KOREADER_DIR:-/Applications/KOReader.app/Contents/koreader}
plugin_source=${WEUI_QA_PLUGIN_SOURCE:-$repo_dir}

if [ ! -f "$plugin_source/_meta.lua" ] || [ ! -f "$plugin_source/main.lua" ]; then
    echo "Invalid WeUI plugin source: $plugin_source" >&2
    exit 2
fi

if [ -n "${WEUI_QA_HOME:-}" ]; then
    qa_root=$WEUI_QA_HOME
    case "$qa_root" in
        /|/Users|/Users/*/Desktop|/tmp) echo "Refusing unsafe WEUI_QA_HOME: $qa_root" >&2; exit 2 ;;
    esac
    mkdir -p "$qa_root"
else
    qa_root=$(mktemp -d /tmp/weui-kpw4-fullqa.XXXXXX)
fi

mkdir -p "$qa_root/artifacts" "$qa_root/cache" "$qa_root/data" \
    "$qa_root/patches" "$qa_root/plugins" "$qa_root/settings/weui" "$qa_root/library/经典"

cp "$repo_dir/scripts/qa/fixtures/settings.reader.lua" "$qa_root/settings.reader.lua"
cp "$repo_dir/scripts/qa/fixtures/weui_settings.lua" "$qa_root/settings/weui/weui_settings.lua"
cp "$repo_dir/scripts/qa/fixtures/1-kpw4-profile.lua" "$qa_root/patches/2-kpw4-profile.lua"
cp "$repo_dir/scripts/qa/fixtures/2-full-qa.lua" "$qa_root/patches/2-full-qa.lua"
cp "$repo_dir/scripts/qa/fixtures/library/欢迎使用 WeUI.txt" "$qa_root/library/欢迎使用 WeUI.txt"
cp "$repo_dir/scripts/qa/fixtures/library/隐私测试书.txt" "$qa_root/library/隐私测试书.txt"
cp "$repo_dir/scripts/qa/fixtures/library/经典/山海小记.txt" "$qa_root/library/经典/山海小记.txt"
ln -s "$plugin_source" "$qa_root/plugins/weui.koplugin"

printf 'QA root: %s\n' "$qa_root"

set +e
(
    cd "$koreader_dir"
    # macOS SDL requests a high-density backing buffer at 2x the logical
    # window size. These logical dimensions therefore produce PW4's physical
    # 1072 x 1448 framebuffer used by the assertions and screenshots.
    KO_HOME="$qa_root" \
    WEUI_QA_ROOT="$qa_root" \
    WEUI_QA_LIBRARY="$qa_root/library" \
    WEUI_QA_STAGE_FROM="${WEUI_QA_STAGE_FROM:-}" \
    WEUI_QA_STAGE_TO="${WEUI_QA_STAGE_TO:-}" \
    EMULATE_READER_W="${WEUI_QA_EMULATE_W:-536}" \
    EMULATE_READER_H="${WEUI_QA_EMULATE_H:-724}" \
    EMULATE_READER_DPI=300 \
    ./luajit ./reader.lua
) >"$qa_root/artifacts/koreader.log" 2>&1
status=$?
set -e

printf 'KOReader exit: %s\n' "$status"
printf 'Results: %s\n' "$qa_root/artifacts/results.tsv"
printf 'Log: %s\n' "$qa_root/artifacts/koreader.log"
exit "$status"

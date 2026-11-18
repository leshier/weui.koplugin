#!/bin/sh
# A persistent manual profile, separate from the user's ordinary KOReader home.
set -eu
repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
manual_home=${WEUI_MANUAL_HOME:-"$HOME/Library/Application Support/koreader-weui-test"}
case "$manual_home" in
    /*) ;;
    *) printf 'WEUI_MANUAL_HOME must be an absolute path.\n' >&2; exit 1 ;;
esac
if [ "$manual_home" = "$HOME/Library/Application Support/koreader" ]; then
    printf 'Choose a separate manual test home.\n' >&2
    exit 1
fi
if [ -d "$manual_home" ] && [ ! -f "$manual_home/.weui-manual-profile" ]; then
    printf 'Refusing to overwrite an existing unmarked profile: %s\n' "$manual_home" >&2
    exit 1
fi
mkdir -p "$manual_home/library" "$manual_home/cache" "$manual_home/data" \
    "$manual_home/patches" "$manual_home/plugins" "$manual_home/settings/weui" "$manual_home/logs"
touch "$manual_home/.weui-manual-profile"
if [ ! -f "$manual_home/settings.reader.lua" ]; then
    cp "$repo_dir/scripts/qa/fixtures/settings.reader.lua" "$manual_home/settings.reader.lua"
fi
if [ ! -f "$manual_home/settings/weui/weui_settings.lua" ]; then
    cp "$repo_dir/scripts/qa/fixtures/weui_settings.lua" "$manual_home/settings/weui/weui_settings.lua"
fi
cp "$repo_dir/scripts/qa/fixtures/1-kpw4-profile.lua" "$manual_home/patches/2-kpw4-profile.lua"
cp "$repo_dir/scripts/qa/fixtures/2-paper-manual-test.lua" "$manual_home/patches/2-paper-manual-test.lua"
if [ ! -e "$manual_home/plugins/weui.koplugin" ]; then
    ln -s "$repo_dir" "$manual_home/plugins/weui.koplugin"
fi
printf 'Manual test home: %s\n' "$manual_home"
if [ "${1:-}" = "--prepare" ]; then exit 0; fi
if [ -f "$manual_home/.weui-manual-pid" ]; then
    manual_pid=$(cat "$manual_home/.weui-manual-pid")
    case "$manual_pid" in
        ''|*[!0-9]*) ;;
        *)
            if kill -0 "$manual_pid" 2>/dev/null; then
                printf 'Manual test profile is already running (PID %s).\n' "$manual_pid"
                exit 0
            fi
            ;;
    esac
fi
if pgrep -x koreader >/dev/null 2>&1; then
    printf 'Exit the running KOReader before opening the independent test profile.\n' >&2
    exit 1
fi
touch "$manual_home/logs/stdout.log" "$manual_home/logs/stderr.log"
chmod 600 "$manual_home/logs/stdout.log" "$manual_home/logs/stderr.log"
/usr/bin/open -a /Applications/KOReader.app \
    --env "KO_HOME=$manual_home" \
    --env "EMULATE_READER_W=536" --env "EMULATE_READER_H=724" --env "EMULATE_READER_DPI=300" \
    --stdout "$manual_home/logs/stdout.log" --stderr "$manual_home/logs/stderr.log" --args -d

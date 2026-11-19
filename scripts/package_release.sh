#!/bin/bash
# The updater expects one weui.koplugin/ root and this fixed asset name.
set -euo pipefail
repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
output_dir=${1:-"$repo_dir/dist"}
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/weui-release.XXXXXX")
trap 'rm -rf "$work_dir"' EXIT
mkdir -p "$work_dir/weui.koplugin" "$output_dir"

# Include runtime roots explicitly. Local profiles, design previews and
# developer tooling cannot enter the archive, even when packaging locally.
rsync -a \
    --exclude='.DS_Store' \
    --exclude='__pycache__' \
    --exclude='*.pyc' \
    --exclude='*.swp' \
    --exclude='*~' \
    --exclude='weui_update.zip' \
    --exclude='zlibrary_credentials.lua' \
    --exclude='/weread/spec/' \
    --include='/_meta.lua' \
    --include='/main.lua' \
    --include='/weui_*.lua' \
    --include='/README.md' \
    --include='/LICENSE*' \
    --include='/NOTICE*' \
    --include='/desktop_modules/***' \
    --include='/fonts/***' \
    --include='/icons/***' \
    --include='/l10n/***' \
    --include='/lib/***' \
    --include='/locale/***' \
    --include='/ui/***' \
    --include='/weread/***' \
    --include='/zlibrary/***' \
    --exclude='/*' \
    "$repo_dir/" "$work_dir/weui.koplugin/"

for required in \
    _meta.lua main.lua weui_initialize.lua weui_paper.lua weui_paper_groups.lua weui_migrations.lua weui_network.lua \
    weui_paper_stats.lua weui_paper_downloads.lua weui_refresh.lua \
    weui_weread_features.lua lib/weread_client.lua lib/weread_downloader.lua \
    weread/UPSTREAM.md weread/lib/settings.lua weread/lib/downloader.lua \
    zlibrary/embedded_plugin.lua zlibrary/runtime_locale.lua \
    fonts/PaperSong.ttf fonts/PaperSong-OFL.txt fonts/NotoEmoji-Regular.ttf \
    fonts/NotoEmoji-OFL.txt LICENSE LICENSE.weread NOTICE.weread LICENSE.zlibrary
do
    test -f "$work_dir/weui.koplugin/$required"
done

( cd "$work_dir" && zip -rq weui.koplugin.zip weui.koplugin )
unzip -tq "$work_dir/weui.koplugin.zip"
unzip -Z1 "$work_dir/weui.koplugin.zip" > "$work_dir/contents.txt"
if grep -Eq '(^weui.koplugin/(scripts|design|\.github|\.screenshots|\.trae-html-share-packages)/|^weui.koplugin/weread/spec/|zlibrary_credentials\.lua$)' "$work_dir/contents.txt"; then
    echo "development files or credentials leaked into release package" >&2
    exit 1
fi
test "$(sed -n 's#^\([^/]*\)/.*#\1#p' "$work_dir/contents.txt" | sort -u)" = "weui.koplugin"
cp "$work_dir/weui.koplugin.zip" "$output_dir/weui.koplugin.zip"
# Only this separate, manually installed asset opts into clearing old settings.
printf 'weui-initialize-1.5.4\n' > "$work_dir/weui.koplugin/weui-initialize.request"
( cd "$work_dir" && zip -rq weui.koplugin-initialize.zip weui.koplugin )
unzip -tq "$work_dir/weui.koplugin-initialize.zip"
cp "$work_dir/weui.koplugin-initialize.zip" "$output_dir/weui.koplugin-initialize.zip"
ls -lh "$output_dir/weui.koplugin.zip" "$output_dir/weui.koplugin-initialize.zip"

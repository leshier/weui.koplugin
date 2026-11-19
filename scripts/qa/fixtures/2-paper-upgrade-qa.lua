-- Seed a v1.5.0 profile before plugin initialization, then check native pages.
local root = assert(os.getenv("WEUI_PAPER_UPGRADE_QA_ROOT"))
local restarting = os.getenv("WEUI_PAPER_UPGRADE_RESTART") == "1"
package.path = root .. "/plugins/weui.koplugin/?.lua;" .. package.path
local Store = require("weui_store")
local Config = require("weui_config")
local Screen = require("device").screen
local UIManager = require("ui/uimanager")
local LuaSettings = require("luasettings")
local settingsdir = require("datastorage"):getSettingsDir()
local library = root .. "/library"
local file = library .. "/upgrade-book.txt"
G_reader_settings:saveSetting("home_dir", library)
G_reader_settings:saveSetting("lastdir", library)
local scales = {
    "weui_style_font_scale_pct", "weui_bar_size_pct", "weui_topbar_size_pct",
    "weui_bar_bottom_margin_pct", "weui_bar_icon_scale_pct",
    "weui_bar_label_scale_pct", "weui_bar_rs_text_scale_pct",
    "weui_hs_module_scale", "weui_hs_label_scale",
}
if not restarting then
    for _, version in ipairs({
        "v2", "v3", "v4", "v5", "v6", "v7", "v8",
        "v9_weread_between_home_history", "v10_restore_classic_ui", "v15_paper",
    }) do Store:setNoFlush("weui_settings_migrated_" .. version, true) end
    Store:setNoFlush("weui_bar_tabs", { "home", "weread", "power", "homescreen" })
    Store:setNoFlush("weui_paper_home", false)
    Store:setNoFlush("weui_bar_mode", "icons")
    Store:setNoFlush("weui_bar_navpager_enabled", true)
    Store:setNoFlush("weui_navbar_transparent", true)
    Store:setNoFlush("weui_statusbar_transparent", true)
    for _, key in ipairs(scales) do Store:setNoFlush(key, 150) end
    Store:setNoFlush("weui_hs_module_order", {
        "quote", "currently", "recent", "clock", "coverdeck", "new_books", "tbr",
        "collections", "reading_goals", "reading_stats", "quick_actions_row_000001",
        "quick_actions_row_000002", "quick_actions_row_000003", "action_list",
    })
    Store:setNoFlush("weui_layout", { pages = {
        { modules = { "clock", "quote" } }, { modules = { "reading_goals" } },
    } })
    Store:setNoFlush("weui_private_books", { [file] = true })
    Store:setNoFlush("weui_privacy_password", "upgrade-fixture-password")
    Store:setNoFlush("weui_privacy_autolock_minutes", 7)
    Store:setNoFlush("weui_reading_goal_physical", 42)
    Store:setNoFlush("weui_zlibrary_proxy_enabled", false)
    Store:setNoFlush("weui_zlibrary_proxy_url", "socks5://127.0.0.1:1080")
    Store:setNoFlush("weui_tbr_list", { file })
    Store:flush()
    local ds = require("docsettings"):open(file)
    ds:saveSetting("doc_props", { title = "旧配置升级测试", authors = "测试作者" })
    ds:saveSetting("percent_finished", 0.42)
    ds:saveSetting("summary", { status = "reading" })
    ds:saveSetting("annotations", { { text = "需要保留的笔记", note = "原有想法", pageno = 12 } })
    ds:flush()
    local collections = LuaSettings:open(settingsdir .. "/collection.lua")
    collections:saveSetting("Upgrade", { { file = file, order = 1 }, settings = { order = 2 } })
    collections:flush()
    local wr = LuaSettings:open(settingsdir .. "/weread.lua")
    wr:saveSetting("auth_schema_version", 1)
    wr:saveSetting("api_key", "upgrade-fixture-key")
    wr:saveSetting("cookies", { wr_skey = "upgrade-fixture-cookie" })
    wr:saveSetting("account", { name = "升级测试", user_vid = "fixture" })
    wr:saveSetting("download_dir", root .. "/downloads")
    wr:saveSetting("sync", { pull_on_open = false, upload_on_close = false, ask_on_conflict = false })
    wr:flush()
    local conn = require("lua-ljsqlite3/init").open(Config.getStatsDbPath())
    dofile(root .. "/patches/paper_stats.lua").create(conn)
    conn:exec("INSERT INTO book(id,title,authors,md5) VALUES(1,'升级测试','测试作者','upgrade-fixture');")
    conn:exec("INSERT INTO page_stat_data VALUES(1,12,1234567890,60,200);")
    conn:close()
end

-- Prime the same caches an old profile can populate before the upgrade repair.
assert(Config.getNavbarMode() == (restarting and "labels" or "icons"))
assert(#Config.loadTabConfig() == (restarting and 3 or 4))
Config.getScaledLabelH()
local Bottom = require("weui_bottombar")
local Top = require("weui_topbar")
Bottom.BAR_H(); Bottom.ICON_SZ(); Bottom.BOT_SP(); Top.TOPBAR_H()
local started = false
require("userpatch").registerPatchPluginFunc("weui", function()
    if started then return end
    started = true
    UIManager:scheduleIn(2, function()
        local ok, err = xpcall(function()
            local plugin = assert(require("apps/filemanager/filemanager").instance._weui_plugin)
            local Paper = require("weui_paper")
            local backup = assert(Store:get("weui_paper_layout_backup_v1"))
            assert(Store:get("weui_paper_layout_revision") == 1)
            assert(backup.values.weui_paper_home == false and backup.values.weui_bar_mode == "icons")
            assert(backup.values.weui_bar_tabs[2] == "weread")
            for _, key in ipairs(scales) do assert(backup.values[key] == 150, "backup: " .. key) end
            if restarting then
                assert(Config.getFontScalePct() == 110, "restart reset new font preference")
                assert(Config.getNavbarMode() == "labels" and #Config.loadTabConfig() == 3)
                assert(Store:get("weui_paper_home") == false and Config.isNavpagerEnabled())
                assert(require("ui/font")._weui_getface_patched, "new font preference not applied")
            else
                assert(Paper.isMain("homescreen"), "old module order retained the old renderer")
                assert(Config.getNavbarMode() == "both", "stale navbar mode cache")
                assert(table.concat(Config.loadTabConfig(), "|") == table.concat(Config.DEFAULT_TABS, "|"),
                    "stale navigation tabs cache")
                for _, key in ipairs(scales) do assert(Store:get(key) == 100, "scale: " .. key) end
                assert(not require("ui/font")._weui_getface_patched, "old font multiplier survived")
                assert(not Config.isNavpagerEnabled())
                assert(not Store:isTrue("weui_navbar_transparent") and not Store:isTrue("weui_statusbar_transparent"))
                assert(Bottom.BAR_H() == Screen:scaleBySize(96), "stale bar height cache")
                assert(Bottom.ICON_SZ() == Screen:scaleBySize(44), "stale icon cache")
                assert(Bottom.BOT_SP() == Screen:scaleBySize(12), "stale margin cache")
                assert(Top.TOPBAR_H() == require("weui_style").FS_TITLE, "stale topbar cache")
                for _, id in ipairs(Config.DEFAULT_TABS) do
                    local page = assert(Paper.navigate(plugin, id))
                    assert(page.screen == id and #page.items > 0)
                    assert(math.abs(page:face("song", 24).size - page:px(24)) <= 1,
                        "Paper font was scaled twice")
                    for _, hit in ipairs(page.hits) do
                        assert(page.offset + hit.x >= 0 and hit.y >= 0
                            and page.offset + hit.x + hit.w <= page.dimen.w + 1
                            and hit.y + hit.h <= page.dimen.h + 1, "touch target outside screen: " .. id)
                    end
                    for _, item in ipairs(page.items) do
                        if item.widget then
                            local size = item.widget:getSize()
                            assert(page.offset + item.x >= 0 and item.y >= 0
                                and page.offset + item.x + size.w <= page.dimen.w + 1
                                and item.y + size.h <= page.dimen.h + 1, "widget outside screen: " .. id)
                        end
                    end
                    UIManager:forceRePaint()
                    Screen:shot(root .. "/artifacts/" .. id .. ".png")
                end
            end
            local stored = LuaSettings:open(settingsdir .. "/weui/weui_settings.lua")
            assert(stored:readSetting("weui_paper_layout_revision") == 1, "revision not persisted")
            assert(#Store:get("weui_hs_module_order") == 14 and #Store:get("weui_layout").pages == 2)
            assert(Store:get("weui_private_books")[file] and Store:get("weui_privacy_password") == "upgrade-fixture-password")
            assert(Store:get("weui_privacy_autolock_minutes") == 7 and Store:get("weui_reading_goal_physical") == 42)
            assert(Store:get("weui_zlibrary_proxy_url") == "socks5://127.0.0.1:1080" and Store:get("weui_tbr_list")[1] == file)
            local ds = require("docsettings"):open(file)
            assert(ds:readSetting("percent_finished") == 0.42 and ds:readSetting("annotations")[1].note == "原有想法")
            assert(LuaSettings:open(settingsdir .. "/collection.lua"):readSetting("Upgrade")[1].file == file)
            assert(require("readcollection").coll.Upgrade[require("ffi/util").realpath(file)], "native collection membership changed")
            local wr = plugin._weread_plugin.settings
            assert(wr:get("api_key") == "upgrade-fixture-key" and wr:get("cookies").wr_skey == "upgrade-fixture-cookie")
            assert(wr:get("account").name == "升级测试" and wr:get("download_dir") == root .. "/downloads")
            assert(wr:get("sync").ask_on_conflict == false)
            local conn = require("lua-ljsqlite3/init").open(Config.getStatsDbPath())
            assert(conn:rowexec("SELECT sum(duration) FROM page_stat_data;") == 60, "statistics changed")
            conn:close()
            if not restarting then
                Store:setNoFlush("weui_paper_home", false)
                Store:setNoFlush("weui_style_font_scale_pct", 110)
                Store:setNoFlush("weui_bar_mode", "labels")
                Store:setNoFlush("weui_bar_tabs", { "homescreen", "home", "weread" })
                Store:setNoFlush("weui_bar_navpager_enabled", true)
                Store:flush()
            end
            local marker = assert(io.open(root .. "/artifacts/" .. (restarting and "restart.pass" or "upgrade.pass"), "w"))
            marker:write("PASS: ", restarting and "restart preserves new preferences" or "legacy upgrade repairs layout and preserves data", "\n")
            marker:close()
        end, debug.traceback)
        if not ok then require("logger").err("Paper upgrade QA:", err) end
        UIManager:quit(ok and 0 or 1)
    end)
end)

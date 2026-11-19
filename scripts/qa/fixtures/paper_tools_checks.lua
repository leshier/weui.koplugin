-- Runs inside the native paper suite, never against the user's profile.
return function(ctx)
    local add, Paper, plugin = ctx.add, ctx.Paper, ctx.plugin
    local tapLabel, top, closeToPage, geometry = ctx.tapLabel, ctx.topWidget, ctx.closeToPage, ctx.geometry
    local UIManager = require("ui/uimanager")
    local Store = require("weui_store")
    local Proxy = require("weui_zlibrary_proxy")
    local Lock = require("weui_lockscreen")
    local Device = require("device")
    local _ = require("weui_i18n").translate
    local page, proxy_items
    local function label(index) return proxy_items[index].text_func and proxy_items[index].text_func() or proxy_items[index].text end
    local function input(value, save)
        local dialog = top()
        assert(dialog.setInputText, "native input editor missing")
        dialog:setInputText(value)
        dialog.buttons[1][save and 2 or 1].callback()
        return dialog
    end
    add("106a-more-tools", function()
        page = Paper.navigate(plugin, "weui_settings")
        plugin = page.plugin -- Reader flows recreate FileManager and its plugin.
        -- Exit the overlay and use the actual native bottom-tab callback.
        page:onClose()
        plugin:_onTabTap("weui_settings", plugin.ui)
        page = Paper._instance
        assert(page and page.screen == "weui_settings" and top() == page, "native More tab opened the legacy settings menu")
        for _, name in ipairs({ "Z-Library 账号与代理", "自定义锁屏", "系统更新" }) do
            tapLabel(page, name); geometry(page)
            assert(top() == page and page.tab == "weui_settings", "tool opened outside More")
            page:onClose(); assert(page.screen == "weui_settings", "tool Back lost More")
        end
        tapLabel(page, "Z-Library 账号与代理")
        proxy_items = Proxy.getMenuItems()
        tapLabel(page, label(1))
        assert(top().text:find("代理"), "missing-server error absent")
        closeToPage()
    end)
    add("106b-proxy-address-cancel", function()
        tapLabel(page, label(2)); input("socks5://127.0.0.1:9", false)
        assert(Store:get("weui_zlibrary_proxy_url") == nil, "address cancel saved config")
    end)
    add("106c-proxy-address-invalid", function()
        tapLabel(page, label(2))
        local dialog = input("socks5://127.0.0.1:70000", true)
        assert(top() ~= dialog and Store:get("weui_zlibrary_proxy_url") == nil, "invalid port accepted")
        UIManager:close(top()); assert(top() == dialog, "validation dismissed editor")
        dialog.buttons[1][1].callback()
    end)
    add("106d-proxy-address-save", function()
        tapLabel(page, label(2)); input("socks5h://127.0.0.1:9", true)
        assert(Proxy._readConfig().scheme == "socks5", "SOCKS5h not normalized")
        assert(ctx.hasText(page, label(2)), "saved address label stale")
    end)
    add("106e-proxy-credentials", function()
        for _, index in ipairs({ 3, 4 }) do
            tapLabel(page, label(index)); input("qa-credential", false)
            tapLabel(page, label(index))
            if index == 4 then assert(top().text_type == "password", "proxy password visible") end
            input("qa-credential", true)
            assert(ctx.hasText(page, label(index)), "credential status stale")
        end
        tapLabel(page, label(1)); closeToPage()
        assert(Proxy.isEnabled() and Proxy.isReady(), "proxy enable did not install transport")
        tapLabel(page, label(1)); closeToPage()
        assert(not Proxy.isEnabled(), "proxy disable failed")
        tapLabel(page, label(1)); closeToPage()
    end)
    add("106f-proxy-probe-start", function() tapLabel(page, label(5)) end)
    add("106g-proxy-probe-error", function()
        return function()
            local widget = top()
            if type(widget.text) ~= "string" or not widget.text:find("直连") then return false end
            closeToPage()
            return true
        end
    end)
    add("106h-proxy-help", function()
        tapLabel(page, label(6))
        assert(top().text and #top().text > 100, "proxy help missing")
        UIManager:close(top())
        tapLabel(page, label(7))
        local confirm = top(); assert(confirm.cancel_callback == nil or type(confirm.cancel_callback) == "function")
        UIManager:close(confirm)
        assert(Proxy.isEnabled(), "clear cancellation changed config")
    end)
    add("106i-proxy-clear-and-return", function()
        tapLabel(page, label(7)); top().ok_callback(); UIManager:close(top()); closeToPage()
        assert(not Proxy.isEnabled() and Store:get("weui_zlibrary_proxy_url") == nil
            and Store:get("weui_zlibrary_proxy_password") == nil, "clear retained proxy credentials")
        page:onClose(); assert(page.screen == "weui_settings", "proxy return")
    end)
    local Updater, OTA, original_check, original_ota, original_capability
    local checks, ota_checks = 0, 0
    add("106j-system-updates", function()
        tapLabel(page, "系统更新"); geometry(page)
        Updater, OTA = require("weui_updater"), require("ui/otamanager")
        original_check, original_ota, original_capability = Updater.checkForUpdates, OTA.fetchAndProcessUpdate, Device.hasOTAUpdates
        Updater.checkForUpdates = function() checks = checks + 1 end
        OTA.fetchAndProcessUpdate = function() ota_checks = ota_checks + 1 end
        tapLabel(page, "检查 WeUI 更新")
        assert(checks == 1 and top() == page, "WeUI update action lost page")
        Device.hasOTAUpdates = function() return true end; page:rebuild()
        tapLabel(page, "检查 KOReader 更新"); assert(ota_checks == 1, "native OTA action not called")
        Device.hasOTAUpdates = function() return false end; page:rebuild()
        tapLabel(page, "检查 KOReader 更新"); assert(top().text:find("不支持"), "unsupported OTA state absent")
        closeToPage()
        Updater.checkForUpdates, OTA.fetchAndProcessUpdate, Device.hasOTAUpdates = original_check, original_ota, original_capability
    end)
    add("106k-update-channel-server", function()
        for _, spec in ipairs({
            { label = "KOReader 更新频道", get = "getOTAChannel", choices = "genChannelList", set = "setOTAChannel" },
            { label = "KOReader 更新服务器", get = "getOTAServer", choices = "genServerList", set = "setOTAServer" },
        }) do
            local old = OTA[spec.get](OTA)
            tapLabel(page, spec.label); geometry(page)
            local choices = OTA[spec.choices](OTA)
            for _, choice in ipairs(choices) do
                tapLabel(page, choice.text)
                assert(choice.checked_func(), "native update choice not saved")
                assert(top() == page, "update setting lost foreground")
            end
            page:onClose(); assert(page.screen == "system_updates" and #page.tool_stack == 0, "nested update Back")
            OTA[spec.set](OTA, old)
        end
    end)
    add("106l-update-address-proxy", function()
        local old = Updater.getCustomApiUrl()
        tapLabel(page, "WeUI 更新地址"); input("https://example.invalid/meta.lua", false)
        assert(Updater.getCustomApiUrl() == old, "update address cancel saved")
        tapLabel(page, "WeUI 更新地址"); input("https://example.invalid/meta.lua", true)
        assert(Updater.getCustomApiUrl() == "https://example.invalid/meta.lua", "update address not saved")
        tapLabel(page, "WeUI 更新地址"); input("", true)
        assert(Updater.getCustomApiUrl() == "", "default update URL not restored")
        local proxy = Updater.getUseZlibraryProxy()
        tapLabel(page, "WeUI 更新使用 Z-Library 代理")
        assert(Updater.getUseZlibraryProxy() ~= proxy, "update proxy setting ignored")
        tapLabel(page, "WeUI 更新使用 Z-Library 代理")
        Updater.setCustomApiUrl(old)
        page:onClose()
    end)
    add("106m-lockscreen-native-preview", function()
        tapLabel(page, "自定义锁屏"); geometry(page)
        tapLabel(page, "预览锁屏")
        assert(top().text:find("KOReader"), "native-preview hint missing")
        closeToPage()
        assert(not Lock.setMode("unknown"), "invalid lockscreen mode accepted")
    end)
    for _, mode in ipairs({ "recent", "stats", "calendar" }) do
        add("106n-lockscreen-" .. mode, function()
            for _, entry in ipairs(Lock.modes) do if entry.id == mode then tapLabel(page, entry.label) end end
            tapLabel(page, "预览锁屏")
            local preview = top()
            assert(preview.name == "weui_lockscreen_preview" and Paper._instance == page, "preview changed current page")
            geometry(preview)
            if mode == "stats" then
                local data = require("weui_library").stats("week", nil, page.books)
                assert(preview.snapshot_stats.seconds == data.seconds, "lockscreen statistics differ")
            end
            -- The stage screenshot is the actual preview, closed in next stage.
        end)
        add("106o-lockscreen-preview-back-" .. mode, function()
            local preview = top()
            if mode == "recent" then preview:handleEvent(require("ui/event"):new("Close"))
            else preview:onClose() end
            assert(top() == page and page.screen == "lockscreen_settings" and Lock.getMode() == mode, "preview Back lost settings")
        end)
    end
    add("106p-lockscreen-calendar-landscape", function()
        require("device").screen:setRotationMode(1); page:rebuild()
        tapLabel(page, "预览锁屏"); geometry(top())
        assert(top().dimen.w > top().dimen.h, "landscape preview not adapted")
    end)
    add("106q-lockscreen-calendar-portrait", function()
        top():onClose()
        require("device").screen:setRotationMode(0); page:rebuild()
        local snapshot = Paper.newLockscreen("calendar", plugin, os.time{ year = 2028, month = 2, day = 29, hour = 12 })
        assert(ctx.hasText(snapshot, "29") and not ctx.hasText(snapshot, "30"), "leap-year calendar")
        snapshot:free()
        snapshot = Paper.newLockscreen("calendar", plugin, os.time{ year = 2026, month = 11, day = 17, hour = 12 })
        geometry(snapshot); snapshot:free()
    end)
    local original_delay, original_mode, Screensaver
    add("106r-native-suspend", function()
        Screensaver = require("ui/screensaver")
        original_delay, original_mode = G_reader_settings:readSetting("screensaver_delay"), G_reader_settings:readSetting("screensaver_type")
        G_reader_settings:saveSetting("screensaver_delay", "disable")
        Device:simulateSuspend()
        assert(Device.screen_saver_mode and Screensaver.screensaver_widget == top(), "native suspend omitted custom snapshot")
        assert(Screensaver.ui == plugin.ui, "screensaver facade escaped show scope")
        assert(Screensaver.screensaver_widget.widget.mode == "calendar", "wrong native snapshot")
    end)
    add("106s-native-resume", function()
        Device:simulateResume()
        assert(not Device.screen_saver_mode and not Screensaver.screensaver_widget and top() == page, "native resume leaked lockscreen")
        assert(Paper._instance == page and page.screen == "lockscreen_settings", "resume lost paper origin")
    end)
    add("106t-native-gesture-lock", function()
        G_reader_settings:saveSetting("screensaver_delay", "gesture")
        Device:simulateSuspend()
        assert(top() == Screensaver.screensaver_lock_widget and top().ui == plugin.ui, "native gesture lock missing")
        Device:simulateResume(); top():onResume()
        assert(Device.screen_saver_lock and top() == Screensaver.screensaver_lock_widget, "gesture lock closed on resume")
        top():onExitScreensaver()
        assert(top() == page and not Device.screen_saver_mode and not Device.screen_saver_lock, "gesture unlock lost page")
    end)
    add("106u-native-delayed-exit", function()
        G_reader_settings:saveSetting("screensaver_delay", "0.1")
        Device:simulateSuspend(); Device:simulateResume()
        assert(Screensaver.delayed_close and Screensaver.screensaver_widget, "native delayed exit bypassed")
        return function()
            if Screensaver.screensaver_widget then return false end
            assert(top() == page and not Device.screen_saver_mode, "delayed resume lost page")
            return true
        end
    end)
    add("106v-private-lockscreen", function()
        local Privacy = require("weui_privacy")
        local book
        for _, candidate in ipairs(require("weui_library").books(plugin, true)) do
            if candidate.last_read > 0 then book = candidate; break end
        end
        assert(book, "private snapshot fixture missing")
        local old = Privacy.isPrivateBook(book.filepath, book.title)
        local unlocked = Privacy.isUnlocked
        Privacy.setPrivateBook(book.filepath, true, book.title)
        Privacy.isUnlocked = function() return true end
        require("weui_library").invalidate()
        for _, mode in ipairs({ "recent", "stats" }) do
            local snapshot = Paper.newLockscreen(mode, plugin)
            assert(not ctx.hasText(snapshot, book.title), "unlocked private title leaked on lockscreen")
            for _, entry in ipairs(snapshot.books) do if entry.md5 == book.md5 then
                assert(entry.private and entry.filepath == nil and entry.title == Privacy.privateTitle(), "private cover path retained")
            end end
            snapshot:free()
        end
        Privacy.isUnlocked = unlocked
        Privacy.setPrivateBook(book.filepath, old, book.title)
        require("weui_library").invalidate()
    end)
    add("106va-lockscreen-empty-state", function()
        local Library = require("weui_library")
        local Config = require("weui_config")
        local books, db = Library.books, Config.getStatsDbPath
        Library.books = function() return {} end
        Config.getStatsDbPath = function() return ctx.root .. "/missing-statistics.sqlite3" end
        local recent = Paper.newLockscreen("recent", plugin)
        assert(ctx.hasText(recent, "下一本书，等你翻开"), "empty recent lockscreen")
        recent:free()
        local stats = Paper.newLockscreen("stats", plugin)
        assert(stats.snapshot_stats.seconds == 0 and ctx.hasText(stats, "今天，给阅读留一点时间"), "empty statistics lockscreen")
        stats:free()
        Library.books, Config.getStatsDbPath = books, db
    end)
    add("106vb-native-extra-flash", function()
        G_reader_settings:saveSetting("screensaver_extra_flash_count", 1)
        G_reader_settings:saveSetting("screensaver_extra_flash_delay", 20)
        G_reader_settings:saveSetting("screensaver_delay", "disable")
        Device:simulateSuspend()
        assert(Screensaver.bb_copy and Device.screensaver_suspend_wait_timeout, "native anti-ghosting flash bypassed")
        return function()
            if Screensaver.bb_copy then return false end
            Device:simulateResume()
            assert(top() == page and not Device.screen_saver_mode and not Device.screensaver_suspend_wait_timeout, "extra flash cleanup failed")
            G_reader_settings:delSetting("screensaver_extra_flash_count")
            G_reader_settings:delSetting("screensaver_extra_flash_delay")
            return true
        end
    end)
    add("106w-native-mode-restore", function()
        Lock.setMode("native")
        G_reader_settings:saveSetting("screensaver_type", "disable")
        G_reader_settings:saveSetting("screensaver_show_message", false)
        G_reader_settings:saveSetting("screensaver_delay", "disable")
        Device:simulateSuspend()
        assert(Screensaver._weui_snapshot_mode == nil and Screensaver.screensaver_type == "disable", "custom mode blocked native setting")
        Device:simulateResume()
        G_reader_settings:saveSetting("screensaver_type", original_mode)
        G_reader_settings:saveSetting("screensaver_delay", original_delay)
        page:onClose(); assert(page.screen == "weui_settings", "lock settings return")
    end)
    add("106x-tools-landscape-and-tabs", function()
        require("device").screen:setRotationMode(1); page:rebuild()
        for _, screen in ipairs({ "proxy_settings", "lockscreen_settings", "system_updates" }) do
            page:showTool(screen); geometry(page)
            page:onShelf()
            assert(Paper._instance.screen == "home" and top() == Paper._instance, "tool navbar stranded page")
            page = Paper.navigate(plugin, "weui_settings")
        end
        require("device").screen:setRotationMode(0); page:rebuild()
    end)
    local reader
    add("106y-reader-suspend-open", function()
        Lock.setMode("recent")
        local book
        for _, candidate in ipairs(page.books) do
            if candidate.filepath and not require("weui_privacy").isPrivateBook(candidate.filepath) then book = candidate; break end
        end
        assert(book, "reader suspend fixture missing")
        page:openBook(book)
    end)
    add("106z-reader-suspend", function()
        reader = assert(require("apps/reader/readerui").instance)
        G_reader_settings:saveSetting("screensaver_delay", "disable")
        Device:simulateSuspend()
        assert(Screensaver.ui == reader and Screensaver.screensaver_widget.widget.mode == "recent", "reader lockscreen lost native UI")
        Device:simulateResume()
        assert(top() == reader and not Device.screen_saver_mode, "reader wakeup lost reading page")
    end)
    add("106za-reader-resume-return", function()
        assert(top() == reader, "deferred wakeup replaced reader")
        reader:handleEvent(require("ui/event"):new("Close"))
    end)
    add("106zb-reader-suspend-cleanup", function()
        assert(Paper._instance and Paper._instance.screen == "weui_settings" and top() == Paper._instance, "reader suspend return lost More")
        Lock.setMode("native")
        G_reader_settings:saveSetting("screensaver_delay", original_delay)
    end)
end

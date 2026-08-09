local logger = require("logger")
local UIManager = require("ui/uimanager")
local userpatch = require("userpatch")

local qa_root = assert(os.getenv("WEUI_QA_ROOT"), "WEUI_QA_ROOT is required")
local library = assert(os.getenv("WEUI_QA_LIBRARY"), "WEUI_QA_LIBRARY is required")
local artifacts = qa_root .. "/artifacts"
local results_path = artifacts .. "/results.tsv"

G_reader_settings:saveSetting("home_dir", library)
G_reader_settings:saveSetting("lastdir", library)
G_reader_settings:saveSetting("screenshot_dir", artifacts)
G_reader_settings:saveSetting("last_migration_date", 20260623)

local function append_result(status, name, detail)
    local fh = io.open(results_path, "ab")
    if fh then
        fh:write(status, "\t", name, "\t", tostring(detail or ""), "\n")
        fh:close()
    end
    logger.info("[WEUI-QA]", status, name, tostring(detail or ""))
end

local function traceback(err)
    return debug.traceback(tostring(err), 2)
end

local function top_widget()
    local stack = UIManager._window_stack or {}
    local entry = stack[#stack]
    return entry and entry.widget or nil
end

local function current_plugin()
    local RUI = package.loaded["apps/reader/readerui"]
    if RUI and RUI.instance and RUI.instance.weui then return RUI.instance.weui end
    local FM = package.loaded["apps/filemanager/filemanager"]
    if FM and FM.instance and FM.instance.weui then return FM.instance.weui end
end

local function current_sui()
    local SUI = package.loaded["weui_window"] or require("weui_window")
    return SUI._open_instances[#SUI._open_instances]
end

local function safe_close(widget)
    if widget and UIManager:isWidgetShown(widget) then
        pcall(UIManager.close, UIManager, widget)
    end
end

local function safe_close_sui(win)
    if win and type(win.close) == "function" then pcall(win.close, win) end
end

local function audit_dimensions(name)
    local bad = {}
    local seen = {}
    local function walk(node, path, depth)
        if type(node) ~= "table" or seen[node] or depth > 22 then return end
        seen[node] = true
        local d = rawget(node, "dimen")
        if type(d) == "table" then
            local w, h = tonumber(d.w), tonumber(d.h)
            if (w and w < 0) or (h and h < 0) then
                bad[#bad + 1] = path .. "=" .. tostring(w) .. "x" .. tostring(h)
            end
        end
        for k, child in pairs(node) do
            if type(k) == "number" and type(child) == "table" then
                walk(child, path .. "/" .. tostring(k), depth + 1)
            end
        end
    end
    for i, entry in ipairs(UIManager._window_stack or {}) do
        walk(entry.widget, "stack" .. tostring(i), 0)
    end
    assert(#bad == 0, name .. ": invalid dimensions: " .. table.concat(bad, ", "))
end

local function trace_edge_widgets(name)
    local fh = io.open(artifacts .. "/edge-widgets.tsv", "ab")
    if not fh then return end
    local seen = {}
    local function walk(node, path, depth)
        if type(node) ~= "table" or seen[node] or depth > 24 then return end
        seen[node] = true
        local d = rawget(node, "dimen")
        if type(d) == "table" then
            local x, y, w, h = tonumber(d.x), tonumber(d.y), tonumber(d.w), tonumber(d.h)
            if x and y and w and h and (x >= 1000 or x + w >= 1050) then
                fh:write(name, "\t", path, "\t", tostring(node.name or ""),
                    "\t", x, ",", y, ",", w, ",", h, "\n")
            end
        end
        for k, child in pairs(node) do
            if type(k) == "number" and type(child) == "table" then
                walk(child, path .. "/" .. tostring(k), depth + 1)
            end
        end
    end
    for i, entry in ipairs(UIManager._window_stack or {}) do
        walk(entry.widget, "stack" .. tostring(i), 0)
    end
    fh:close()
end

local stages = {}
local function add(name, action, opts)
    opts = opts or {}
    stages[#stages + 1] = {
        name = name,
        action = action,
        wait = opts.wait or 0.65,
        screenshot = opts.screenshot ~= false,
        cleanup = opts.cleanup,
    }
end

local settings_win
local onboarding_win
local weread_menu
local offline_win
local zlibrary_list
local zlibrary_details
local zlibrary_credentials

add("01-home", function()
    local Screen = require("device").screen
    assert(Screen:getWidth() == 1072, "expected width 1072, got " .. tostring(Screen:getWidth()))
    assert(Screen:getHeight() == 1448, "expected height 1448, got " .. tostring(Screen:getHeight()))
    assert(require("device"):hasColorScreen() == false, "PW4 profile must be grayscale")
    local HS = require("weui_homescreen")
    if not HS._instance then current_plugin():onWeUIGoHomescreen() end
end, { wait = 1.5 })

add("02-library-root", function()
    assert(current_plugin(), "WeUI FileManager plugin missing")
    current_plugin():onWeUIGoLibrary()
end)

add("03-private-book-masked", function()
    local Privacy = require("weui_privacy")
    local private_file = library .. "/隐私测试书.txt"
    Privacy.setPrivateBook(private_file, true, "隐私测试书")
    Privacy.lockNow()
    assert(Privacy.isPrivateBook(private_file, "隐私测试书"), "private book was not persisted")
    local FM = require("apps/filemanager/filemanager")
    assert(FM.instance and FM.instance.file_chooser, "FileManager missing")
    FM.instance.file_chooser:refreshPath()
end, { wait = 3.2 })

add("04-library-nested", function()
    local FM = require("apps/filemanager/filemanager")
    assert(FM.instance and FM.instance.file_chooser, "FileManager missing")
    FM.instance.file_chooser:changeToPath(library .. "/经典")
end)

add("05-home-return", function()
    current_plugin():onWeUIGoHomescreen()
end)

add("06-settings-root", function()
    current_plugin():onWeUISettingsWindow()
    settings_win = current_sui()
    assert(settings_win and settings_win._name == "weui_win_settings", "settings window did not open")
end)

for _, spec in ipairs({
    { "07-settings-home", "home_screen_settings" },
    { "08-settings-bars", "bars_settings" },
    { "09-settings-library", "library_settings" },
    { "10-settings-style", "style_settings" },
    { "11-settings-layout", "pages" },
    { "12-settings-about", "about_settings" },
}) do
    add(spec[1], function()
        while #settings_win._nav_stack > 1 do settings_win:_navPop() end
        settings_win:_navPush(spec[2])
        assert(settings_win:_navCurrent().id == spec[2])
    end)
end

add("13-onboarding-welcome", function()
    safe_close_sui(settings_win)
    settings_win = nil
    require("weui_onboarding").show()
    onboarding_win = current_sui()
    assert(onboarding_win and onboarding_win._name == "weui_win_onboarding", "onboarding did not open")
end)

add("14-onboarding-presets", function()
    onboarding_win:_navPush("presets")
end)

add("15-onboarding-tips", function()
    while #onboarding_win._nav_stack > 1 do onboarding_win:_navPop() end
    onboarding_win:_navPush("tips")
end)

add("16-recent", function()
    safe_close_sui(onboarding_win)
    onboarding_win = nil
    require("weui_quickactions").showRecentWindow()
    assert(current_sui() and current_sui()._name == "weui_win_recent", "recent window did not open")
end, { cleanup = function() safe_close_sui(current_sui()) end })

add("17-weread-main", function()
    local wr = assert(current_plugin()._weread_plugin, "integrated WeRead plugin missing")
    weread_menu = wr:showMainMenu()
    assert(weread_menu, "WeRead main menu did not open")
end, { cleanup = function() safe_close(weread_menu); weread_menu = nil end })

add("18-weread-offline", function()
    require("ui/offline_manager").show()
    offline_win = current_sui()
    assert(offline_win and offline_win._name == "weui_win_offline_manager", "offline manager did not open")
end, { cleanup = function() safe_close_sui(offline_win); offline_win = nil end })

add("19-zlibrary-browse", function()
    local zlib = assert(current_plugin()._zlibrary_plugin, "embedded Z-Library plugin missing")
    local Config = require("zlibrary.config")
    Config.getMultiSearchCache():insert("popular", {
        { id = "qa-1", hash = "qa_hash_1", title = "长安十二时辰", author = "马伯庸", year = "2017", extension = "epub", filesizeString = "3.2 MB", language = "Chinese" },
        { id = "qa-2", hash = "qa_hash_2", title = "The Design of Everyday Things", author = "Don Norman", year = "2013", extension = "pdf", filesizeString = "8.4 MB", language = "English" },
        { id = "qa-3", hash = "qa_hash_3", title = "墨水屏排版与交互设计实践", author = "WeUI 测试组", year = "2026", extension = "epub", filesizeString = "1.8 MB", language = "Chinese" },
    })
    Config.getConfigRuntimeCache():insert("favorite_book_ids", {})
    zlib:showMultiSearchDialog(1, "阅读")
    zlibrary_list = top_widget()
    assert(zlibrary_list, "Z-Library browse page did not open")
end, { wait = 1.0 })

add("20-zlibrary-details", function()
    local zlib = assert(current_plugin()._zlibrary_plugin)
    local Ui = require("zlibrary.ui")
    zlibrary_details = Ui.showBookDetails(zlib, {
        id = "qa-detail",
        hash = "qa_detail_hash",
        title = "墨水屏阅读体验设计：从书库到锁屏",
        author = "WeUI 设计组",
        year = "2026",
        extension = "epub",
        filesizeString = "2.6 MB",
        language = "Chinese",
        publisher = "Kindle UI Lab",
        pages = "368",
        description = "本书讨论适合黑白电子墨水屏的高对比度界面、统一图标、足够大的触控区域，以及下载渠道、本地书库、隐私书和可定制锁屏之间的完整使用流程。",
    })
    assert(zlibrary_details, "Z-Library details did not open")
end, { wait = 1.0, cleanup = function() safe_close(zlibrary_details); zlibrary_details = nil end })

add("21-zlibrary-credentials", function()
    local ok, err = require("weui_zlibrary_ui").openCredentials()
    assert(ok, tostring(err))
    zlibrary_credentials = top_widget()
    assert(zlibrary_credentials, "credentials dialog did not open")
end, { cleanup = function()
    safe_close(zlibrary_credentials)
    zlibrary_credentials = nil
    safe_close(zlibrary_list)
    zlibrary_list = nil
end })

add("22-reader", function()
    local ReaderUI = require("apps/reader/readerui")
    ReaderUI:showReader(library .. "/欢迎使用 WeUI.txt")
end, { wait = 3.0 })

add("23-sleep-screen", function()
    assert(require("apps/reader/readerui").instance, "reader not active before screensaver")
    local Screen = require("device").screen
    append_result("INFO", "sleep-before", table.concat({
        Screen:getWidth(), Screen:getHeight(), Screen:getRotationMode(),
    }, "x"))
    G_reader_settings:saveSetting("screensaver_type", "message")
    G_reader_settings:makeTrue("screensaver_show_message")
    local Screensaver = require("ui/screensaver")
    Screensaver:setup()
    Screensaver:show()
    append_result("INFO", "sleep-after", table.concat({
        Screen:getWidth(), Screen:getHeight(), Screen:getRotationMode(),
    }, "x"))
    UIManager:scheduleIn(0.8, function() trace_edge_widgets("23-sleep-screen") end)
end, {
    wait = 1.0,
    cleanup = function()
        local Screensaver = require("ui/screensaver")
        pcall(Screensaver.close_widget, Screensaver)
        pcall(Screensaver.cleanup, Screensaver)
        require("device").screen_saver_mode = false
    end,
})

add("24-return-library", function()
    local ReaderUI = require("apps/reader/readerui")
    assert(ReaderUI.instance, "reader instance missing")
    ReaderUI.instance:onHome()
end, { wait = 2.0 })

local qa_started = false
local qa_failures = 0

local function run_suite()
    if qa_started then return end
    qa_started = true
    append_result("INFO", "profile", "1072x1448@300dpi grayscale zh_CN")

    local first_stage = math.max(1, tonumber(os.getenv("WEUI_QA_STAGE_FROM")) or 1)
    local last_stage = math.min(#stages, tonumber(os.getenv("WEUI_QA_STAGE_TO")) or #stages)
    local index = first_stage - 1
    local function next_stage()
        index = index + 1
        local stage = stages[index]
        if not stage or index > last_stage then
            append_result(qa_failures == 0 and "PASS" or "FAIL", "suite", "failures=" .. tostring(qa_failures))
            UIManager:scheduleIn(0.2, function() UIManager:quit(qa_failures == 0 and 0 or 1) end)
            return
        end

        local ok, err = xpcall(stage.action, traceback)
        if not ok then
            qa_failures = qa_failures + 1
            append_result("FAIL", stage.name, err)
        end

        UIManager:scheduleIn(stage.wait, function()
            local post_ok, post_err = xpcall(function()
                UIManager:forceRePaint()
                audit_dimensions(stage.name)
                if stage.screenshot then
                    require("device").screen:shot(artifacts .. "/" .. stage.name .. ".png")
                end
            end, traceback)
            if post_ok and ok then
                append_result("PASS", stage.name, "")
            elseif not post_ok then
                qa_failures = qa_failures + 1
                append_result("FAIL", stage.name .. "-post", post_err)
            end

            if stage.cleanup then
                local cleanup_ok, cleanup_err = xpcall(stage.cleanup, traceback)
                if not cleanup_ok then
                    qa_failures = qa_failures + 1
                    append_result("FAIL", stage.name .. "-cleanup", cleanup_err)
                end
            end
            UIManager:scheduleIn(0.2, next_stage)
        end)
    end

    next_stage()
end

userpatch.registerPatchPluginFunc("weui", function(class)
    -- registerPatchPluginFunc is invoked immediately after the first instance
    -- has been created, while FileManager:init is still running. Scheduling
    -- here waits until that init and its first paint are complete. The suite's
    -- own guard prevents a ReaderUI instance from starting it a second time.
    UIManager:scheduleIn(1.0, run_suite)
end)

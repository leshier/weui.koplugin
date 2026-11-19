-- Native rendering and interaction tests, confined to a disposable KO_HOME.
local trace
if os.getenv("WEUI_PAPER_TRACE") == "1" then
    trace = dofile(assert(os.getenv("WEUI_PAPER_QA_ROOT"))
        .. "/plugins/weui.koplugin/scripts/qa/fixtures/paper_refresh_trace.lua")
end
local UIManager = require("ui/uimanager")
local userpatch = require("userpatch")
local root = assert(os.getenv("WEUI_PAPER_QA_ROOT"))
local booksdir = root .. "/library"
G_reader_settings:saveSetting("home_dir", booksdir)
G_reader_settings:saveSetting("lastdir", booksdir)
G_reader_settings:saveSetting("last_migration_date", 20260623)
local titles = { "山海小记", "日常的秩序", "四季书", "城与乡", "时间的形状", "云的来信", "行走之间", "远方的灯" }
local files = {}
for i, title in ipairs(titles) do
    local file = booksdir .. "/" .. title .. ".txt"
    local fh = assert(io.open(file, "w")); fh:write((title .. "\n这是一段用于界面验证的原创文字。\n"):rep(100)); fh:close()
    files[i] = file
    local ds = require("docsettings"):open(file)
    ds:saveSetting("doc_props", { title = title, authors = "纸页测试" })
    ds:saveSetting("percent_finished", i < 4 and i * 0.15 or 0)
    ds:saveSetting("summary", { status = i == 8 and "complete" or i < 4 and "reading" or "new",
        modified = os.date("%Y-%m-%d") })
    ds:saveSetting("partial_md5_checksum", string.format("%032d", i))
    ds:saveSetting("doc_pages", 200)
    ds:saveSetting("last_page", i * 30)
    if i < 4 then
        ds:saveSetting("annotations", {
            { drawer = "lighten", text = "阅读让我们暂时放下熟悉的判断，尝试另一种观察世界的方式。",
                note = i == 1 and "每一页都是一次停留。" or nil, pageno = 15 * i, datetime = os.date("%Y-%m-%d") .. " 12:00:00" },
            { drawer = "underline", text = "每一次返回，也都从上次停下的地方继续。",
                pageno = 25 * i, datetime = os.date("%Y-%m-%d") .. " 10:00:00" },
        })
    end
    ds:flush()
end
local history = require("readhistory")
history.hist = {}
for i = 1, 4 do history.hist[i] = { file = files[i], time = os.time() - i * 300 } end
local started, stages, index, failures = false, {}, 0, 0
local dwell = tonumber(os.getenv("WEUI_PAPER_DWELL")) or 0.1
assert(dwell >= 0.1 and dwell <= 30, "invalid paper QA dwell")
local plugin, Paper, Data
local function add(name, fn) stages[#stages + 1] = { name = name, fn = fn } end
local function tap(page, x, y)
    return page:onTapPaper(nil, { pos = { x = page:px(x) + page.offset, y = page:px(y) } })
end
local function tapLabel(page, label)
    for _, item in ipairs(page.items) do
        if item.widget and item.widget.text == label then
            return page:onTapPaper(nil, { pos = { x = page.offset + item.x + 3, y = item.y + 3 } })
        end
    end
    error("touch label missing: " .. label)
end
local function hasText(page, label)
    for _, item in ipairs(page.items) do if item.widget and item.widget.text == label then return true end end
    return false
end
local function buttonByText(dialog, label)
    for _, row in ipairs(dialog.buttons or {}) do
        for _, button in ipairs(row) do
            if button.text == label then return button end
        end
    end
    error("button missing: " .. label)
end
local function topWidget()
    local stack = require("weui_core").getWindowStack()
    local widget = assert(stack[#stack] and stack[#stack].widget, "empty window stack")
    return widget
end
local function geometry(page)
    for _, hit in ipairs(page.hits) do
        assert(hit.x >= 0 and hit.y >= 0 and hit.x + hit.w <= page.dimen.w
            and hit.y + hit.h <= page.dimen.h, "touch target outside framebuffer")
    end
    for _, item in ipairs(page.items) do
        if item.widget then
            local size = item.widget:getSize()
            assert(item.y + size.h <= page.dimen.h, "text or cover outside framebuffer")
        end
    end
end
local function closeToPage()
    while topWidget() ~= Paper._instance do UIManager:close(topWidget()) end
end
local function submit(text)
    local input = topWidget()
    assert(type(input.setInputText) == "function", "password input missing")
    input:setInputText(text)
    input.buttons[1][2].callback()
    return input
end
local function findBook(path)
    local realpath = require("ffi/util").realpath
    for _, book in ipairs(Paper._instance.books) do
        if realpath(book.filepath) == realpath(path) then return book end
    end
    error("fixture book missing")
end
local function seedStats()
    local SQ = require("lua-ljsqlite3/init")
    local conn = SQ.open(require("weui_config").getStatsDbPath())
    dofile(root .. "/plugins/weui.koplugin/scripts/qa/fixtures/paper_stats.lua").create(conn)
    for i = 1, 2 do
        conn:exec(string.format("INSERT OR REPLACE INTO book(id,title,authors,md5) VALUES(%d,'%s','纸页测试','%032d')", i, titles[i], i))
    end
    local t = os.date("*t")
    for i = 0, 13 do
        local ts = os.time{ year = t.year, month = t.month, day = t.day - i, hour = 12 }
        conn:exec(string.format("INSERT INTO page_stat_data VALUES(%d,%d,%d,%d,200)", i % 2 + 1, i + 1, ts, (i < 7 and 40 or 20) * 60))
    end
    conn:close()
end
add("01-home", function()
    Paper, Data = require("weui_paper"), require("weui_library")
    seedStats()
    local chooser = require("apps/filemanager/filemanager").instance.file_chooser
    for _ = 1, 2 do
        local _, readable = chooser:genItemTableFromPath(booksdir)
        assert(readable == true, "directory cache lost native readable status")
    end
    local _, unreadable = chooser:genItemTableFromPath(booksdir .. "/missing-directory")
    assert(unreadable == false, "failed directory read was reported as readable")
    assert(not chooser.unreadable_path_warned, "readable library produced a directory warning")
    local page = Paper.navigate(plugin, "homescreen")
    assert(require("weui_config").getActionById("homescreen").label == "书房", "default room label")
    assert(#page.books == 8, "fixture book discovery")
    local stats = Data.stats("week", nil, page.books)
    assert(stats.seconds == 7 * 40 * 60 and stats.previous == 7 * 20 * 60, "rolling7 totals")
    assert(stats.streak == 14 and stats.best == 14, "streak")
    local sum = 0; for _, b in ipairs(stats.bars) do sum = sum + b.seconds end
    assert(sum == stats.seconds, "chart and KPI disagree")
    geometry(page)
end)
add("02-library", function()
    tap(Paper._instance, 170, Paper._instance.logical_h - 24)
    local page = Paper._instance
    assert(page.screen == "home" and page.pages == 2, "library navigation or pagination")
    geometry(page)
end)
add("02-native-input-regression", function()
    dofile(root .. "/plugins/weui.koplugin/scripts/qa/fixtures/paper_input_checks.lua")({
        Paper = Paper, plugin = plugin,
    })
end)
add("03-library-page-two", function()
    local page = Paper._instance
    tap(page, 338, page.body_bottom - 20)
    assert(page.state.page == 2, "next-page touch target")
end)
add("04-search-filter-sort", function()
    local page = Paper._instance
    page.state.query, page.state.filter, page.state.page = "山海", "all", 1
    page:rebuild()
    assert(page.pages == 1 and #Data.filter(page.books, "山海", "all") == 1, "title search")
    assert(#Data.filter(page.books, "", "unread") == 3, "unread status")
    page.state.query, page.state.filter, page.state.layout, page.state.sort = "", "all", "list", "progress"
    page:rebuild()
    assert(Data.filter(page.books, "", "all", "progress")[1].percent == 0.45, "progress sort")
end)
add("05-sources-from-library", function()
    Paper._instance.state.layout = "grid"
    Paper._instance:showSources()
    assert(Paper._instance.tab == "home" and Paper._instance.screen == "sources", "source origin")
    geometry(Paper._instance)
end)
add("06-weread-source", function()
    local wr = plugin._weread_plugin
    local books = {}
    for i = 1, 8 do books[i] = { bookId = tostring(i), title = titles[i], author = "纸页测试" } end
    wr.settings:set("shelf_cache", { books = books, updated_at = os.time() }); wr.settings:flush()
    wr.shelf_books, wr.shelf_regular, wr.shelf_mp = nil, nil, nil
    wr:showShelfGrid(1, "books")
    assert(Paper._instance.wr == wr and Paper._instance.tab == "home", "secondary source navigation")
    assert(#wr.shelf_books == 8, "offline shelf restoration")
    geometry(Paper._instance)
end)
add("07-source-back", function()
    Paper._instance:onClose()
    assert(Paper._instance.screen == "sources" and Paper._instance.tab == "home", "source back origin")
    Paper._instance:onClose()
    assert(Paper._instance.screen == "home", "hub back to library")
end)
add("08-notes", function()
    local page = Paper.navigate(plugin, "notes")
    assert(#page.records == 6, "modern annotations")
    assert(page.records[1].page ~= nil, "annotation page reference")
    geometry(page)
end)
add("09-note-type-and-export", function()
    local page = Paper._instance
    page.state.filter = "note"; page:rebuild()
    assert(#page.records == 1, "note-type filter")
    local dest = root .. "/artifacts/notes.txt"
    assert(Data.exportNotes(page.records, dest), "export failed")
    local fh = assert(io.open(dest)); local text = fh:read("*a"); fh:close()
    assert(text:find("每一页都是一次停留。", 1, true), "export lost note")
    assert(text:find("阅读让我们", 1, true), "export lost quoted text")
    assert(not Data.exportNotes(page.records, dest), "export overwrote an existing file")
    page.state.filter = "all"; page:rebuild()
end)
add("09a-note-details", function()
    local page = Paper._instance
    tap(page, 100, 254)
    local detail = topWidget()
    assert(detail.text and detail.text:find("阅读让我们", 1, true), "note details lost quotation")
    assert(detail.text:find("页", 1, true), "note details lost location")
end)
add("09b-note-details-back", function()
    UIManager:close(topWidget())
    assert(topWidget() == Paper._instance and Paper._instance.screen == "notes", "note details return")
end)
for _, period in ipairs({ "week", "month", "year", "all" }) do
    add("10-stats-" .. period, function()
        local page = Paper.navigate(plugin, "stats_calendar")
        page.state.period = period; page:rebuild()
        local stats = Data.stats(period, nil, page.books)
        local sum = 0; for _, bar in ipairs(stats.bars) do sum = sum + bar.seconds end
        assert(sum == stats.seconds, "period chart and KPI disagree")
        assert(#stats.ranking == 2, "period ranking")
        geometry(page)
    end)
end
local stats_origin, stats_window
add("10a-statistics-rankings-centered", function()
    stats_origin = Paper._instance
    tap(stats_origin, 450, 543)
    local sheet = Paper._instance
    assert(sheet.screen == "rankings" and sheet.origin_page == stats_origin and topWidget() == sheet, "statistics rankings left paper")
    assert(math.abs(sheet.panel_y - (sheet.logical_h - sheet.panel_h) / 2) < 1, "rankings not vertically centered")
    geometry(sheet)
    sheet:onSetRotationMode(1); geometry(sheet)
    assert(math.abs(sheet.panel_y - (sheet.logical_h - sheet.panel_h) / 2) < 1, "landscape rankings not centered")
    sheet:onSetRotationMode(0)
end)
add("10b-statistics-ranking-book-back", function()
    local sheet = Paper._instance
    tapLabel(sheet, titles[1])
    assert(topWidget() ~= sheet, "ranking book detail not opened")
    closeToPage()
    assert(topWidget() == sheet and sheet.origin_page == stats_origin, "ranking detail back lost centered sheet")
    sheet:onClose()
    assert(topWidget() == stats_origin and Paper._instance == stats_origin, "rankings close lost statistics")
    tap(stats_origin, 490, 70)
    topWidget().buttons[2][1].callback()
end)
add("10c-statistics-overview-month-transition", function()
    assert(topWidget() == stats_origin and stats_origin.screen == "stats_details", "details changed page")
    stats_window = #UIManager._window_stack
    for _, label in ipairs({ "月", "年", "全部", "近7天" }) do
        tapLabel(stats_origin, label)
        assert(topWidget() == stats_origin and #UIManager._window_stack == stats_window, "period added a window")
        geometry(stats_origin)
    end
    stats_origin:moveStatsMonth(-1)
    assert(hasText(stats_origin, "日历与详细统计"), "calendar navigation left details")
end)
add("10d-statistics-insights-close", function()
    stats_origin:onClose()
    assert(Paper._instance == stats_origin and topWidget() == stats_origin, "month statistics close lost paper page")
end)
add("11-more", function() geometry(Paper.navigate(plugin, "weui_settings")) end)
add("11a-goal-save", function()
    local page = Paper._instance
    page:goals()
    local sheet = topWidget()
    assert(sheet._weui_paper_sheet and sheet.origin_page == page, "goal sheet origin")
    tapLabel(sheet, "暂不设置")
    assert(sheet.picking_annual, "annual target picker did not open")
    tapLabel(sheet, "每年 24 本")
    tapLabel(sheet, "每年 24 本")
    tapLabel(sheet, "每月阅读时间")
    local input = topWidget(); input:setInputText("12"); input.buttons[1][2].callback()
    assert(not sheet.picking_annual and topWidget() == sheet, "monthly target did not return to goal main")
    tapLabel(sheet, "每年 24 本")
    tapLabel(sheet, "每日阅读时间")
    input = topWidget(); input:setInputText("40"); input.buttons[1][2].callback()
    assert(not sheet.picking_annual and topWidget() == sheet, "daily target did not return to goal main")
    assert(require("weui_store"):get("weui_reading_goal") == nil, "goal draft persisted before save")
    geometry(sheet)
    tapLabel(sheet, "保存目标")
    local path = require("datastorage"):getSettingsDir() .. "/weui/weui_settings.lua"
    local saved = require("luasettings"):open(path)
    assert(saved:readSetting("weui_reading_goal") == 24, "annual goal was not persisted")
    assert(saved:readSetting("weui_monthly_reading_goal_secs") == 12 * 3600, "monthly goal unit")
    assert(saved:readSetting("weui_daily_reading_goal_secs") == 40 * 60, "daily goal unit")
    assert(topWidget() == page, "goal dialog remains open")
end)
add("12-sources-from-more", function()
    tapLabel(Paper._instance, "书籍来源")
    assert(Paper._instance.tab == "weui_settings", "more source origin")
    Paper._instance:onClose()
    assert(Paper._instance.screen == "weui_settings", "more source return")
    Paper._instance:showSources()
end)
add("12a-zlibrary-search", function()
    -- Seed only the browse cache; the real search entry opens without network I/O.
    require("zlibrary.config").getMultiSearchCache():insert("popular", {})
    require("zlibrary.ui")._last_search_input = "山海"
    tap(Paper._instance, 450, 550)
    local input = topWidget()
    assert(type(input.getInputText) == "function" and input:getInputText() == "山海", "Z-Library search entry")
    assert(require("weui_zlibrary_ui").isOpen(), "Z-Library page not tracked")
    input:setInputText("日常")
end)
add("12b-zlibrary-browser", function()
    UIManager:close(topWidget())
    assert(topWidget()._weui_zlibrary_page, "Z-Library browser missing")
end)
add("12c-zlibrary-back", function()
    UIManager:close(topWidget())
end)
add("12d-zlibrary-return", function()
    assert(not require("weui_zlibrary_ui").isOpen(), "Z-Library close not tracked")
    assert(topWidget() == Paper._instance and Paper._instance.screen == "sources", "source hub not restored")
    assert(Paper._instance.tab == "weui_settings", "source origin changed")
end)
local import_origin
add("13-local-import-picker", function()
    local file = root .. "/data/新书.txt"
    local fh = assert(io.open(file, "w")); fh:write("一本新书的原创试读文字。"); fh:close()
    local lfs = require("libs/libkoreader-lfs")
    assert(lfs.mkdir(booksdir .. "/空目录"))
    local unsupported = assert(io.open(booksdir .. "/unsupported.exe", "w")); unsupported:write("unsupported"); unsupported:close()
    import_origin = Paper._instance
    tapLabel(import_origin, "本地导入")
    local picker = Paper._instance
    assert(picker._weui_paper_files and topWidget() == picker and picker.tab == "weui_settings", "import left paper navigation")
    assert(hasText(picker, "‹ 返回书籍来源") and hasText(picker, "取消"), "import back/cancel missing")
    assert(not hasText(picker, "unsupported.exe"), "unsupported import format shown")
    geometry(picker)
end)
add("13a-import-folder-back-and-cancel", function()
    local picker = Paper._instance
    tapLabel(picker, "空目录")
    assert(hasText(picker, "这个目录还没有书籍"), "empty folder missing recovery")
    geometry(picker)
    picker:onClose()
    assert(picker.path == require("ffi/util").realpath(booksdir), "hardware back did not restore directory")
    tapLabel(picker, "上一级 ›")
    assert(picker.path == require("ffi/util").realpath(root), "parent directory navigation")
    tapLabel(picker, "data")
    assert(hasText(picker, "新书.txt"), "nested import file missing")
    picker:onSetRotationMode(1); geometry(picker)
    picker:onSetRotationMode(0); geometry(picker)
    tapLabel(picker, "取消")
    assert(Paper._instance == import_origin and topWidget() == import_origin and import_origin.screen == "sources", "cancel lost source page")
    tapLabel(import_origin, "本地导入")
    tapLabel(Paper._instance, "‹ 返回书籍来源")
    assert(Paper._instance == import_origin and topWidget() == import_origin, "visible back lost source page")
end)
add("13b-local-import-real-selection", function()
    tapLabel(import_origin, "本地导入")
    tapLabel(Paper._instance, "上一级 ›")
    tapLabel(Paper._instance, "data")
    tapLabel(Paper._instance, "新书.txt")
    closeToPage()
    local page = Paper._instance
    assert(page.screen == "home" and topWidget() == page, "successful import did not return to paper shelf")
    assert(#page.books == 9, "imported file missing or duplicated")
end)
add("13c-local-import-duplicate", function()
    Paper.navigate(plugin, "weui_settings")
    tapLabel(Paper._instance, "书籍来源")
    tapLabel(Paper._instance, "本地导入")
    tapLabel(Paper._instance, "上一级 ›")
    tapLabel(Paper._instance, "data")
    tapLabel(Paper._instance, "新书.txt")
    closeToPage()
    assert(#Paper._instance.books == 9 and Paper._instance.screen == "home", "repeat import duplicated book or changed style")
end)
add("14-privacy", function()
    local Privacy = require("weui_privacy")
    Privacy.setPrivateBook(files[1], true, titles[1]); Privacy.lockNow()
    Data.invalidate()
    local page = Paper.navigate(plugin, "notes")
    assert(#page.records == 4, "locked private notes leaked")
    local stats = Data.stats("week", nil, page.books)
    for _, r in ipairs(stats.ranking) do assert(r.title ~= titles[1], "private ranking title leaked") end
end)
add("15-landscape", function()
    local page = Paper.navigate(plugin, "home")
    page:onSetRotationMode(1)
    geometry(page)
end)
add("16-portrait", function()
    local page = Paper._instance
    page:onSetRotationMode(0); geometry(page)
end)
add("17-open-book", function()
    local Privacy = require("weui_privacy")
    Privacy.setPrivateBook(files[1], false, titles[1])
    Data.invalidate()
    local page = Paper.navigate(plugin, "home")
    page:openBook(assert(Data.filter(page.books, "山海", "all")[1]))
end)
add("18-reading-page", function()
    local reader = assert(require("apps/reader/readerui").instance, "reader did not open")
    assert(require("ffi/util").realpath(reader.document.file) == require("ffi/util").realpath(files[1]), "wrong book opened")
    reader:handleEvent(require("ui/event"):new("GotoPage", 3))
    assert(reader.rolling.current_page == 3, "reader did not turn the page")
end)
add("19-return-to-shelf", function()
    local reader = assert(require("apps/reader/readerui").instance)
    require("weui_bottombar").navigate(assert(reader.weui), "home", reader, nil, false)
end)
add("20-progress-after-return", function()
    assert(not require("apps/reader/readerui").instance, "reader stayed open")
    Paper, Data = require("weui_paper"), require("weui_library")
    local page = assert(Paper._instance, "paper shelf did not return")
    assert(page.screen == "home" and topWidget() == page, "incorrect page after reading")
    local book = assert(Data.filter(page.books, "山海", "all")[1])
    local ds = require("docsettings"):open(files[1])
    assert(book.percent == ds:readSetting("percent_finished"), "stale cached reading progress")
    assert(book.last_read > 0, "last read was not refreshed")
    geometry(page)
end)
add("21-open-for-gesture", function()
    local page = Paper._instance
    page:openBook(assert(Data.filter(page.books, "山海", "all")[1]))
end)
add("22-library-gesture", function()
    local reader = assert(require("apps/reader/readerui").instance)
    assert(reader.weui:onWeUIGoLibrary(), "library gesture was not handled")
end)
add("23-gesture-return", function()
    assert(not require("apps/reader/readerui").instance, "gesture left reader open")
    Paper, Data = require("weui_paper"), require("weui_library")
    local page = assert(Paper._instance, "gesture did not restore paper shelf")
    assert(page.screen == "home" and topWidget() == page, "gesture returned to wrong page")
    geometry(page)
end)
local Privacy, private_note, password, new_password, captured_timer, privacy_settings
add("24-privacy-settings", function()
    Privacy = require("weui_privacy")
    local page = Paper.navigate(plugin, "weui_settings")
    local found
    for _, item in ipairs(page.items) do
        if item.widget and item.widget.text == "隐私与密码" then found = true end
    end
    assert(found, "privacy entry missing from More")
    -- Disposable credentials stay in this process and isolated KO_HOME.
    password, new_password = "paper-qa-" .. os.time(), "paper-qa-new-" .. os.time()
    Privacy.setAutoLockMinutes(1)
    local ds = require("docsettings"):open(files[2])
    local props = ds:readSetting("doc_props")
    props.tags = { "私密测试标签" }
    ds:saveSetting("doc_props", props)
    ds:saveSetting("last_toc_title", "私密测试章节")
    local annotations = ds:readSetting("annotations")
    annotations[1].note = "私密笔记测试原文"
    ds:saveSetting("annotations", annotations); ds:flush()
    Data.invalidate()
    privacy_settings = assert(page:privacySettings(), "privacy submenu did not open")
    assert(topWidget() == privacy_settings._wrapper, "privacy settings not in foreground")
    assert(privacy_settings:_navCurrent().id == "nested_menu", "privacy submenu not selected")
end)
add("25-private-book-long-press", function()
    privacy_settings:close()
    Paper.navigate(plugin, "home"):bookDetails(findBook(files[2]))
    local dialog = topWidget()
    buttonByText(dialog, require("weui_i18n").translate("Set as private book")).callback()
    assert(topWidget().text_type == "password", "password setup is not masked")
end)
add("26-password-empty-rejected", function()
    local input = submit("")
    assert(not Privacy.hasPassword(), "empty password accepted")
    UIManager:close(topWidget())
    assert(topWidget() == input, "empty-password validation dismissed input")
    submit(password)
    assert(Privacy.verifyPassword(password), "setup did not persist password")
    assert(topWidget().text_type == "password", "book privacy toggle bypassed authentication")
end)
add("27-password-mark-book", function()
    submit(password)
    assert(Privacy.isPrivateBook(files[2]), "long press did not mark book private")
    assert(not Privacy.isUnlocked(), "marking private book left it temporarily visible")
    closeToPage()
    local book = findBook(files[2])
    assert(book.private and book.title == Privacy.privateTitle(), "locked title leaked")
    assert(book.authors == Privacy.privateAuthor() and book.tags == "" and book.chapter == "", "locked metadata leaked")
    assert(#Data.filter(Paper._instance.books, "私密测试标签", "all") == 0, "locked tag searchable")
    Paper._instance:openBook(book)
end)
add("28-password-wrong-blocked", function()
    local input = submit("wrong-fixture-password")
    assert(not Privacy.isUnlocked() and not require("apps/reader/readerui").instance, "wrong password opened reader")
    UIManager:close(topWidget())
    assert(topWidget() == input, "wrong password closed input")
    submit(password)
    assert(Privacy.isUnlocked() and topWidget().buttons[2][1], "book confirmation missing after unlock")
    assert(not require("apps/reader/readerui").instance, "confirmation bypassed")
end)
add("29-private-unlock-cancel", function()
    topWidget().buttons[2][1].callback()
    assert(topWidget() == Paper._instance, "cancel did not return to shelf")
    assert(not require("apps/reader/readerui").instance, "cancel opened private book")
    local page = Paper.navigate(plugin, "notes")
    for _, record in ipairs(page.records) do
        if record.note == "私密笔记测试原文" then private_note = record end
    end
    assert(private_note and private_note.book.title == titles[2], "unlock left stale masked note cache")
    page:noteDetails(private_note)
    assert(topWidget().text:find("私密笔记测试原文", 1, true), "private note did not open")
    assert(topWidget()._weui_private_book, "private note missing relock marker")
end)
add("30-lock-closes-private-note", function()
    Privacy.lockNow()
    assert(topWidget() == Paper._instance, "lock left private note viewer open")
    for _, record in ipairs(Paper._instance.records) do
        assert(record.note ~= "私密笔记测试原文", "lock left private note on page")
    end
    local dest = root .. "/artifacts/locked-notes.txt"
    assert(not Data.exportNotes({ private_note }, dest), "stale private note exported while locked")
    assert(not require("libs/libkoreader-lfs").attributes(dest), "denied export created a file")
    Paper._instance:noteDetails(private_note)
end)
add("31-stale-note-password-gate", function()
    assert(topWidget().text_type == "password", "stale note bypassed password")
    submit(password)
    topWidget().buttons[1][1].callback()
    assert(topWidget()._weui_private_book, "unlocked stale note not protected")
    closeToPage()
end)
add("32-autolock-rearm", function()
    local original_schedule, original_unschedule = UIManager.scheduleIn, UIManager.unschedule
    local armed, cancelled = {}, {}
    UIManager.scheduleIn = function(self, delay, action, ...)
        if delay == 60 then armed[#armed + 1] = action end
        return original_schedule(self, delay, action, ...)
    end
    UIManager.unschedule = function(self, action)
        cancelled[action] = true
        return original_unschedule(self, action)
    end
    local ok, err = xpcall(function()
        Privacy.setAutoLockMinutes(1)
        Privacy.requirePassword(function() end)
    end, debug.traceback)
    UIManager.scheduleIn, UIManager.unschedule = original_schedule, original_unschedule
    assert(ok, err)
    assert(#armed == 2 and cancelled[armed[1]], "session refresh failed to cancel prior timer")
    captured_timer = armed[2]
    Paper._instance:rebuild(true)
    Paper._instance:noteDetails(private_note)
end)
add("33-autolock-hides-content", function()
    assert(Privacy.isUnlocked() and topWidget()._weui_private_book, "auto-lock fixture not unlocked")
    -- Execute the scheduled callback deterministically; no wall-clock wait.
    UIManager:unschedule(captured_timer); captured_timer()
    assert(not Privacy.isUnlocked() and topWidget() == Paper._instance, "auto-lock left note viewer open")
    for _, record in ipairs(Paper._instance.records) do
        assert(record.note ~= "私密笔记测试原文", "auto-lock left private notes visible")
    end
    Privacy.changePassword()
end)
add("34-change-password-wrong-current", function()
    local input = submit("wrong-fixture-password")
    assert(Privacy.verifyPassword(password) and not Privacy.verifyPassword(new_password), "incorrect current password changed credentials")
    UIManager:close(topWidget())
    assert(topWidget() == input, "wrong current password skipped validation")
    submit(password); submit(new_password)
end)
add("35-change-password-mismatch", function()
    local input = submit("different-fixture-password")
    assert(Privacy.verifyPassword(password), "mismatched confirmation changed credentials")
    UIManager:close(topWidget())
    assert(topWidget() == input, "mismatch dismissed confirmation")
    submit(new_password)
    assert(Privacy.verifyPassword(new_password) and not Privacy.verifyPassword(password), "password change not persisted")
    closeToPage()
end)
add("36-private-collection", function()
    local collections = require("readcollection")
    collections:addCollection("私密测试分组")
    collections:addItem(files[3], "私密测试分组")
    Privacy.setPrivateCollection("私密测试分组", true)
    assert(Privacy.isPrivateBook(files[3]) and not Privacy.isCollectionRevealed("私密测试分组"), "collection member not masked")
    assert(#Privacy.getPrivateCollections() == 1, "private collection list")
    Privacy.requirePassword(function() end)
end)
add("37-collection-unlock-and-disable-session", function()
    submit(new_password); closeToPage()
    assert(Privacy.isCollectionRevealed("私密测试分组"), "collection did not reveal after unlock")
    Privacy.setAutoLockMinutes(0)
    assert(not Privacy.isUnlocked() and not Privacy.isCollectionRevealed("私密测试分组"), "per-open mode retained unlocked session")
    Privacy.setPrivateCollection("私密测试分组", false)
    assert(not Privacy.isPrivateBook(files[3]), "collection flag not removed")
    Paper.navigate(plugin, "home"):bookDetails(findBook(files[2]))
    buttonByText(topWidget(), require("weui_i18n").translate("Remove private book")).callback()
end)
add("38-remove-private-password-gate", function()
    local input = submit("wrong-fixture-password")
    assert(Privacy.isPrivateBook(files[2]), "wrong password removed privacy")
    UIManager:close(topWidget())
    assert(topWidget() == input, "removal password input missing")
    submit(new_password); closeToPage()
    assert(not Privacy.isPrivateBook(files[2]), "authenticated privacy removal failed")
    assert(findBook(files[2]).title == titles[2], "removed book still masked")
    local saved = require("luasettings"):open(require("datastorage"):getSettingsDir() .. "/weui/weui_settings.lua")
    assert(next(saved:readSetting("weui_private_books") or {}) == nil, "privacy removal not persisted")
end)
add("39-navigation-stress", function()
    local ids = { "homescreen", "home", "notes", "stats_calendar", "weui_settings" }
    local clock = require("ui/time")
    local samples = {}
    local function cycle(count, measure)
        for i = 1, count do
            local before = clock.now()
            local page = Paper.navigate(plugin, ids[(i - 1) % #ids + 1])
            UIManager:forceRePaint()
            assert(topWidget() == page, "navigation lost foreground")
            geometry(page)
            if measure then samples[#samples + 1] = clock.to_s(clock.since(before)) * 1000 end
        end
    end
    cycle(25, false); collectgarbage("collect")
    local before_kb = collectgarbage("count")
    cycle(100, true); collectgarbage("collect")
    local after_kb = collectgarbage("count")
    table.sort(samples)
    local total = 0; for _, ms in ipairs(samples) do total = total + ms end
    local fh = assert(io.open(root .. "/artifacts/stress.tsv", "w"))
    fh:write("switches\tmean_ms\tp95_ms\tmax_ms\tlua_before_kb\tlua_after_kb\tlua_delta_kb\n")
    fh:write(string.format("%d\t%.2f\t%.2f\t%.2f\t%.2f\t%.2f\t%.2f\n", #samples,
        total / #samples, samples[95], samples[#samples], before_kb, after_kb, after_kb - before_kb))
    fh:close()
    assert(after_kb - before_kb < 8192, "navigation retained over 8 MiB of Lua objects")
end)
add("40-private-reader-password", function()
    Privacy.setPrivateBook(files[2], true, titles[2])
    Privacy.lockNow()
    local page = Paper.navigate(plugin, "home")
    page:openBook(findBook(files[2]))
end)
add("41-private-reader-confirm", function()
    assert(not require("apps/reader/readerui").instance, "private reader opened before password")
    submit(new_password)
    assert(not Privacy.isUnlocked(), "per-open mode retained session")
    topWidget().buttons[1][1].callback()
end)
add("42-private-reader-turn-and-return", function()
    local reader = assert(require("apps/reader/readerui").instance, "authenticated private reader did not open")
    assert(require("ffi/util").realpath(reader.document.file) == require("ffi/util").realpath(files[2]), "wrong private book opened")
    reader:handleEvent(require("ui/event"):new("GotoPage", 3))
    assert(reader.rolling.current_page == 3, "private reader did not turn page")
    require("weui_bottombar").navigate(assert(reader.weui), "home", reader, nil, false)
end)
add("43-private-reader-masked-return", function()
    Paper, Data, Privacy = require("weui_paper"), require("weui_library"), require("weui_privacy")
    assert(not require("apps/reader/readerui").instance, "private reader remained open")
    assert(topWidget() == Paper._instance, "private reader returned to wrong page")
    assert(not Privacy.isUnlocked() and findBook(files[2]).title == Privacy.privateTitle(), "per-open return leaked title")
end)
local tools_settings
add("44-settings-tools", function()
    Paper.navigate(plugin, "weui_settings")
    tools_settings = require("weui_settings_window"):show()
    assert(topWidget() == tools_settings._wrapper, "tools settings did not open")
end)
add("45-settings-tool-closes-wrapper", function()
    local selected
    local label = require("weui_i18n").translate("WeRead")
    local function walk(widget, tapper)
        if type(widget) ~= "table" then return end
        if rawget(widget, "onTap") then tapper = widget end
        if widget.text == label then selected = tapper end
        for _, child in ipairs(widget) do walk(child, tapper) end
    end
    walk(tools_settings._wrapper)
    assert(selected, "WeRead tool row missing")
    selected:onTap()
    for _, entry in ipairs(UIManager._window_stack) do
        assert(entry.widget ~= tools_settings._wrapper, "tool navigation left settings wrapper open")
    end
end)
add("46-settings-tool-source", function()
    assert(Paper._instance.wr and topWidget() == Paper._instance, "settings tool did not open source shelf")
    assert(Paper._instance.tab == "weui_settings", "settings tool lost source origin")
    Paper._instance:onClose()
end)
local sheet_origin, origin_stack_size
add("47-room-favorites-sheet", function()
    Paper, Data, Privacy = require("weui_paper"), require("weui_library"), require("weui_privacy")
    sheet_origin = Paper.navigate(plugin, "homescreen")
    plugin = sheet_origin.plugin
    Privacy.setAutoLockMinutes(1); Privacy.lockNow()
    for _, i in ipairs({ 2, 4, 8 }) do
        local book = findBook(files[i])
        if not book.favorite then Data.favorite(book) end
    end
    local collections = require("readcollection")
    collections.coll = {
        [collections.default_collection_name] = collections.coll[collections.default_collection_name],
    }
    collections.coll_settings = { [collections.default_collection_name] = collections.coll_settings[collections.default_collection_name] }
    collections:addCollection("散文")
    collections:addItem(files[4], "散文"); collections:write()
    sheet_origin:rebuild(true)
    origin_stack_size = #UIManager._window_stack
    tap(sheet_origin, 100, sheet_origin.body_bottom - 20)
    local sheet = Paper._instance
    assert(sheet._weui_paper_sheet and sheet.screen == "favorites" and topWidget() == sheet, "favorites shortcut still opens legacy UI")
    assert(sheet.origin_page == sheet_origin and plugin.active_action == "homescreen", "favorites lost room origin")
    assert(#Data.filter(sheet.books, "", "favorites") == 3 and hasText(sheet, "3 本收藏 · 4 个书籍分组"), "favorites/group real data")
    assert(not hasText(sheet, titles[2]) and hasText(sheet, Privacy.privateTitle()), "favorite private title leaked")
    assert(math.abs(sheet.panel_h - 522.6) < 0.01, "favorites paragraph spacing differs from design")
    assert(sheet.panel_y >= 28 and sheet.panel_y + sheet.panel_h == sheet.logical_h - 18, "sheet bottom geometry")
    geometry(sheet)
end)
add("48-favorites-group", function()
    local sheet = Paper._instance
    tapLabel(sheet, "正在读")
    assert(sheet.group.status == "reading", "reading group did not open")
    for _, entry in ipairs(sheet.entries) do assert(entry.book.status == "reading", "group mixed statuses") end
    sheet:onClose()
    assert(Paper._instance == sheet and not sheet.group and hasText(sheet, "收藏与分组"), "group Back did not return to favorites")
    tapLabel(sheet, "散文")
    assert(#sheet.entries == 1 and sheet.entries[1].book.filepath == require("ffi/util").realpath(files[4]), "actual collection membership")
    geometry(sheet)
end)
add("49-sheet-close-restores-origin", function()
    local sheet = Paper._instance
    tap(sheet, 485, sheet.panel_y + 30)
    assert(sheet._closed and Paper._instance == sheet_origin and topWidget() == sheet_origin, "close icon did not close entire sheet")
    assert(#UIManager._window_stack == origin_stack_size and plugin.active_action == "homescreen", "sheet close left overlay or wrong tab")
end)
add("50-room-history-sheet", function()
    local hist = require("readhistory")
    local noon = os.date("*t"); noon.hour = 12
    hist.hist = {
        { file = files[1], time = os.time() - 60 }, { file = files[2], time = os.time() - 120 },
        { file = files[3], time = os.time(noon) - 24 * 3600 },
        { file = files[4], time = os.time(noon) - 4 * 24 * 3600 },
    }
    Data.invalidate(); sheet_origin:rebuild(true)
    tap(sheet_origin, 260, sheet_origin.body_bottom - 20)
    local sheet = Paper._instance
    assert(sheet.screen == "history" and sheet._weui_paper_sheet and topWidget() == sheet, "history shortcut still opens legacy menu")
    assert(#sheet.entries == 4 and sheet.entries[1].book.filepath == require("ffi/util").realpath(files[1]), "history order or unread inclusion")
    assert(sheet.entries[1].meta == "今天" and sheet.entries[3].meta == "昨天", "relative history dates")
    assert(not hasText(sheet, titles[2]), "history private title leaked")
    assert(sheet.panel_h == 297, "history row or panel spacing differs from design")
    geometry(sheet)
end)
add("51-history-dismiss-and-all-alias", function()
    tap(Paper._instance, 100, 100)
    assert(Paper._instance == sheet_origin and topWidget() == sheet_origin, "scrim tap reached background")
    tap(sheet_origin, 460, 429)
    assert(Paper._instance.screen == "history" and Paper._instance.origin_page == sheet_origin, "recent All bypassed paper sheet")
    Paper._instance:onClose()
end)
add("52-room-goals-sheet", function()
    local Store = require("weui_store")
    Store:set("weui_reading_goal_physical", 3)
    tap(sheet_origin, 430, sheet_origin.body_bottom - 20)
    local sheet = Paper._instance
    assert(sheet.screen == "reading_goals" and sheet._weui_paper_sheet, "room goal still opens button dialog")
    assert(sheet.facts.done == 4 and sheet.facts.target == 24 and sheet.facts.remaining == 20, "annual goal facts disagree")
    assert(Data.yearlyBooks(sheet_origin.books) == sheet.facts.done, "room and goal completed counts differ")
    assert(hasText(sheet, "今年已读完") and hasText(sheet, "还需完成") and hasText(sheet, "保存目标"), "approved goal layout missing")
    assert(sheet.panel_h == 326.5 and not hasText(sheet, "每月阅读时间")
        and not hasText(sheet, "每日阅读时间"), "goal main differs from approved annual layout")
    geometry(sheet)
end)
add("52a-goal-secondary-navigation", function()
    local sheet = Paper._instance
    tapLabel(sheet, "每年 24 本")
    assert(sheet.picking_annual and hasText(sheet, "每月阅读时间") and hasText(sheet, "每日阅读时间"),
        "monthly/daily targets missing from picker")
    geometry(sheet)
end)
add("52b-goal-secondary-cancel", function()
    local sheet = Paper._instance
    tapLabel(sheet, "每日阅读时间")
    local input = topWidget()
    input:setInputText("90"); input.buttons[1][1].callback()
    assert(sheet.picking_annual and sheet.draft.daily == 40 * 60, "cancel changed daily target or discarded picker")
    sheet:onClose()
    assert(not sheet.picking_annual and hasText(sheet, "保存目标"), "picker Back failed to restore main")
    geometry(sheet)
end)
add("53-goal-draft-cancel", function()
    local sheet = Paper._instance
    tapLabel(sheet, "每年 24 本"); tapLabel(sheet, "每年 36 本")
    tapLabel(sheet, "每年 36 本")
    tapLabel(sheet, "每月阅读时间")
    local input = topWidget(); input:setInputText("18"); input.buttons[1][2].callback()
    assert(sheet.draft.annual == 36 and sheet.draft.monthly == 18 * 3600, "goal draft edits")
    assert(require("weui_store"):get("weui_reading_goal") == 24, "picker auto-saved draft")
    sheet:onClose()
    assert(Paper._instance == sheet_origin and require("weui_store"):get("weui_monthly_reading_goal_secs") == 12 * 3600, "cancel saved goal draft")
end)
add("54-goal-validation", function()
    sheet_origin:goals()
    local sheet = Paper._instance
    tapLabel(sheet, "每年 24 本"); tapLabel(sheet, "自定义本数")
    local input = topWidget()
    input:setInputText("-1"); input.buttons[1][2].callback()
    assert(sheet.draft.annual == 24 and topWidget() ~= sheet, "negative annual goal accepted")
    UIManager:close(topWidget())
    input:setInputText("1.5"); input.buttons[1][2].callback()
    assert(sheet.draft.annual == 24 and topWidget() ~= sheet, "fractional annual goal accepted")
    UIManager:close(topWidget())
    input:setInputText("10000"); input.buttons[1][2].callback()
    assert(sheet.draft.annual == 24 and topWidget() ~= sheet, "oversized goal accepted")
    UIManager:close(topWidget())
    input:setInputText("30"); input.buttons[1][2].callback()
    assert(sheet.draft.annual == 30 and not sheet.picking_annual, "custom goal did not return to goal sheet")
    geometry(sheet)
end)
add("55-goal-save-and-zero", function()
    local sheet = Paper._instance
    tapLabel(sheet, "保存目标")
    assert(Paper._instance == sheet_origin and require("weui_store"):get("weui_reading_goal") == 30, "custom goal not persisted")
    sheet_origin:goals(); sheet = Paper._instance
    tapLabel(sheet, "每年 30 本"); tapLabel(sheet, "暂不设置"); tapLabel(sheet, "保存目标")
    assert(require("weui_store"):get("weui_reading_goal") == 0, "disable annual goal not saved")
    sheet_origin:goals(); sheet = Paper._instance
    assert(sheet.facts.remaining == 0 and hasText(sheet, "未设置"), "zero-goal facts")
    sheet:dismiss()
    require("weui_store"):set("weui_reading_goal", 30)
    require("weui_store"):set("weui_reading_goal_physical", 0)
end)
add("56-more-entry-aliases", function()
    sheet_origin = Paper.navigate(plugin, "weui_settings")
    for _, label in ipairs({ "收藏与书籍分组", "阅读历史", "阅读目标" }) do
        tapLabel(sheet_origin, label)
        local sheet = Paper._instance
        assert(sheet._weui_paper_sheet and sheet.origin_page == sheet_origin, "More shortcut route")
        assert(plugin.active_action == "weui_settings", "More shortcut changed active tab")
        sheet:onClose()
        assert(Paper._instance == sheet_origin and topWidget() == sheet_origin, "More shortcut return")
    end
    require("weui_quickactions").execute("collections", { plugin = plugin, fm = plugin.ui })
    assert(Paper._instance.screen == "favorites", "quick action bypassed sheet")
    Paper._instance:dismiss()
    require("weui_bottombar").navigate(plugin, "history", sheet_origin)
    assert(Paper._instance.screen == "history" and Paper._instance.origin_page == sheet_origin, "bottom bar history bypassed sheet")
    Paper._instance:dismiss()
end)
add("57-stats-goal-alias", function()
    sheet_origin = Paper.navigate(plugin, "stats_calendar")
    sheet_origin:statsOptions()
    topWidget().buttons[1][1].callback()
    assert(Paper._instance._weui_paper_sheet and Paper._instance.screen == "reading_goals", "statistics goal route")
    Paper._instance:onClose()
    assert(Paper._instance == sheet_origin and topWidget() == sheet_origin and plugin.active_action == "stats_calendar", "statistics goal return")
end)
add("58-history-pagination", function()
    local hist = require("readhistory")
    for i = 1, 14 do
        local file = booksdir .. "/分页书籍" .. i .. ".txt"
        local fh = assert(io.open(file, "w")); fh:write("用于验证阅读历史分页的原创文字。"); fh:close()
        hist.hist[#hist.hist + 1] = { file = file, time = os.time() - (i + 10) * 300 }
    end
    Data.invalidate()
    sheet_origin = Paper.navigate(plugin, "homescreen")
    sheet_origin:action("history")
    local sheet = Paper._instance
    assert(sheet.pages == 2 and #sheet.entries == 18, "history pagination lost records")
    sheet:onNextPage()
    assert(sheet.state.page == 2, "history next page")
    geometry(sheet)
    sheet:onPrevPage(); assert(sheet.state.page == 1, "history previous page")
    sheet:onSwipePaper(nil, { direction = "west" }); assert(sheet.state.page == 2, "history swipe pagination")
end)
add("59-sheet-landscape", function()
    local sheet = Paper._instance
    sheet:onSetRotationMode(1)
    geometry(sheet); geometry(sheet.origin_page)
    assert(sheet.panel_y + sheet.panel_h == sheet.logical_h - 18, "landscape bottom anchor")
    assert(sheet.offset > 0 and sheet.origin_page.offset == sheet.offset, "landscape sheet alignment")
end)
add("60-sheet-portrait-and-navigation", function()
    Paper._instance:onSetRotationMode(0); geometry(Paper._instance)
    local old_sheet, old_origin = Paper._instance, sheet_origin
    local page = Paper.navigate(plugin, "weui_settings")
    assert(old_sheet._closed and old_origin._closed and Paper._instance == page and topWidget() == page, "navigation resurrected closed origin")
    for _, entry in ipairs(UIManager._window_stack) do assert(not entry.widget._weui_paper_sheet, "sheet retained after navigation") end
    sheet_origin = Paper.navigate(plugin, "homescreen")
end)
add("61-sheet-privacy-locked", function()
    local collections = require("readcollection")
    collections:addCollection("纸页私密分组")
    collections:addItem(files[3], "纸页私密分组")
    Privacy.setPrivateCollection("纸页私密分组", true); Privacy.lockNow()
    sheet_origin:action("favorites")
    local sheet = Paper._instance
    assert(hasText(sheet, "私密分组") and not hasText(sheet, "纸页私密分组"), "private collection name leaked")
    assert(not hasText(sheet, titles[2]), "private favorite leaked")
    tapLabel(sheet, "私密分组")
    assert(topWidget().text_type == "password" and Paper._instance == sheet, "private collection bypassed authentication")
    submit(new_password); closeToPage()
end)
add("62-sheet-privacy-unlocked", function()
    local sheet = Paper._instance
    assert(Privacy.isUnlocked() and sheet.group.name == "纸页私密分组", "private group unlock did not navigate")
    assert(hasText(sheet, "纸页私密分组") and hasText(sheet, titles[3]), "unlocked collection remained masked")
    geometry(sheet)
    sheet:back()
    assert(hasText(sheet, titles[2]) and hasText(sheet, "纸页私密分组"), "unlocked favorites stale")
    tapLabel(sheet, "纸页私密分组")
end)
add("63-sheet-privacy-relock", function()
    local sheet = Paper._instance
    Privacy.lockNow()
    assert(topWidget() == sheet and Paper._instance == sheet, "privacy relock discarded paper sheet")
    assert(hasText(sheet, "私密分组") and hasText(sheet, Privacy.privateTitle()), "relock did not mask visible group")
    assert(not hasText(sheet, titles[3]) and not hasText(sheet, "纸页私密分组"), "relock left private group content on framebuffer")
    for _, book in ipairs(sheet.origin_page.books) do
        if book.filepath == require("ffi/util").realpath(files[3]) then assert(book.private and book.title == Privacy.privateTitle(), "sheet background retained private book") end
    end
    sheet:back()
    tapLabel(sheet, Privacy.privateTitle())
    assert(Paper._instance == sheet and not require("apps/reader/readerui").instance, "private favorite opened reader before authentication or lost sheet")
end)
add("64-private-sheet-book-cancel", function()
    assert(topWidget().text_type == "password", "private favorite bypassed deferred password prompt")
    topWidget().buttons[1][1].callback()
    assert(topWidget() == Paper._instance and Paper._instance.origin_page == sheet_origin, "private book cancel did not return to sheet")
    assert(not require("apps/reader/readerui").instance, "cancel opened private reader")
    Paper._instance:dismiss()
    Privacy.setPrivateCollection("纸页私密分组", false)
    Privacy.setAutoLockMinutes(0)
end)
add("65-history-open-real-book", function()
    sheet_origin:action("history")
    local sheet = Paper._instance
    while not hasText(sheet, titles[4]) and sheet.state.page < sheet.pages do sheet:onNextPage() end
    tapLabel(sheet, titles[4])
end)
add("66-history-reader-and-return", function()
    local reader = assert(require("apps/reader/readerui").instance, "history row did not open real reader")
    assert(require("ffi/util").realpath(reader.document.file) == require("ffi/util").realpath(files[4]), "history opened wrong book")
    require("weui_bottombar").navigate(assert(reader.weui), "homescreen", reader, nil, false)
end)
add("67-history-reading-return", function()
    Paper, Data, Privacy = require("weui_paper"), require("weui_library"), require("weui_privacy")
    assert(not require("apps/reader/readerui").instance and Paper._instance.screen == "homescreen", "history reader did not return to room")
    assert(topWidget() == Paper._instance, "history reader left sheet on stack")
    sheet_origin = Paper._instance
    plugin = sheet_origin.plugin
    for _, id in ipairs({ "favorites", "history", "reading_goals" }) do
        sheet_origin:action(id)
        assert(Paper._instance.origin_page == sheet_origin, "sheet origin after real reading")
        Paper._instance:onClose()
    end
end)
add("68-sheet-stack-stress", function()
    local initial = #UIManager._window_stack
    collectgarbage("collect")
    local before = collectgarbage("count")
    for i = 1, 20 do
        for _, id in ipairs({ "favorites", "history", "reading_goals" }) do
            sheet_origin:action(id)
            local sheet = Paper._instance
            UIManager:forceRePaint()
            assert(topWidget() == sheet and sheet.origin_page == sheet_origin, "sheet stress foreground")
            geometry(sheet)
            sheet:onClose()
            assert(topWidget() == sheet_origin and #UIManager._window_stack == initial, "sheet stress retained window")
        end
    end
    collectgarbage("collect")
    assert(collectgarbage("count") - before < 8192, "sheet stress retained over 8 MiB")
end)
local delete_path, delete_sidecar, delete_page, delete_book, delete_confirm, private_delete_path
local function openDeleteMenu(page, book)
    page:bookDetails(book)
    local menu = topWidget()
    buttonByText(menu, "删除书籍").callback()
    return topWidget()
end
local function deleteFixture(path, title)
    local fh = assert(io.open(path, "w")); fh:write(title .. "\n这本书专用于删除回归。\n"); fh:close()
    local ds = require("docsettings"):open(path)
    ds:saveSetting("doc_props", { title = title, authors = "纸页测试" })
    ds:saveSetting("percent_finished", 0.25)
    local sidecar = ds:flush()
    Data.import(path)
    return sidecar
end
add("69-book-delete-confirmation", function()
    G_reader_settings:saveSetting("autoremove_deleted_items_from_history", true)
    delete_path = root .. "/delete-book.txt"
    delete_sidecar = deleteFixture(delete_path, "删除回归书")
    delete_path = require("ffi/util").realpath(delete_path)
    local coll = require("readcollection")
    coll:addItem(delete_path, coll.default_collection_name)
    coll:addCollection("删除回归分组"); coll:addItem(delete_path, "删除回归分组"); coll:write()
    table.insert(require("readhistory").hist, 1, { file = delete_path, time = os.time() })
    Data.invalidate()
    delete_page = Paper.navigate(plugin, "home")
    delete_book = findBook(delete_path)
    delete_confirm = openDeleteMenu(delete_page, delete_book)
    assert(delete_confirm.ok_text == require("gettext")("Delete") and delete_confirm.text:find("delete-book.txt", 1, true),
        "native delete confirmation missing")
    assert(require("libs/libkoreader-lfs").attributes(delete_path, "mode") == "file", "menu deleted before confirmation")
end)
add("70-book-delete-cancel", function()
    delete_confirm:onClose()
    local coll = require("readcollection")
    assert(topWidget() == delete_page and require("libs/libkoreader-lfs").attributes(delete_path, "mode") == "file",
        "cancel deleted book or lost shelf")
    assert(coll.coll[coll.default_collection_name][delete_path] and coll.coll["删除回归分组"][delete_path],
        "cancel changed collections")
end)
add("71-book-delete-failure", function()
    local confirm = openDeleteMenu(delete_page, delete_book)
    local remove = os.remove
    os.remove = function(path, ...)
        if path == delete_path then return nil, "fixture deletion denied" end
        return remove(path, ...)
    end
    local ok, err = pcall(confirm.ok_callback)
    os.remove = remove
    UIManager:close(confirm)
    assert(ok, err)
    assert(topWidget().text and topWidget().text:find("delete-book.txt", 1, true), "failed delete did not report failure")
    assert(require("libs/libkoreader-lfs").attributes(delete_path, "mode") == "file", "failed delete removed file")
    assert(require("readcollection").coll["删除回归分组"][delete_path], "failed delete removed collection member")
    closeToPage()
end)
add("72-book-delete-from-favorites", function()
    delete_page:action("favorites")
    local sheet = Paper._instance
    local confirm = openDeleteMenu(sheet, delete_book)
    confirm.ok_callback(); UIManager:close(confirm)
    local lfs = require("libs/libkoreader-lfs")
    assert(not lfs.attributes(delete_path) and not lfs.attributes(delete_sidecar), "file or native metadata retained")
    assert(topWidget() == sheet and not hasText(sheet, delete_book.title), "favorites retained deleted book")
    for _, book in ipairs(sheet.origin_page.books) do assert(book.filepath ~= delete_path, "background retained deleted book") end
    for _, item in ipairs(require("readhistory").hist) do assert(item.file ~= delete_path, "history retained deleted file") end
    for _, coll in pairs(require("readcollection").coll) do assert(not coll[delete_path], "collection retained deleted file") end
    for _, path in ipairs(require("weui_store"):get("weui_library_files") or {}) do
        assert(path ~= delete_path, "import list retained deleted file")
    end
    local saved = require("luasettings"):open(root .. "/settings/weui/weui_settings.lua")
    for _, path in ipairs(saved:readSetting("weui_library_files") or {}) do assert(path ~= delete_path, "deleted import not persisted") end
    geometry(sheet); sheet:dismiss()
end)
add("73-private-book-delete-password", function()
    Privacy.setAutoLockMinutes(0)
    private_delete_path = root .. "/delete-private-book.txt"
    deleteFixture(private_delete_path, "私密删除回归书")
    private_delete_path = require("ffi/util").realpath(private_delete_path)
    Privacy.setPrivateBook(private_delete_path, true)
    Privacy.lockNow()
    delete_page = Paper.navigate(plugin, "home")
    delete_book = findBook(private_delete_path)
    local input = openDeleteMenu(delete_page, delete_book)
    assert(input.text_type == "password" and not input.text, "private delete exposed file confirmation before password")
    assert(require("libs/libkoreader-lfs").attributes(private_delete_path), "private delete bypassed password")
end)
add("74-private-book-delete-wrong-password", function()
    local input = submit("wrong-delete-password")
    assert(not Privacy.isUnlocked() and require("libs/libkoreader-lfs").attributes(private_delete_path), "wrong password deleted private book")
    UIManager:close(topWidget())
    assert(topWidget() == input, "wrong password dismissed authentication")
    submit(new_password)
    delete_confirm = topWidget()
    assert(delete_confirm._weui_private_book == private_delete_path and delete_confirm.ok_callback,
        "private delete confirmation not protected against relock")
end)
add("75-private-delete-relock", function()
    local stale = delete_confirm
    Privacy.lockNow()
    assert(topWidget() == delete_page, "relock left private delete details visible")
    stale.ok_callback()
    assert(topWidget().text_type == "password" and require("libs/libkoreader-lfs").attributes(private_delete_path),
        "stale confirmation bypassed relock")
    topWidget().buttons[1][1].callback()
end)
add("76-private-book-delete-confirmed", function()
    openDeleteMenu(delete_page, findBook(private_delete_path))
    submit(new_password)
    local confirm = topWidget()
    confirm.ok_callback(); UIManager:close(confirm)
    assert(not require("libs/libkoreader-lfs").attributes(private_delete_path), "authenticated delete did not remove book")
    assert(topWidget() == delete_page, "private deletion lost shelf")
    geometry(delete_page)
end)
local return_origin, return_reader, return_file, return_stats_id, return_page
local function assertPaperReturn(screen, kind)
    assert(not require("apps/reader/readerui").instance, "reader remained open after native return")
    local page = assert(Paper._instance, "native return exposed file manager")
    assert(page.screen == screen and topWidget() == page and not page._closed, "native return lost paper origin")
    assert(page.plugin == require("apps/filemanager/filemanager").instance._weui_plugin, "paper retained destroyed FM plugin")
    assert(not Paper._reader_origin, "reader origin not consumed")
    if kind then assert(page[kind], "paper overlay not restored") end
    geometry(page)
    plugin = page.plugin
    return page
end
add("76a-more-history-open-native-return", function()
    return_origin = Paper.navigate(plugin, "weui_settings")
    tapLabel(return_origin, "阅读历史")
    local sheet = Paper._instance
    while not hasText(sheet, titles[4]) and sheet.state.page < sheet.pages do sheet:onNextPage() end
    return_page = sheet.state.page
    tapLabel(sheet, titles[4])
end)
add("76b-more-history-native-menu-return", function()
    return_reader = assert(require("apps/reader/readerui").instance, "history book did not open")
    return_file = return_reader.document.file
    assert(return_reader.statistics and return_reader.statistics:isEnabled(), "native statistics disabled")
    return_stats_id = assert(return_reader.statistics.id_curr_book, "native statistics book missing")
    assert(return_origin._closed and Paper._reader_origin, "paper not suspended before FM recreation")
    return_reader:handleEvent(require("ui/event"):new("GotoPage", 3))
    local return_callback = assert(return_reader.menu.menu_items.filemanager).callback
    return_reader.menu:onShowMenu()
    assert(topWidget() == return_reader.menu.menu_container, "native reader menu not visible")
    local tab
    for _, item in ipairs(return_reader.menu.tab_item_table) do
        if item.callback == return_callback then tab = item end
    end
    assert(tab, "native menu lost File browser callback")
    tab.callback()
end)
add("76c-history-restored-and-reopen", function()
    local sheet = assertPaperReturn("history", "_weui_paper_sheet")
    assert(sheet.tab == "weui_settings" and sheet.origin_page.screen == "weui_settings" and sheet.state.page == return_page, "More/history page not preserved")
    local book
    for _, entry in ipairs(sheet.entries) do if entry.book and entry.book.filepath == return_file then book = entry.book; break end end
    assert(book and book.percent > 0, "returned progress stale")
    while not hasText(sheet, book.title) and sheet.state.page > 1 do sheet:onPrevPage() end
    tapLabel(sheet, book.title)
end)
add("76d-repeat-open-and-native-home", function()
    local reader = assert(require("apps/reader/readerui").instance)
    assert(reader.statistics.id_curr_book == return_stats_id, "reopen created duplicate statistics book")
    assert(reader.rolling.current_page == 3, "reopen lost reader progress")
    reader:onHome()
end)
add("76e-more-group-open", function()
    assertPaperReturn("history", "_weui_paper_sheet"):dismiss()
    tapLabel(Paper._instance, "收藏与书籍分组")
    tapLabel(Paper._instance, "正在读")
    local sheet = Paper._instance
    local title
    for _, entry in ipairs(sheet.entries) do if entry.book and entry.book.filepath == return_file then title = entry.label end end
    assert(title, "read book missing from reading group")
    while not hasText(sheet, title) and sheet.state.page < sheet.pages do sheet:onNextPage() end
    tapLabel(sheet, title)
end)
add("76f-reader-reload-keeps-origin", function()
    local reader = assert(require("apps/reader/readerui").instance)
    assert(Paper._reader_origin[#Paper._reader_origin].group.status == "reading", "collection group not captured")
    reader:reloadDocument()
end)
add("76g-native-close-after-reload", function()
    local reader = assert(require("apps/reader/readerui").instance)
    assert(topWidget() == reader and Paper._reader_origin, "reload exposed or discarded origin")
    assert(reader.statistics.id_curr_book == return_stats_id, "reload statistics identity changed")
    reader:handleEvent(require("ui/event"):new("Close"))
end)
add("76h-group-restored-and-explicit-tab", function()
    local sheet = assertPaperReturn("favorites", "_weui_paper_sheet")
    assert(sheet.group.status == "reading" and sheet.tab == "weui_settings", "native Close lost collection group")
    local title
    for _, entry in ipairs(sheet.entries) do if entry.book and entry.book.filepath == return_file then title = entry.label end end
    while not hasText(sheet, title) and sheet.state.page < sheet.pages do sheet:onNextPage() end
    tapLabel(sheet, assert(title))
end)
add("76i-explicit-shelf-tab-wins", function()
    local reader = assert(require("apps/reader/readerui").instance)
    require("weui_bottombar").navigate(reader.weui, "home", reader, nil, false)
end)
add("76j-shelf-filter-open", function()
    local page = assertPaperReturn("home")
    page.state.query, page.state.filter, page.state.sort, page.state.page = "时间", "all", "title", 1
    page:rebuild()
    local book = findBook(files[5])
    tapLabel(page, book.title)
end)
add("76k-native-menu-with-folder-setting", function()
    local reader = assert(require("apps/reader/readerui").instance)
    require("weui_store"):set("weui_hs_return_to_book_folder", true)
    reader.menu.menu_items.filemanager.callback()
end)
add("76l-filter-restored-and-source-back", function()
    local page = assertPaperReturn("home")
    assert(page.state.query == "时间" and page.state.filter == "all" and page.state.sort == "title", "shelf search/sort lost")
    require("weui_store"):set("weui_hs_return_to_book_folder", false)
    page.state.query, page.state.sort = "", "recent"
    page:showSources()
    tapLabel(page, "本地导入")
    Paper._instance:dismiss()
    assert(Paper._instance == page and page.screen == "sources", "shelf source import cancel")
    page:onClose()
    assert(page.screen == "home", "source back did not restore shelf")
end)
add("76m-statistics-fixture-migration", function()
    local SQ = require("lua-ljsqlite3/init")
    local database = root .. "/data/old-statistics.sqlite3"
    local conn = SQ.open(database)
    conn:exec([[
        CREATE TABLE book(id INTEGER PRIMARY KEY,title TEXT,authors TEXT,notes INTEGER DEFAULT 0,
          highlights INTEGER DEFAULT 0,pages INTEGER DEFAULT 200,series TEXT,language TEXT,md5 TEXT,
          last_open INTEGER DEFAULT 0,total_read_time INTEGER DEFAULT 0,total_read_pages INTEGER DEFAULT 0);
        CREATE TABLE page_stat_data(id_book INTEGER,page INTEGER,start_time INTEGER,duration INTEGER,total_pages INTEGER);
        INSERT INTO book VALUES(1,'山海小记','纸页测试',2,3,200,NULL,NULL,'00000000000000000000000000000001',123,45,6);
        INSERT INTO book VALUES(2,'城与乡','N/A',0,0,38,'38','N/A','N/A',456,NULL,0);
        INSERT INTO page_stat_data VALUES(2,3,456,30,38);
    ]])
    local Stats = dofile(root .. "/plugins/weui.koplugin/scripts/qa/fixtures/paper_stats.lua")
    local repaired, backup = Stats.repair(conn, database, booksdir)
    assert(repaired and require("libs/libkoreader-lfs").attributes(backup, "mode") == "file", "migration missing backup")
    assert(conn:rowexec("SELECT group_concat(name, ',') FROM pragma_table_info('book');")
        == "id,title,authors,notes,last_open,highlights,pages,series,language,md5,total_read_time,total_read_pages", "native column order not restored")
    assert(conn:rowexec("SELECT md5 FROM book WHERE id=2;") == require("docsettings"):open(files[4]):readSetting("partial_md5_checksum"), "displaced hash not recovered")
    assert(conn:rowexec("SELECT sum(duration) FROM page_stat_data;") == 30, "migration lost page durations")
    assert(conn:rowexec("SELECT total_read_time FROM book WHERE id=1;") == 45 and conn:rowexec("SELECT notes FROM book WHERE id=1;") == 2, "migration altered seeded named fields")
    assert(not Stats.repair(conn, database, booksdir), "migration not idempotent")
    conn:close()
    conn = SQ.open(backup)
    assert(conn:rowexec("SELECT md5 FROM book WHERE id=2;") == "N/A", "backup did not retain original database")
    conn:close()
end)
add("76n-download-folder-paper-picker", function()
    local page = Paper.navigate(plugin, "weui_settings")
    tapLabel(page, "下载管理")
    assert(topWidget() == page and page.screen == "downloads", "download manager missing")
    local downloader = page.plugin._weread_plugin.downloader
    for i = 1, 8 do
        local task = downloader:_newTask("book", "返回筛选测试 " .. i, 1)
        downloader:_updateTask(task, { status = "done", progress = 1 })
    end
    page:rebuild()
    tapLabel(page, "已完成")
    page:onNextPage()
    assert(page.state.download_page == 2, "download pagination missing")
    local config = require("zlibrary.config")
    local original = config.getDownloadDir
    config.getDownloadDir = function() return root end
    tapLabel(page, "Z-Library 下载目录")
    config.getDownloadDir = original
    local picker = Paper._instance
    assert(picker._weui_paper_files and picker.mode == "read" and hasText(picker, "‹ 返回更多"), "download folder left paper")
    tapLabel(picker, "data")
    geometry(picker)
    tapLabel(picker, "新书.txt")
end)
add("76o-download-book-native-back", function()
    local reader = assert(require("apps/reader/readerui").instance, "download file did not open reader")
    reader.menu.menu_items.filemanager.callback()
end)
add("76p-download-picker-restored", function()
    local picker = assertPaperReturn("files", "_weui_paper_files")
    assert(picker.path == require("ffi/util").realpath(root .. "/data") and #picker.path_history == 1, "download directory/back stack lost")
    tapLabel(picker, "‹ 返回上个目录")
    assert(picker.path == require("ffi/util").realpath(root), "download return did not restore parent")
    tapLabel(picker, "取消")
    assert(Paper._instance.screen == "downloads" and topWidget() == Paper._instance, "download cancel lost manager")
    assert(Paper._instance.state.download_filter == "done" and Paper._instance.state.download_page == 2
        and hasText(Paper._instance, "返回筛选测试 4"), "reader return lost download filter/page/tasks")
    Paper._instance.plugin._weread_plugin.downloader:clearFinishedTasks()
    Paper._instance:onClose()
    plugin = Paper._instance.plugin
end)
local wr, wr_book, wr_origin, wr_original, wr_calls, wr_download, wr_online
add("77-weread-cached-detail-offline", function()
    wr = plugin._weread_plugin or plugin:_initWeReadModule()
    wr_original = { client = wr.client, online = wr.isNetworkOnline, login = wr.requireLogin,
        start = wr.downloader.start, qr = wr.qr_login }
    wr_calls, wr_download = 0, nil
    wr.isNetworkOnline = function() return false end
    wr.requireLogin = function() return true end
    wr_book = { book_id = "paper-qa", title = "山海小记", author = "纸页测试",
        intro = ("从一页纸开始，记录阅读中的观察与停留。\n"):rep(80),
        publisher = "纸页", wordCount = 123400, newRating = 875, progress = 35,
        categoryName = "随笔", cached_file = files[6], cache_dir = root .. "/data/weread/cache/paper-qa" }
    wr_book.chapters = {}
    for i = 1, 24 do
        wr_book.chapters[i] = { chapterUid = i, title = "第 " .. i .. " 章 · 观察与停留", wordCount = 800 }
    end
    assert(require("lib.content").save_catalog_cache(wr.client, wr.settings, wr_book, wr_book.chapters))
    wr.settings:set("books", { ["paper-qa"] = wr_book }); wr.settings:flush()
    wr.shelf_regular, wr.shelf_books = { wr_book }, { wr_book }
    wr_origin = Paper.navigate(plugin, "home")
    wr:showShelfGrid(1, "books")
    assert(hasText(Paper._instance, "已缓存")
        or hasText(Paper._instance, "纸页测试 · 已缓存 · 35%"),
        "shelf omitted cache status")
    wr:showBookRecord({ bookId = "paper-qa", title = "山海小记", author = "纸页测试" })
    local sheet = topWidget()
    assert(sheet._weui_weread_sheet and sheet.view.kind == "detail", "book details retained legacy menu")
    assert(sheet.view.book.cached_file == files[6] and hasText(sheet, "开始阅读"), "offline cache path not restored")
    assert(hasText(sheet, "书籍详情") and hasText(sheet, "87.5%"), "paper metadata missing")
    geometry(sheet)
end)
add("78-weread-description-pagination", function()
    tapLabel(topWidget(), "更多信息与操作")
    local actions = topWidget()
    assert(actions.view.kind == "list" and not actions.entries[1].label:find("返回"), "legacy back row leaked")
    wr:showTextDetail("书籍简介", wr_book.intro)
    local sheet = topWidget()
    assert(sheet.pages > 1, "description clipped without pages")
    local visible = sheet.body_text:getVisLineCount()
    sheet:onNextPage()
    assert(sheet.state.page == 2 and sheet.body_text.virtual_line_num == visible + 1, "text pages skip or repeat lines")
    geometry(sheet)
end)
add("79-weread-description-return", function()
    local sheet = topWidget()
    sheet:onClose()
    assert(sheet.view.kind == "list", "text back did not restore actions")
    sheet:onClose()
    assert(sheet.view.kind == "detail", "actions back did not restore details")
    tapLabel(sheet, "章节与目录")
    assert(sheet.view.kind == "list" and sheet.pages > 1, "chapter list not paginated")
    sheet:onNextPage()
    assert(sheet.state.page == 2, "chapter next page")
    geometry(sheet)
end)
add("80-weread-chapter-confirmation", function()
    topWidget():onClose()
    wr.downloader.start = function(_, book, chapters, suffix, options)
        wr_download = { book = book, chapters = chapters, suffix = suffix, options = options }
    end
    local sheet = topWidget()
    tapLabel(sheet, "重新下载")
    assert(sheet.view.kind == "confirm" and hasText(sheet, "下载"), "download confirmation switched styles")
    geometry(sheet)
end)
add("81-weread-download-cancel", function()
    tapLabel(topWidget(), "取消")
    assert(topWidget().view.kind == "detail" and not wr_download, "cancel started download")
    tapLabel(topWidget(), "重新下载")
    tap(topWidget(), 390, topWidget().panel_y + 250)
    assert(wr_download and wr_download.suffix == "full" and #wr_download.chapters == 24, "full download callback changed")
    assert(topWidget().view.kind == "detail", "download confirmation left extra overlay")
end)
add("82-weread-online-detail-mock", function()
    wr.client = setmetatable({
        get_book_info = function() wr_calls = wr_calls + 1; return { intro = wr_book.intro, publisher = "在线测试", newRating = 920 } end,
        get_progress = function() return { book = { progress = 47 } } end,
        get_book_bookmarks = function() return { chapters = { { chapterUid = 1, title = "第一章" } },
            updated = { { chapterUid = 1, markText = "阅读中的一次停留。", createTime = os.time() } } } end,
        get_my_reviews = function() return { reviews = { { review = { content = "纸页测试笔记", abstract = "一页纸", chapterName = "第一章" } } } } end,
        get_best_bookmarks = function() return { items = { { markText = "热门划线测试", totalCount = 3 } } } end,
        get_public_reviews = function() return { reviews = { { review = { content = "公开书评测试", author = { name = "纸页测试" } } } } } end,
        get_similar_books = function() return { booksimilar = { books = { { bookInfo = { bookId = "similar-qa", title = "相似书测试" } } } } } end,
    }, { __index = wr_original.client })
    wr.isNetworkOnline = function() return true end
    local configured = wr.settings.is_api_configured
    wr_original.configured = configured
    wr.settings.is_api_configured = function() return true end
    wr:showBookRecord(wr_book)
end)
add("83-weread-online-detail-result", function()
    assert(wr_calls == 1 and topWidget().view.book.progress == 47 and hasText(topWidget(), "92.0%"), "online details did not refresh in place")
    wr:showBookNotes(wr_book)
end)
add("84-weread-my-notes", function()
    local sheet = topWidget()
    assert(sheet.view.kind == "list" and #sheet.entries == 2, "notes/highlights not listed")
    tapLabel(sheet, "阅读中的一次停留。")
    assert(sheet.view.kind == "text" and sheet.view.text:find("第一章"), "note full text missing chapter")
    geometry(sheet)
end)
add("85-weread-notes-return", function()
    local sheet = topWidget()
    sheet:onClose(); assert(sheet.view.kind == "list", "note return lost list")
    sheet:onClose(); assert(sheet.view.kind == "detail", "notes return lost book")
    wr:showPopularHighlights(wr_book)
end)
add("86-weread-popular-highlights", function()
    local sheet = topWidget()
    assert(sheet.entries[1].label == "热门划线测试", "popular highlights not displayed")
    sheet:onClose()
    wr:showPublicReviews(wr_book, 0)
end)
add("87-weread-public-reviews", function()
    local sheet = topWidget()
    assert(sheet.entries[1].label == "公开书评测试", "public review not displayed")
    sheet:onClose()
    wr:showSimilarBooks(wr_book)
end)
add("88-weread-similar-book-navigation", function()
    local sheet = topWidget()
    assert(sheet.entries[1].label == "相似书测试", "similar books not displayed")
    tapLabel(sheet, "相似书测试")
    assert(sheet.view.kind == "detail" and sheet.view.book.book_id == "similar-qa", "similar book opened wrong detail")
    sheet:onClose()
    assert(sheet.entries[1].label == "相似书测试", "similar book back lost list")
    sheet:onClose()
    assert(sheet.view.book.book_id == "paper-qa", "similar list back lost source book")
end)
add("89-weread-stale-online-navigation", function()
    local before = wr_calls
    wr:showBookRecord(wr_book)
    Paper.navigate(plugin, "weui_settings")
    wr_original.stale_count = before
end)
add("90-weread-stale-online-result", function()
    assert(wr_calls == wr_original.stale_count and Paper._instance.screen == "weui_settings", "late request reopened exited WeRead")
    wr:showShelfGrid(2, "books")
    local source = Paper._instance
    tap(source, 430, 238)
    tapLabel(topWidget(), "书名降序")
    assert(Paper._instance == source and wr.settings:get("shelf").sort_order == "name_desc", "shelf sorting did not persist or return")
    geometry(source)
end)
add("91-weread-download-manager", function()
    wr:showMainMenu()
    local sheet = topWidget()
    assert(sheet._weui_weread_sheet and sheet.view.kind == "list", "account menu is still legacy")
    wr:showDownloadTasks()
    assert(sheet.view.kind == "list", "download manager switched styles")
    wr:showDownloadTaskList("active")
    assert(sheet.view.handle._download_refresh_handle, "download refresh timer not installed")
    wr_original.task_handle = sheet.view.handle
    geometry(sheet)
end)
add("92-weread-download-manager-return", function()
    local sheet = topWidget()
    sheet:onClose()
    assert(wr_original.task_handle._closed and not wr_original.task_handle._download_refresh_handle, "download timer retained after back")
    sheet:dismiss()
    assert(Paper._instance.screen == "weread", "manager close did not restore source")
    wr:showBookMenu(wr_book)
    topWidget():onSetRotationMode(1)
    geometry(topWidget())
end)
add("93-weread-sheet-portrait", function()
    topWidget():onSetRotationMode(0)
    geometry(topWidget())
    for _ = 1, 15 do
        wr:showChapterList(wr_book); topWidget():onClose()
        wr:showTextDetail("测试全文", wr_book.intro); topWidget():onClose()
    end
    assert(#topWidget().history == 0, "WeRead history accumulated duplicate pages")
end)
local paper_task
add("93a-weread-task-progress", function()
    paper_task = wr.downloader:_newTask("book", "纸页下载测试", 24)
    wr.downloader:showTask(paper_task)
    wr.downloader:_updateTask(paper_task, { status = "running", progress = 12, stage = "正在下载章节" })
    assert(topWidget().view.kind == "task" and hasText(topWidget(), "50%"), "paper download progress not updated")
    geometry(topWidget())
end)
add("93b-weread-task-completion", function()
    wr.downloader:_updateTask(paper_task, { status = "done", progress = 24, output_path = files[6] })
    assert(hasText(topWidget(), "下载完成") and hasText(topWidget(), "开始阅读"), "completed task missing reading action")
    topWidget():onClose()
    assert(topWidget().view.kind == "detail" and paper_task.hidden, "task back lost book or retained progress")
end)
add("94-weread-cached-read", function()
    wr.client = wr_original.client
    wr.isNetworkOnline = function() return false end
    wr.requireLogin = wr_original.login
    wr.settings.is_api_configured = wr_original.configured
    wr.downloader.start = wr_original.start
    local source = topWidget().origin_page
    wr_original.return_tab, wr_original.return_screen = source.tab, source.origin_page.screen
    tapLabel(topWidget(), "开始阅读")
end)
add("95-weread-reader-visible", function()
    local Reader = require("apps/reader/readerui")
    assert(Reader.instance and Reader.instance.document.file == files[6], "cached WeRead did not open native reader")
    assert(topWidget() == Reader.instance, "WeRead overlay obscures reader")
    Reader.instance:handleEvent(require("ui/event"):new("Close"))
end)
add("96-weread-reader-return", function()
    assert(Paper._instance and not Paper._instance._closed, "cached reader lost paper return")
    assert(Paper._instance.screen == "weread" and Paper._instance.origin_page.screen == wr_original.return_screen
        and Paper._instance.tab == wr_original.return_tab and topWidget() == Paper._instance,
        "cached reader lost WeRead shelf/source origin")
    Paper.navigate(plugin, "home")
    wr:showBookMenu({ book_id = "missing-cache-qa", title = "未缓存测试", cached_file = root .. "/missing.epub" })
    assert(hasText(topWidget(), "未缓存") and not hasText(topWidget(), "开始阅读"), "missing cache still enabled")
    wr.requireLogin = wr_original.login
    wr.qr_login = { start = function() wr_original.login_prompt = true end }
    assert(not wr:requireLogin(true, true), "missing login was accepted")
end)
add("97-weread-login-and-cleanup", function()
    assert(wr_original.login_prompt, "unauthenticated action did not open login flow")
    closeToPage()
    wr.qr_login = wr_original.qr
    wr.isNetworkOnline = wr_original.online
    Paper.navigate(plugin, "home")
end)

if os.getenv("WEUI_PAPER_ONLINE_AUTH") then
    add("98-live-login-and-shelf", function()
        local auth = assert(loadfile(os.getenv("WEUI_PAPER_ONLINE_AUTH")))()
        wr.settings:update_auth({ api_key = auth.api_key, cookies = auth.cookies, wr_ticket = auth.wr_ticket,
            wr_wrpa = auth.wr_wrpa, account = auth.account })
        wr.settings:set("read_report", { enabled = false })
        wr.settings:set("sync", { pull_on_open = false, upload_on_close = false, upload_interval_minutes = 0 })
        wr.settings:flush()
        assert(wr.settings:is_cookie_configured() and wr.settings:is_api_configured(), "current login is incomplete")
        local response = wr.client:gateway("/shelf/sync", {})
        local shelf = response.books or {}
        wr_online = { shelf = shelf }
        for _, book in ipairs(shelf) do
            if not require("lib.weread").is_mp_book(book.bookId) then wr_online.book = book; break end
        end
        assert(wr_online.book, "no regular book available for online QA")
        wr.shelf_books, wr.shelf_regular, wr.shelf_mp = shelf, shelf, {}
        wr:showShelfGrid(1, "books")
        wr:showBookRecord(wr_online.book)
    end)
    add("99-live-book-detail", function()
        local sheet = topWidget()
        assert(sheet.view.kind == "detail" and sheet.view.book.updated_at, "live book details did not load")
        wr_online.book = sheet.view.book
        assert(wr_online.book.publisher or wr_online.book.intro, "live book metadata is empty")
        assert(hasText(sheet, string.format("%.1f%%", wr_online.book.newRating / 10)), "live recommendation units differ from official API")
        local cover = require("datastorage"):getSettingsDir() .. "/weread_covers/" .. wr_online.book.book_id .. ".jpg"
        assert(require("libs/libkoreader-lfs").attributes(cover, "size") > 0, "live cover was not cached")
        wr:showBookNotes(wr_online.book)
    end)
    add("100-live-notes", function()
        assert(topWidget().view.kind == "list", "live notes did not return a paper list")
        topWidget():onClose()
        wr:showPopularHighlights(wr_online.book)
    end)
    add("101-live-highlights", function()
        assert(topWidget().view.kind == "list", "live highlights did not return a paper list")
        topWidget():onClose()
        wr:showPublicReviews(wr_online.book, 0)
    end)
    add("102-live-reviews", function()
        assert(topWidget().view.kind == "list", "live reviews did not return a paper list")
        topWidget():onClose()
        wr:showChapterList(wr_online.book)
    end)
    add("103-live-chapters-and-download", function()
        local book = wr_online.book
        assert(topWidget().view.kind == "list" and book.chapters and #book.chapters > 0, "live catalog unavailable")
        local chapter = book.chapters[1]
        for _, item in ipairs(book.chapters) do
            if (tonumber(item.wordCount) or 0) > 0 and (tonumber(item.wordCount) or 0) < (tonumber(chapter.wordCount) or 100000) then chapter = item end
        end
        wr.downloader:start(book, { chapter }, "qa", { foreground = false })
        return function()
            local task = wr.downloader:getTasks()[1]
            if not task or task.status == "queued" or task.status == "running" then return false end
            assert(task.status == "done", "live chapter download failed: " .. tostring(task.error))
            assert(task.output_path and require("libs/libkoreader-lfs").attributes(task.output_path, "size") > 0, "live EPUB missing")
            wr_online.path = task.output_path
            closeToPage()
            wr:showBookMenu(book)
            return true
        end
    end)
    add("104-live-downloaded-read", function()
        wr:openFile(wr_online.path)
    end)
    add("105-live-reader-and-close", function()
        local Reader = require("apps/reader/readerui")
        assert(Reader.instance and Reader.instance.document.file == wr_online.path, "live EPUB not readable")
        assert(topWidget() == Reader.instance, "live reader obscured by WeRead")
        Reader.instance:handleEvent(require("ui/event"):new("Close"))
    end)
    add("106-live-return-and-offline", function()
        Paper.navigate(plugin, "home")
        wr.isNetworkOnline = function() return false end
        wr:showShelfGrid(1, "books")
        wr:showBookRecord(wr_online.book)
        assert(topWidget().view.kind == "detail", "live cached detail unavailable offline")
        geometry(topWidget())
    end)
end

-- Register tools only after the plugin and all existing flows have run.
add("106-tools-register", function()
    local previous = #stages
    if os.getenv("WEUI_PAPER_POLISH_ONLY") ~= "1" then
        dofile(root .. "/plugins/weui.koplugin/scripts/qa/fixtures/paper_tools_checks.lua")({
            add = add, Paper = Paper, plugin = plugin, tapLabel = tapLabel, topWidget = topWidget,
            closeToPage = closeToPage, geometry = geometry, hasText = hasText, root = root,
        })
    end
    dofile(root .. "/plugins/weui.koplugin/scripts/qa/fixtures/paper_polish_checks.lua")({
        add = add, Paper = Paper, plugin = plugin, tapLabel = tapLabel, topWidget = topWidget,
        closeToPage = closeToPage, geometry = geometry, hasText = hasText, root = root,
    })
    -- Insert the newly registered flows before the final teardown.
    local tools = {}
    for i = previous + 1, #stages do tools[#tools + 1] = stages[i] end
    for i = #stages, previous + 1, -1 do stages[i] = nil end
    for i = #tools, 1, -1 do table.insert(stages, index + 1, tools[i]) end
end)

add("107-reader-patches-teardown", function()
    local Reader = require("apps/reader/readerui")
    local Patches = require("weui_patches")
    local coroutine_original, fm_original = Reader._weui_show_coroutine_orig, Reader._weui_show_fm_orig
    assert(coroutine_original and fm_original, "reader patch originals missing")
    Patches.patchReaderShowCoroutine(plugin)
    local coroutine_wrapper, fm_wrapper = Reader.showReaderCoroutine, Reader.showFileManager
    Patches.patchReaderShowCoroutine(plugin)
    assert(Reader.showReaderCoroutine == coroutine_wrapper and Reader.showFileManager == fm_wrapper, "reader patches stacked on reinstallation")
    Patches.teardownAll(plugin)
    local Screensaver = require("ui/screensaver")
    assert(not Screensaver._weui_web_patched and not Screensaver._weui_snapshot_mode, "screensaver teardown retained wrappers")
    assert(Reader.showReaderCoroutine == coroutine_original and Reader.showFileManager == fm_original, "reader teardown did not restore native functions")
    assert(not Reader._weui_show_coroutine_patched and not Paper._reader_origin, "reader teardown retained transient state")
end)

local function nextStage()
    index = index + 1
    local stage = stages[index]
    if not stage then
        local fh = assert(io.open(root .. "/artifacts/results.tsv", "a"))
        fh:write(failures == 0 and "PASS" or "FAIL", "\tsuite\tstages=", #stages, " failures=", failures, "\n")
        fh:close()
        UIManager:quit(failures == 0 and 0 or 1); return
    end
    local clock = require("ui/time")
    if trace then trace.stage = stage.name end
    local started_at = clock.now()
    local ok, err = xpcall(stage.fn, debug.traceback)
    if not ok then failures = failures + 1 end
    local function finish()
        UIManager:scheduleIn(dwell, function()
        UIManager:forceRePaint()
        if ok and trace and trace.violations[stage.name] then
            ok, err = false, trace.violations[stage.name]; failures = failures + 1
        end
        if ok and UIManager._weui_paper_return_blocker then
            ok, err = false, "reader return retained its modal snapshot"; failures = failures + 1
        end
        local fh = assert(io.open(root .. "/artifacts/results.tsv", "a"))
        fh:write(ok and "PASS" or "FAIL", "\t", stage.name, "\t", ok and "" or tostring(err), "\n"); fh:close()
        local metrics = assert(io.open(root .. "/artifacts/stages.tsv", "a"))
        metrics:write(string.format("%s\t%.2f\t%.2f\t%d\n", stage.name,
            clock.to_s(clock.since(started_at)) * 1000, collectgarbage("count"), #UIManager._window_stack))
        metrics:close()
        require("device").screen:shot(root .. "/artifacts/" .. stage.name .. ".png")
        UIManager:scheduleIn(0.1, nextStage)
        end)
    end
    if ok and type(err) == "function" then
        local predicate, deadline = err, clock.now() + clock.s(150)
        local function waitForStage()
            local ready
            ok, ready = xpcall(predicate, debug.traceback)
            if not ok then err = ready; failures = failures + 1; finish()
            elseif ready then err = nil; finish()
            elseif clock.now() > deadline then ok, err = false, "stage timed out"; failures = failures + 1; finish()
            else UIManager:scheduleIn(0.25, waitForStage) end
        end
        UIManager:scheduleIn(0.25, waitForStage)
    else finish() end
end
userpatch.registerPatchPluginFunc("weui", function()
    if started then return end
    started = true
    if os.getenv("WEUI_PAPER_POLISH_ONLY") == "1" then
        local selected = {}
        for _, stage in ipairs(stages) do
            if stage.name == "01-home" or stage.name == "106-tools-register"
                    or stage.name == "107-reader-patches-teardown" then selected[#selected + 1] = stage end
        end
        stages = selected
    end
    if os.getenv("WEUI_PAPER_SLOW") == "1" then
        local selected = {}
        for _, stage in ipairs(stages) do
            if stage.name ~= "39-navigation-stress" and stage.name ~= "68-sheet-stack-stress" then
                selected[#selected + 1] = stage
            end
        end
        stages = selected
    end
    local files_only = os.getenv("WEUI_PAPER_FILES_TRACE_ONLY") == "1"
    if os.getenv("WEUI_PAPER_OPEN_TRACE_ONLY") == "1" or files_only then
        local selected = {}
        for _, stage in ipairs(stages) do
            if stage.name:match("^0[1-5]%-") or files_only and (stage.name == "11-more"
                    or stage.name == "12-sources-from-more" or stage.name:match("^13"))
                    or not files_only and (stage.name:match("^1[7-9]%-") or stage.name:match("^2[0-3]%-")) then
                selected[#selected + 1] = stage
            end
        end
        stages = selected
    end
    if os.getenv("WEUI_PAPER_TOOLS_ONLY") == "1" then
        local selected = {}
        for _, stage in ipairs(stages) do
            if stage.name == "01-home" or stage.name == "106-tools-register" or stage.name == "107-reader-patches-teardown" then
                selected[#selected + 1] = stage
            end
        end
        stages = selected
    end
    UIManager:scheduleIn(1, function()
        local FM = require("apps/filemanager/filemanager")
        plugin = FM.instance._weui_plugin
        nextStage()
    end)
end)

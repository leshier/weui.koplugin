-- Seven reported issues exercised with real widgets and isolated settings.
return function(ctx)
    local add, Paper, plugin = ctx.add, ctx.Paper, ctx.plugin
    local UIManager = require("ui/uimanager")
    local Library = require("weui_library")
    local Config = require("weui_config")
    local top, tap, has = ctx.topWidget, ctx.tapLabel, ctx.hasText
    local page, zlib, original_verify, user, password
    local ZConfig = require("zlibrary.config")
    local browser, results
    local function checkNavbar(widget, origin)
        local BB = require("ffi/blitbuffer")
        local Screen = require("device").screen
        local tabs = Config.loadTabConfig()
        assert(widget._navbar_bar and widget._navbar_bar._weui_paper_navbar, "search reverted to legacy navbar")
        local expected = Paper.newNavbar(origin, tabs)
        local actual_bb = BB.new(Screen:getWidth(), Paper.navbarHeight(), BB.TYPE_BB8)
        local expected_bb = BB.new(Screen:getWidth(), Paper.navbarHeight(), BB.TYPE_BB8)
        expected:paintTo(expected_bb, 0, 0)
        widget._navbar_bar:paintTo(actual_bb, 0, 0)
        assert(require("ffi").string(actual_bb.data, actual_bb.stride * actual_bb.h)
            == require("ffi").string(expected_bb.data, expected_bb.stride * expected_bb.h),
            "search navbar differs from paper navbar pixels")
        actual_bb:free(); expected_bb:free(); expected:free()
        assert(widget._navbar_bar.overlap_offset[2] == Screen:getHeight() - Paper.navbarHeight(),
            "navbar position changed")
        assert(widget.height == require("weui_core").getContentHeight(widget), "search content overlaps navbar")
    end
    add("106zba-zlibrary-paper-navbar", function()
        page = Paper.navigate(plugin, "weui_settings")
        plugin = page.plugin
        page:showSources()
        ZConfig.getMultiSearchCache():insert("popular", {})
        require("zlibrary.ui")._last_search_input = "纸页底栏测试"
        page:action("zlibrary", true)
        local stack = UIManager._window_stack
        for _, entry in ipairs(stack) do
            if entry.widget._weui_zlibrary_page then browser = entry.widget end
        end
        assert(browser, "real Z-Library search browser missing")
        checkNavbar(browser, "weui_settings")
        UIManager:close(top())
        assert(top() == browser, "search editor did not return to browser")
    end)
    add("106zbb-zlibrary-result-navbar", function()
        results = require("zlibrary.ui").createSearchResultsMenu(plugin.ui, "纸页底栏测试",
            { { text = "纸页结果测试", book_data = { id = "paper-qa", hash = "paper-qa" } } },
            function() end, { show_cover_search = false })
        checkNavbar(results, "weui_settings")
        local store = require("weui_store")
        store:set("weui_bar_navpager_enabled", true)
        require("weui_bottombar").rebuildAllNavbars(plugin)
        checkNavbar(results, "weui_settings")
        assert(not require("weui_paper")._instance._closed, "navbar rebuild closed paper origin")
        store:set("weui_bar_navpager_enabled", false)
    end)
    add("106zbc-zlibrary-navbar-rotation", function()
        local Screen = require("device").screen
        Screen:setRotationMode(1)
        require("weui_bottombar").rewrapAllWidgets(plugin)
        checkNavbar(results, "weui_settings")
        Screen:setRotationMode(0)
        require("weui_bottombar").rewrapAllWidgets(plugin)
        checkNavbar(results, "weui_settings")
        UIManager:close(results); UIManager:close(browser)
        assert(top() == page, "Z-Library close lost original paper page")
        page:onClose()
    end)
    add("106zbd-zlibrary-empty-result-tab-tap", function()
        local empty = require("zlibrary.ui").createSearchResultsMenu(plugin.ui, "没有匹配结果",
            {}, function() end, { show_cover_search = false })
        checkNavbar(empty, "weui_settings")
        empty:handleEvent(require("ui/event"):new("Gesture", {
            ges = "tap", pos = require("ui/geometry"):new{
                x = 24 + 3.5 * 488 / 5, y = require("device").screen:getHeight() - 30,
            },
        }))
        assert(top() == Paper._instance and Paper._instance.screen == "stats_calendar",
            "paper navbar tap did not select the visible stats tab")
        assert(not require("weui_zlibrary_ui").isOpen(), "tab navigation retained search page")
    end)
    add("106zc-tbr-chinese", function()
        page = Paper.navigate(plugin, "weui_settings")
        plugin = page.plugin
        local RC = require("readcollection")
        RC:addCollection("To Be Read"); RC:write()
        page:action("collections")
        assert(has(top(), "待读") and not has(top(), "To Be Read"), "English system group exposed")
        top():onClose()
    end)
    add("106zd-zlibrary-login-entry", function()
        tap(page, "Z-Library 账号与代理")
        assert(has(page, "未登录"), "empty account reported logged in")
        zlib = plugin._zlibrary_plugin or plugin:_initZlibraryModule()
        original_verify = zlib._verifyCredentials
        user, password = "paper-reader@example.test", " exact-password "
        zlib._verifyCredentials = function(_, email, secret, callback)
            assert(email == user and secret == password, "credentials modified before verification")
            callback("ok", nil, { user_id = "qa-user", user_key = "qa-session" })
        end
        tap(page, "登录并保存账号密码")
        local dialog = top()
        assert(dialog.title == "Z-Library 登录", "login title not Chinese")
        assert(dialog.input_fields[2].text_type == "password", "password field not masked")
        dialog.input_fields[1]:setText(user)
        dialog.input_fields[2]:setText(password)
        dialog.buttons[1][2].callback()
    end)
    add("106ze-zlibrary-login-persistence", function()
        ctx.closeToPage()
        assert(ZConfig.getSetting(ZConfig.SETTINGS_USERNAME_KEY) == user
            and ZConfig.getSetting(ZConfig.SETTINGS_PASSWORD_KEY) == password, "account/password not saved")
        local settings = require("luasettings"):open(require("datastorage"):getSettingsDir() .. "/zlibrary.lua")
        assert(settings:readSetting(ZConfig.SETTINGS_USERNAME_KEY) == user
            and settings:readSetting(ZConfig.SETTINGS_PASSWORD_KEY) == password, "credentials not persisted to disk")
        assert(has(page, "已登录"), "login status did not refresh")
        zlib._verifyCredentials = original_verify
        ZConfig.clearCredentials()
        page:onClose()
    end)
    add("106zf-download-manager-tabs", function()
        local wr = plugin._weread_plugin or plugin:_initWeReadModule()
        wr.downloader:clearFinishedTasks()
        local task = wr.downloader:_newTask("book", "下载管理测试", 10)
        wr.downloader:_updateTask(task, { status = "running", progress = 5 })
        page:downloads()
        tap(page, "全部")
        local count = #UIManager._window_stack
        assert(has(page, "50%") and page._download_timer, "active task/progress missing")
        for _, label in ipairs({ "下载中", "已完成", "已停止", "全部" }) do
            tap(page, label)
            assert(top() == page and #UIManager._window_stack == count, "task filter opened a window")
        end
        ctx.geometry(page)
        tap(page, "下载管理测试")
        top().buttons[1][1].callback()
        assert(task.status == "cancelled" and not page._download_timer, "cancel failed or refresh retained")
        tap(page, "清除已结束任务")
        assert(not has(page, "下载管理测试"), "clear left task on screen")
        page:onClose()
    end)
    local cover_path
    add("106zfa-stats-calendar-boundaries", function()
        page = Paper.navigate(plugin, "stats_calendar")
        page.screen, page.state.stats_month, page.state.period = "stats_details", "2024-02-01", "month"
        page:rebuild()
        assert(has(page, "2024-02-01 — 2024-02-29") and has(page, "29") and not has(page, "30"),
            "month boundary/leap day incorrect")
        local count = #UIManager._window_stack
        tap(page, "年")
        assert(has(page, "2024-01-01 — 2024-12-31") and #UIManager._window_stack == count,
            "year totals used only selected month or added a window")
        ctx.geometry(page)
        page:onClose()
    end)
    add("106zg-new-book-cover-start", function()
        page = Paper.navigate(plugin, "home")
        cover_path = ctx.root .. "/artifacts/自动封面测试.epub"
        local BB = require("ffi/blitbuffer")
        local bb = BB.new(80, 112, BB.TYPE_BB8)
        bb:paintRect(0, 0, 80, 112, BB.COLOR_WHITE)
        bb:paintRect(8, 8, 64, 96, BB.COLOR_BLACK)
        bb:writePNG(ctx.root .. "/artifacts/auto-cover.png"); bb:free()
        local archive = require("ffi/archiver").Writer:new{}
        assert(archive:open(cover_path, "epub"), archive.err)
        local entries = {
            { "mimetype", "application/epub+zip" },
            { "META-INF/container.xml", [[<?xml version="1.0"?><container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="book.opf" media-type="application/oebps-package+xml"/></rootfiles></container>]] },
            { "book.opf", [[<?xml version="1.0"?><package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="id">paper-cover-qa</dc:identifier><dc:title>自动封面测试</dc:title><dc:language>zh-CN</dc:language><meta name="cover" content="cover"/></metadata><manifest><item id="cover" href="cover.png" media-type="image/png" properties="cover-image"/><item id="text" href="text.xhtml" media-type="application/xhtml+xml"/></manifest><spine><itemref idref="text"/></spine></package>]] },
            { "text.xhtml", [[<html xmlns="http://www.w3.org/1999/xhtml"><head><title>自动封面测试</title></head><body><p>新书封面自动刷新验证。</p></body></html>]] },
        }
        for _, entry in ipairs(entries) do assert(archive:addFileFromMemory(entry[1], entry[2], os.time()), archive.err) end
        local ok = archive:addPath("cover.png", ctx.root .. "/artifacts/auto-cover.png", false, os.time())
        assert(ok or archive.err == nil, archive.err)
        archive:close()
        local bim = assert(Config.getBookInfoManager(), "native cover extractor missing")
        bim:deleteBookInfo(cover_path)
        page.state.query, page.state.filter = "自动封面测试", "all"
        assert(Library.import(cover_path))
        assert(has(page, "自动封面测试"), "import did not refresh visible book list")
        assert(page._cover_poll_timer, "new cover extraction refresh not scheduled")
        return function()
            return not page._pending_cover_files[require("ffi/util").realpath(cover_path)]
        end
    end)
    add("106zh-new-book-cover-ready", function()
        local cover = require("desktop_modules/module_books_shared").getBookCover(
            require("ffi/util").realpath(cover_path), 80, 112)
        assert(cover, "cover extraction did not reach visible shelf")
        cover:free()
        assert(not page._cover_poll_timer, "cover poll retained after completion")
        ctx.geometry(page)
    end)
end

return function(host, wr, root)
    local UIManager = require("ui/uimanager")
    local Screen = require("device").screen
    local socket = require("socket")
    local json = require("json")
    local http = require("socket.http")
    local ltn12 = require("ltn12")
    local Content = require("weread.lib.content")
    local Paper = require("weui_paper")
    local function pump(predicate, timeout)
        local deadline = socket.gettime() + (timeout or 30)
        repeat
            UIManager:handleInput()
            if predicate() then return end
            assert(socket.gettime() < deadline, "feature condition timed out")
            require("ffi/util").usleep(10000)
        until false
    end
    local function control(values)
        local chunks, body = {}, values and json.encode(values)
        local _, status = http.request{
            url = wr.settings.mock_endpoint .. (values and "/__control" or "/__state"),
            method = values and "POST" or "GET",
            headers = { ["Content-Type"] = "application/json", ["Content-Length"] = body and #body or 0 },
            source = body and ltn12.source.string(body), sink = ltn12.sink.table(chunks),
        }
        assert(status == 200)
        return json.decode(table.concat(chunks))
    end
    local function requestCount()
        local count = 0
        for _, request in ipairs(control().requests) do
            if request.host == "weread.qq.com" or request.host == "i.weread.qq.com" then count = count + 1 end
        end
        return count
    end
    local function top()
        local stack = UIManager._window_stack
        return assert(stack[#stack]).widget
    end
    local function closeTo(page)
        while top() ~= page do UIManager:close(top()) end
    end
    local function shot(name)
        UIManager:forceRePaint(); Screen:shot(root .. "/evidence/" .. name .. ".png")
    end
    local function item(items, title)
        for _, entry in ipairs(items) do
            if (entry.text_func and entry.text_func() or entry.text) == title then return entry end
        end
        error("missing item " .. title)
    end
    local tr = require("weread.lib.plugin_util").tr
    local shelf = wr.client:get_shelf()
    assert(#shelf.books == 26 and type(shelf.archive) == "table")
    wr.library_db:cacheShelf(shelf.books, shelf.archive)
    wr.settings:set("shelf_cache", { books = shelf.books, archives = shelf.archive,
        account_key = wr.library_db:accountKey() })
    wr:applyShelfSnapshot(shelf.books, shelf.archive)
    wr:showShelfGrid(1, "books")
    local page = top()
    assert(page.screen == "weread" and #wr.shelf_groups >= 3)
    shot("feature-01-shelf")
    wr:showMainMenu()
    assert(top()._weui_weread_sheet)
    local settings_item = item(top().view.items, tr("Settings"))
    wr:showList(tr("Settings"), settings_item.sub_item_table_func())
    local menu = top()
    assert(item(menu.view.items, tr("Download settings")) and item(menu.view.items, tr("Progress management")))
    shot("feature-02-settings")
    wr:showList("阅读时长上报", wr:getReadReportMenuItems())
    local report_items = top().view.items
    wr:showList("上报间隔", report_items[3].sub_item_table_func())
    local intervals, interval_handle = top().view.items, top().view.handle
    assert(#intervals == 2 and not wr.settings:get("read_report").enabled)
    intervals[2].callback(interval_handle)
    assert(wr.settings:get("read_report").interval_seconds == 60 and intervals[2].checked_func())
    intervals[1].callback(interval_handle)
    assert(wr.settings:get("read_report").interval_seconds == 30 and not wr.read_report:status().running)
    shot("feature-02-report-interval")
    closeTo(page)
    wr:showShelfGroups()
    local groups = top().view.items
    assert(#groups >= 4)
    groups[2].callback()
    assert(top() == page and #wr:getPaperShelfBooks("books") < 26)
    shot("feature-03-group")
    wr.shelf_group_key = nil
    wr:showShelfFilterOptions(function() wr:returnToPaperShelf() end)
    assert(top()._weui_weread_sheet)
    top().view.items[2].callback()
    assert(top() == page and #wr:getPaperShelfBooks("books") == 0)
    wr:showShelfFilterOptions(function() wr:returnToPaperShelf() end)
    top().view.items[2].callback()
    assert(#wr:getPaperShelfBooks("books") == 26, "repeated filter tap did not clear")
    local prefs = wr.settings:get("shelf")
    prefs.view_mode, prefs.paginated = "list", false
    wr.settings:set("shelf", prefs); page:rebuild()
    local first = page.state.scroll_index
    page:onSwipePaper(nil, { direction = "north" })
    assert(page.state.scroll_index == first + 1)
    page:onNextPage()
    assert(page.state.scroll_index == first + 1 + page.weread_scroll.count)
    page:onPrevPage(); page:onSwipePaper(nil, { direction = "south" })
    assert(page.state.scroll_index == first)
    shot("feature-04-scroll")
    prefs.paginated, prefs.view_mode = true, "cover"
    wr.settings:set("shelf", prefs); wr.settings:flush(); page:rebuild()
    local book = wr.client:get_book_info("900001")
    Content.ensure_reader_state(wr.client, book)
    local chapters = Content.fetch_catalog(wr.client, book)
    assert(#chapters == 6)
    Content.save_catalog_cache(wr.client, wr.settings, book, chapters)
    wr.library_db:putChapters("900001", chapters)
    book.book_id, book.chapters = "900001", chapters
    local records = wr.settings:get("books", {})
    records["900001"] = book
    wr.settings:set("books", records); wr.settings:flush()
    local picker_chapters = {}
    for i = 1, 18 do picker_chapters[i] = { chapterUid = i, title = "多选分页测试章节 " .. i } end
    local selection = wr:showChapterDownloadSelection(book, picker_chapters)
    selection.item_table[2].callback()
    assert(top().view.pinned_action.text_func():find("1", 1, true))
    selection:onGotoPage(2)
    assert(selection.page == 2 and selection.page_num > 1, "chapter selection did not cross a real page")
    selection.item_table[11].callback()
    assert(top().view.pinned_action.text_func():find("2", 1, true))
    selection.item_table[1].callback()
    assert(top().view.pinned_action.text_func():find("18", 1, true))
    shot("feature-05-selection")
    closeTo(page)
    -- Full-book checkpoints survive cancellation during the next HTTP batch.
    local task = wr.downloader:start(book, chapters, "full", { foreground = true, offer_read = false })
    assert(task and top().view.kind == "task")
    pump(function()
        local job = task.dl
        return job and job.workspace and Content.full_download_completed_chapters(job.workspace, chapters)[1]
    end)
    local workspace = task.dl.workspace
    control{ match = "/web/book/chapter/", delay = 3, times = 0 }
    local before = socket.gettime()
    wr.downloader:cancelTask(task)
    pump(function() return not wr.downloader.current_task and not wr.downloader.engine._active_job end)
    assert(socket.gettime() - before < 1, "foreground cancellation blocked")
    assert(task.status == "cancelled" and Content.full_download_completed_chapters(workspace, chapters)[1])
    shot("feature-06-cancel-checkpoint")
    control{ match = "", delay = 0, times = 0 }
    local resumed = wr.downloader:start(book, chapters, "full", { foreground = true, offer_read = false })
    pump(function() return resumed.status == "done" or resumed.status == "failed" end, 100)
    assert(resumed.status == "done", tostring(resumed.error))
    assert(not require("libs/libkoreader-lfs").attributes(workspace.path))
    local full_path = assert(resumed.output_path)
    shot("feature-07-resumed")
    closeTo(page)
    local a = wr.downloader:start(book, { chapters[1] }, "chapter", { single_chapter = true, foreground = false })
    local b = wr.downloader:start(book, { chapters[2] }, "chapter", { single_chapter = true, foreground = false })
    assert(a and b and b.status == "queued")
    pump(function() return b.status == "done" or b.status == "failed" end, 60)
    assert(a.status == "done" and b.status == "done")
    assert(book.cached_chapters["1"] and book.cached_chapters["2"])
    wr:showWereadCollection()
    assert(top()._weui_weread_sheet and #top().view.items >= 1)
    shot("feature-08-local-collection")
    closeTo(page)
    -- Promote a slow background subprocess into the same paper task UI.
    book.cached_chapters["3"] = nil
    control{ match = "/web/book/chapter/", delay = 1, times = 0 }
    assert(wr.downloader:start(book, { chapters[3] }, "chapter", {
        single_chapter = true, prefetch = true, silent_completion = true, start_delay = 0.01 }))
    pump(function() return wr.downloader:getActivePrefetch() ~= nil end)
    local opened
    local previous = wr.downloader.engine.open_file
    wr.downloader.engine.open_file = function(path) opened = path end
    assert(wr.downloader:promotePrefetch(book, chapters[3]))
    local promoted = assert(wr.downloader.current_task)
    assert(top()._weui_weread_sheet and top().view.kind == "task")
    shot("feature-09-promoted-prefetch")
    pump(function() return promoted.status == "done" or promoted.status == "failed" end, 40)
    assert(promoted.status == "done" and opened == promoted.output_path)
    wr.downloader.engine.open_file = previous
    control{ match = "", delay = 0, times = 0 }
    assert(UIManager._prevent_standby_count == 0, "download standby leak")
    local before_offline = requestCount()
    wr.shelf_books, wr.shelf_regular, wr.shelf_mp = nil, nil, nil
    wr:ensurePaperShelf()
    assert(#wr:getPaperShelfBooks("books") == 26 and requestCount() == before_offline,
        "offline snapshot changed count or performed HTTP")
    closeTo(page)
    UIManager:close(page)
    print("PASS: real shelf groups/offline/settings/continuous list/multiselect/download checkpoints/queue/prefetch promotion")
end

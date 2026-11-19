-- Refresh budgets use native widgets/queues, not a simulated framebuffer driver.
return function(ctx)
    local UIManager = require("ui/uimanager")
    local Screen = require("device").screen
    local BB = require("ffi/blitbuffer")
    local ffi = require("ffi")
    local Refresh = require("weui_refresh")
    local Paper, plugin = ctx.Paper, ctx.plugin
    local page, saved_wr, tasks, sheet, cover_a, cover_b
    local saved_date, minute, saved_info, first_host, second_host
    local baseline = os.getenv("WEUI_PAPER_REFRESH_BASELINE") == "1"
    local metrics = assert(io.open(ctx.root .. "/artifacts/refresh-budget.tsv", "w"))
    metrics:write("action\trefreshes\tarea_percent\n")
    local function measure(name, action, skip_pixels)
        UIManager:forceRePaint()
        local before = Screen.bb:copy()
        action()
        local area, count = 0, #UIManager._refresh_stack
        local regions, modes = {}, {}
        for _, refresh in ipairs(UIManager._refresh_stack) do
            area = area + refresh.region.w * refresh.region.h
            regions[#regions + 1] = refresh.region:copy()
            modes[#modes + 1] = refresh.mode
        end
        metrics:write(string.format("%s\t%d\t%.3f\n", name, count,
            area * 100 / (Screen:getWidth() * Screen:getHeight())))
        metrics:flush()
        UIManager:forceRePaint()
        if not baseline and not skip_pixels then
            -- Independently paint all visible native widgets to detect missed
            -- updates even if no dirty flag/refresh was queued.
            local expected = before:copy()
            local stack, start = UIManager._window_stack, 1
            for i = #stack, 1, -1 do if stack[i].widget.covers_fullscreen then start = i; break end end
            for i = start, #stack do
                local window = stack[i]
                window.widget:paintTo(expected, window.x, window.y)
            end
            assert(ffi.string(expected.data, expected.stride * expected.h)
                == ffi.string(Screen.bb.data, Screen.bb.stride * Screen.bb.h),
                name .. ": native paint differs from current model")
            local old, new = BB.new(before.w, before.h, BB.TYPE_BB8), BB.new(expected.w, expected.h, BB.TYPE_BB8)
            old:blitFrom(before, 0, 0, 0, 0, before.w, before.h)
            new:blitFrom(expected, 0, 0, 0, 0, expected.w, expected.h)
            for y = 0, new.h - 1 do
                for x = 0, new.w - 1 do
                    if old.data[y * old.stride + x] ~= new.data[y * new.stride + x] then
                        local covered = false
                        for _, r in ipairs(regions) do
                            if x >= r.x and y >= r.y and x < r.x + r.w and y < r.y + r.h then covered = true; break end
                        end
                        assert(covered, string.format("%s: changed pixel outside refresh at %d,%d", name, x, y))
                    end
                end
            end
            old:free(); new:free(); expected:free()
        end
        before:free()
        return count, area, modes
    end
    local function tick()
        local timer = assert(page._download_timer, "download timer missing")
        UIManager:unschedule(timer)
        timer()
    end
    ctx.add("106refresh-01-download-setup", function()
        -- Real reader returns may replace FileManager and its plugin instance.
        plugin = assert(require("apps/filemanager/filemanager").instance._weui_plugin)
        saved_wr = plugin._weread_plugin
        saved_date, minute = os.date, "12:34"
        os.date = function(fmt, ...) if fmt == "%H:%M" then return minute end; return saved_date(fmt, ...) end
        tasks = { { id = "refresh-1", title = "下载刷新测试", status = "running", progress = 20, total = 100 } }
        plugin._weread_plugin = { downloader = { getTasks = function() return tasks end } }
        page = Paper.navigate(plugin, "downloads")
    end)
    ctx.add("106refresh-02-idle", function()
        local rebuild, builds = page.rebuild, 0
        page.rebuild = function(self, ...) builds = builds + 1; return rebuild(self, ...) end
        local count = measure("idle-poll", tick)
        page.rebuild = rebuild
        if not baseline then assert(count == 0 and builds == 0, "unchanged downloads rebuilt/refreshed screen") end
    end)
    ctx.add("106refresh-03-progress", function()
        local count, area = measure("progress", function() tasks[1].progress = 21; tick() end)
        if not baseline then
            assert(count == 1 and area < Screen:getWidth() * Screen:getHeight() * 0.06,
                "progress refreshed beyond its row")
        end
    end)
    if not baseline then
    ctx.add("106refresh-04-progress-reset", function()
        local count, area = measure("progress-reset", function() tasks[1].progress = 0; tick() end)
        assert(count == 1 and area < Screen:getWidth() * Screen:getHeight() * 0.06, "progress reset refreshed too much")
    end)
    ctx.add("106refresh-05-text-shrink", function()
        measure("long-title", function() tasks[1].title = "需要清除旧像素的较长下载标题"; tick() end)
        local count, area = measure("short-title", function() tasks[1].title = "短"; tick() end)
        assert(count == 1 and area < Screen:getWidth() * Screen:getHeight() * 0.08, "short title refreshed too much")
    end)
    ctx.add("106refresh-06-pending-paints", function()
        measure("two-rebuilds-before-paint", function()
            tasks[1].progress = 98; page:rebuild()
            tasks[1].progress = 11; page:rebuild()
        end)
    end)
    ctx.add("106refresh-07-hidden-row", function()
        for i = 2, 8 do tasks[i] = { id = "refresh-" .. i, title = "队列书籍" .. i,
            status = "running", progress = 10, total = 100 } end
        page:rebuild(); UIManager:forceRePaint()
        local count = measure("off-page-progress", function() tasks[5].progress = 45; tick() end)
        assert(count == 0, "off-page progress refreshed visible rows")
    end)
    ctx.add("106refresh-08-covered-poll", function()
        UIManager:show(require("ui/widget/infomessage"):new{ text = "覆盖下载列表的弹窗" })
        local count = measure("covered-progress", function() tasks[1].progress = 45; tick() end)
        assert(count == 0, "covered download list refreshed")
    end)
    ctx.add("106refresh-09-uncovered-poll", function()
        UIManager:close(ctx.topWidget())
        local count = measure("uncovered-progress", tick)
        assert(count == 1, "returning to download list did not catch up")
    end)
    ctx.add("106refresh-10-suspend", function()
        page:onSuspend()
        assert(not page._download_timer, "suspend retained download timer")
        plugin._weui_suspended = true
        local count = measure("suspended-rebuild", function() tasks[1].progress = 66; page:rebuild() end, true)
        assert(count == 0, "suspended page refreshed")
        page:onSuspend()
    end)
    ctx.add("106refresh-11-resume", function()
        plugin._weui_suspended = false
        local count = measure("resume-catch-up", function() page:onResume() end)
        assert(count == 1 and page._download_timer, "resume missed progress or timer")
    end)
    ctx.add("106refresh-12-page-clock", function()
        local count, area = measure("paper-clock", function()
            minute = "12:35"; require("weui_topbar").refresh(plugin)
        end)
        assert(count == 1 and area < Screen:getWidth() * Screen:getHeight() * 0.01, "clock refreshed beyond status text")
        assert(measure("paper-clock-unchanged", function() require("weui_topbar").refresh(plugin) end) == 0,
            "unchanged paper clock refreshed")
    end)
    ctx.add("106refresh-13-native-clearing", function()
        local rate, counter = UIManager.FULL_REFRESH_COUNT, UIManager.refresh_count
        local avoid = G_reader_settings:readSetting("avoid_flashing_ui")
        G_reader_settings:saveSetting("avoid_flashing_ui", false)
        UIManager.FULL_REFRESH_COUNT, UIManager.refresh_count = 3, 0
        local _, _, modes = measure("large-content-change", function() page.screen = "home"; page:rebuild() end)
        assert(modes[1] == "partial" and UIManager.refresh_count == 1, "large page bypassed native partial counting")
        local _, _, flash = measure("periodic-native-clear", function() page.screen = "homescreen"; page:rebuild() end)
        assert(flash[1] == "flashui", "periodic native clearing was lost")
        G_reader_settings:saveSetting("avoid_flashing_ui", true)
        local _, _, quiet = measure("respect-avoid-flashing", function() page.screen = "home"; page:rebuild() end)
        assert(quiet[1] == "ui", "native avoid-flashing setting ignored")
        G_reader_settings:saveSetting("avoid_flashing_ui", avoid)
        UIManager.FULL_REFRESH_COUNT, UIManager.refresh_count = rate, counter
    end)
    ctx.add("106refresh-14-cover-replacement", function()
        cover_a, cover_b = BB.new(page:px(60), page:px(80), BB.TYPE_BB8), BB.new(page:px(60), page:px(80), BB.TYPE_BB8)
        cover_a:fill(BB.COLOR_BLACK); cover_b:fill(BB.COLOR_DARK_GRAY)
        local function cover(bb)
            return require("ui/widget/container/framecontainer"):new{
                padding = 0, margin = 0, bordersize = 1,
                require("ui/widget/imagewidget"):new{ image = bb, image_disposable = false,
                    width = bb.w, height = bb.h, scale_factor = 1 },
            }
        end
        local item = { x = page:px(28), y = page:px(220), widget = cover(cover_a) }
        page.items[#page.items + 1] = item
        Refresh.update(page); UIManager:forceRePaint()
        local count, area = measure("cached-cover-change", function()
            item.widget:free(); item.widget = cover(cover_b); Refresh.update(page)
        end)
        assert(count == 1 and area < Screen:getWidth() * Screen:getHeight() * 0.02, "cover change refreshed too much")
        assert(Refresh.region(page._painted_layout, Refresh.capture(page)) == nil, "unchanged shared cover considered dirty")
        page:rebuild()
        cover_a:free(); cover_b:free(); cover_a, cover_b = nil, nil
    end)
    ctx.add("106refresh-15-rotation", function()
        local _, area = measure("rotation", function() page:onSetRotationMode(1) end, true)
        assert(area == Screen:getWidth() * Screen:getHeight(), "rotation did not refresh resized screen")
        page:onSetRotationMode(0)
    end)
    ctx.add("106refresh-16-transparent-sheet", function()
        local Sheet = require("weui_paper_sheets").extend(getmetatable(page).__index, Paper)
        local View = require("weui_paper_weread").extend(Sheet, Paper)
        sheet = View:new{ plugin = plugin, origin_page = page, wr = {} }
        sheet:setView{ key = "refresh-text", kind = "text", title = "原生文本分页", text = ("第一段。\n第二段。\n"):rep(90) }
        Paper._instance = sheet; UIManager:show(sheet, "ui")
    end)
    ctx.add("106refresh-17-text-pagination", function()
        assert(sheet.pages > 1, "text fixture not paginated")
        assert(measure("sheet-unchanged", function() sheet:rebuild() end) == 0, "unchanged transparent sheet refreshed")
        local count = measure("text-scroll", function() sheet:onNextPage() end)
        assert(count == 1, "text page did not refresh")
    end)
    ctx.add("106refresh-18-task-coalescing", function()
        sheet:setView{ key = "refresh-task", kind = "task", task = tasks[1] }
        UIManager:forceRePaint()
        local count = measure("task-burst", function()
            tasks[1].progress = 70; sheet:onTaskUpdated(tasks[1])
            tasks[1].progress = 71; sheet:onTaskUpdated(tasks[1])
        end, true)
        assert(count == 0 and sheet._task_refresh_timer, "task burst was not coalesced")
        local function taskTick()
            local timer = sheet._task_refresh_timer
            UIManager:unschedule(timer); timer()
        end
        local updated, area = measure("task-progress", taskTick)
        assert(updated == 1 and area < Screen:getWidth() * Screen:getHeight() * 0.1, "task progress refreshed whole sheet")
        local done = measure("task-complete-immediate", function() tasks[1].status = "done"; sheet:onTaskUpdated(tasks[1]) end)
        assert(done == 1 and not sheet._task_refresh_timer, "task completion was delayed")
        tasks[1].status = "running"; sheet:onTaskUpdated(tasks[1]); sheet:back()
        assert(not sheet._task_refresh_timer, "task timer retained after back")
    end)
    ctx.add("106refresh-19-sheet-dismissal", function()
        measure("sheet-dismissal", function() sheet:dismiss() end)
        assert(Paper._instance == page and ctx.topWidget() == page, "sheet dismissal lost original page")
    end)
    ctx.add("106refresh-20-native-topbars", function()
        UIManager:close(page)
        local Topbar, Core = require("weui_topbar"), require("weui_core")
        saved_info = Topbar.getTopbarInfo
        minute = "12:35"
        Topbar.getTopbarInfo = function() return { time = minute, battery = 66, battery_sym = "" } end
        local function host()
            local w = require("ui/widget/container/inputcontainer"):new{ dimen = Screen:getSize(), covers_fullscreen = true }
            local tabs = require("weui_config").loadTabConfig()
            local inner = require("ui/widget/container/framecontainer"):new{
                padding = 0, margin = 0, bordersize = 0, background = BB.COLOR_WHITE, dimen = Screen:getSize(),
                require("ui/widget/widget"):new{ dimen = Screen:getSize() },
            }
            local container, wrapper, bar, tb, idx, on, tbidx = Core.wrapWithNavbar(inner, "home", tabs, true, w)
            w[1] = wrapper
            Core.applyNavbarState(w, container, bar, tb, idx, on, tbidx, tabs)
            UIManager:show(w, "ui")
            return w
        end
        first_host, second_host = host(), host()
        UIManager:forceRePaint()
        local count, area = measure("native-topbar-clock", function() minute = "12:36"; Topbar.refresh(plugin) end)
        assert(count == 1 and area < Screen:getWidth() * Screen:getHeight() * 0.08, "topbar refreshed covered windows/full screen")
        assert(first_host._navbar_topbar ~= second_host._navbar_topbar, "windows share mutable topbar")
        assert(measure("native-topbar-unchanged", function() Topbar.refresh(plugin) end) == 0, "unchanged native topbar refreshed")
    end)
    ctx.add("106refresh-21-topbar-suspend", function()
        plugin._weui_suspended = true
        assert(measure("native-topbar-suspended", function() require("weui_topbar").refresh(plugin) end) == 0,
            "suspended topbar refreshed")
        plugin._weui_suspended = false
        UIManager:close(second_host); UIManager:close(first_host)
        second_host:free(); first_host:free()
        second_host, first_host = nil, nil
    end)
    end
    ctx.add("106refresh-99-cleanup", function()
        if saved_info then require("weui_topbar").getTopbarInfo = saved_info end
        if saved_date then os.date = saved_date end
        plugin._weui_suspended = false
        plugin._weread_plugin = saved_wr
        Paper.navigate(plugin, "homescreen")
        assert(not page._download_timer, "closed download page retained timer")
        metrics:close()
    end)
end

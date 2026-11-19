-- WeRead views use the same paper sheet as the local library.
local Screen = require("device").screen
local BB = require("ffi/blitbuffer")
local Geom = require("ui/geometry")
local UIManager = require("ui/uimanager")
local Refresh = require("weui_refresh")
local Config = require("weui_config")
local lfs = require("libs/libkoreader-lfs")
local ink, sub, rule = BB.gray(0.91), BB.gray(0.66), BB.gray(0.28)
local M = {}

local function clean(text)
    return tostring(text or ""):gsub("<br%s*/?>", "\n"):gsub("</p>", "\n")
        :gsub("<[^>]+>", ""):gsub("&nbsp;", " "):gsub("&amp;", "&")
        :gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("\r", "")
end

function M.extend(Sheet, Paper)
    local View = Sheet:extend{ name = "weui_weread_sheet", _weui_weread_sheet = true }

    function View:init()
        self.history = {}
        Sheet.init(self)
    end

    function View:release(view)
        if view and view.task then view.task.hidden = true end
        if view == self.view and self._task_refresh_timer then
            UIManager:unschedule(self._task_refresh_timer); self._task_refresh_timer = nil
        end
        if not view or not view.handle then return end
        local handle = view.handle
        handle._closed = true
        if handle.onClose then handle:onClose() end
        if handle._download_refresh_handle then
            UIManager:unschedule(handle._download_refresh_handle)
            handle._download_refresh_handle = nil
        end
    end

    -- Each list gets its own handle: a late refresh cannot replace another view.
    function View:setView(view)
        if self.view then
            if self.view.key == view.key then
                view.page = view.page or self.state.page
                self:release(self.view)
            else
                local found
                for i, previous in ipairs(self.history) do
                    if previous.key == view.key then found = i; break end
                end
                if found then
                    self:release(self.view)
                    view.page = self.history[found].page
                    for i = #self.history, found, -1 do
                        self:release(self.history[i]); table.remove(self.history, i)
                    end
                else
                    self.view.page = self.state.page
                    self.history[#self.history + 1] = self.view
                end
            end
        end
        self.view, self.state.page = view, view.page or 1
        if view.kind == "list" then
            local sheet = self
            view.handle = { _weread_paper_view = true, widget = self, view = view,
                item_table = view.items, dimen = self.dimen }
            function view.handle:switchItemTable(_, items)
                if self._closed or sheet._closed then return end
                self.view.items, self.item_table = items, items
                if sheet.view == self.view then sheet:rebuild() end
            end
            function view.handle:updateItems()
                if not self._closed and not sheet._closed and sheet.view == self.view then sheet:rebuild() end
            end
            function view.handle:onGotoPage(page)
                if self._closed or sheet._closed then return end
                self.view.page = math.max(1, tonumber(page) or 1)
                if sheet.view == self.view then sheet.state.page = self.view.page; sheet:rebuild() end
            end
        end
        self:rebuild()
        return view.handle or self
    end

    function View:back()
        if #self.history == 0 then return self:dismiss() end
        self:release(self.view)
        self.view = table.remove(self.history)
        self.state.page = self.view.page or 1
        self:rebuild()
        return true
    end

    function View:onClose() return self:back() end

    function View:drawRows()
        local entries = {}
        for _, item in ipairs(self.view.items or {}) do
            if not item._weread_back and not (item.text == "" and item.select_enabled == false) then
                local enabled = item.select_enabled ~= false
                if item.enabled_func then enabled = item.enabled_func() ~= false end
                if item.select_enabled_func then enabled = enabled and item.select_enabled_func() ~= false end
                if item.enabled == false then enabled = false end
                local label = item.text_func and item.text_func() or item.text
                local checked = item.checked_func and item.checked_func() or item.checked
                if checked then label = "✓ " .. tostring(label or "") end
                local meta = item.mandatory_func and item.mandatory_func() or item.mandatory
                if item.post_text and item.post_text ~= "" then
                    meta = meta and meta ~= "" and (item.post_text .. " · " .. meta) or item.post_text
                end
                local callback = item.callback
                if item.sub_item_table or item.sub_item_table_func then
                    meta = "›"
                    callback = function()
                        local items = item.sub_item_table_func and item.sub_item_table_func() or item.sub_item_table
                        self.wr:showList(clean(label), items)
                    end
                end
                entries[#entries + 1] = {
                    label = clean(label), meta = clean(meta),
                    icon_path = item.icon_path or (item.book and Config.ICON.weread_book or Config.ICON.ko_settings),
                    callback = enabled and callback and function()
                        callback(self.view.handle)
                        if not self._closed then self:rebuild() end
                    end or nil, disabled = not enabled,
                    hold = enabled and item.hold_callback or nil,
                }
            end
        end
        if #entries == 0 then entries[1] = { label = self.view.empty_text or "暂无内容", disabled = true } end
        self.entries = entries
        local pinned = self.view.pinned_action
        self.pinned_action = pinned
        self:drawList(self.view.title, self.view.subtitle, true)
        self.pinned_action = nil
        if pinned then
            local enabled = not pinned.select_enabled_func or pinned.select_enabled_func()
            self:action(pinned.text_func and pinned.text_func() or pinned.text, 38,
                self.panel_y + self.panel_h - 62, 460,
                function() pinned.callback(self.view.handle) end, true, enabled)
        end
        self.view.handle.page, self.view.handle.page_num = self.state.page, self.pages
        self.view.page = self.state.page
    end

    function View:sheetRow(label, meta, y, callback, hold, selected, icon_path)
        if icon_path then self:icon(icon_path, 40, y + 13, 22) end
        self:lineText(label, icon_path and 76 or 38, y, icon_path and 268 or 306, 12, 47, { color = callback and ink or sub })
        self:lineText(meta or "", 350, y, 148, 10, 47, { align = "right", color = sub })
        self:rect(38, y + 47, 460, 1, BB.gray(0.2))
        self:hit(38, y, 460, 48, callback, hold)
    end

    function View:paging(y)
        self:lineText("‹", 174, y, 48, 25, 40, { align = "center", color = self.state.page > 1 and ink or rule })
        self:lineText(self.state.page .. " / " .. self.pages, 238, y, 60, 11, 40, { align = "center", color = sub })
        self:lineText("›", 314, y, 48, 25, 40, { align = "center", color = self.state.page < self.pages and ink or rule })
        self:hit(174, y, 48, 40, function() self:onPrevPage() end)
        self:hit(314, y, 48, 40, function() self:onNextPage() end)
    end

    function View:drawText()
        local height = math.min(590, self.logical_h - 46)
        local y = self:frame(self.view.title, height, true)
        local body_h = height - 145
        self.body_text = self:text(clean(self.view.text), 38, y, 460, 12, { h = body_h, line_height = 0.6, ellipsis = false })
        self.pages = math.max(1, math.ceil(self.body_text:getAllLineCount() / self.body_text:getVisLineCount()))
        self.state.page = math.max(1, math.min(self.state.page, self.pages))
        if self.state.page > 1 then
            self.body_text:scrollToRatio((self.state.page - 1) / math.max(1, self.pages - 1), true)
        end
        self:paging(y + body_h + 8)
    end

    function View:action(label, x, y, w, callback, solid, enabled)
        self:rect(x, y, w, 48, solid and ink or rule, not solid and 1 or nil)
        self:lineText(label, x + 7, y, w - 14, 13, 48,
            { align = "center", color = solid and BB.COLOR_WHITE or enabled == false and sub or ink })
        self:hit(x, y, w, 48, enabled ~= false and callback or nil)
    end

    function View:drawBook()
        local book, wr = self.view.book, self.wr
        local id = book.book_id or book.bookId
        local saved = wr.settings:get("books", {})[id]
        local path = saved and saved.cached_file or book.cached_file
        local cached = type(path) == "string" and lfs.attributes(path, "mode") == "file"
        book.cached_file = cached and path or nil
        self.pages = nil
        local height = math.min(632, self.logical_h - 46)
        local y = self:frame("书籍详情", height, #self.history > 0)
        self:cover({ title = book.title or "未命名", authors = book.author or "", source_book = book }, 38, y, 108, 151, true)
        local progress = math.min(100, math.max(0, tonumber(book.progress) or 0))
        local reading = { authors = book.author or "作者未提供", percent = progress / 100,
            status = book.finishReading == 1 and "done" or nil }
        local title = self:text(book.title or "未命名", 164, y + 2, 334, 22,
            { font = "song", h = 62, height_adjust = true, line_height = 0.15 })
        local info_y = y + 2 + title:getSize().h / self.scale + 7
        local info = self:bookReadingInfo(reading, 164, info_y, 334, { size = 12,
            status = book.finishReading == 1 and "已读完" or "已读 " .. string.format("%.0f%%", progress) })
        local bar_y = info_y + info:getSize().h / self.scale + 7
        self:readingProgress(reading, 164, bar_y, 334, 6)
        self:lineText(book.categoryName or book.category or "微信读书", 164, bar_y + 17, 334, 10, 20, { color = sub })
        self:lineText(cached and "已缓存 · 可离线阅读" or self.view.status or "尚未缓存", 164, bar_y + 41, 334, 10, 20, { color = sub })
        local words = tonumber(book.wordCount) or 0
        local rating = tonumber(book.newRating) or 0
        local values = { words > 0 and (words >= 10000 and string.format("%.1f 万", words / 10000) or tostring(words)) or "—",
            rating > 0 and string.format("%.1f%%", rating / 10) or "—" }
        local captions = { "字数", "推荐值" }
        if words == 0 and book.chapters and #book.chapters > 0 then
            values[1], captions[1] = tostring(#book.chapters), "章节"
        end
        self:rect(38, y + 169, 460, 1, rule)
        for i = 1, #values do
            local x = 38 + (i - 1) * 460 / #values
            self:lineText(values[i], x, y + 177, 460 / #values, 14, 22)
            self:lineText(captions[i], x, y + 201, 460 / #values, 10, 19, { color = sub })
        end
        self:rect(38, y + 230, 460, 1, rule)
        local intro_h = math.max(35, height - 581)
        self:text(clean(book.intro and book.intro ~= "" and book.intro or "暂无简介"), 38, y + 246, 460, 12, { h = intro_h })
        self:hit(38, y + 246, 460, intro_h, function() wr:showTextDetail("书籍简介", clean(book.intro or "暂无简介")) end)
        local row_y = y + 254 + intro_h
        local rows = {
            { "章节与目录", function() wr:showChapterList(book) end, Config.ICON.weread_chapters },
            { "笔记与划线", function()
                Paper.showWeReadView(wr, { kind = "list", title = "笔记与划线", key = "notes:" .. id, items = {
                    { text = "我的笔记", callback = function() wr:showBookNotes(book) end },
                    { text = "热门划线", callback = function() wr:showPopularHighlights(book) end },
                    { text = "公开书评", callback = function() wr:showPublicReviews(book, 0) end },
                } })
            end, Config.ICON.weread_notes },
            { "更多信息与操作", function() wr:showBookActions(book) end, Config.ICON.weui_menu },
        }
        for _, row in ipairs(rows) do
            self:sheetRow(row[1], "›", row_y, wr:safeCallback(row[1], row[2]), nil, nil, row[3])
            row_y = row_y + 48
        end
        local buttons_y = self.panel_y + height - 70
        self:action(cached and "开始阅读" or "未缓存", 38, buttons_y, 222,
            wr:safeCallback("缓存阅读", function() wr:openCachedBook(book) end), false, cached)
        self:action(cached and "重新下载" or "下载整本", 276, buttons_y, 222,
            wr:safeCallback("下载整本", function() wr:confirmDownloadAllChapters(book) end), true)
    end

    function View:drawConfirm()
        self.pages = nil
        local y = self:frame(self.view.title, 310, true)
        self:text(self.view.text, 38, y, 460, 12, { h = 115 })
        self:action("取消", 38, y + 144, 222, function() self:back() end)
        self:action(self.view.ok_text or "确定", 276, y + 144, 222, function()
            local callback = self.view.callback
            self:back()
            callback()
        end, true)
    end

    function View:drawTask()
        local task = self.view.task
        self.pages = nil
        local y = self:frame("下载进度", 430, true)
        local labels = { queued = "等待下载", running = "正在下载", done = "下载完成",
            failed = "下载失败", cancelled = "已取消" }
        local progress, total = tonumber(task.progress) or 0, math.max(1, tonumber(task.total) or 1)
        local ratio = math.max(0, math.min(1, progress / total))
        self:text(task.title or "微信读书", 38, y, 460, 18, { font = "song", h = 53 })
        self:lineText(labels[task.status] or task.status, 38, y + 67, 330, 12, 24)
        self:lineText(string.format("%.0f%%", ratio * 100), 368, y + 67, 130, 14, 24, { align = "right" })
        self:rect(38, y + 104, 460, 3, rule)
        self:rect(38, y + 104, 460 * ratio, 3, ink)
        self:lineText(string.format("%d / %d 章", math.floor(progress), total), 38, y + 118, 460, 10, 22, { color = sub })
        self:text(clean(task.error or task.stage or ""), 38, y + 158, 460, 12, { h = 73 })
        self:hit(38, y + 158, 460, 73, function()
            self.wr:showTextDetail("下载日志", table.concat(task.logs or {}, "\n"))
        end)
        local active = task.status == "queued" or task.status == "running"
        self:action(active and "取消下载" or "返回", 38, y + 261, 222,
            active and self.view.cancel_callback or function() self:back() end)
        self:action(task.output_path and "开始阅读" or "隐藏进度", 276, y + 261, 222,
            task.output_path and self.view.read_callback or function() self:back() end, true)
    end

    function View:onTaskUpdated(task)
        if self._closed or not self.view or self.view.task ~= task or not Refresh.awake(self.plugin) then return end
        local terminal = task.status ~= "queued" and task.status ~= "running"
        if terminal and Refresh.top(self) then
            if self._task_refresh_timer then UIManager:unschedule(self._task_refresh_timer); self._task_refresh_timer = nil end
            self:rebuild()
            return
        end
        if self._task_refresh_timer then return end
        local function poll()
            self._task_refresh_timer = nil
            if self._closed or not self.view or self.view.task ~= task or not Refresh.awake(self.plugin) then return end
            if Refresh.top(self) then self:rebuild()
            else self._task_refresh_timer = poll; UIManager:scheduleIn(2, poll) end
        end
        self._task_refresh_timer = poll
        UIManager:scheduleIn(2, poll)
    end

    function View:rebuild()
        if self._closed then return end
        self:freeItems()
        self.scale = math.min(Screen:getWidth() / 536, Screen:getHeight() / 724)
        self.logical_h = Screen:getHeight() / self.scale
        self.offset = math.floor((Screen:getWidth() - self:px(536)) / 2)
        self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
        self.items, self.hits = {}, {}
        self._pending_cover_files = {}
        if self.view then
            if self.view.kind == "detail" then self:drawBook()
            elseif self.view.kind == "text" then self:drawText()
            elseif self.view.kind == "confirm" then self:drawConfirm()
            elseif self.view.kind == "task" then self:drawTask()
            else self:drawRows() end
        end
        Refresh.update(self)
        self:scheduleCoverRefresh()
    end

    function View:onCloseWidget()
        self:release(self.view)
        for _, view in ipairs(self.history) do self:release(view) end
        Sheet.onCloseWidget(self)
    end
    return View
end

return M

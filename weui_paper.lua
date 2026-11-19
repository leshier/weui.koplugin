-- WeUI · 纸页. Native KOReader widgets at the approved 536 × 724 geometry.
local Device = require("device")
local Screen = Device.screen
local BB = require("ffi/blitbuffer")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local InputContainer = require("ui/widget/container/inputcontainer")
local GestureRange = require("ui/gesturerange")
local TextWidget = require("ui/widget/textwidget")
local TextBoxWidget = require("ui/widget/textboxwidget")
local ImageWidget = require("ui/widget/imagewidget")
local UIManager = require("ui/uimanager")
local Refresh = require("weui_refresh")
local Store = require("weui_store")
local Config = require("weui_config")
local Library = require("weui_library")
local SH = require("desktop_modules/module_books_shared")
local Privacy = require("weui_privacy")
local _ = require("weui_i18n").translate
local M = {}
local dir = debug.getinfo(1, "S").source:match("^@(.+/)[^/]+$")
local song = dir .. "fonts/PaperSong.ttf"
-- Blitbuffer.gray uses darkness: 0 is white, 1 is black.
local ink, sub, rule = BB.gray(0.91), BB.gray(0.66), BB.gray(0.28)
local ids = { "homescreen", "home", "notes", "stats_calendar", "weui_settings" }
local labels = {
    homescreen = _("Reading Room"), home = _("Bookshelf"), notes = _("Notes"),
    stats_calendar = _("Stats"), weui_settings = _("More"),
}
local states = {}
local Page = InputContainer:extend{ covers_fullscreen = true, _navbar_injected = true }
local sheet_ids = { favorites = "favorites", collections = "favorites", history = "history", reading_goals = "reading_goals",
    rankings = "rankings", groups = "groups" }
local Sheet
local GroupSheet
local WeReadSheet
local FilePicker

function M.isMain(id)
    if id == "homescreen" and Store:get("weui_paper_home") == false then return false end
    for _, action in ipairs(ids) do if action == id then return true end end
    return false
end

function M.isSheet(id) return sheet_ids[id] ~= nil end

function M.originTab()
    return M._instance and M._instance.tab
end

local function owner(plugin)
    local FM = package.loaded["apps/filemanager/filemanager"]
    return FM and FM.instance and FM.instance._weui_plugin
        or plugin and plugin.ui and plugin.ui._weui_plugin or plugin
end

local function toast(text)
    UIManager:show(require("ui/widget/infomessage"):new{ text = text, timeout = 3 })
end

local function duration(seconds)
    local mins = math.floor((seconds or 0) / 60)
    return string.format("%d 小时 %d 分", math.floor(mins / 60), mins % 60)
end

function Page:init()
    self.name = self.screen == "homescreen" and "homescreen" or "weui_paper"
    self._weui_full_page_group = self.wr and "weread" or "paper"
    self._weread_full_page = self.wr and true or nil
    self.tab = self.tab or self.screen
    self.state = self.state or states[self.screen] or { query = "", filter = "all", page = 1, sort = "recent", period = "week" }
    states[self.screen] = self.state
    self.key_events = {
        Close = { { "Back" }, { "Esc" } },
        NextPage = { { "PageForward" }, { "Right" } },
        PrevPage = { { "PageBack" }, { "Left" } },
        Room = { { "1" } }, Shelf = { { "2" } }, Notes = { { "3" } },
        Stats = { { "4" } }, More = { { "5" } },
    }
    self.ges_events = {
        TapPaper = { GestureRange:new{ ges = "tap", range = function() return self.dimen end } },
        SwipePaper = { GestureRange:new{ ges = "swipe", range = function() return self.dimen end } },
        HoldPaper = { GestureRange:new{ ges = "hold", range = function() return self.dimen end } },
    }
    self:rebuild()
end

function Page:px(n) return math.floor(n * self.scale + 0.5) end
function Page:face(kind, size)
    -- Font:getFace applies DPI scaling. Convert the desired physical size once.
    local logical = self:px(size) * 100 / Screen:scaleBySize(100)
    return Font:getFace(kind == "song" and song or kind == "number" and "NotoSerif-Regular.ttf"
        or "NotoSansCJKsc-Regular.otf", logical)
end
function Page:text(text, x, y, w, size, opts)
    opts = opts or {}
    local widget
    local properties = {
        text = tostring(text or ""), face = self:face(opts.font, size or 12),
        fgcolor = opts.color or ink, bgcolor = opts.background or BB.COLOR_WHITE,
        bold = opts.bold, padding = 0,
    }
    if opts.h then
        properties.width, properties.height = self:px(w), self:px(opts.h)
        properties.height_adjust = opts.height_adjust
        properties.height_overflow_show_ellipsis = opts.ellipsis ~= false
        properties.line_height = opts.line_height or 0.35
        widget = TextBoxWidget:new(properties)
    else
        properties.max_width = self:px(w)
        properties.truncate_with_ellipsis = true
        widget = TextWidget:new(properties)
        local width = widget:getSize().w / self.scale
        if opts.align == "right" then x = x + w - width
        elseif opts.align == "center" then x = x + (w - width) / 2 end
    end
    self.items[#self.items + 1] = { widget = widget, x = self:px(x), y = self:px(y) }
    return widget
end
function Page:rect(x, y, w, h, color, border)
    self.items[#self.items + 1] = { x = self:px(x), y = self:px(y), w = self:px(w), h = self:px(h),
        color = color or rule, border = border and math.max(1, self:px(border)) }
end
function Page:line(y, color) self:rect(28, y, 480, 0.7, color) end
function Page:hit(x, y, w, h, callback, hold)
    self.hits[#self.hits + 1] = { x = self:px(x), y = self:px(y), w = self:px(w), h = self:px(h),
        callback = callback, hold = hold }
end
function Page:icon(path, x, y, size)
    if not path then return end
    local widget = ImageWidget:new{ file = path, width = self:px(size), height = self:px(size), is_icon = true, alpha = true }
    self.items[#self.items + 1] = { widget = widget, x = self:px(x), y = self:px(y) }
end
function Page:iconButton(path, x, y, callback, label)
    self:icon(path, x + 13, y + 13, 22)
    self:hit(x, y, 48, 48, callback, label and function() toast(label) end)
end
function Page:button(label, x, y, w, callback, solid)
    if solid then self:rect(x, y, w, 48, ink)
    else self:rect(x, y, w, 48, rule, 0.7) end
    self:text(label, x + 7, y + 15, w - 14, 12, { color = solid and BB.COLOR_WHITE or ink, align = "center" })
    self:hit(x, y, w, 48, callback)
end
function Page:heading(title, subtitle)
    self:text(title, 28, 43, 340, 33, { font = "song" })
    self:text(subtitle, 28, 89, 420, 11, { color = sub })
end
function Page:section(label, y, action, callback)
    self:text(label, 28, y, 370, 12, { bold = true })
    if action then
        self:text(action .. " ›", 418, y, 90, 11, { align = "right", color = sub })
        self:hit(410, y - 12, 98, 42, callback)
    end
end
function Page:search(y, placeholder, callback)
    self:rect(28, y, 480, 42, rule, 0.7)
    self:icon(Config.ICON.ko_search, 41, y + 12, 18)
    self:text(self.state.query ~= "" and self.state.query or placeholder, 70, y + 12, 395, 12, { color = sub })
    self:hit(28, y, 480, 42, callback)
end
function Page:askSearch()
    local dialog
    dialog = require("ui/widget/inputdialog"):new{
        title = self.screen == "notes" and "搜索笔记与划线" or "搜索书名、作者或标签",
        input = self.state.query,
        buttons = { {
            { text = "清除", callback = function()
                UIManager:close(dialog); self.state.query = ""; self.state.page = 1; self:rebuild()
            end },
            { text = _("Cancel"), callback = function() UIManager:close(dialog) end },
            { text = _("Search"), is_enter_default = true, callback = function()
                self.state.query = dialog:getInputText(); self.state.page = 1
                UIManager:close(dialog); self:rebuild()
            end },
        } },
    }
    UIManager:show(dialog); dialog:onShowKeyboard()
end
function Page:filters(list, y, counts)
    local x = 28
    for _, entry in ipairs(list) do
        local id, label = entry[1], entry[2]
        if counts and counts[id] then label = label .. " " .. counts[id] end
        local active = self.state.filter == id
        local width = entry[3] or 86
        local text = self:text(label, x, y + 12, width, 12,
            { bold = active, color = active and ink or sub, align = "center" })
        if active then
            local underline_w = text:getSize().w / self.scale
            self:rect(x + (width - underline_w) / 2, y + 36, underline_w, 2, ink)
        end
        self:hit(x, y, width, 43, function()
            self.state.filter, self.state.page = id, 1; self:rebuild()
        end)
        x = x + width
    end
end
function Page:cover(book, x, y, w, h, allow_source_cover)
    if book.source_book and not allow_source_cover then
        self:rect(x, y, w, h, BB.gray(0.04))
        self:rect(x, y, w, h, rule, 0.7)
        local size = math.min(44, w * 0.55, h * 0.55)
        self:icon(Config.ICON.weread_book, x + (w - size) / 2, y + (h - size) / 2, size)
        return
    end
    local filepath = book.filepath or book.source_book and book.source_book.cached_file
    local cover = filepath and SH.getBookCover(filepath, self:px(w), self:px(h))
    if not cover and filepath and not book.private and not Config.isCoverMissing(filepath) then
        self._pending_cover_files = self._pending_cover_files or {}
        self._pending_cover_files[filepath] = true
    end
    if not cover and book.source_book then
        local id = tostring(book.source_book.book_id or book.source_book.bookId or ""):gsub("[^%w_.-]", "_")
        local path = require("datastorage"):getSettingsDir() .. "/weread_covers/" .. id .. ".jpg"
        if require("libs/libkoreader-lfs").attributes(path, "mode") == "file" then
            cover = ImageWidget:new{ file = path, width = self:px(w), height = self:px(h), scale_factor = 0 }
        elseif self.wr then
            self.wr:queuePaperCover(book.source_book, self)
        end
    end
    if cover then self.items[#self.items + 1] = { widget = cover, x = self:px(x), y = self:px(y) }
    else
        self:rect(x, y, w, h, BB.gray(0.04))
        self:rect(x, y, w, h, sub, 0.7)
        self:rect(x + 3, y, 0.7, h, rule)
        self:text(book.title, x + 12, y + 18, w - 24, math.min(22, w * 0.19),
            { font = "song", h = h - 48, background = BB.gray(0.04) })
        self:text(book.authors or "", x + 12, y + h - 21, w - 24, 8, { color = sub })
    end
end
function Page:bookStatus(book)
    return book.status == "done" and "读完" or book.percent > 0 and SH.pctStr(book.percent) or "未读"
end
function Page:readingProgress(book, x, y, w, h)
    local percent = book.status == "done" and 1 or tonumber(book.percent) or 0
    percent = math.max(0, math.min(1, percent))
    -- Keep a visible track at zero, and a solid fill thick enough for e-ink.
    self:rect(x, y, w, h or 5, rule)
    if percent > 0 then
        self:rect(x, y, math.max(1 / self.scale, w * percent), h or 5, ink)
    end
end
function Page:bookReadingInfo(book, x, y, w, opts)
    opts = opts or {}
    local size = opts.size or 10
    local status = opts.status or self:bookStatus(book)
    if opts.cached then status = "已缓存 · " .. status end
    local author = tostring(book.authors or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if author ~= "" then
        -- Reserve the complete reading status, then fit the author into what
        -- remains. A single text run keeps all metadata on one baseline.
        local suffix = TextWidget:new{ text = " · " .. status, face = self:face(nil, size), padding = 0 }
        local suffix_w = suffix:getSize().w
        suffix:free()
        local author_w = self:px(w) - suffix_w
        if author_w > self:px(size) then
            local fitted = TextWidget:new{ text = author, face = self:face(nil, size),
                max_width = author_w, truncate_with_ellipsis = true, padding = 0 }
            local text, ellipsis = fitted:getFittedText()
            author = text .. (ellipsis and "…" or "")
            fitted:free()
            status = author .. " · " .. status
        end
    end
    return self:text(status, x, y, w, size, { color = sub })
end
function Page:bookCell(book, x, y, w, cover_w, cover_h, compact)
    local cover_x = x + (w - cover_w) / 2
    self:cover(book, cover_x, y, cover_w, cover_h)
    if book.cached then
        local badge_x = cover_x + 3
        self:rect(badge_x, y + cover_h - 19, 39, 16, BB.COLOR_WHITE)
        self:text("已缓存", badge_x + 3, y + cover_h - 17, 33, 8)
    end
    local title_y = y + cover_h + 7
    local title_h = compact and 17 or 30
    self:text(book.title, cover_x, title_y, cover_w, 13,
        { font = "song", h = title_h, line_height = 0.15 })
    local info_y = title_y + title_h + 4
    local info = self:bookReadingInfo(book, cover_x, info_y, cover_w)
    local bar_y = info_y + info:getSize().h / self.scale + 5
    self:readingProgress(book, cover_x, bar_y, cover_w)
    self:hit(x, y, w, bar_y - y + 11, function() self:openBook(book) end,
        function() self:bookDetails(book) end)
end
function Page:bookRow(book, x, y, w, h)
    self:cover(book, x, y, 42, math.min(59, h - 8))
    local text_x, text_w = x + 58, w - 58
    self:text(book.title, text_x, y + 1, text_w, 15, { font = "song" })
    self:bookReadingInfo(book, text_x, y + 25, text_w, { cached = book.cached })
    self:readingProgress(book, text_x, y + 45, text_w)
    self:rect(x, y + h - 3, w, 0.7, rule)
    self:hit(x, y, w, h, function() self:openBook(book) end, function() self:bookDetails(book) end)
end
function Page:bookDetails(book)
    if self.wr then return self.wr:showBookRecord(book.source_book) end
    local dialog
    local privacy_button = Privacy.genPrivacyButton(book.filepath, function()
        UIManager:close(dialog); self:rebuild()
    end)
    dialog = require("ui/widget/buttondialog"):new{
        title = book.title .. "\n" .. book.authors .. "\n" .. self:bookStatus(book),
        buttons = {
            { { text = "开始阅读", callback = function() UIManager:close(dialog); self:openBook(book) end } },
            { { text = book.favorite and "取消收藏" or "加入收藏", callback = function()
                UIManager:close(dialog); Library.favorite(book); self:rebuild(true)
            end } },
            { { text = "阅读笔记", callback = function()
                UIManager:close(dialog); states.notes = { query = book.title, filter = "all", page = 1 }
                M.navigate(self.plugin, "notes")
            end } },
            { { text = "设置书籍分组", callback = function()
                UIManager:close(dialog)
                local function show() if not self._closed then M.showGroups(self, book) end end
                if Privacy.isPrivateBook(book.filepath) then Privacy.requirePassword(show) else show() end
            end } },
            { privacy_button },
            { { text = "删除书籍", callback = function()
                UIManager:close(dialog); self:deleteBook(book)
            end } },
            { { text = _("Close"), callback = function() UIManager:close(dialog) end } },
        },
    }
    UIManager:show(dialog)
end
function Page:deleteBook(book)
    local path = book.filepath
    if type(path) ~= "string" or require("libs/libkoreader-lfs").attributes(path, "mode") ~= "file" then
        toast("书籍文件不存在，请刷新书架。")
        return
    end
    local function confirm()
        if self._closed then return end
        local fm = require("apps/filemanager/filemanager").instance
        if not fm then return end
        fm:showDeleteFileDialog(path, function()
            Library.forgetFile(path)
            if not self._closed then self:rebuild(true) end
        end)
        if Privacy.isPrivateBook(path) then
            local stack = UIManager._window_stack
            local dialog = stack[#stack] and stack[#stack].widget
            if dialog and dialog.ok_callback then
                dialog._weui_private_book = path
                local delete = dialog.ok_callback
                dialog.ok_callback = function()
                    if self._closed then return end
                    local visible = false
                    for _, entry in ipairs(UIManager._window_stack) do
                        if entry.widget == dialog then visible = true; break end
                    end
                    -- Password success grants this visible confirmation even
                    -- when sessions are disabled. Relocking closes the dialog.
                    if not visible then
                        Privacy.requirePassword(function() self:deleteBook(book) end)
                        return
                    end
                    delete()
                end
            end
        end
    end
    if Privacy.isPrivateBook(path) then Privacy.requirePassword(confirm)
    else confirm() end
end
function Page:openBook(book)
    if self.wr then self.wr:showBookRecord(book.source_book); return end
    Privacy.openBook(book.filepath)
end
function Page:pager(total, per_page)
    self.pages = math.max(1, math.ceil(total / per_page))
    self.state.page = math.max(1, math.min(self.state.page, self.pages))
    local y = self.body_bottom - 40
    self:line(y, rule)
    self:text("‹", 174, y + 4, 48, 25, { align = "center", color = self.state.page > 1 and ink or rule })
    self:text(self.state.page .. " / " .. self.pages, 238, y + 14, 60, 11, { align = "center", color = sub })
    self:text("›", 314, y + 4, 48, 25, { align = "center", color = self.state.page < self.pages and ink or rule })
    self:hit(174, y, 48, 40, function() self:onPrevPage() end)
    self:hit(314, y, 48, 40, function() self:onNextPage() end)
end
function Page:empty(title, text, y, callback)
    self:text(title, 60, y, 416, 22, { font = "song", align = "center" })
    self:text(text, 60, y + 42, 416, 12, { h = 52, color = sub })
    if callback then self:button("查看全部", 213, y + 109, 110, callback) end
end
function Page:library()
    local books = self.books
    self:heading("书架", (Library.isScanning() and "正在整理书架 · " or "我的书籍 · ") .. #books .. " 本")
    self:iconButton(Config.ICON.group, 358, 48, function() M.showGroups(self) end, "书籍分组")
    self:iconButton(Config.ICON.weui_import, 412, 48, function() self:showSources() end, "添加书籍")
    self:iconButton(Config.ICON.weui_menu, 466, 48, function() self:libraryOptions() end)
    self:search(123, "搜索书名、作者或标签", function() self:askSearch() end)
    local counts = { all = #books, reading = 0, unread = 0, done = 0 }
    for _, book in ipairs(books) do counts[book.status] = counts[book.status] + 1 end
    self:filters({ { "all", "全部", 98 }, { "reading", "在读", 98 }, { "unread", "未读", 98 },
        { "done", "读完", 98 }, { "favorites", "收藏", 88 } }, 170, counts)
    local result = Library.filter(books, self.state.query, self.state.filter, self.state.sort)
    self:pager(#result, 6)
    if #result == 0 then
        self:empty(Library.isScanning() and "正在整理书架" or "这里还没有书",
            Library.isScanning() and "书籍会自动显示，可以先切换到其他页面。"
            or self.state.query ~= "" and "试试另一个书名或作者。" or "从右上方添加图标导入，或选择线上来源。", 307,
            function() self.state.query, self.state.filter = "", "all"; self:rebuild() end)
        return
    end
    local list = self.state.layout == "list"
    local row_h = (self.body_bottom - 40 - 221) / (list and 6 or 2)
    for i = 1, 6 do
        local book = result[(self.state.page - 1) * 6 + i]
        if book then
            if list then
                local y = 221 + (i - 1) * row_h
                self:bookRow(book, 28, y, 480, row_h)
            else
                local col, row = (i - 1) % 3, math.floor((i - 1) / 3)
                -- Two native title lines also include the font's descenders.
                self:bookCell(book, 28 + col * 168, 221 + row * row_h, 144, 90, math.min(126, row_h - 80))
            end
        end
    end
end
function Page:libraryOptions()
    local dialog
    local function change(key, value)
        UIManager:close(dialog); self.state[key], self.state.page = value, 1; self:rebuild()
    end
    dialog = require("ui/widget/buttondialog"):new{ title = "书架整理", buttons = {
        { { text = "书籍分组", callback = function() UIManager:close(dialog); M.showGroups(self) end } },
        { { text = self.state.layout == "list" and "封面视图" or "列表视图",
            callback = function() change("layout", self.state.layout == "list" and "grid" or "list") end } },
        { { text = "按最近阅读", callback = function() change("sort", "recent") end },
          { text = "按书名", callback = function() change("sort", "title") end } },
        { { text = "按阅读进度", callback = function() change("sort", "progress") end } },
        { { text = "刷新书架", callback = function() UIManager:close(dialog); self:rebuild(true) end },
          { text = "浏览文件夹", callback = function() UIManager:close(dialog); self:localImport() end } },
        { { text = _("Close"), callback = function() UIManager:close(dialog) end } },
    } }
    UIManager:show(dialog)
end
function Page:home()
    local weekdays = { "日", "一", "二", "三", "四", "五", "六" }
    self:heading("书房", string.format("%d月%d日，星期%s", tonumber(os.date("%m")), tonumber(os.date("%d")), weekdays[tonumber(os.date("%w")) + 1]))
    self:iconButton(Config.ICON.ko_search, 412, 48, function()
        M.navigate(self.plugin, "home"); M._instance:askSearch()
    end)
    self:iconButton(Config.ICON.weui_menu, 466, 48, function() M.navigate(self.plugin, "weui_settings") end)
    self:section("继续阅读", 121)
    local recent = {}
    for _, book in ipairs(self.books) do if book.last_read > 0 then recent[#recent + 1] = book end end
    local book = recent[1]
    if book then
        self:cover(book, 28, 150, 114, 160)
        local title = self:text(book.title, 164, 148, 344, 24,
            { font = "song", h = 60, height_adjust = true, line_height = 0.15 })
        local info_y = 148 + title:getSize().h / self.scale + 9
        local info = self:bookReadingInfo(book, 164, info_y, 344, { size = 12,
            status = book.status == "done" and "已读完" or "已读 " .. SH.pctStr(book.percent) })
        local bar_y = info_y + info:getSize().h / self.scale + 7
        self:readingProgress(book, 164, bar_y, 344, 6)
        self:text(book.chapter ~= "" and book.chapter or "从上次停下的地方继续", 164, bar_y + 20, 344, 11, { color = sub })
        self:text(book.last_page and ("上次读到第 " .. book.last_page .. " 页") or "进度已保存在本机", 164, bar_y + 42, 214, 10, { color = sub })
        self:button("继续阅读 →", 398, 280, 110, function() self:openBook(book) end, true)
        self:hit(28, 150, 114, 160, function() self:openBook(book) end)
        self:hit(164, 148, 344, 180, function() self:openBook(book) end)
    else
        self:empty("从一本书开始", "添加一本书，让书房成为安静的阅读角落。", 171)
        self:button("前往书架 →", 398, 275, 110, function() M.navigate(self.plugin, "home") end, true)
    end
    self:line(336, rule)
    local stats = Library.stats("week", nil, self.books)
    local done = Library.yearlyBooks(self.books)
    local goal = tonumber(Store:get("weui_reading_goal")) or 0
    local values = { duration(stats.seconds), stats.streak .. " 天", done .. (goal > 0 and (" / " .. goal) or "") .. " 本" }
    local captions = { "近7天阅读", "连续阅读", "年度阅读目标" }
    for i = 1, 3 do
        local x = 28 + (i - 1) * 164
        if i > 1 then self:rect(x - 12, 351, 0.7, 45, rule) end
        self:text(values[i], x, 350, 147, i == 1 and 19 or 23, { font = "number" })
        self:text(captions[i], x, 383, 147, 10, { color = sub })
        self:hit(x, 344, 147, 58, function()
            if i == 3 then self:goals() else M.navigate(self.plugin, "stats_calendar") end
        end)
    end
    self:line(409, rule)
    self:section("最近阅读", 427, "全部", function() self:action("history") end)
    for i = 1, 3 do
        local b = recent[i + 1]
        if b then
            local x = 28 + (i - 1) * 168
            self:bookCell(b, x, 455, 144, 74, 92, true)
        end
    end
    if #recent < 2 then self:text("开始阅读后，这里会显示最近的书籍。", 28, 489, 480, 12, { color = sub }) end
    local y = self.body_bottom - 40
    self:line(y, rule)
    local shortcuts = { { "收藏", "favorites" }, { "历史", "history" }, { "目标", "reading_goals" } }
    for i, item in ipairs(shortcuts) do
        self:text(item[1], 28 + (i - 1) * 160, y + 15, 160, 11, { align = "center" })
        self:hit(28 + (i - 1) * 160, y, 160, 40, function()
            if i == 3 then self:goals() else self:action(item[2]) end
        end)
    end
end
function Page:notes()
    local records = Library.notes(self.books, self.state.query, self.state.filter)
    self.records = records
    local bookset = {}
    for _, n in ipairs(records) do bookset[n.book.filepath] = true end
    local count = 0; for _ in pairs(bookset) do count = count + 1 end
    self:heading("笔记与划线", #records .. " 条记录 · 来自 " .. count .. " 本书")
    self:iconButton(Config.ICON.weui_export, 466, 48, function() self:export() end)
    self:search(123, "搜索书名、笔记或划线内容", function() self:askSearch() end)
    self:filters({ { "all", "全部", 82 }, { "note", "笔记", 82 }, { "highlight", "划线", 82 } }, 170)
    self:pager(#records, 3)
    if #records == 0 then
        self:empty("留下一点阅读痕迹", "在书中添加划线或笔记，记录会汇总在这里。", 297)
        return
    end
    for i = 1, 3 do
        local record = records[(self.state.page - 1) * 3 + i]
        if record then
            local y = 225 + (i - 1) * 129
            self:text(record.book.title, 28, y, 390, 11, { bold = true })
            self:text(record.kind == "note" and "笔记" or "划线", 449, y, 59, 11, { color = sub, align = "right" })
            self:text(record.text, 28, y + 28, 480, 14, { font = "song", h = 46, line_height = 0.65 })
            self:text(record.page and ("第 " .. record.page .. " 页") or record.chapter, 28, y + 87, 310, 10, { color = sub })
            self:text(record.date:sub(1, 10), 371, y + 87, 137, 10, { color = sub, align = "right" })
            self:line(y + 115, rule)
            self:hit(28, y - 5, 480, 120, function() self:noteDetails(record) end)
        end
    end
end
function Page:noteDetails(record)
    local private = Privacy.isPrivateBook(record.book.filepath)
    local function show()
        local text = record.book.title .. " · " .. (record.page and ("第 " .. record.page .. " 页") or record.chapter)
            .. " · " .. record.date .. "\n\n" .. record.quote
            .. (record.note and ("\n\n笔记\n" .. record.note) or "")
        UIManager:show(require("ui/widget/textviewer"):new{
            title = record.kind == "note" and "阅读笔记" or "阅读划线",
            text = text, _weui_private_book = private and record.book.filepath or nil,
            text_face = self:face("song", 17), width = math.floor(Screen:getWidth() * 0.9),
            height = math.floor(Screen:getHeight() * 0.8),
        })
    end
    if private and not Privacy.isUnlocked() then Privacy.requestAccess(record.book.filepath, show)
    else show() end
end
function Page:export()
    if not self.records or #self.records == 0 then toast("当前没有可导出的笔记。"); return end
    local base = require("datastorage"):getSettingsDir() .. "/weui"
    local path = base .. "/阅读笔记-" .. os.date("%Y%m%d-%H%M%S") .. ".txt"
    local i = 1
    while require("libs/libkoreader-lfs").attributes(path) do
        path = base .. "/阅读笔记-" .. os.date("%Y%m%d-%H%M%S") .. "-" .. i .. ".txt"; i = i + 1
    end
    local ok, err = Library.exportNotes(self.records, path)
    toast(ok and ("已导出 " .. #self.records .. " 条记录\n" .. path) or ("导出失败：" .. tostring(err)))
end
function Page:stats()
    local period = self.state.period
    local data = Library.stats(period, nil, self.books)
    self:heading("阅读统计", data.start .. " — " .. data.finish)
    self:iconButton(Config.ICON.weui_menu, 466, 48, function() self:statsOptions() end)
    local periods = { { "week", "近7天" }, { "month", "月" }, { "year", "年" }, { "all", "全部" } }
    for i, item in ipairs(periods) do
        local x = 28 + (i - 1) * 120
        self:text(item[2], x, 124, 120, 12, { align = "center", bold = period == item[1], color = period == item[1] and ink or sub })
        if period == item[1] then self:rect(x + 16, 149, 88, 2, ink) end
        self:hit(x, 113, 120, 43, function() self.state.period = item[1]; self:rebuild() end)
    end
    local captions = { week = "近7天阅读时长", month = "本月阅读时长", year = "今年阅读时长", all = "累计阅读时长" }
    self:text(captions[period], 28, 170, 300, 11, { color = sub })
    local minutes = math.floor(data.seconds / 60)
    local hours, mins = math.floor(minutes / 60), minutes % 60
    local number = self:text(hours, 28, 193, 230, 47, { font = "number" })
    local nx = 28 + number:getSize().w / self.scale + 7
    self:text("小时", nx, 229, 34, 11, { color = sub })
    nx = nx + 38
    number = self:text(mins, nx, 193, 230, 47, { font = "number" })
    nx = nx + number:getSize().w / self.scale + 7
    self:text("分", nx, 229, 25, 11, { color = sub })
    local growth = data.previous > 0 and string.format("%+.0f%% 较上期", (data.seconds / data.previous - 1) * 100) or "记录每一点阅读时光"
    self:text(period == "all" and (data.days .. " 天有阅读") or growth, 339, 205, 169, 11, { color = sub, align = "right" })
    self:text("日均 " .. math.floor((data.average or 0) / 60) .. " 分钟", 339, 228, 169, 11, { color = sub, align = "right" })
    self:line(261, rule)
    self:text(period == "week" and "每日阅读" or period == "month" and "每周阅读" or period == "year" and "每月阅读" or "每年阅读",
        28, 277, 240, 11, { bold = true })
    self:text("分钟", 438, 277, 70, 10, { align = "right", color = sub })
    local max = 1
    for _, bar in ipairs(data.bars) do max = math.max(max, bar.seconds) end
    local n = #data.bars
    for i, bar in ipairs(data.bars) do
        local w = 464 / math.max(1, n)
        local x = 36 + (i - 1) * w
        local h = math.max(1, math.floor(bar.seconds / max * 82))
        local last = period == "year" and i == tonumber(os.date("%m")) or period ~= "year" and i == n
        self:text(math.floor(bar.seconds / 60), x, 398 - h - 21, w, n > 9 and 8 or 9, { align = "center", color = last and ink or sub })
        self:rect(x + (w - math.min(22, w * 0.5)) / 2, 398 - h, math.min(22, w * 0.5), h, last and ink or rule)
        self:text(bar.label, x, 409, w, n > 9 and 9 or 10, { align = "center", color = sub })
    end
    self:line(398, rule)
    self:line(439, rule)
    self:text(data.streak, 28, 455, 55, 30, { font = "number" })
    self:text("天连续阅读", 85, 476, 80, 10)
    self:text("最长纪录 " .. data.best .. " 天", 28, 498, 145, 9, { color = sub })
    for i = 1, 28 do
        local date = Library.day(data.finish, i - 28)
        self.items[#self.items + 1] = { circle = true, x = self:px(193 + ((i - 1) % 14) * 23),
            y = self:px(467 + math.floor((i - 1) / 14) * 18), radius = self:px(4),
            color = data.daily[date] and ink or rule }
    end
    self:text("近28天 · 黑点为有阅读的日子", 183, 501, 325, 9, { color = sub, align = "right" })
    self:line(524, rule)
    self:section(period == "week" and "最近读过" or "阅读书目", 543, "查看全部", function() self:rankings(data.ranking) end)
    for i = 1, 2 do
        local record = data.ranking[i]
        if record then
            local y = 574 + (i - 1) * 37
            self:text(string.format("%02d", i), 28, y + 7, 25, 13, { font = "number", color = sub })
            self:text(record.title, 61, y + 9, 300, 12)
            self:text(duration(record.seconds), 369, y + 10, 139, 10, { align = "right", color = sub })
            self:line(y + 36, rule)
            self:hit(28, y, 480, 37, function() if record.book then self:bookDetails(record.book) else self:rankings(data.ranking) end end)
        end
    end
    if not data.available then self:text("开始阅读后，这里会显示统计记录。", 28, 587, 480, 12, { color = sub }) end
end
function Page:rankings(records)
    if #records == 0 then toast("这个周期还没有阅读记录。"); return end
    return M.showSheet("rankings", self, records)
end
function Page:statsOptions()
    local dialog
    dialog = require("ui/widget/buttondialog"):new{ title = "阅读统计", buttons = {
        { { text = "阅读目标", callback = function() UIManager:close(dialog); self:goals() end } },
        { { text = "日历与详细统计", callback = function()
            UIManager:close(dialog); self.screen = "stats_details"; self:rebuild()
        end } },
        { { text = _("Close"), callback = function() UIManager:close(dialog) end } },
    } }
    UIManager:show(dialog)
end
function Page:row(icon, label, meta, y, callback, h)
    h = h or 49
    self:icon(icon, 28, y + 14, 20)
    self:text(label, 64, y + 15, 273, 12)
    self:text(meta or "", 329, y + 16, 155, 10, { color = sub, align = "right" })
    self:text("›", 491, y + 11, 17, 18, { color = sub })
    self:line(y + h, rule)
    self:hit(28, y, 480, h, callback)
end
function Page:more()
    self:heading("更多", "你的阅读工具箱")
    self:rect(28, 125, 480, 61, BB.gray(0.05))
    self:text("书", 42, 137, 35, 26, { font = "song" })
    self:text(Device.model or "KOReader", 95, 139, 374, 13, { bold = true })
    self:text("我的书架 · 纸页阅读界面", 95, 163, 374, 10, { color = sub })
    self:hit(28, 125, 480, 61, function() self:deviceInfo() end)
    self:text("阅读工具", 28, 207, 480, 10, { color = sub })
    self:row(Config.ICON.weui_sources, "书籍来源", "本地 / 微信读书 / Z-Library", 227, function() self:showSources() end, 42)
    self:row(Config.ICON.weread_download, "下载管理", "本机书籍与下载任务", 269, function() self:downloads() end, 42)
    self:row(Config.ICON.weui_goal, "阅读目标", "年度 / 每月 / 每天", 311, function() self:goals() end, 42)
    self:row(Config.ICON.collections, "收藏与书籍分组", "", 353, function() self:action("collections") end, 42)
    self:row(Config.ICON.history, "阅读历史", "", 395, function() self:action("history") end, 42)
    self:row(Config.ICON.weui_layout, "外观与排版", "纸页", 437, function()
        require("weui_settings_window"):show(function() self:rebuild(true) end)
    end, 42)
    self:row(Config.ICON.weui_privacy, "隐私与密码", Privacy.isUnlocked() and "已解锁" or "已锁定",
        479, function() self:privacySettings() end, 42)
    self:row(Config.ICON.weui_proxy, "Z-Library 账号与代理", require("weui_zlibrary_proxy").getStatusText(),
        521, function() self:showTool("proxy_settings") end, 42)
    self:row(Config.ICON.weui_lockscreen, "自定义锁屏", require("weui_lockscreen").getLabel(),
        563, function() self:showTool("lockscreen_settings") end, 42)
    self:row(Config.ICON.weui_update, "系统更新", "KOReader / WeUI",
        605, function() self:showTool("system_updates") end, 42)
end
function Page:privacySettings()
    local native = {}
    self.plugin:addToMainMenu(native)
    for index, item in ipairs(native.weui and native.weui.sub_item_table or {}) do
        if item.text == _("Privacy") and item.sub_item_table_func then
            local win = require("weui_settings_window"):show(function() self:rebuild(true) end)
            win:_navPush("nested_menu", { title = _("Privacy"), items_func = item.sub_item_table_func })
            return win
        end
    end
end
function Page:showSources()
    self.origin, self.screen = self.tab, "sources"
    self:rebuild()
end
function Page:sources()
    self:text("‹ 返回" .. (labels[self.origin] or "书架"), 28, 44, 300, 11, { color = sub })
    self:hit(28, 30, 170, 42, function() self.screen = self.tab; self:rebuild() end)
    self:text("添加书籍", 408, 44, 100, 9, { align = "right", color = sub })
    self:text("书籍来源", 28, 92, 480, 33, { font = "song" })
    self:text("为书架添一本新书", 28, 140, 480, 11, { color = sub })
    self:text("从本机导入，或从线上来源获取。\n添加后，回到书架开始阅读。", 28, 187, 480, 17, { font = "song", h = 70, line_height = 0.75 })
    self:text("本机", 28, 281, 480, 10, { color = sub })
    self:sourceRow(Config.ICON.weui_import, "本地导入", "EPUB、PDF 及其他支持的格式", "选择文件", 309, function() self:localImport() end)
    self:text("线上来源", 28, 405, 480, 10, { color = sub })
    local wr = self.plugin._weread_plugin or self.plugin:_initWeReadModule()
    local account = wr and wr.settings and wr.settings:get("account") or {}
    local connected = account.name and account.name ~= ""
    self:sourceRow(Config.ICON.weread, "微信读书", "获取线上书架中的书籍", connected and "已连接" or "连接账号", 431, function()
        if wr then wr:showShelfGrid(1, "books") else toast("微信读书模块尚未就绪。") end
    end)
    self:sourceRow(Config.ICON.zlibrary, "Z-Library", "搜索书籍，下载到本机", "搜索书籍", 513, function() self:action("zlibrary", true) end)
    self:text("已添加的书籍统一保存在书架。\n阅读进度、笔记与统计会随书籍一起记录。", 28, 612, 480, 11, { color = sub, h = 36 })
end
function Page:sourceRow(icon, title, desc, meta, y, callback)
    self:icon(icon, 28, y + 16, 25)
    self:text(title, 75, y + 12, 300, 17, { font = "song" })
    self:text(desc, 75, y + 42, 350, 11, { color = sub })
    self:text(meta .. " ›", 416, y + 28, 92, 10, { color = sub, align = "right" })
    self:line(y + 77, rule)
    self:hit(28, y, 480, 77, callback)
end
function Page:localImport()
    return M.showFilePicker(self, "import", G_reader_settings:readSetting("home_dir") or Device.home_dir)
end
function Page:goalInput(title, key, factor)
    local dialog
    dialog = require("ui/widget/inputdialog"):new{ title = title,
        input = tostring((tonumber(Store:get(key)) or 0) / factor), input_type = "number",
        buttons = { {
            { text = _("Cancel"), callback = function() UIManager:close(dialog) end },
            { text = _("Save"), is_enter_default = true, callback = function()
                local value = tonumber(dialog:getInputText())
                if not value or value < 0 or value > 9999 or value ~= math.floor(value) then toast("请输入 0 到 9999 的整数。"); return end
                Store:set(key, value * factor); UIManager:close(dialog); self:rebuild()
            end },
        } },
    }
    UIManager:show(dialog); dialog:onShowKeyboard()
end
function Page:goals()
    return M.showSheet("reading_goals", self)
end
function Page:downloads()
    self:showTool("downloads")
end
function Page:deviceInfo()
    local version = require("version")
    local name = version.getCurrentRevision and version:getCurrentRevision() or tostring(version)
    toast(string.format("%s\nKOReader %s\n%d × %d\nWe UI · 纸页", Device.model or "阅读设备", name, Screen:getWidth(), Screen:getHeight()))
end
function Page:action(id, in_place)
    if M.isSheet(id) then return M.showSheet(id, self) end
    if in_place then require("weui_quickactions").execute(id, { plugin = self.plugin, fm = self.plugin.ui })
    else
        require("weui_bottombar").navigate(self.plugin, id, self, Config.loadTabConfig(), false)
    end
end
function Page:weread()
    self:text("‹ 返回书籍来源", 28, 42, 220, 11, { color = sub })
    self:hit(28, 30, 200, 42, function() self:onClose() end)
    self:text("微信读书", 28, 83, 320, 31, { font = "song" })
    self:iconButton(Config.ICON.weui_menu, 466, 78, function() self.wr:showMainMenu() end)
    local account = self.wr.settings:get("account") or {}
    self:text(account.name and account.name ~= "" and account.name or "尚未连接账号", 28, 129, 340, 11, { color = sub })
    self:iconButton(Config.ICON.zlibrary_refresh, 466, 122, function()
        self.wr:safeCallback("获取书架", function() self.wr:showBookshelf() end)()
    end, "获取最新书架")
    self:search(177, "搜索线上书架中的书名或作者", function() self:askSearch() end)
    self:filters({ { "all", "书籍", 100 }, { "mp", "公众号", 110 } }, 224)
    self:iconButton(Config.ICON.weread_filter, 238, 224, function() self.wr:showShelfOptions() end, "筛选书架")
    self:lineSortWeRead()
    local source = self.wr:getPaperShelfBooks(self.state.filter)
    local books = {}
    local saved_books, downloaded_cache = self.wr.settings:get("books", {}), {}
    for _, b in ipairs(source or {}) do
        local title, authors = b.title or "", b.author or ""
        if self.state.query == "" or (title .. " " .. authors):lower():find(self.state.query:lower(), 1, true) then
            books[#books + 1] = { title = title, authors = authors, source_book = b, percent = math.min(1, math.max(0, (tonumber(b.progress) or 0) / 100)),
                status = b.finishReading == 1 and "done" or "unread",
                cached = self.wr:isBookDownloaded(b, saved_books, downloaded_cache) }
        end
    end
    local list_mode = self.wr.settings:get("shelf").view_mode == "list"
    local perpage = list_mode and math.max(1, math.floor((self.body_bottom - 319) / 64)) or 6
    local first
    if list_mode and self.wr.settings:get("shelf").paginated == false then
        -- Virtual rows keep memory and refresh work bounded on e-ink devices.
        -- Vertical swipes advance one row; page keys advance one viewport.
        self.weread_scroll = { total = #books, count = perpage }
        local prefs = self.wr.settings:get("shelf")
        local context = table.concat({ self.state.query, self.state.filter,
            tostring(self.wr.shelf_group_key), tostring(prefs.sort_order),
            tostring(prefs.filter_reading), tostring(prefs.filter_download) }, ":")
        if self._scroll_context ~= context then self.state.scroll_index = 1; self._scroll_context = context end
        self.state.scroll_index = math.max(1, math.min(self.state.scroll_index or 1,
            math.max(1, #books - perpage + 1)))
        first = self.state.scroll_index
        self.pages = 1
        local y = self.body_bottom - 40
        self:line(y, rule)
        self:text(string.format("%d–%d / %d · 上下滑动", #books > 0 and first or 0,
            math.min(#books, first + perpage - 1), #books), 128, y + 14, 280, 11,
            { align = "center", color = sub })
    else
        self.weread_scroll = nil
        self:pager(#books, perpage)
        first = (self.state.page - 1) * perpage + 1
    end
    if #books == 0 then
        self:empty(self.state.query ~= "" and "没有匹配的书籍" or "线上书架还没有书",
            self.state.query ~= "" and "修改书名或作者，再试一次。" or "点击右上方刷新图标，连接账号并同步书架。", 357)
        return
    end
    local row_h = (self.body_bottom - 40 - 279) / 2
    if list_mode then
        for i = 1, perpage do
            local b = books[first + i - 1]
            if b then
                local y = 279 + (i - 1) * 64
                self:bookRow(b, 28, y, 480, 64)
            end
        end
        return
    end
    for i = 1, 6 do
        local b = books[(self.state.page - 1) * 6 + i]
        if b then
            self:bookCell(b, 28 + ((i - 1) % 3) * 168, 279 + math.floor((i - 1) / 3) * row_h,
                144, 80, math.min(112, row_h - 62), true)
        end
    end
end
function Page:lineSortWeRead()
    local labels = { time_desc = "最近阅读", time_asc = "最早阅读", name_asc = "书名升序", name_desc = "书名降序", default = "默认顺序" }
    self:iconButton(Config.ICON.weread_sort, 412, 224, function()
        local entries = {}
        for _, id in ipairs({ "time_desc", "time_asc", "name_asc", "name_desc", "default" }) do
            entries[#entries + 1] = { text = labels[id], callback = function()
                local settings = self.wr.settings:get("shelf")
                settings.sort_order = id; self.wr.settings:set("shelf", settings); self.wr.settings:flush()
                M._instance:dismiss(); self.state.page = 1; self:rebuild()
            end }
        end
        M.showWeReadView(self.wr, { kind = "list", title = "书架排序", items = entries })
    end, labels[self.wr.settings:get("shelf").sort_order] or "最近阅读")
end
function Page:navbar()
    local tabs = self.navbar_tabs or Config.loadTabConfig()
    local y = self.logical_h - 66
    self:rect(24, y, 488, 0.7, ink)
    local w = 488 / #tabs
    for i, id in ipairs(tabs) do
        local action = Config.getActionById(id)
        local x = 24 + (i - 1) * w
        if id == self.tab then self:rect(x + (w - 30) / 2, y - 1, 30, 3, ink) end
        self:icon(action.icon, x + (w - 21) / 2, y + 13, 21)
        self:text(action.label, x, y + 42, w, 11, { align = "center", color = id == self.tab and ink or sub, bold = id == self.tab })
        self:hit(x, y, w, 66, function()
            if M.isMain(id) then M.navigate(self.plugin, id) else self:action(id) end
        end)
    end
end

function M.navbarHeight()
    return math.floor(66 * math.min(Screen:getWidth() / 536, Screen:getHeight() / 724) + 0.5)
end

local Navbar = Page:extend{ name = "weui_paper_navbar", _weui_paper_navbar = true }
function Navbar:init()
    self.scale = math.min(Screen:getWidth() / 536, Screen:getHeight() / 724)
    self.logical_h = 66
    self.offset = math.floor((Screen:getWidth() - self:px(536)) / 2)
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = M.navbarHeight() }
    self.items, self.hits = {}, {}
    self:navbar()
end
-- The host's navbar touch zones own navigation on embedded pages.
function Navbar:hit() end
function Navbar:free() self:freeItems() end

function M.newNavbar(action, tabs, origin)
    tabs = tabs or Config.loadTabConfig()
    if not Config.tabInTabs(action, tabs) then action = origin or M.originTab() or "home" end
    return Navbar:new{ tab = action, navbar_tabs = tabs }
end

function Page:rebuild(force)
    self:freeItems()
    if self.screen ~= "downloads" and self._download_timer then
        UIManager:unschedule(self._download_timer); self._download_timer = nil
    end
    self.scale = math.min(Screen:getWidth() / 536, Screen:getHeight() / 724)
    self.logical_h = Screen:getHeight() / self.scale
    self.offset = math.floor((Screen:getWidth() - self:px(536)) / 2)
    self.body_bottom = self.logical_h - 76
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    self.items, self.hits = {}, {}
    self._pending_cover_files = {}
    local needs_books = self.screen == "homescreen" or self.screen == "home" or self.screen == "notes"
        or self.screen == "stats_calendar" or self.screen == "stats_details"
    if force and not needs_books then Library.invalidate() end
    self.books = self.wr and {} or needs_books and Library.books(self.plugin, force, true) or Library.snapshot()
    self:text(os.date("%H:%M"), 28, 10, 150, 11)
    self._clock_item = self.items[#self.items]
    local power = Device:getPowerDevice()
    local capacity = power and power.getCapacity and power:getCapacity()
    self:text(capacity and (capacity .. "%") or "KOReader", 358, 10, 150, 11, { align = "right", color = sub })
    self._battery_item = self.items[#self.items]
    local builders = { homescreen = self.home, home = self.library, notes = self.notes, stats_calendar = self.stats,
        weui_settings = self.more, sources = self.sources, weread = self.weread,
        proxy_settings = self.proxySettings, lockscreen_settings = self.lockscreenSettings,
        system_updates = self.systemUpdates, stats_details = self.statsDetails,
        downloads = self.downloadManager }
    builders[self.screen](self)
    self:navbar()
    Refresh.update(self)
    self:scheduleCoverRefresh()
end

function Page:refreshStatusBar()
    if self._closed or not self._clock_item or not Refresh.awake(self.plugin) or not Refresh.visible(self) then return end
    local clock, battery = self._clock_item.widget, self._battery_item.widget
    local power = Device:getPowerDevice()
    local capacity = power and power.getCapacity and power:getCapacity()
    local time, charge = os.date("%H:%M"), capacity and (capacity .. "%") or "KOReader"
    if clock.text == time and battery.text == charge then return end
    clock:setText(time)
    battery:setText(charge)
    self._battery_item.x = self:px(508) - battery:getSize().w
    Refresh.update(self)
end

function Page:scheduleCoverRefresh()
    if self._cover_poll_timer then UIManager:unschedule(self._cover_poll_timer); self._cover_poll_timer = nil end
    if not next(self._pending_cover_files or {}) then self._cover_poll_started = nil; return end
    self._cover_poll_started = self._cover_poll_started or os.time()
    if Config.flushCoverQueue() == false then return end
    if os.time() - self._cover_poll_started > 45 then return end
    local function poll()
        self._cover_poll_timer = nil
        if self._closed or M._instance ~= self then return end
        local bim = Config.getBookInfoManager()
        local running = bim and bim:isExtractingInBackground()
        if not running then
            for path in pairs(self._pending_cover_files or {}) do Config._cover_extract_pending[path] = nil end
        end
        if running then
            if os.time() - self._cover_poll_started <= 45 then
                self._cover_poll_timer = poll
                UIManager:scheduleIn(1, poll)
            end
        else
            self:rebuild()
        end
    end
    self._cover_poll_timer = poll
    UIManager:scheduleIn(1, self._cover_poll_timer)
end
function Page:getSize() return self.dimen end
function Page:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    bb:paintRect(x, y, self.dimen.w, self.dimen.h, BB.COLOR_WHITE)
    self:paintItems(bb, x + self.offset, y)
    Refresh.painted(self)
end
function Page:paintItems(bb, x, y)
    for _, item in ipairs(self.items) do
        if item.widget then item.widget:paintTo(bb, x + item.x, y + item.y)
        elseif item.circle then bb:paintCircle(x + item.x, y + item.y, item.radius, item.color)
        elseif item.border then bb:paintBorder(x + item.x, y + item.y, item.w, item.h, item.border, item.color)
        else bb:paintRect(x + item.x, y + item.y, item.w, math.max(1, item.h), item.color) end
    end
end
function Page:onTapPaper(_, ges)
    local x, y = ges.pos.x - self.dimen.x - self.offset, ges.pos.y - self.dimen.y
    for _, hit in ipairs(self.hits) do
        if x >= hit.x and x < hit.x + hit.w and y >= hit.y and y < hit.y + hit.h then
            if hit.callback then hit.callback() end
            return true
        end
    end
    return true
end
function Page:onHoldPaper(_, ges)
    local x, y = ges.pos.x - self.dimen.x - self.offset, ges.pos.y - self.dimen.y
    for _, hit in ipairs(self.hits) do
        if hit.hold and x >= hit.x and x < hit.x + hit.w and y >= hit.y and y < hit.y + hit.h then
            hit.hold(); return true
        end
    end
    return true
end
function Page:onSwipePaper(_, ges)
    if self.weread_scroll then
        if ges.direction == "north" then return self:scrollWeRead(1)
        elseif ges.direction == "south" then return self:scrollWeRead(-1) end
    end
    if ges.direction == "west" then return self:onNextPage()
    elseif ges.direction == "east" then return self:onPrevPage() end
    return true
end
function Page:onPan(_, ges)
    local delta = ges and ges.mousewheel_direction
    if not delta or delta == 0 then return end
    local time = require("ui/time")
    local now = time.now()
    local direction = delta < 0 and 1 or -1
    if self._wheel_direction == direction and self._wheel_time
            and now - self._wheel_time < time.ms(180) then return true end
    self._wheel_direction, self._wheel_time = direction, now
    if direction > 0 then return self:onNextPage() end
    return self:onPrevPage()
end
function Page:scrollWeRead(delta)
    local scroll = self.weread_scroll
    if not scroll then return true end
    self.state.scroll_index = math.max(1, math.min((self.state.scroll_index or 1) + delta,
        math.max(1, scroll.total - scroll.count + 1)))
    self:rebuild()
    return true
end
function Page:onNextPage()
    if self.screen == "downloads" then return self:downloadNextPage(1) end
    if self.weread_scroll then return self:scrollWeRead(self.weread_scroll.count) end
    if self.pages and self.state.page < self.pages then self.state.page = self.state.page + 1; self:rebuild() end
    return true
end
function Page:onPrevPage()
    if self.screen == "downloads" then return self:downloadNextPage(-1) end
    if self.weread_scroll then return self:scrollWeRead(-self.weread_scroll.count) end
    if self.pages and self.state.page > 1 then self.state.page = self.state.page - 1; self:rebuild() end
    return true
end
function Page:onSetRotationMode(mode)
    Screen:setRotationMode(mode); self:rebuild(); return true
end
function Page:onScreenResize() self:rebuild(); return true end
function Page:onSuspend()
    if self._download_timer then UIManager:unschedule(self._download_timer); self._download_timer = nil end
    if self._task_refresh_timer then UIManager:unschedule(self._task_refresh_timer); self._task_refresh_timer = nil end
end
function Page:onResume() self:rebuild(true) end
function Page:onRoom() M.navigate(self.plugin, "homescreen"); return true end
function Page:onShelf() M.navigate(self.plugin, "home"); return true end
function Page:onNotes() M.navigate(self.plugin, "notes"); return true end
function Page:onStats() M.navigate(self.plugin, "stats_calendar"); return true end
function Page:onMore() M.navigate(self.plugin, "weui_settings"); return true end
function Page:onClose()
    if self.screen == "proxy_settings" or self.screen == "lockscreen_settings" or self.screen == "system_updates"
            or self.screen == "downloads" then
        self:toolBack(); return true
    end
    if self.screen == "sources" or self.screen == "stats_details" then self.screen = self.tab; self:rebuild(); return true end
    self._navbar_closing_intentionally = true
    UIManager:close(self)
    if self.origin_page then
        M._instance = self.origin_page
        self.plugin.active_action = self.origin_page.tab
        self.origin_page:rebuild(true)
    end
    return true
end
function Page:freeItems()
    for _, item in ipairs(self.items or {}) do if item.widget then item.widget:free() end end
    self.items = {}
end
function Page:onCloseWidget()
    self._closed = true
    if self._cover_poll_timer then UIManager:unschedule(self._cover_poll_timer); self._cover_poll_timer = nil end
    if self._download_timer then UIManager:unschedule(self._download_timer); self._download_timer = nil end
    if self._task_refresh_timer then UIManager:unschedule(self._task_refresh_timer); self._task_refresh_timer = nil end
    self:freeItems()
    self._painted_layout, self._refresh_layout = nil, nil
    self._clock_item, self._battery_item = nil, nil
    if M._instance == self then M._instance = nil end
    local HS = package.loaded["weui_homescreen"]
    if HS and HS._instance == self then HS._instance = nil end
end
-- Homescreen lifecycle consumers use these names.
function Page:_refresh(keep_cache) self:rebuild(not keep_cache) end
function Page:_refreshImmediate(keep_cache) self:rebuild(not keep_cache) end

require("weui_paper_tools").apply(Page)
require("weui_paper_stats").apply(Page)
require("weui_paper_downloads").apply(Page, M)

function M.newLockscreen(mode, plugin, timestamp)
    local Snapshot = require("weui_paper_lockscreen").extend(Page)
    return Snapshot:new{ mode = mode, plugin = owner(plugin), timestamp = timestamp }
end

function M.showSheet(id, origin, rank_records, target_book)
    id = sheet_ids[id]
    origin = origin or M._instance
    if not id or not origin or origin._closed or origin.wr then return end
    if origin._weui_paper_sheet then
        if origin.screen == id then return origin end
        local previous = origin.origin_page
        origin:dismiss()
        origin = previous
    end
    if not origin or origin._closed then return end
    local visible = false
    for _, entry in ipairs(UIManager._window_stack) do
        if entry.widget == origin then visible = true; break end
    end
    if not visible then return end
    Sheet = Sheet or require("weui_paper_sheets").extend(Page, M)
    local class = Sheet
    if id == "groups" then
        GroupSheet = GroupSheet or require("weui_paper_groups").extend(Sheet)
        class = GroupSheet
    end
    local window = class:new{ screen = id, plugin = origin.plugin, tab = origin.tab, origin_page = origin,
        rank_records = rank_records, target_book = target_book }
    M._instance = window
    UIManager:show(window, "ui")
    return window
end

function M.showGroups(origin, book)
    return M.showSheet("groups", origin, nil, book)
end

function M.showFilePicker(origin, mode, path)
    if not origin or origin._closed then return end
    FilePicker = FilePicker or require("weui_paper_files").extend(Page, M)
    local window = FilePicker:new{
        screen = "files", plugin = origin.plugin, tab = origin.tab, origin_page = origin,
        mode = mode, path = path,
    }
    M._instance = window
    UIManager:show(window, "ui")
    return window
end

local function values(source)
    local out = {}
    for key, value in pairs(source or {}) do
        if type(value) == "string" or type(value) == "number" or type(value) == "boolean" then out[key] = value end
    end
    return out
end

-- FM is destroyed before a ReaderUI is constructed. Retain values only:
-- closed pages and their old plugin callbacks must never be reused on return.
function M.suspendForReader()
    local current = M._instance
    if not current or current._closed then return end
    local stack, visible = UIManager._window_stack, false
    for _, entry in ipairs(stack) do if entry.widget == current then visible = true; break end end
    if not visible then return end
    local chain, page = {}, current
    while page and not page._closed do
        if not page._weui_weread_sheet then
            table.insert(chain, 1, {
                screen = page.screen, tab = page.tab, state = values(page.state), origin = page.origin,
                kind = page._weui_paper_files and "files" or page._weui_paper_sheet and "sheet" or "page",
                group = page.group and values(page.group), path = page.path, mode = page.mode,
            })
            if page.path_history then
                local history = {}
                for _, entry in ipairs(page.path_history) do history[#history + 1] = values(entry) end
                chain[1].path_history = history
            end
        end
        page = page.origin_page
    end
    if #chain == 0 or not M.isMain(chain[1].tab) then return end
    M._reader_origin = chain
    local close = {}
    for i = #stack, 1, -1 do
        local widget = stack[i].widget
        if widget and (widget == current or widget._weui_full_page_group == "paper"
                or widget._weui_full_page_group == "weread" or widget._weui_paper_sheet) then
            close[#close + 1] = widget
        end
    end
    for _, widget in ipairs(close) do
        widget._navbar_closing_intentionally = true
        UIManager:close(widget)
    end
end

function M.restoreAfterReader(plugin)
    local chain = M._reader_origin
    if not chain then return end
    M._reader_origin = nil
    plugin = owner(plugin)
    if not plugin or not plugin.ui or not plugin.ui.file_chooser then return end
    local page = M.navigate(plugin, chain[1].tab)
    for i, saved in ipairs(chain) do
        if i > 1 then
            if saved.kind == "sheet" then page = M.showSheet(saved.screen, page)
            elseif saved.kind == "files" then page = M.showFilePicker(page, saved.mode, saved.path)
            end
        end
        if saved.screen == "weread" then
            local wr = plugin._weread_plugin or plugin:_initWeReadModule()
            if wr then page = M.showWeRead(wr) end
        end
        if not page then break end
        if saved.kind == "page" and saved.screen ~= "weread" then page.screen = saved.screen end
        for key, value in pairs(saved.state) do page.state[key] = value end
        page.origin, page.group = saved.origin, saved.group
        if saved.path_history then page.path_history = saved.path_history end
        page:rebuild(true)
    end
    return page
end

function M.clearReaderOrigin() M._reader_origin = nil end

function M.navigate(plugin, id)
    plugin = owner(plugin)
    local fm = plugin and plugin.ui
    if not plugin or not fm then return end
    local stack = require("weui_core").getWindowStack()
    local close = {}
    for i = #stack, 1, -1 do
        local w = stack[i].widget
        if w == fm then break end
        -- All overlays above the FM belong to the page being left.
        if w and not w._weui_paper_return_blocker then close[#close + 1] = w end
    end
    for _, w in ipairs(close) do
        w._navbar_closing_intentionally = true
        local cb = w.close_callback; w.close_callback = nil
        UIManager:close(w); w.close_callback = cb
    end
    plugin.active_action = id
    local page = Page:new{ screen = id, plugin = plugin, tab = id }
    M._instance = page
    if id == "homescreen" then require("weui_homescreen")._instance = page end
    UIManager:show(page)
    return page
end
function M.showWeRead(wr, page, tab)
    local origin = M._instance
    if origin and origin._weui_weread_sheet then
        local previous = origin.origin_page
        origin:dismiss()
        origin = previous
    end
    if origin and not origin._closed and origin.screen == "weread" then
        origin.state.page = page or 1
        origin.state.filter = tab == "mp" and "mp" or "all"
        origin:rebuild()
        return origin
    end
    local plugin = owner(wr)
    local previous = origin and origin.tab or plugin.active_action or "home"
    if previous == "weread" or previous == "zlibrary" then previous = "home" end
    local window = Page:new{ screen = "weread", plugin = plugin, wr = wr, tab = previous,
        origin_page = origin, _navbar_prev_action = previous }
    window.state.page = page or 1
    window.state.filter = tab == "mp" and "mp" or "all"
    window:rebuild()
    M._instance = window
    UIManager:show(window)
    return window
end

function M.weReadOrigin(wr)
    local origin = M._instance
    if not origin or origin._closed then return end
    if origin._weui_weread_sheet then return origin.wr == wr and origin or nil end
    if origin._weui_paper_sheet then return end
    return origin
end

function M.showWeReadView(wr, view)
    local origin = M.weReadOrigin(wr)
    if not origin then return end
    view.key = view.key or view.kind .. ":" .. view.title
    if origin._weui_weread_sheet then return origin:setView(view) end
    Sheet = Sheet or require("weui_paper_sheets").extend(Page, M)
    WeReadSheet = WeReadSheet or require("weui_paper_weread").extend(Sheet, M)
    local window = WeReadSheet:new{ screen = "weread", plugin = origin.plugin, wr = wr,
        tab = origin.tab, origin_page = origin }
    M._instance = window
    local result = window:setView(view)
    UIManager:show(window, "ui")
    return result
end

return M

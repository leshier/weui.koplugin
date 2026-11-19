-- Paper bottom sheets share the page's fonts, drawing and gesture coordinates.
local Device = require("device")
local Screen = Device.screen
local BB = require("ffi/blitbuffer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local UIManager = require("ui/uimanager")
local Refresh = require("weui_refresh")
local Library = require("weui_library")
local Store = require("weui_store")
local Config = require("weui_config")
local Privacy = require("weui_privacy")
local Collections = require("readcollection")
local ffiUtil = require("ffi/util")
local ink, sub, rule = BB.gray(0.91), BB.gray(0.66), BB.gray(0.28)
local list_rule, facts_rule = BB.gray(0.2), BB.gray(68 / 255)
local M = {}
local goal_fields = {
    annual = { key = "weui_reading_goal", factor = 1, title = "年度阅读目标（本）" },
    monthly = { key = "weui_monthly_reading_goal_secs", factor = 3600, title = "每月阅读目标（小时）" },
    daily = { key = "weui_daily_reading_goal_secs", factor = 60, title = "每日阅读目标（分钟）" },
}
local virtual_groups = { { "reading", "正在读" }, { "unread", "待读清单" }, { "done", "读完的书" } }

local function relativeDate(timestamp)
    local date = os.date("%Y-%m-%d", timestamp)
    local today = os.date("%Y-%m-%d")
    if date == today then return "今天" end
    if date == Library.day(today, -1) then return "昨天" end
    return os.date(date:sub(1, 4) == today:sub(1, 4) and "%m月%d日" or "%Y年%m月%d日", timestamp)
end

function M.extend(Page, Paper)
    local Sheet = Page:extend{
        name = "weui_paper_sheet", covers_fullscreen = false, alpha = 0.86,
        _weui_paper_sheet = true,
    }

    function Sheet:init()
        self.state = { page = 1 }
        self.key_events = {
            Close = { { "Back" }, { "Esc" } },
            NextPage = { { "PageForward" }, { "Right" } },
            PrevPage = { { "PageBack" }, { "Left" } },
        }
        self.ges_events = {
            TapPaper = { GestureRange:new{ ges = "tap", range = function() return self.dimen end } },
            HoldPaper = { GestureRange:new{ ges = "hold", range = function() return self.dimen end } },
            SwipePaper = { GestureRange:new{ ges = "swipe", range = function() return self.dimen end } },
        }
        if self.screen == "reading_goals" then
            self.draft = {}
            for id, field in pairs(goal_fields) do self.draft[id] = tonumber(Store:get(field.key)) or 0 end
        end
        self:rebuild()
    end

    -- Center the native font's measured height inside the prototype's line box.
    function Sheet:lineText(text, x, y, w, size, height, opts)
        local widget = self:text(text, x, y, w, size, opts)
        self.items[#self.items].y = self:px(y + (height - widget:getSize().h / self.scale) / 2)
        return widget
    end

    function Sheet:frame(title, height, back)
        self.panel_y = self.screen == "rankings" and (self.logical_h - height) / 2 or self.logical_h - 18 - height
        self.panel_h = height
        local y = self.panel_y
        self:rect(16, y, 504, height, BB.COLOR_WHITE)
        self:rect(16, y, 504, height, ink, 1)
        self:lineText(title, back and 78 or 38, y + 1, back and 366 or 406, 24, 64, { font = "song" })
        self:iconButton(Config.ICON.weui_close, 462, y + 9, function() self:dismiss() end)
        if back then
            self:lineText("‹", 26, y + 9, 48, 27, 48, { align = "center", color = sub })
            self:hit(26, y + 9, 48, 48, function() self:back() end)
        end
        self:rect(38, y + 65, 460, 1, rule)
        return y + 83
    end

    function Sheet:sheetRow(label, meta, y, callback, hold, selected, icon_path)
        if icon_path then self:icon(icon_path, 40, y + 13, 22) end
        self:lineText(label, icon_path and 76 or 38, y, icon_path and 292 or 330, 12, 47)
        self:lineText(meta or "", 374, y, 124, 10, 47, { align = "right", color = sub })
        if selected then self:lineText("✓", 469, y, 29, 15, 47, { align = "right" }) end
        self:rect(38, y + 47, 460, 1, list_rule)
        self:hit(38, y, 460, 48, callback, hold)
    end

    function Sheet:bookEntry(book, history)
        return { label = book.title, meta = history and relativeDate(book.last_read) or book.authors,
            book = book, callback = function() self:openBook(book) end,
            hold = function() self:bookDetails(book) end }
    end

    function Sheet:groupBooks(group)
        if group.status then return Library.filter(self.books, "", group.status) end
        local members = {}
        for path in pairs((Collections.coll or {})[group.name] or {}) do
            members[ffiUtil.realpath(path) or path] = true
        end
        local books = {}
        for _, book in ipairs(self.books) do if members[book.filepath] then books[#books + 1] = book end end
        return books
    end

    function Sheet:openGroup(group)
        local function show()
            if self._closed then return end
            self.group, self.state.page = group, 1
            self:rebuild(true)
        end
        if group.name and not Privacy.isCollectionRevealed(group.name) then Privacy.requirePassword(show)
        else show() end
    end

    function Sheet:list()
        local entries, title, intro = {}, "阅读历史"
        if self.screen == "rankings" then
            title = "阅读书目"
            local records = self.rank_records or Library.stats(self.origin_page.state.period, nil, self.books).ranking
            intro = #records .. " 本书"
            for _, record in ipairs(records) do
                local minutes = math.floor((record.seconds or 0) / 60)
                entries[#entries + 1] = { label = record.title,
                    meta = string.format("%d 小时 %d 分", math.floor(minutes / 60), minutes % 60),
                    callback = record.book and function() self:bookDetails(record.book) end }
            end
        elseif self.group then
            title = self.group.label or (Privacy.isCollectionRevealed(self.group.name) and Library.collectionDisplayName(self.group.name) or "私密分组")
            local books = self:groupBooks(self.group)
            intro = #books .. " 本书"
            for _, book in ipairs(books) do entries[#entries + 1] = self:bookEntry(book) end
        elseif self.screen == "history" then
            for _, book in ipairs(self.books) do
                if book.last_read > 0 then entries[#entries + 1] = self:bookEntry(book, true) end
            end
            table.sort(entries, function(a, b)
                if a.book.last_read ~= b.book.last_read then return a.book.last_read > b.book.last_read end
                return a.book.filepath < b.book.filepath
            end)
        else
            title = "收藏与分组"
            local favorites = Library.filter(self.books, "", "favorites")
            for _, book in ipairs(favorites) do entries[#entries + 1] = self:bookEntry(book) end
            if #favorites == 0 then entries[#entries + 1] = { label = "还没有收藏", meta = "长按书籍可收藏" } end
            entries[#entries + 1] = { section = "书籍分组" }
            local groups = {}
            for _, spec in ipairs(virtual_groups) do groups[#groups + 1] = { status = spec[1], label = spec[2] } end
            if not Collections.coll then Collections:_read() end
            local actual = {}
            for name in pairs(Collections.coll or {}) do
                if name ~= Collections.default_collection_name then actual[#actual + 1] = { name = name } end
            end
            table.sort(actual, function(a, b)
                local an = Privacy.isCollectionRevealed(a.name) and Library.collectionDisplayName(a.name) or "私密分组"
                local bn = Privacy.isCollectionRevealed(b.name) and Library.collectionDisplayName(b.name) or "私密分组"
                return an < bn
            end)
            for _, group in ipairs(actual) do groups[#groups + 1] = group end
            for _, group in ipairs(groups) do
                local revealed = not group.name or Privacy.isCollectionRevealed(group.name)
                entries[#entries + 1] = {
                    label = group.label or (revealed and Library.collectionDisplayName(group.name) or "私密分组"),
                    icon_path = revealed and Config.ICON.group or Config.ICON.weui_privacy,
                    meta = revealed and (#self:groupBooks(group) .. " 本") or "已锁定",
                    group = group, callback = function() self:openGroup(group) end,
                }
            end
            intro = #favorites .. " 本收藏 · " .. #groups .. " 个书籍分组"
        end
        if #entries == 0 then
            entries[1] = { label = self.screen == "history" and "还没有阅读记录" or "这个分组还没有书" }
        end
        self.entries = entries
        self:drawList(title, intro, self.group ~= nil)
    end

    function Sheet:drawList(title, intro, back)
        local overhead = 105 + (intro and 34.8 or 0) + (self.pinned_action and 62 or 0)
        self.per_page = math.max(1, math.floor((math.min(635, self.logical_h - 46) - overhead - 40) / 48))
        self.pages = math.max(1, math.ceil(#self.entries / self.per_page))
        self.state.page = math.max(1, math.min(self.state.page, self.pages))
        local first = (self.state.page - 1) * self.per_page + 1
        local count = math.min(self.per_page, #self.entries - first + 1)
        local rows_height = 0
        for i = first, first + count - 1 do
            rows_height = rows_height + (self.entries[i].section and 46.8 or 48)
        end
        local y = self:frame(title, overhead + rows_height + (self.pages > 1 and 40 or 0), back)
        if intro then
            self:lineText(intro, 38, y, 460, 12, 22.8, { color = sub })
            y = y + 34.8
        end
        for i = first, first + count - 1 do
            local entry = self.entries[i]
            if entry.section then
                self:lineText(entry.section, 38, y + 12, 460, 12, 22.8, { color = sub })
                y = y + 46.8
            else
                self:sheetRow(entry.label, entry.meta, y, entry.callback, entry.hold, entry.selected, entry.icon_path)
                y = y + 48
            end
        end
        if self.pages > 1 then
            self:text("‹", 174, y + 4, 48, 25, { align = "center", color = self.state.page > 1 and ink or rule })
            self:text(self.state.page .. " / " .. self.pages, 238, y + 14, 60, 11, { align = "center", color = sub })
            self:text("›", 314, y + 4, 48, 25, { align = "center", color = self.state.page < self.pages and ink or rule })
            self:hit(174, y, 48, 40, function() self:onPrevPage() end)
            self:hit(314, y, 48, 40, function() self:onNextPage() end)
        end
    end

    function Sheet:goals()
        self.pages = nil
        local y = self:frame("阅读目标", 326.5)
        local done = Library.yearlyBooks(self.books)
        self.facts = { done = done, target = self.draft.annual, remaining = math.max(0, self.draft.annual - done) }
        self:rect(38, y, 460, 1, facts_rule)
        local values = { done .. " 本", self.draft.annual > 0 and self.draft.annual .. " 本" or "未设置",
            self.draft.annual > 0 and self.facts.remaining .. " 本" or "—" }
        local captions = { "今年已读完", "年度目标", "还需完成" }
        for i = 1, 3 do
            local x = 38 + (i - 1) * 460 / 3
            self:lineText(values[i], x, y + 14, 460 / 3, 14, 20.5)
            self:lineText(captions[i], x, y + 39.5, 460 / 3, 10, 14.5, { color = sub })
        end
        self:rect(38, y + 67, 460, 1, facts_rule)
        self:lineText("年度阅读目标", 38, y + 87, 460, 11, 16.5, { color = sub })
        self:rect(38, y + 111.5, 460, 42, rule, 1)
        self:lineText(self.draft.annual > 0 and ("每年 " .. self.draft.annual .. " 本") or "暂不设置",
            49, y + 112.5, 409, 12, 40)
        self:icon(Config.ICON.weui_chevron_down, 483, y + 126.5, 12)
        self:hit(38, y + 111.5, 460, 42, function()
            self.picking_annual, self.state.page = true, 1; self:rebuild()
        end)
        self:rect(38, y + 173.5, 460, 48, ink)
        self:lineText("保存目标", 45, y + 173.5, 446, 13, 48, { color = BB.COLOR_WHITE, align = "center" })
        self:hit(38, y + 173.5, 460, 48, function() self:saveGoals() end)
    end

    function Sheet:annualChoices()
        self.entries = {}
        local choices, seen = { 0, 12, 18, 24, 30, 36, 48, self.draft.annual }, {}
        table.sort(choices)
        for _, value in ipairs(choices) do
            if not seen[value] then
                seen[value] = true
                self.entries[#self.entries + 1] = {
                    label = value > 0 and ("每年 " .. value .. " 本") or "暂不设置",
                    selected = self.draft.annual == value, callback = function()
                        self.draft.annual, self.picking_annual, self.state.page = value, nil, 1
                        self:rebuild()
                    end,
                }
            end
        end
        self.entries[#self.entries + 1] = { label = "自定义本数", meta = "›", callback = function() self:editGoal("annual") end }
        self.entries[#self.entries + 1] = {
            label = "每月阅读时间", meta = self.draft.monthly > 0 and self.draft.monthly / 3600 .. " 小时 ›" or "未设置 ›",
            callback = function() self:editGoal("monthly") end,
        }
        self.entries[#self.entries + 1] = {
            label = "每日阅读时间", meta = self.draft.daily > 0 and self.draft.daily / 60 .. " 分钟 ›" or "未设置 ›",
            callback = function() self:editGoal("daily") end,
        }
        self:drawList("年度阅读目标", nil, true)
    end

    function Sheet:editGoal(id)
        local field, dialog = goal_fields[id]
        dialog = require("ui/widget/inputdialog"):new{
            title = field.title, input = tostring(self.draft[id] / field.factor), input_type = "number",
            buttons = { {
                { text = "取消", callback = function() UIManager:close(dialog) end },
                { text = "确定", is_enter_default = true, callback = function()
                    local value = tonumber(dialog:getInputText())
                    if not value or value < 0 or value > 9999 or value ~= math.floor(value) then
                        UIManager:show(require("ui/widget/infomessage"):new{ text = "请输入 0 到 9999 的整数。", timeout = 3 })
                        return
                    end
                    self.draft[id] = value * field.factor
                    UIManager:close(dialog)
                    if self._closed then return end
                    self.picking_annual, self.state.page = nil, 1; self:rebuild()
                end },
            } },
        }
        UIManager:show(dialog); dialog:onShowKeyboard()
    end

    function Sheet:saveGoals()
        for id, field in pairs(goal_fields) do Store:set(field.key, self.draft[id]) end
        self:dismiss()
    end

    function Sheet:back()
        self.group, self.picking_annual, self.state.page = nil, nil, 1
        self:rebuild()
        return true
    end

    function Sheet:rebuild(force)
        self:freeItems()
        if force and not self.origin_page._closed then self.origin_page:rebuild(true) end
        self.scale = math.min(Screen:getWidth() / 536, Screen:getHeight() / 724)
        self.logical_h = Screen:getHeight() / self.scale
        self.offset = math.floor((Screen:getWidth() - self:px(536)) / 2)
        self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
        self.items, self.hits = {}, {}
        self.books = Library.books(self.plugin, force, true)
        if self.screen == "reading_goals" then
            if self.picking_annual then self:annualChoices() else self:goals() end
        else self:list() end
        Refresh.update(self)
    end

    function Sheet:paintTo(bb, x, y)
        self.dimen.x, self.dimen.y = x, y
        local top = self:px(28)
        bb:blendRectRGB32(x, y + top, self.dimen.w, self.dimen.h - top, BB.ColorRGB32(255, 255, 255, 220))
        self:paintItems(bb, x + self.offset, y)
        Refresh.painted(self)
    end

    function Sheet:onTapPaper(_, ges)
        local x = (ges.pos.x - self.dimen.x - self.offset) / self.scale
        local y = (ges.pos.y - self.dimen.y) / self.scale
        if x < 16 or x >= 520 or y < self.panel_y or y >= self.panel_y + self.panel_h then return self:dismiss() end
        return Page.onTapPaper(self, nil, ges)
    end

    function Sheet:onClose()
        if self.group or self.picking_annual then return self:back() end
        return self:dismiss()
    end

    function Sheet:dismiss()
        UIManager:close(self, "ui")
        return true
    end

    function Sheet:openBook(book)
        -- Keep the sheet until the actual open begins, including password
        -- cancellation. The reader hook snapshots the sheet's group/page.
        Page.openBook(self, book)
    end

    function Sheet:onScreenResize()
        self.origin_page:rebuild(); self:rebuild(); return true
    end
    function Sheet:onSetRotationMode(mode)
        Screen:setRotationMode(mode); return self:onScreenResize()
    end

    function Sheet:onCloseWidget()
        Page.onCloseWidget(self)
        if self._navbar_closing_intentionally then return end
        local origin = self.origin_page
        for _, entry in ipairs(UIManager._window_stack) do
            if entry.widget == origin and not origin._closed then
                Paper._instance = origin
                self.plugin.active_action = origin.tab
                origin:rebuild(true)
                break
            end
        end
    end
    return Sheet
end

return M

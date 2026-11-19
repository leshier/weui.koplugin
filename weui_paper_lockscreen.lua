-- A static local snapshot. No navigation, network requests or refresh timers.
local Device = require("device")
local Screen = Device.screen
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local UIManager = require("ui/uimanager")
local Library = require("weui_library")
local Privacy = require("weui_privacy")
local BB = require("ffi/blitbuffer")
local ink, sub, rule = BB.COLOR_BLACK, BB.gray(0.72), BB.gray(0.42)
local M = {}

function M.extend(Page)
    local Snapshot = Page:extend{
        name = "weui_lockscreen", covers_fullscreen = true, _navbar_injected = true,
        _navbar_closing_intentionally = true,
    }

    function Snapshot:init()
        self.timestamp = self.timestamp or os.time()
        self.scale = math.min(Screen:getWidth() / 536, Screen:getHeight() / 724)
        self.logical_h = Screen:getHeight() / self.scale
        self.offset = math.floor((Screen:getWidth() - self:px(536)) / 2)
        self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
        self.items, self.hits, self.books = {}, {}, {}
        -- Copy before masking, even if the in-app privacy session is unlocked.
        for _, source in ipairs(self.mode ~= "calendar" and Library.snapshot() or {}) do
            local book = {}
            for key, value in pairs(source) do book[key] = value end
            if Privacy.isPrivateBook(book.filepath, book.title) then
                book.private = true
                book.title, book.authors = Privacy.privateTitle(), Privacy.privateAuthor()
                book.filepath, book.source_book, book.chapter, book.tags = nil, nil, "", ""
            end
            self.books[#self.books + 1] = book
        end
        if self.mode == "recent" then self:recent()
        elseif self.mode == "stats" then self:statistics()
        else self:calendar() end
        self:text(os.date("%Y年%m月%d日", self.timestamp), 28, self.logical_h - 68, 480, 11, { color = sub, align = "center" })
        self:text("休息片刻，再读一页", 28, self.logical_h - 41, 480, 11, { color = sub, align = "center" })
    end

    function Snapshot:recent()
        self:heading("最近阅读", "书页停在这里，醒来继续")
        local recent = {}
        for _, book in ipairs(self.books) do if book.last_read > 0 then recent[#recent + 1] = book end end
        if not recent[1] then
            self:text("下一本书，等你翻开", 28, 275, 480, 27, { font = "song", align = "center" })
            return
        end
        local book = recent[1]
        self:cover(book, 187, 177, 162, 226)
        self:text(book.title, 28, 436, 480, 26, { font = "song", align = "center" })
        self:text(book.authors, 28, 480, 480, 12, { color = sub, align = "center" })
        self:text(book.private and "私密书籍" or self:bookStatus(book), 28, 513, 480, 12, { color = sub, align = "center" })
        for i = 2, math.min(#recent, 3) do
            self:text(recent[i].title, 28, 560 + (i - 2) * 31, 480, 13, { font = "song", align = "center" })
        end
    end

    function Snapshot:statistics()
        self:heading("阅读时光", "过去七天，与你读过的书")
        local stats = Library.stats("week", self.timestamp, self.books)
        self.snapshot_stats = stats
        local minutes = math.floor(stats.seconds / 60)
        self:text(string.format("%d", math.floor(minutes / 60)), 28, 178, 480, 75, { font = "number", align = "center" })
        self:text(string.format("小时  %d 分钟", minutes % 60), 28, 282, 480, 16, { align = "center" })
        self:text("连续阅读 " .. stats.streak .. " 天", 28, 327, 480, 13, { color = sub, align = "center" })
        local maximum = 1
        for _, bar in ipairs(stats.bars) do maximum = math.max(maximum, bar.seconds) end
        for i, bar in ipairs(stats.bars) do
            local x, height = 47 + (i - 1) * 66, math.max(1, 112 * bar.seconds / maximum)
            self:rect(x, 484 - height, 34, height, bar.seconds > 0 and ink or rule)
            self:text(bar.label, x - 12, 499, 58, 9, { color = sub, align = "center" })
        end
        local record = stats.ranking[1]
        if record then
            local title = Privacy.isPrivateBook(nil, record.title) and Privacy.privateTitle() or record.title
            self:text(title, 28, 565, 480, 22, { font = "song", align = "center" })
        else self:text("今天，给阅读留一点时间", 28, 565, 480, 22, { font = "song", align = "center" }) end
    end

    function Snapshot:calendar()
        local date = os.date("*t", self.timestamp)
        self:text(string.format("%d年 · %d月", date.year, date.month), 28, 94, 480, 27, { font = "song", align = "center" })
        self:text(tostring(date.day), 28, 168, 480, 100, { font = "number", align = "center" })
        local weekdays = { "日", "一", "二", "三", "四", "五", "六" }
        self:text("星期" .. weekdays[date.wday], 28, 303, 480, 15, { align = "center" })
        local first = os.date("*t", os.time{ year = date.year, month = date.month, day = 1, hour = 12 })
        local days = tonumber(os.date("%d", os.time{ year = date.year, month = date.month + 1, day = 0, hour = 12 }))
        local start = (first.wday + 5) % 7 -- Monday first
        for i, label in ipairs({ "一", "二", "三", "四", "五", "六", "日" }) do
            self:text(label, 40 + (i - 1) * 66, 380, 60, 11, { color = sub, align = "center" })
        end
        self:line(410)
        for day = 1, days do
            local index = start + day - 1
            local x, y = 40 + index % 7 * 66, 432 + math.floor(index / 7) * 31
            if day == date.day then self:rect(x + 14, y - 5, 32, 28, ink) end
            self:text(tostring(day), x, y, 60, 13, {
                font = "number", align = "center", color = day == date.day and BB.COLOR_WHITE or ink,
                background = day == date.day and ink or BB.COLOR_WHITE,
            })
        end
    end

    function Snapshot:enablePreview()
        self.name = "weui_lockscreen_preview"
        self.key_events = { Close = { { "Back" }, { "Esc" }, { "Enter" } } }
        self.ges_events = { Close = { GestureRange:new{ ges = "tap", range = self.dimen } } }
        self:text("轻触或按返回关闭预览", 28, 20, 480, 10, { color = sub, align = "center" })
    end
    function Snapshot:onClose() UIManager:close(self); return true end
    function Snapshot:free() self:freeItems() end
    function Snapshot:onCloseWidget() self:freeItems() end
    -- This is a captured image in widget form, never a live paper page.
    function Snapshot:onResume() end
    function Snapshot:onSetRotationMode() return true end
    function Snapshot:onScreenResize() return true end

    return Snapshot
end
return M

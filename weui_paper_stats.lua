-- Calendar and period details stay on the same Paper page.
local BB = require("ffi/blitbuffer")
local Library = require("weui_library")
local ink, sub = BB.gray(0.91), BB.gray(0.66)
local M = {}

local function monthTime(date, offset)
    return os.time{ year = tonumber(date:sub(1, 4)), month = tonumber(date:sub(6, 7)) + (offset or 0),
        day = 1, hour = 12 }
end

function M.apply(Page)
    function Page:moveStatsMonth(delta)
        self.state.stats_month = os.date("%Y-%m-01", monthTime(self.state.stats_month, delta))
        self.state.stats_day = nil
        self:rebuild()
    end

    function Page:statsDetails()
        self.pages = nil
        self.state.stats_month = self.state.stats_month or os.date("%Y-%m-01")
        local month = self.state.stats_month
        local next_month = os.date("%Y-%m-%d", monthTime(month, 1))
        local last = Library.day(next_month, -1)
        local period = self.state.period or "week"
        local anchor = os.time{ year = tonumber(next_month:sub(1, 4)), month = tonumber(next_month:sub(6, 7)),
            day = 1, hour = 0 } - 1
        if period == "year" then
            anchor = os.time{ year = tonumber(month:sub(1, 4)) + 1, month = 1, day = 1, hour = 0 } - 1
        end
        anchor = math.min(os.time(), anchor)
        local data = Library.stats(period, period ~= "all" and anchor or nil, self.books)
        self:text("‹ 返回阅读统计", 28, 44, 300, 11, { color = sub })
        self:hit(28, 30, 200, 42, function() self.screen = self.tab; self:rebuild() end)
        self:text("日历与详细统计", 28, 87, 480, 30, { font = "song" })
        local periods = { { "week", "近7天" }, { "month", "月" }, { "year", "年" }, { "all", "全部" } }
        for i, entry in ipairs(periods) do
            local id, x = entry[1], 28 + (i - 1) * 120
            self:text(entry[2], x, 137, 120, 12, { align = "center", bold = period == id })
            if period == id then self:rect(x + 18, 164, 84, 2, ink) end
            self:hit(x, 126, 120, 43, function() self.state.period = id; self:rebuild() end)
        end
        self:text(data.start .. " — " .. data.finish, 28, 185, 480, 11, { color = sub })
        local minutes = math.floor(data.seconds / 60)
        self:text(string.format("%d 小时 %d 分", math.floor(minutes / 60), minutes % 60), 28, 211, 480, 29,
            { font = "number" })
        self:text(string.format("%d 天有阅读 · 日均 %d 分钟 · %d 本书", data.days,
            math.floor((data.average or 0) / 60), #data.ranking), 28, 253, 480, 11, { color = sub })
        self:line(283)
        self:text("‹", 28, 294, 48, 23, { align = "center" })
        self:text(month:sub(1, 4) .. " 年 " .. tonumber(month:sub(6, 7)) .. " 月", 84, 301, 368, 15,
            { align = "center", font = "song" })
        self:text("›", 460, 294, 48, 23, { align = "center" })
        self:hit(28, 286, 48, 43, function() self:moveStatsMonth(-1) end)
        self:hit(460, 286, 48, 43, function() self:moveStatsMonth(1) end)
        local weekdays = { "一", "二", "三", "四", "五", "六", "日" }
        for i, label in ipairs(weekdays) do
            self:text(label, 28 + (i - 1) * 480 / 7, 339, 480 / 7, 10, { align = "center", color = sub })
        end
        local offset = (tonumber(os.date("%w", monthTime(month))) + 6) % 7
        local today = os.date("%Y-%m-%d")
        self.state.stats_day = self.state.stats_day or (today >= month and today <= last and today or last)
        for d = 1, tonumber(last:sub(9, 10)) do
            local date = string.format("%s%02d", month:sub(1, 8), d)
            local cell = offset + d - 1
            local x, y = 28 + cell % 7 * 480 / 7, 363 + math.floor(cell / 7) * 32
            local selected = self.state.stats_day == date
            if selected then self:rect(x + 15, y, 480 / 7 - 30, 28, ink) end
            self:text(d, x, y + 4, 480 / 7, 12, { align = "center",
                color = selected and BB.COLOR_WHITE or ink })
            if data.daily[date] then
                self:rect(x + 30, y + 24, 9, 2, selected and BB.COLOR_WHITE or ink)
            end
            self:hit(x, y, 480 / 7, 32, function() self.state.stats_day = date; self:rebuild() end)
        end
        self:line(563)
        local secs = data.daily[self.state.stats_day] or 0
        self:text(self.state.stats_day .. " · 阅读 " .. math.floor(secs / 60) .. " 分钟", 28, 580, 480, 14)
        self:text("黑线表示当天有阅读 · 点击日期查看时长", 28, 607, 480, 10, { color = sub })
        if not data.available then self:text("开始阅读后会显示记录。", 28, 629, 480, 10, { color = sub }) end
    end
end

return M

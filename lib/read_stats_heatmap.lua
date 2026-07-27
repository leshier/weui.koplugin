-- lib/read_stats_heatmap.lua - Monthly reading heatmap calendar (pure logic).
--
-- Turns a normalized monthly stats table (see lib/read_stats.lua) into a
-- Monday-first calendar grid where each day cell carries a 0-4 intensity level
-- derived from reading seconds. No UI / Blitbuffer dependency, so it is fully
-- unit-testable outside the koreader runtime.
--
-- Time zone: the calendar is interpreted in Beijing time (CST, UTC+8), matching
-- the read_stats normalization (base_time is a Beijing-midnight timestamp and
-- every readTimes bucket is a Beijing-midnight day). The number of days in a
-- month and the weekday of day 1 are civil-calendar properties, so they are
-- computed directly from the broken-down Beijing date without any device-TZ
-- dependence.

local M = {}

local CST_OFFSET = 8 * 3600 -- Beijing time, east of UTC

-- Beijing-time broken-down components for a timestamp (isdst = false).
local function cst_date(ts)
    return os.date("!*t", ts + CST_OFFSET)
end

-- Number of days in a (Gregorian) month. Pure arithmetic, no os.time -> no TZ.
local function days_in_month(year, month)
    local long = { [1] = true, [3] = true, [5] = true, [7] = true,
                   [8] = true, [10] = true, [12] = true }
    if long[month] then return 31 end
    if month == 2 then
        local leap = (year % 4 == 0 and year % 100 ~= 0) or (year % 400 == 0)
        return leap and 29 or 28
    end
    return 30
end
M.days_in_month = days_in_month

-- Monday-first column index (0..6) for a Lua wday (1=Sun .. 7=Sat).
-- Mon=0, Tue=1, Wed=2, Thu=3, Fri=4, Sat=5, Sun=6.
local function monday_col(wday)
    if wday == 1 then return 6 end -- Sunday
    return wday - 2
end
M.monday_col = monday_col

-- Map a normalized monthly stats table to a heatmap grid.
--
-- Input (the subset we read):
--   data.base_time : Beijing-midnight timestamp of day 1 (from read_stats.fetch)
--   data.buckets   : array of { ts, label = tostring(day), value = seconds }
--
-- Returns:
--   {
--     year, month, dim_days,            -- civil month metadata
--     first_col,                        -- Monday-first column of day 1 (0..6)
--     weeks = {                          -- array of weeks, each a list of <=7 cells
--       { day = n|nil, seconds, level = 0..4, in_month = bool },
--       ...
--     },
--     max_seconds, active_days, total_seconds,
--     legend = { steps = {0,1,2,3,4}, max = max_seconds },
--   }
--
-- Intensity levels (0 = no reading, 4 = most) use four equal bands of the
-- nonzero maximum, so the scale adapts to each user's habits:
--   L1: (0,        max*0.25]
--   L2: (max*0.25, max*0.5]
--   L3: (max*0.5,  max*0.75]
--   L4: (max*0.75, max]
function M.build(data)
    data = type(data) == "table" and data or {}
    local base_time = tonumber(data.base_time) or 0
    local d = cst_date(base_time)
    local year, month = d.year, d.month
    local dim_days = days_in_month(year, month)
    local first_col = monday_col(d.wday)

    -- Index daily seconds by day-of-month. Buckets carry label = tostring(day).
    local sec_by_day = {}
    local max_seconds, total_seconds, active_days = 0, 0, 0
    local buckets = data.buckets or {}
    for _i, b in ipairs(buckets) do
        local day = tonumber(b.label) or tonumber(b.day)
        local sec = tonumber(b.value) or 0
        if day and day >= 1 and day <= 31 and sec > 0 then
            -- Keep the max per day in case of duplicate buckets.
            local prev = sec_by_day[day] or 0
            if sec > prev then sec_by_day[day] = sec end
        end
    end
    for day = 1, dim_days do
        local sec = sec_by_day[day] or 0
        if sec > 0 then
            total_seconds = total_seconds + sec
            active_days = active_days + 1
            if sec > max_seconds then max_seconds = sec end
        end
    end

    -- Level function: four equal bands of max_seconds.
    local function level_for(sec)
        if not sec or sec <= 0 then return 0 end
        if max_seconds <= 0 then return 0 end
        local r = sec / max_seconds
        if r > 0.75 then return 4 end
        if r > 0.50 then return 3 end
        if r > 0.25 then return 2 end
        return 1
    end

    -- Build a flat cell list with leading + trailing blanks, then chunk into weeks.
    local cells = {}
    for _i = 1, first_col do
        cells[#cells + 1] = { day = nil, seconds = 0, level = 0, in_month = false }
    end
    for day = 1, dim_days do
        local sec = sec_by_day[day] or 0
        cells[#cells + 1] = {
            day = day, seconds = sec,
            level = level_for(sec), in_month = true,
        }
    end
    -- Pad the final week to a full 7 cells.
    local tail = #cells % 7
    if tail ~= 0 then
        for _i = 1, 7 - tail do
            cells[#cells + 1] = { day = nil, seconds = 0, level = 0, in_month = false }
        end
    end

    local weeks = {}
    for i = 1, #cells, 7 do
        local week = {}
        for j = 0, 6 do
            week[#week + 1] = cells[i + j]
        end
        weeks[#weeks + 1] = week
    end

    return {
        year = year,
        month = month,
        dim_days = dim_days,
        first_col = first_col,
        weeks = weeks,
        max_seconds = max_seconds,
        active_days = active_days,
        total_seconds = total_seconds,
        legend = { steps = { 0, 1, 2, 3, 4 }, max = max_seconds },
    }
end

return M

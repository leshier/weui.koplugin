-- WeRead Reading Stats homescreen module (enhanced).
-- Renders cached monthly cloud statistics with an overview-style layout:
-- large total time + day stats on the left, a mini 7-day bar chart on the
-- right, and summary chips along the bottom.  Matches the feel of the full
-- WeRead reading statistics page but condensed to homescreen scale.
-- Tapping the module opens the full WeRead statistics view.

local Blitbuffer      = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device          = require("device")
local Font            = require("ui/font")
local FrameContainer  = require("ui/widget/container/framecontainer")
local Geom            = require("ui/geometry")
local GestureRange    = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan  = require("ui/widget/horizontalspan")
local InputContainer  = require("ui/widget/container/inputcontainer")
local LineWidget      = require("ui/widget/linewidget")
local RightContainer  = require("ui/widget/container/rightcontainer")
local TextBoxWidget   = require("ui/widget/textboxwidget")
local TextWidget      = require("ui/widget/textwidget")
local UIManager       = require("ui/uimanager")
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")
local Screen          = Device.screen
local logger          = require("logger")

local _           = require("weui_i18n").translate
local T           = require("ffi/util").template
local Config      = require("weui_config")
local SUISettings = require("weui_store")
local SUIStyle    = require("weui_style")

local M = {
    id = "weread_stats",
    name = _("WeRead Reading Stats"),
    label = nil,
    default_on = false,
}

local CACHE_KEY = "weui_weread_stats_cache_v1"
local ENABLED_KEY = "weread_stats_enabled"
local REFRESH_INTERVAL = 3600
local RETRY_INTERVAL = 300

-- Layout constants (base scale = 1.0)
local BASE_H          = Screen:scaleBySize(150)
local BASE_PAD        = Screen:scaleBySize(12)
local BASE_RADIUS     = Screen:scaleBySize(12)
local BASE_TITLE_FS   = SUIStyle.FS_BODY        -- 18
local BASE_BIG_FS     = SUIStyle.FS_TITLE + 4   -- 26
local BASE_SUB_FS     = SUIStyle.FS_DETAIL      -- 15
local BASE_CHART_H    = Screen:scaleBySize(56)
local BASE_CHART_DAYS = 7

local _refreshing = false
local _last_attempt = 0

local function resolveWeRead()
    local FM = package.loaded["apps/filemanager/filemanager"]
    local fm = FM and FM.instance
    local plugin = fm and fm._weui_plugin
    return (plugin and plugin._weread_plugin) or (fm and fm.weread)
end

local function format_duration(seconds)
    seconds = math.max(0, math.floor(tonumber(seconds) or 0))
    if seconds < 60 then return _("< 1 min") end
    local h = math.floor(seconds / 3600)
    local m = math.floor((seconds % 3600) / 60)
    if h > 0 and m > 0 then return T(_("%1 h %2 min"), h, m) end
    if h > 0 then return T(_("%1 h"), h) end
    return T(_("%1 min"), m)
end

local function format_duration_short(seconds)
    seconds = math.max(0, math.floor(tonumber(seconds) or 0))
    local h = math.floor(seconds / 3600)
    local m = math.floor((seconds % 3600) / 60)
    if h > 0 then
        return T(_("%1h%2m"), h, m)
    end
    return T(_("%1m"), m)
end

local function cacheSnapshot(data)
    return {
        updated_at = os.time(),
        period_label = data.period_label,
        total_read_time = tonumber(data.total_read_time) or 0,
        read_days = tonumber(data.read_days) or 0,
        day_average = tonumber(data.day_average) or 0,
        compare = data.compare,
        rank_text = data.rank_text,
        buckets = data.buckets or {},
        summary = data.summary or {},
    }
end

function M.updateCache(data)
    if type(data) ~= "table" then return false end
    SUISettings:setNoFlush(CACHE_KEY, cacheSnapshot(data))
    return true
end

local function showNotice(text)
    local InfoMessage = require("ui/widget/infomessage")
    UIManager:show(InfoMessage:new{ text = text, timeout = 2 })
end

function M.refresh(force, notify)
    local now = os.time()
    local cache = SUISettings:readSetting(CACHE_KEY)
    if not force and type(cache) == "table"
            and now - (tonumber(cache.updated_at) or 0) < REFRESH_INTERVAL then
        return false
    end
    if _refreshing or (not force and now - _last_attempt < RETRY_INTERVAL) then
        return false
    end

    local wr = resolveWeRead()
    if not wr or not wr.client or not wr.settings
            or not wr.settings:is_api_configured() then
        if notify then showNotice(_("Please log in to WeRead first.")) end
        return false
    end
    if wr.isNetworkOnline and not wr:isNetworkOnline() then
        if notify then showNotice(_("No network connection.")) end
        return false
    end

    _refreshing = true
    _last_attempt = now
    if notify then showNotice(_("Refreshing WeRead statistics...")) end
    UIManager:scheduleIn(0.1, function()
        local ok, data = pcall(function()
            return require("lib.read_stats").fetch(wr.client, "monthly", nil)
        end)
        _refreshing = false
        if not ok or type(data) ~= "table" then
            logger.warn("weui: WeRead stats refresh failed:", tostring(data))
            if notify then showNotice(_("Failed to refresh WeRead statistics.")) end
            return
        end
        M.updateCache(data)
        local HS = package.loaded["weui_homescreen"]
        if HS and HS.refresh then HS.refresh(true) end
    end)
    return true
end

function M.isEnabled(pfx)
    return SUISettings:readSetting(pfx .. ENABLED_KEY) == true
end

function M.setEnabled(pfx, on)
    SUISettings:saveSetting(pfx .. ENABLED_KEY, on == true)
end

-- Build a mini 7-day bar chart from the most recent daily buckets.
-- Returns a HorizontalGroup with bars + day labels.
local function buildMiniChart(buckets, chart_w, chart_h, small_face)
    local n = BASE_CHART_DAYS
    local days = {}

    -- Take the last N buckets (most recent days)
    local all = buckets or {}
    local start = math.max(1, #all - n + 1)
    for i = start, #all do
        days[#days + 1] = all[i]
    end
    -- Pad with empty at front if we have fewer than N days
    while #days < n do
        table.insert(days, 1, { value = 0, label = "" })
    end

    -- Find max value for scaling
    local max_val = 1
    for _, d in ipairs(days) do
        local v = tonumber(d.value) or 0
        if v > max_val then max_val = v end
    end

    local bar_gap = Screen:scaleBySize(3)
    local total_gap = bar_gap * (n - 1)
    local bar_w = math.max(2, math.floor((chart_w - total_gap) / n))

    local bars_row = HorizontalGroup:new{ align = "bottom" }
    local labels_row = HorizontalGroup:new{ align = "center" }

    for i, d in ipairs(days) do
        local value = tonumber(d.value) or 0
        local bar_h = math.max(2, math.floor(chart_h * value / max_val))

        local bar = LineWidget:new{
            dimen = Geom:new{ w = bar_w, h = bar_h },
            background = Blitbuffer.COLOR_BLACK,
        }
        -- Push bar to bottom
        local bar_col = VerticalGroup:new{
            align = "center",
            VerticalSpan:new{ width = chart_h - bar_h },
            bar,
        }
        table.insert(bars_row, bar_col)

        -- Day label (1-2 chars: day of month)
        local label = d.day_label or ""
        if label == "" and d.ts then
            label = tostring(os.date("%d", d.ts))
        end
        local lbl = TextWidget:new{
            text = label,
            face = small_face,
            fgcolor = Blitbuffer.COLOR_GRAY,
        }
        local lbl_col = CenterContainer:new{
            dimen = Geom:new{ w = bar_w, h = small_face.size + Screen:scaleBySize(2) },
            lbl,
        }
        table.insert(labels_row, lbl_col)

        if i < n then
            table.insert(bars_row, HorizontalSpan:new{ width = bar_gap })
            table.insert(labels_row, HorizontalSpan:new{ width = bar_gap })
        end
    end

    local chart_group = VerticalGroup:new{
        align = "center",
        bars_row,
        VerticalSpan:new{ width = Screen:scaleBySize(2) },
        labels_row,
    }
    return chart_group
end

-- Build summary chips line (e.g. "读过 12 本    读完 5 本    笔记 38 条")
local function buildSummaryLine(summary, width, body_face)
    if not summary or #summary == 0 then return nil end
    local chips = {}
    for _, s in ipairs(summary) do
        chips[#chips + 1] = T("%1 %2", s.name, s.counts)
    end
    return TextBoxWidget:new{
        text = table.concat(chips, "    "),
        face = body_face,
        width = width,
        fgcolor = Blitbuffer.COLOR_DARK_GRAY,
    }
end

local function openFullStats()
    local wr = resolveWeRead()
    if wr and wr.showReadStats then
        wr:showReadStats()
    else
        showNotice(_("WeRead module is not available."))
    end
end

function M.build(w, ctx)
    if not M.isEnabled(ctx.pfx) then return nil end

    local scale = Config.getModuleScale(M.id, ctx.pfx)
    local h = math.max(Screen:scaleBySize(80), math.floor(BASE_H * scale))
    local pad = math.max(4, math.floor(BASE_PAD * scale))
    local radius = math.max(2, math.floor(BASE_RADIUS * scale))
    local title_face = Font:getFace(
        SUIStyle.FACE_REGULAR, math.max(9, math.floor(BASE_TITLE_FS * scale)))
    local big_face = Font:getFace(
        SUIStyle.FACE_REGULAR, math.max(12, math.floor(BASE_BIG_FS * scale)))
    local sub_face = Font:getFace(
        SUIStyle.FACE_REGULAR, math.max(8, math.floor(BASE_SUB_FS * scale)))
    local chart_h = math.max(Screen:scaleBySize(32), math.floor(BASE_CHART_H * scale))

    local cache = SUISettings:readSetting(CACHE_KEY)
    local has_data = type(cache) == "table"

    -- ── Title row ───────────────────────────────────────────────
    local title_text = TextWidget:new{
        text = _("WeRead Reading"),
        face = title_face,
        bold = true,
    }
    local rank_text = ""
    if has_data and cache.rank_text and cache.rank_text ~= "" then
        rank_text = cache.rank_text
    end
    local rank_widget = TextWidget:new{
        text = rank_text,
        face = sub_face,
        fgcolor = Blitbuffer.COLOR_DARK_GRAY,
    }
    local title_row = HorizontalGroup:new{
        align = "center",
        title_text,
        HorizontalSpan:new{ width = Screen:scaleBySize(8) },
        rank_widget,
    }

    -- ── Stats + chart row ──────────────────────────────────────
    local inner_w = w - 2 * pad
    local left_w = math.floor(inner_w * 0.52)
    local right_w = inner_w - left_w - Screen:scaleBySize(10)

    -- Left side: big number + sub-stats
    local total_text = has_data and format_duration_short(cache.total_read_time) or "--"
    local big_num = TextWidget:new{
        text = total_text,
        face = big_face,
        bold = true,
    }
    local days_text = ""
    if has_data then
        days_text = T(_("%1 days · avg %2"),
            cache.read_days or 0,
            format_duration_short(cache.day_average))
    end
    local sub_stats = TextWidget:new{
        text = days_text,
        face = sub_face,
        fgcolor = Blitbuffer.COLOR_DARK_GRAY,
    }
    local left_col = VerticalGroup:new{
        align = "left",
        big_num,
        VerticalSpan:new{ width = Screen:scaleBySize(2) },
        sub_stats,
    }

    -- Right side: mini bar chart
    local chart = buildMiniChart(
        has_data and cache.buckets or {},
        right_w, chart_h, sub_face)
    local chart_container = RightContainer:new{
        dimen = Geom:new{ w = right_w, h = chart_h + sub_face.size + Screen:scaleBySize(4) },
        chart,
    }

    local stats_row = HorizontalGroup:new{
        align = "bottom",
        left_col,
        HorizontalSpan:new{ width = Screen:scaleBySize(10) },
        chart_container,
    }

    -- ── Summary chips ──────────────────────────────────────────
    local summary_line = buildSummaryLine(
        has_data and cache.summary or {}, inner_w, sub_face)

    -- ── Assemble content ───────────────────────────────────────
    local content = VerticalGroup:new{ align = "left" }
    table.insert(content, title_row)
    table.insert(content, VerticalSpan:new{ width = Screen:scaleBySize(6) })
    table.insert(content, stats_row)
    if summary_line then
        table.insert(content, VerticalSpan:new{ width = Screen:scaleBySize(8) })
        table.insert(content, summary_line)
    end

    local card = FrameContainer:new{
        dimen = Geom:new{ w = w, h = h },
        bordersize = SUIStyle.BORDER_SZ,
        color = Blitbuffer.gray(0.72),
        background = Blitbuffer.COLOR_WHITE,
        radius = radius,
        padding = 0,
        CenterContainer:new{
            dimen = Geom:new{ w = w, h = h },
            HorizontalGroup:new{
                HorizontalSpan:new{ width = pad },
                VerticalGroup:new{
                    align = "left",
                    VerticalSpan:new{ width = pad },
                    content,
                    VerticalSpan:new{ width = pad },
                },
                HorizontalSpan:new{ width = pad },
            },
        },
    }

    local tappable = InputContainer:new{
        dimen = Geom:new{ w = w, h = h },
        [1] = card,
    }
    tappable.ges_events = {
        TapWeReadStats = {
            GestureRange:new{ ges = "tap", range = function() return tappable.dimen end },
        },
    }
    function tappable:onTapWeReadStats()
        openFullStats()
        return true
    end

    M.refresh(false, false)
    return tappable
end

function M.getHeight(ctx)
    return math.max(
        Screen:scaleBySize(80),
        math.floor(BASE_H * Config.getModuleScale(M.id, ctx and ctx.pfx)))
end

function M.getMenuItems(ctx_menu)
    local pfx = ctx_menu.pfx
    return {
        {
            text = ctx_menu._("Refresh now"),
            callback = function() M.refresh(true, true) end,
        },
        Config.makeScaleItem{
            text_func = function() return ctx_menu._("Scale") end,
            enabled_func = function() return not Config.isScaleLinked() end,
            title = ctx_menu._("Scale"),
            info = ctx_menu._("Scale for this module.\n100% is the default size."),
            get = function() return Config.getModuleScalePct(M.id, pfx) end,
            set = function(v) Config.setModuleScale(v, M.id, pfx) end,
            refresh = ctx_menu.refresh,
        },
    }
end

return M

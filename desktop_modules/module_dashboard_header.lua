-- module_dashboard_header.lua — We UI
-- Compact dashboard header: date + title + sync / search / settings actions.
-- Replaces the oversized clock on the redesigned home screen.

local Blitbuffer      = require("ffi/blitbuffer")
local Device          = require("device")
local Font            = require("ui/font")
local FrameContainer  = require("ui/widget/container/framecontainer")
local Geom            = require("ui/geometry")
local GestureRange    = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan  = require("ui/widget/horizontalspan")
local ImageWidget     = require("ui/widget/imagewidget")
local InputContainer  = require("ui/widget/container/inputcontainer")
local CenterContainer = require("ui/widget/container/centercontainer")
local OverlapGroup    = require("ui/widget/overlapgroup")
local TextWidget      = require("ui/widget/textwidget")
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")

local Screen       = Device.screen
local _            = require("weui_i18n").translate
local Config       = require("weui_config")
local SUIStyle     = require("weui_style")
local UI           = require("weui_core")

local M = {}

M.id         = "dashboard_header"
M.name       = _("Dashboard Header")
M.label      = nil
M.default_on = true

local function _dateText()
    local now = os.time()
    local month = tonumber(os.date("%m", now))
    local day   = tonumber(os.date("%d", now))
    local wday  = tonumber(os.date("%w", now))
    if not month or not day or not wday then
        return os.date("%Y-%m-%d", now)
    end
    local weekdays = { "日", "一", "二", "三", "四", "五", "六" }
    return string.format("%d月%d日 · 周%s", month, day, weekdays[wday + 1] or "")
end

local function _iconButton(path, icon_sz, tap_sz, fallback_text, on_tap)
    local image
    local ok = pcall(function()
        image = ImageWidget:new{
            file    = path,
            width   = icon_sz,
            height  = icon_sz,
            is_icon = true,
            alpha   = true,
        }
        image:_render()
    end)
    if not ok or not image then
        if image then image:free() end
        image = CenterContainer:new{
            dimen = Geom:new{ w = icon_sz, h = icon_sz },
            TextWidget:new{
                text    = fallback_text or "?",
                face    = Font:getFace(SUIStyle.FACE_REGULAR, math.max(10, math.floor(icon_sz * 0.62))),
                fgcolor = Blitbuffer.COLOR_BLACK,
            },
        }
    end
    local button = InputContainer:new{
        dimen = Geom:new{ w = tap_sz, h = tap_sz },
        CenterContainer:new{
            dimen = Geom:new{ w = tap_sz, h = tap_sz },
            image,
        },
    }
    button.ges_events = {
        TapDashboardHeader = {
            GestureRange:new{
                ges   = "tap",
                range = function() return button.dimen end,
            },
        },
    }
    function button:onTapDashboardHeader()
        if on_tap then on_tap() end
        return true
    end
    return button
end

function M.build(w, ctx)
    local scale    = Config.getModuleScale(M.id, ctx and ctx.pfx)
    local pad      = Screen:scaleBySize(14)
    local header_h = math.max(1, math.floor(Screen:scaleBySize(62) * scale))
    local title_fs = math.max(16, math.floor(34 * scale))
    local date_fs  = math.max(10, math.floor(17 * scale))
    local icon_sz  = math.max(18, math.floor(Screen:scaleBySize(26) * scale))
    local tap_sz   = math.max(icon_sz, math.floor(Screen:scaleBySize(44) * scale))
    local gap      = Screen:scaleBySize(4)

    local function emit(action_id)
        if ctx and ctx.on_qa_tap then
            ctx.on_qa_tap(action_id)
        end
    end

    local left = VerticalGroup:new{
        align = "left",
        TextWidget:new{
            text    = _dateText(),
            face    = Font:getFace(SUIStyle.FACE_REGULAR, date_fs),
            fgcolor = SUIStyle.GRAY.sub,
        },
        VerticalSpan:new{ width = math.max(1, Screen:scaleBySize(2)) },
        TextWidget:new{
            text    = _("Reading Room"),
            face    = Font:getFace(SUIStyle.FACE_BOLD, title_fs),
            bold    = true,
            fgcolor = Blitbuffer.COLOR_BLACK,
        },
    }

    local right = HorizontalGroup:new{
        align = "center",
        _iconButton(Config.ICON.zlibrary_refresh, icon_sz, tap_sz, "↻", function() emit("weread") end),
        HorizontalSpan:new{ width = gap },
        _iconButton(Config.ICON.ko_search, icon_sz, tap_sz, "⌕", function() emit("file_search") end),
        HorizontalSpan:new{ width = gap },
        _iconButton(Config.ICON.ko_settings, icon_sz, tap_sz, "≡", function() emit("weui_settings") end),
    }

    local left_box = FrameContainer:new{
        bordersize   = 0,
        padding      = 0,
        padding_left = pad,
        left,
    }

    local right_w = 3 * tap_sz + 2 * gap
    right.overlap_offset = {
        math.max(0, w - right_w - pad),
        math.floor((header_h - tap_sz) / 2),
    }

    return OverlapGroup:new{
        dimen = Geom:new{ w = w, h = header_h },
        left_box,
        right,
    }
end

function M.getHeight(ctx)
    local scale = Config.getModuleScale(M.id, ctx and ctx.pfx)
    return math.max(1, math.floor(Screen:scaleBySize(62) * scale))
end

return M

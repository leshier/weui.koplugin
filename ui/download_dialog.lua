local Blitbuffer = require("ffi/blitbuffer")
local ButtonTable = require("ui/widget/buttontable")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local InputContainer = require("ui/widget/container/inputcontainer")
local ProgressWidget = require("ui/widget/progresswidget")
local TextBoxWidget = require("ui/widget/textboxwidget")
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local time = require("ui/time")
local Screen = Device.screen

local DownloadDialog = InputContainer:extend{
    title = "",
    subtitle = "",
    progress_max = 100,
    buttons = nil,
    -- Repaint throttle for the progress bar / subtitle. Repaints only flush
    -- between download steps (when the single UI thread yields), so a tight
    -- throttle stays cheap and keeps the latest log line fresh.
    refresh_time_seconds = 1,
    -- Fixed subtitle height in number of lines, so the dialog doesn't resize.
    -- Only the latest log line is shown (history is discarded), so a couple of
    -- lines is enough: one for status/progress, one for the latest log.
    subtitle_lines = 3,
}

function DownloadDialog:init()
    self.dimen = Screen:getSize()
    self.last_redraw_time_ms = 0

    local width = Screen:getWidth() - Screen:scaleBySize(80)

    local vertical_group = VerticalGroup:new{}
    self.vertical_group = vertical_group

    self.title_widget = TextWidget:new{
        text = self.title or "",
        face = Font:getFace("ffont"),
        bold = true,
        max_width = width,
    }
    local title_height = self.title_widget:getSize().h
    self.title_container = CenterContainer:new{
        dimen = Geom:new{
            w = width,
            h = title_height,
        },
        self.title_widget,
    }
    table.insert(vertical_group, self.title_container)

    -- Use a fixed-height TextBoxWidget for the subtitle. The caller passes only
    -- the latest log line (previous logs are discarded), so there is no scrollbar
    -- and no scrolling/relayout overhead - just a cheap setText on update.
    local _measure_tb = TextBoxWidget:new{
        text = "Tg",
        face = Font:getFace("cfont"),
        width = width,
        for_measurement_only = true,
    }
    local line_height = _measure_tb:getLineHeight()
    _measure_tb:free()
    local subtitle_height = line_height * self.subtitle_lines
    self.subtitle_widget = TextBoxWidget:new{
        text = self.subtitle or "",
        face = Font:getFace("cfont"),
        width = width,
        height = subtitle_height,
        alignment = "left",
    }
    table.insert(vertical_group, VerticalSpan:new{ width = Size.padding.small })
    table.insert(vertical_group, self.subtitle_widget)

    if self.progress_max and self.progress_max > 0 then
        self.progress_bar = ProgressWidget:new{
            fillcolor = Blitbuffer.COLOR_BLACK,
            width = width,
            height = Screen:scaleBySize(18),
            padding = Size.padding.large,
            margin = Size.margin.tiny,
            percentage = 0,
        }
        table.insert(vertical_group, VerticalSpan:new{ width = Size.padding.small })
        table.insert(vertical_group, self.progress_bar)
    end

    if self.buttons then
        local button_table = ButtonTable:new{
            width = width,
            buttons = self.buttons,
            zero_sep = true,
            show_parent = self,
        }
        table.insert(vertical_group, VerticalSpan:new{ width = Size.padding.large })
        table.insert(vertical_group, button_table)
    end

    self[1] = CenterContainer:new{
        dimen = Screen:getSize(),
        FrameContainer:new{
            radius = Size.radius.window,
            bordersize = Size.border.window,
            padding = Size.padding.large,
            padding_bottom = self.buttons and 0 or nil,
            background = Blitbuffer.COLOR_WHITE,
            vertical_group,
        },
    }
end

function DownloadDialog:reportProgress(progress, force)
    if not self.progress_bar then return end
    self.progress_bar:setPercentage(progress / self.progress_max)
    local now = time.now()
    local elapsed = now - self.last_redraw_time_ms
    if force or self.progress_bar.percentage >= 1 or elapsed >= self.refresh_time_seconds * 1000 * 1000 then
        self.last_redraw_time_ms = now
        UIManager:setDirty(self, "ui")
        UIManager:forceRePaint()
    end
end

function DownloadDialog:setTitle(title)
    self.title = title or ""
    if self.title_widget and self.title_widget.setText then
        self.title_widget:setText(self.title)
    end
end

function DownloadDialog:setSubtitle(subtitle, force)
    self.subtitle = subtitle or ""
    local tw = self.subtitle_widget
    if not (tw and tw.setText) then return end
    -- Throttle the relayout. setSubtitle is called once per chapter during
    -- downloads; TextBoxWidget:setText early-returns when the text is unchanged,
    -- but the progress percent changes each call, so we still throttle to avoid
    -- piling up relayouts on the (single-threaded) UI thread.
    local now = time.now()
    if not force and self._last_subtitle_update
            and (now - self._last_subtitle_update) < time.ms(500) then
        return
    end
    self._last_subtitle_update = now
    tw:setText(self.subtitle)
end

function DownloadDialog:show()
    UIManager:show(self, "ui")
end

function DownloadDialog:close()
    UIManager:close(self, "ui")
end

return DownloadDialog

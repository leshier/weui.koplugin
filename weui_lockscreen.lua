-- Custom content inside KOReader's native screensaver lifecycle.
local Store = require("weui_store")
local M = {}
local KEY = "weui_lockscreen_mode"
M.modes = {
    { id = "native", label = "跟随 KOReader 设置" },
    { id = "recent", label = "最近阅读" },
    { id = "stats", label = "阅读统计" },
    { id = "calendar", label = "简洁日历" },
}
function M.getMode()
    local value = Store:get(KEY)
    for _, mode in ipairs(M.modes) do if mode.id == value then return value end end
    return "native"
end
function M.getLabel()
    local value = M.getMode()
    for _, mode in ipairs(M.modes) do if mode.id == value then return mode.label end end
end
function M.setMode(value)
    for _, mode in ipairs(M.modes) do
        if mode.id == value then Store:set(KEY, value); return true end
    end
    return false
end
function M.preview(plugin)
    local mode = M.getMode()
    if mode == "native" then
        require("ui/uimanager"):show(require("ui/widget/infomessage"):new{
            text = "当前跟随 KOReader 锁屏设置。选择一种自定义样式后即可预览。", timeout = 3,
        })
        return
    end
    local widget = require("weui_paper").newLockscreen(mode, plugin)
    widget:enablePreview()
    require("ui/uimanager"):show(widget, "full")
    return widget
end

local installed, original_setup, original_show, original_cleanup, setup_wrapper, show_wrapper, cleanup_wrapper
function M.install()
    local Screensaver = require("ui/screensaver")
    if installed then return end
    original_setup, original_show, original_cleanup = Screensaver.setup, Screensaver.show, Screensaver.cleanup
    setup_wrapper = function(self, event, ...)
        original_setup(self, event, ...)
        self._weui_snapshot_mode = nil
        local mode = M.getMode()
        -- Keep reboot/poweroff messages and their explicitly selected modes.
        if mode ~= "native" and not event and self.ui then
            self._weui_snapshot_mode = mode
            -- Native readingprogress already supports both orientations,
            -- white backgrounds, gesture locks, extra flashes and delayed exit.
            self.screensaver_type, self.screensaver_background = "readingprogress", "white"
            self.show_message = false
        end
    end
    show_wrapper = function(self, ...)
        if not self._weui_snapshot_mode or not self.ui then return original_show(self, ...) end
        local ui = self.ui
        local plugin = ui._weui_plugin
        local snapshot = require("weui_paper").newLockscreen(self._weui_snapshot_mode, plugin)
        local facade = setmetatable({ statistics = {
            onShowReaderProgress = function() return snapshot end,
        } }, { __index = ui })
        self.ui = facade
        local args, count = { ... }, select("#", ...)
        local ok, result = xpcall(function()
            return original_show(self, unpack(args, 1, count))
        end, debug.traceback)
        self.ui = ui
        if self.screensaver_lock_widget then self.screensaver_lock_widget.ui = ui end
        if not ok then snapshot:free(); error(result, 0) end
        return result
    end
    cleanup_wrapper = function(self, ...)
        self._weui_snapshot_mode = nil
        return original_cleanup(self, ...)
    end
    Screensaver.setup, Screensaver.show, Screensaver.cleanup = setup_wrapper, show_wrapper, cleanup_wrapper
    installed = Screensaver
end
function M.uninstall()
    if not installed then return end
    if installed.setup == setup_wrapper then installed.setup = original_setup end
    if installed.show == show_wrapper then installed.show = original_show end
    if installed.cleanup == cleanup_wrapper then installed.cleanup = original_cleanup end
    installed._weui_snapshot_mode = nil
    installed = nil
end
return M

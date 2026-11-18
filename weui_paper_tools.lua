-- Paper settings pages keep their parent tab and use native centered editors.
local UIManager = require("ui/uimanager")
local Device = require("device")
local _ = require("weui_i18n").translate
local M = {}
local dir = debug.getinfo(1, "S").source:match("^@(.+/)[^/]+$")

function M.apply(Page)
    function Page:showTool(screen)
        self.tool_stack = nil
        self.screen = screen
        self:rebuild()
    end

    function Page:toolBack()
        if self.tool_stack and #self.tool_stack > 0 then
            table.remove(self.tool_stack)
            self:rebuild()
        else
            self.screen = self.tab
            self:rebuild()
        end
    end

    function Page:toolHeader(title, subtitle)
        self:text("‹ 返回" .. (self.tool_stack and #self.tool_stack > 0 and "系统更新" or "更多"), 28, 44, 320, 11)
        self:hit(28, 30, 200, 42, function() self:toolBack() end)
        self:text(title, 28, 92, 480, 33, { font = "song" })
        self:text(subtitle, 28, 140, 480, 11)
    end

    function Page:toolMenu(items, y, height)
        for i, item in ipairs(items) do
            local entry = item
            local enabled = not entry.enabled_func or entry.enabled_func()
            local label = entry.text_func and entry.text_func() or entry.text
            local checked = entry.checked_func and entry.checked_func()
            self:row(nil, label, entry.meta or (checked and "✓" or ""), y + (i - 1) * height, function()
                if not enabled then return end
                if entry.sub_item_table or entry.sub_item_table_func then
                    self.tool_stack = self.tool_stack or {}
                    self.tool_stack[#self.tool_stack + 1] = {
                        title = label, items = entry.sub_item_table or entry.sub_item_table_func(),
                    }
                    self:rebuild()
                elseif entry.callback then
                    entry.callback()
                    if not self._closed then self:rebuild() end
                end
            end, height)
        end
    end

    function Page:proxySettings()
        local Proxy = require("weui_zlibrary_proxy")
        self:toolHeader("Z-Library 代理", "SOCKS5 · 由代理解析目标域名")
        self:text("开启后，Z-Library 的所有请求经过代理。\n连接失败会中止请求。", 28, 183, 480, 12, { h = 44 })
        self:toolMenu(Proxy.getMenuItems(function()
            if not self._closed then self:rebuild() end
        end), 250, 52)
    end

    function Page:lockscreenSettings()
        local Lock = require("weui_lockscreen")
        self:toolHeader("自定义锁屏", "选择休眠时显示的纸页")
        self:text("休眠时保留静态画面，唤醒后返回原页面。\n私密书籍的名称和封面始终隐藏。", 28, 183, 480, 12, { h = 44 })
        local entries = {}
        for _, mode in ipairs(Lock.modes) do
            local id = mode.id
            entries[#entries + 1] = {
                text = mode.label, checked_func = function() return Lock.getMode() == id end,
                callback = function() Lock.setMode(id) end,
            }
        end
        entries[#entries + 1] = { text = "预览锁屏", callback = function()
            Lock.preview(self.plugin)
        end }
        self:toolMenu(entries, 265, 57)
        self:text("自定义内容在休眠时生成，不在休眠中联网或刷新。", 28, 591, 480, 10)
    end

    function Page:updateInput(title, value, save)
        local dialog
        dialog = require("ui/widget/inputdialog"):new{
            title = title, input = value or "", description = "留空使用默认地址。",
            buttons = { {
                { text = _("Cancel"), callback = function() UIManager:close(dialog) end },
                { text = _("Save"), is_enter_default = true, callback = function()
                    save(dialog:getInputText())
                    UIManager:close(dialog)
                    if not self._closed then self:rebuild() end
                end },
            } },
        }
        UIManager:show(dialog); dialog:onShowKeyboard()
    end

    function Page:systemUpdates()
        local Updater = require("weui_updater")
        local OTA = require("ui/otamanager")
        local nested = self.tool_stack and self.tool_stack[#self.tool_stack]
        self:toolHeader(nested and nested.title or "系统更新", "KOReader 与 WeUI 的版本和更新")
        if nested then
            self:toolMenu(nested.items, 200, 56)
            return
        end
        local version = require("version"):getCurrentRevision()
        self:text("KOReader  " .. tostring(version), 28, 184, 480, 13)
        self:text("WeUI  " .. tostring(dofile(dir .. "_meta.lua").version), 28, 218, 480, 13)
        local supported = Device:hasOTAUpdates()
        local entries = {
            { text = "检查 WeUI 更新", callback = function() Updater.checkForUpdates() end },
            { text = "检查 KOReader 更新", meta = supported and "" or "本设备不支持",
                callback = function()
                    if supported then OTA:fetchAndProcessUpdate()
                    else UIManager:show(require("ui/widget/infomessage"):new{
                        text = "此设备不支持 KOReader 在线更新。请使用对应设备的安装包更新。", timeout = 4,
                    }) end
                end },
            { text = "KOReader 更新频道", meta = OTA:getOTAChannel(), sub_item_table = OTA:genChannelList() },
            { text = "KOReader 更新服务器", sub_item_table = OTA:genServerList() },
            { text = "WeUI 更新地址", meta = Updater.getCustomApiUrl() ~= "" and "自定义" or "默认",
                callback = function() self:updateInput("WeUI 更新地址", Updater.getCustomApiUrl(), Updater.setCustomApiUrl) end },
            { text = "WeUI 更新使用 Z-Library 代理", checked_func = Updater.getUseZlibraryProxy,
                callback = function() Updater.setUseZlibraryProxy(not Updater.getUseZlibraryProxy()) end },
        }
        self:toolMenu(entries, 280, 53)
        self:text("检查后可查看更新说明，再选择是否安装。", 28, 624, 480, 10)
    end
end

return M

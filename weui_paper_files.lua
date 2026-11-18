-- A file browser drawn with the same paper primitives as the bookshelf.
local Device = require("device")
local Screen = Device.screen
local BB = require("ffi/blitbuffer")
local Geom = require("ui/geometry")
local UIManager = require("ui/uimanager")
local Config = require("weui_config")
local Registry = require("document/documentregistry")
local Library = require("weui_library")
local lfs = require("libs/libkoreader-lfs")
local ffiUtil = require("ffi/util")
local M = {}
local sub, rule = BB.gray(0.66), BB.gray(0.28)

function M.extend(Page, Paper)
    local Picker = Page:extend{ _weui_paper_files = true }

    function Picker:init()
        self.state = { page = 1, query = "" }
        self.path = ffiUtil.realpath(self.path or "") or self.path
        if lfs.attributes(self.path or "", "mode") ~= "directory" then
            self.path = G_reader_settings:readSetting("home_dir") or Device.home_dir or "/"
        end
        self.path_history = {}
        Page.init(self)
    end

    function Picker:changePath(path)
        if lfs.attributes(path, "mode") ~= "directory" then return end
        self.path_history[#self.path_history + 1] = { path = self.path, page = self.state.page }
        self.path, self.state.page = ffiUtil.realpath(path) or path, 1
        self:rebuild()
    end

    function Picker:back()
        local previous = table.remove(self.path_history)
        if previous then
            self.path, self.state.page = previous.path, previous.page
            self:rebuild()
            return true
        end
        return self:dismiss()
    end

    function Picker:dismiss()
        self._navbar_closing_intentionally = true
        UIManager:close(self, "ui")
        local origin = self.origin_page
        if origin and not origin._closed then
            Paper._instance = origin
            self.plugin.active_action = origin.tab
            origin:rebuild(true)
        end
        return true
    end
    Picker.onClose = Picker.back

    function Picker:choose(entry)
        if entry.directory then return self:changePath(entry.path) end
        if self.mode == "read" then return require("weui_privacy").openBook(entry.path) end
        local imported, err = Library.import(entry.path)
        if imported then
            Paper.navigate(self.plugin, "home")
            UIManager:show(require("ui/widget/infomessage"):new{ text = "已添加到书架。", timeout = 3 })
        else
            UIManager:show(require("ui/widget/infomessage"):new{ text = err, timeout = 3 })
            self:rebuild()
        end
    end

    function Picker:rebuild()
        self:freeItems()
        self.scale = math.min(Screen:getWidth() / 536, Screen:getHeight() / 724)
        self.logical_h = Screen:getHeight() / self.scale
        self.offset = math.floor((Screen:getWidth() - self:px(536)) / 2)
        self.body_bottom = self.logical_h - 76
        self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
        self.items, self.hits, self.entries = {}, {}, {}
        self:text(os.date("%H:%M"), 28, 10, 150, 11)
        local back = #self.path_history > 0 and "‹ 返回上个目录" or "‹ 返回书籍来源"
        if self.mode == "read" and #self.path_history == 0 then back = "‹ 返回更多" end
        self:text(back, 28, 44, 280, 11, { color = sub })
        self:hit(28, 30, 280, 42, function() self:back() end)
        self:text("取消", 438, 44, 70, 11, { align = "right", color = sub })
        self:hit(432, 30, 76, 42, function() self:dismiss() end)
        self:text(self.mode == "read" and "下载目录" or "本地导入", 28, 92, 480, 33, { font = "song" })
        self:text(self.mode == "read" and "点击书籍开始阅读" or "点击文件，将它添加到书架", 28, 140, 480, 11, { color = sub })
        self:text(self.path, 28, 184, 396, 11, { color = sub })
        local parent = self.path:match("^(.*)/[^/]+$") or "/"
        if parent == "" then parent = "/" end
        self:text("上一级 ›", 422, 184, 86, 11, { color = self.path == "/" and rule or sub, align = "right" })
        self:hit(416, 172, 92, 42, function() if self.path ~= "/" then self:changePath(parent) end end)
        self:line(218)
        local ok = pcall(function()
            for name in lfs.dir(self.path) do
                if name:sub(1, 1) ~= "." and name:sub(-4) ~= ".sdr" then
                    local path = self.path .. (self.path == "/" and "" or "/") .. name
                    local mode = lfs.attributes(path, "mode")
                    if mode == "directory" or mode == "file" and Registry:hasProvider(path) then
                        self.entries[#self.entries + 1] = { label = name, path = path, directory = mode == "directory" }
                    end
                end
            end
        end)
        if not ok then self.entries = {} end
        table.sort(self.entries, function(a, b)
            if a.directory ~= b.directory then return a.directory end
            return a.label < b.label
        end)
        local per_page = math.max(1, math.floor((self.body_bottom - 40 - 236) / 58))
        self:pager(#self.entries, per_page)
        if #self.entries == 0 then
            self:empty(ok and "这个目录还没有书籍" or "无法读取这个目录",
                "可返回上一级目录，或取消后重新选择。", 288)
        end
        local first = (self.state.page - 1) * per_page + 1
        for i = 1, per_page do
            local entry = self.entries[first + i - 1]
            if entry then
                local y = 236 + (i - 1) * 58
                self:icon(entry.directory and Config.ICON.weread_folder or Config.ICON.weread_book, 28, y + 14, 23)
                self:text(entry.label, 66, y + 17, 344, 13)
                self:text(entry.directory and "打开 ›" or self.mode == "read" and "阅读 ›" or "导入 ›",
                    422, y + 19, 86, 10, { align = "right", color = sub })
                self:line(y + 56)
                self:hit(28, y, 480, 58, function() self:choose(entry) end)
            end
        end
        self:navbar()
        UIManager:setDirty(self, "ui")
    end
    return Picker
end

return M

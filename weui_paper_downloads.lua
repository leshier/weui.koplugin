-- Persistent WeRead task history, with actions and a bounded visible refresh.
local UIManager = require("ui/uimanager")
local Refresh = require("weui_refresh")
local BB = require("ffi/blitbuffer")
local Config = require("weui_config")
local lfs = require("libs/libkoreader-lfs")
local ink, sub, rule = BB.gray(0.91), BB.gray(0.66), BB.gray(0.28)
local labels = { queued = "等待下载", running = "正在下载", done = "已完成",
    failed = "失败 · 可重试", cancelled = "已取消", interrupted = "已中断 · 可继续" }
local M = {}

local function taskList(page, wr)
    local filtered, active_count = {}, 0
    local tasks = wr and wr.downloader and wr.downloader:getTasks() or {}
    for _, task in ipairs(tasks) do
        local active = task.status == "queued" or task.status == "running"
        if active then active_count = active_count + 1 end
        local key = active and "active" or task.status == "done" and "done" or "stopped"
        if page.state.download_filter == "all" or page.state.download_filter == key then
            filtered[#filtered + 1] = task
        end
    end
    return filtered, active_count
end

local function taskRatio(task)
    return math.max(0, math.min(1, (tonumber(task.progress) or 0) / math.max(1, tonumber(task.total) or 1)))
end

local function visibleState(page, tasks)
    local pages = math.max(1, math.ceil(#tasks / 4))
    local current = math.min(page.state.download_page or 1, pages)
    local out = { tostring(current), tostring(pages) }
    for i = 1, 4 do
        local task = tasks[(current - 1) * 4 + i]
        if task then
            for _, value in ipairs({ task.id or "", task.title or "微信读书", task.status or "",
                    string.format("%.0f%%", taskRatio(task) * 100), tostring(page:px(480 * taskRatio(task))) }) do
                value = tostring(value)
                out[#out + 1] = #value .. ":" .. value
            end
        end
    end
    return table.concat(out, "|")
end

function M.apply(Page, Paper)
    function Page:scheduleDownloadRefresh(wr)
        if self._download_timer then UIManager:unschedule(self._download_timer) end
        local function poll()
            self._download_timer = nil
            if self._closed or self.screen ~= "downloads" then return end
            if not Refresh.awake(self.plugin) then return end -- onResume restarts it
            local tasks, active_count = taskList(self, wr)
            if Paper._instance == self and Refresh.top(self)
                    and visibleState(self, tasks) ~= self._download_visible_state then
                self:rebuild()
            elseif active_count > 0 or not Refresh.top(self) then
                self._download_timer = poll
                UIManager:scheduleIn(2, poll)
            end
        end
        self._download_timer = poll
        UIManager:scheduleIn(2, poll)
    end

    function Page:downloadNextPage(delta)
        self.state.download_page = math.max(1, math.min((self.state.download_page or 1) + delta, self.download_pages or 1))
        self:rebuild()
        return true
    end

    function Page:downloadActions(wr, task)
        local dialog
        local buttons = {}
        if task.status == "queued" or task.status == "running" then
            buttons[#buttons + 1] = { { text = "取消下载", callback = function()
                UIManager:close(dialog); wr.downloader:cancelTask(task); self:rebuild()
            end } }
        elseif task.request then
            buttons[#buttons + 1] = { { text = "继续 / 重试下载", callback = function()
                UIManager:close(dialog); wr.downloader:retryTask(task); self:rebuild()
            end } }
        end
        if task.output_path and lfs.attributes(task.output_path, "mode") == "file" then
            buttons[#buttons + 1] = { { text = "开始阅读", callback = function()
                UIManager:close(dialog); wr:openFile(task.output_path)
            end } }
        end
        buttons[#buttons + 1] = { { text = "关闭", callback = function() UIManager:close(dialog) end } }
        dialog = require("ui/widget/buttondialog"):new{
            title = (task.title or "微信读书") .. "\n" .. (labels[task.status] or "") .. "\n" .. (task.stage or ""),
            buttons = buttons,
        }
        UIManager:show(dialog)
    end

    function Page:downloadManager()
        if self._download_timer then UIManager:unschedule(self._download_timer); self._download_timer = nil end
        self.state.download_filter = self.state.download_filter or "all"
        local wr = self.plugin._weread_plugin or self.plugin:_initWeReadModule()
        self:toolHeader("下载管理", "微信读书任务自动保存，重启后可继续")
        local filters = { { "all", "全部" }, { "active", "下载中" }, { "done", "已完成" }, { "stopped", "已停止" } }
        local filtered, active_count = taskList(self, wr)
        self._download_visible_state = visibleState(self, filtered)
        for i, entry in ipairs(filters) do
            local id, x = entry[1], 28 + (i - 1) * 120
            self:text(entry[2], x, 180, 120, 12, { align = "center", bold = self.state.download_filter == id })
            if self.state.download_filter == id then self:rect(x + 18, 205, 84, 2, ink) end
            self:hit(x, 167, 120, 43, function()
                self.state.download_filter, self.state.download_page = id, 1; self:rebuild()
            end)
        end
        self.download_pages = math.max(1, math.ceil(#filtered / 4))
        self.state.download_page = math.min(self.state.download_page or 1, self.download_pages)
        for i = 1, 4 do
            local task = filtered[(self.state.download_page - 1) * 4 + i]
            if task then
                local y = 224 + (i - 1) * 73
                local ratio = taskRatio(task)
                self:text(task.title or "微信读书", 28, y, 480, 15, { font = "song" })
                self:text(labels[task.status] or task.status, 28, y + 29, 340, 10, { color = sub })
                self:text(string.format("%.0f%%", ratio * 100), 388, y + 29, 120, 10, { align = "right", color = sub })
                self:rect(28, y + 53, 480, 3, rule)
                if ratio > 0 then self:rect(28, y + 53, 480 * ratio, 3, ink) end
                self:hit(28, y - 3, 480, 66, function() self:downloadActions(wr, task) end)
            end
        end
        if #filtered == 0 then
            self:text("暂无下载任务", 28, 266, 480, 20, { font = "song", align = "center" })
            self:text("从微信读书的书籍详情选择下载，任务会显示在这里。", 28, 308, 480, 12, { h = 42, color = sub })
        end
        self:text("‹", 166, 520, 48, 23, { align = "center" })
        self:text(self.state.download_page .. " / " .. self.download_pages, 226, 528, 84, 11, { align = "center" })
        self:text("›", 322, 520, 48, 23, { align = "center" })
        self:hit(166, 515, 48, 43, function() self:downloadNextPage(-1) end)
        self:hit(322, 515, 48, 43, function() self:downloadNextPage(1) end)
        self:row(Config.ICON.weread_trash, "清除已结束任务", "保留书籍文件", 556, function()
            if wr then wr.downloader:clearFinishedTasks(); self:rebuild() end
        end, 40)
        self:button("微信读书离线缓存", 28, 600, 232, function() require("ui/offline_manager").show() end)
        self:button("Z-Library 下载目录", 276, 600, 232, function()
            Paper.showFilePicker(self, "read", require("zlibrary.config").getDownloadDir())
        end)
        if active_count > 0 then
            self:scheduleDownloadRefresh(wr)
        end
    end
end

return M

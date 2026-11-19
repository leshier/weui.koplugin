-- The task UI remains stable while the download engine owns checkpoints,
-- subprocess cancellation, footnotes and streamed assets.
local Legacy = require("lib.downloader")
local Engine = require("weread.lib.downloader")
local UIManager = require("ui/uimanager")
local Content = require("weread.lib.content")
local Adapter = setmetatable({}, { __index = Legacy })
Adapter.__index = Adapter
local terminal = { done = true, failed = true, cancelled = true, interrupted = true }
local function copy(value)
    if type(value) ~= "table" then return value end
    local out = {}
    for key, item in pairs(value) do out[key] = copy(item) end
    return out
end

local function savedBook(book)
    return { book_id = book.book_id or book.bookId, title = book.title, author = book.author }
end

function Adapter:_saveTasks()
    if not self.settings then return end
    if self._task_save_timer then UIManager:unschedule(self._task_save_timer); self._task_save_timer = nil end
    local records = {}
    for _, task in ipairs(self:getTasks()) do
        if #records >= 50 then break end
        -- Never serialize the live job, callbacks, HTTP responses or auth data.
        local record = {}
        for _, key in ipairs({ "id", "kind", "title", "status", "progress", "total",
            "output_path", "started_at", "updated_at", "request" }) do record[key] = copy(task[key]) end
        records[#records + 1] = record
    end
    self.settings:set("download_tasks", records)
    self.settings:flush()
end

function Adapter:_restoreTasks()
    if not self.settings then return end
    for i, saved in ipairs(self.settings:get("download_tasks", {})) do
        if i > 50 then break end
        if type(saved) == "table" and type(saved.id) == "string" and not self.tasks[saved.id] then
            local task = copy(saved)
            if task.status == "running" or task.status == "queued" then task.status = "interrupted" end
            task.hidden, task.cancelled = true, task.status == "cancelled"
            task.logs = {}
            task.stage = task.status == "interrupted" and "上次下载中断，可继续下载" or ""
            self.tasks[task.id] = task
            self.task_order[#self.task_order + 1] = task.id
            self._next_task_id = math.max(self._next_task_id, tonumber(task.id:match("%-(%d+)$")) or 0)
        end
    end
    self:_trimFinishedTasks()
end

function Adapter:_newTask(...)
    local task = Legacy._newTask(self, ...)
    self:_saveTasks()
    return task
end

function Adapter:_updateTask(task, fields)
    local old_status = task and task.status
    Legacy._updateTask(self, task, fields)
    if not self.settings or not task then return end
    if old_status ~= task.status or terminal[task.status] then self:_saveTasks()
    elseif not self._task_save_timer then
        self._task_save_timer = function() self._task_save_timer = nil; self:_saveTasks() end
        UIManager:scheduleIn(1, self._task_save_timer)
    end
end

function Adapter:_trimFinishedTasks()
    local kept = 0
    for i = 1, #self.task_order do
        local task = self.tasks[self.task_order[i]]
        if task and terminal[task.status] then
            kept = kept + 1
            if kept > self.MAX_FINISHED_TASKS then
                if task.dialog then task.dialog:close() end
                self.tasks[task.id] = nil
            end
        end
    end
    for i = #self.task_order, 1, -1 do
        if not self.tasks[self.task_order[i]] then table.remove(self.task_order, i) end
    end
    self:_saveTasks()
end

function Adapter:clearFinishedTasks()
    for i = #self.task_order, 1, -1 do
        local task = self.tasks[self.task_order[i]]
        if task and terminal[task.status] then
            if task.dialog then task.dialog:close() end
            self.tasks[task.id] = nil
            table.remove(self.task_order, i)
        end
    end
    self:_saveTasks()
end

function Adapter:retryTask(task)
    if not task or not terminal[task.status] or not task.request or task._retry_pending then return false end
    local request = task.request
    if not self.require_login(true, false) then return false end
    task._retry_pending = true
    local scheduled = self.run_online_task("继续下载", function()
        local ok, result = pcall(function()
            local book = copy(request.book)
            if request.article then return self:startMPArticle(book, copy(request.article)) end
            local catalog = Content.fetch_catalog(self.client, book)
            local selected, wanted = {}, {}
            for _, uid in ipairs(request.chapter_uids or {}) do wanted[tostring(uid)] = true end
            for _, chapter in ipairs(catalog) do
                if wanted[tostring(chapter.chapterUid)] then selected[#selected + 1] = chapter end
            end
            if #selected ~= #(request.chapter_uids or {}) then error("章节目录已变化，请在书籍详情重新选择下载。", 0) end
            local options = copy(request.options or {})
            options.foreground = false
            return self:start(book, selected, request.suffix, options)
        end)
        task._retry_pending = nil
        if not ok then self.show_info("继续下载失败：" .. tostring(result)) end
    end)
    if scheduled == false then task._retry_pending = nil end
    return scheduled ~= false
end

function Adapter:new(options)
    local object = Legacy.new(self, options)
    object.queue = {}
    local core_options = {}
    for key, value in pairs(options) do core_options[key] = value end
    object.engine = Engine:new(core_options)
    object:_restoreTasks()
    -- A progress proxy exposes cancellation to Trapper and paints the same
    -- paper task sheet as the rest of WeUI.
    function object.engine:_ensureProgressDialog(job)
        if job.progress_dialog then return job.progress_dialog end
        local task = object.current_task
        if not task then return Engine._ensureProgressDialog(self, job) end
        task.dl = job
        local proxy = { progress_max = job.total }
        function proxy:setTitle(title)
            object:_updateTask(task, { stage = title })
        end
        function proxy:reportProgress(progress)
            object:_updateTask(task, { progress = progress })
        end
        function proxy:show() end
        function proxy:close() end
        job.progress_dialog = proxy
        object:_updateTask(task, { status = "running", stage = job.stage_title or "准备下载" })
        return proxy
    end
    return object
end

function Adapter:recover() return self.engine:recover() end
function Adapter:getActivePrefetch() return self.engine:getActivePrefetch() end
function Adapter:isPrefetching(...) return self.engine:isPrefetching(...) end
function Adapter:isPromotedPrefetch(...) return self.engine:isPromotedPrefetch(...) end
function Adapter:promotePrefetch(book, chapter)
    local job = self.engine:getActivePrefetch()
    if self.current_task or not self.engine:isPrefetching(book, chapter) then return false end
    local task = self:_newTask("chapter", chapter.title or book.title, job.total)
    task.request = { book = savedBook(book), chapter_uids = { chapter.chapterUid },
        suffix = tostring(chapter.chapterUid), options = { single_chapter = true } }
    self:_saveTasks()
    task.foreground, task.hidden = true, false
    self.current_task = task
    local previous = job.on_complete
    job.on_complete = function(ok, value)
        if previous then
            local called, err = pcall(previous, ok, value)
            if not called then require("logger").warn("WeRead prefetch callback:", tostring(err)) end
        end
        if not task.cancelled then
            self:_updateTask(task, { status = ok and "done" or "failed",
                stage = ok and "下载完成" or "下载失败，可重新下载以继续",
                progress = ok and task.total or task.progress,
                output_path = ok and value or nil, error = not ok and tostring(value) or nil })
        end
        self.current_task = nil
        UIManager:scheduleIn(0.1, function() self:_drain() end)
    end
    self:showTask(task)
    return self.engine:promotePrefetch(book, chapter)
end
function Adapter:cancelPrefetch(...) return self.engine:cancelPrefetch(...) end

function Adapter:_drain()
    if self._shutting_down then return end
    if self.current_task then return end
    local request = table.remove(self.queue, 1)
    if not request then return end
    local task = request.task
    if task.cancelled then return self:_drain() end
    self.current_task = task
    local function complete(ok, value)
        if task.status ~= "cancelled" then
            self:_updateTask(task, {
                status = ok and "done" or "failed",
                stage = ok and "下载完成" or "下载失败，可重新下载以继续",
                progress = ok and task.total or task.progress,
                output_path = ok and value or nil,
                error = not ok and tostring(value):match("^[^\r\n]*") or nil,
            })
        end
        self.current_task = nil
        self:_trimFinishedTasks()
        if request.options.on_complete then
            local called, err = pcall(request.options.on_complete, ok, value)
            if not called then require("logger").warn("WeRead completion callback:", tostring(err)) end
        end
        UIManager:scheduleIn(0.1, function() self:_drain() end)
    end
    if request.article then
        self:_updateTask(task, { status = "running", stage = "下载公众号文章" })
        local scheduled = self.run_online_task("下载公众号文章", function()
            if task.cancelled then complete(false, "cancelled"); return end
            local ok, path = pcall(Content.fetch_mp_article_html, self.client, self.settings,
                request.book, request.article, {
                    progress = function(current, total)
                        if task.cancelled then error("cancelled", 0) end
                        self:_updateTask(task, { progress = current, total = total, stage = "下载文章图片" })
                    end,
                })
            if task.cancelled then complete(false, "cancelled"); return end
            if ok then
                local books = self.settings:get("books", {})
                local id = request.book.book_id or request.book.bookId
                local record = books[id] or request.book
                record.cache_dir = request.book.cache_dir
                books[id] = record
                self.settings:set("books", books); self.settings:flush()
                self.refresh_shelf()
            end
            complete(ok, path)
        end)
        if scheduled == false then complete(false, "offline") end
        return
    end
    local options = {}
    for key, value in pairs(request.options) do options[key] = value end
    options.on_complete = complete
    options.silent_completion = true
    local ok, started = pcall(self.engine.start, self.engine,
        request.book, request.chapters, request.suffix, options)
    if not ok then complete(false, started)
    elseif started == false and self.current_task == task then complete(false, "download_not_started") end
end

function Adapter:start(book, chapters, suffix, options)
    options = options or {}
    if options.prefetch then
        if self.current_task or #self.queue > 0 then return false end
        return self.engine:start(book, chapters, suffix, options)
    end
    if not self.require_login(true, false) or #chapters == 0 then return false end
    self:cancelPrefetch("manual_download")
    local task = self:_newTask(options.single_chapter and "chapter" or "book", book.title, #chapters)
    local uids = {}
    for _, chapter in ipairs(chapters) do uids[#uids + 1] = chapter.chapterUid end
    task.request = { book = savedBook(book), chapter_uids = uids, suffix = suffix,
        options = { single_chapter = options.single_chapter, separate_chapters = options.separate_chapters } }
    self:_saveTasks()
    task.foreground = options.foreground ~= false
    self.queue[#self.queue + 1] = {
        task = task, book = book, chapters = chapters, suffix = suffix, options = options,
    }
    if task.foreground then task.hidden = false; self:showTask(task) end
    self:_drain()
    return task
end

function Adapter:startMPArticle(book, article)
    if not self.require_login(true, false) then return false end
    local task = self:_newTask("article", article.title, 1)
    task.request = { book = savedBook(book), article = {} }
    for _, key in ipairs({ "title", "bookId", "reviewId", "reviewIds", "originalId" }) do
        task.request.article[key] = copy(article[key])
    end
    self:_saveTasks()
    self.queue[#self.queue + 1] = { task = task, book = book, article = article, options = {} }
    task.hidden = false; self:showTask(task)
    self:_drain()
    return task
end

function Adapter:cancelTask(task)
    if not task or (task.status ~= "queued" and task.status ~= "running") then return end
    local job = task.dl
    if job then
        job.cancelled, job.cancel_reason = true, "cancelled"
        local dismiss = job.progress_dialog and job.progress_dialog.dismiss_callback
        if dismiss then dismiss() end
        if job.prefetch then self.engine:cancelPrefetch("cancelled") end
    end
    Legacy.cancelTask(self, task)
    self:_saveTasks()
    self:_drain()
end

function Adapter:shutdown()
    -- Do not start another queued task while shutting the host down.
    self.queue = {}
    self._shutting_down = true
    for _, task in ipairs(self:getTasks()) do self:cancelTask(task) end
    self:cancelPrefetch("plugin_teardown")
    local job = self.engine._active_job
    if job then self.engine:_releaseStandby(job) end
    self:_saveTasks()
end

return Adapter

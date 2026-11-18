-- The task UI remains stable while the download engine owns checkpoints,
-- subprocess cancellation, footnotes and streamed assets.
local Legacy = require("lib.downloader")
local Engine = require("weread.lib.downloader")
local UIManager = require("ui/uimanager")
local Content = require("weread.lib.content")
local Adapter = setmetatable({}, { __index = Legacy })
Adapter.__index = Adapter

function Adapter:new(options)
    local object = Legacy.new(self, options)
    object.queue = {}
    local core_options = {}
    for key, value in pairs(options) do core_options[key] = value end
    object.engine = Engine:new(core_options)
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
    self:_drain()
end

function Adapter:shutdown()
    -- Do not start another queued task while shutting the host down.
    self.queue = {}
    for _, task in ipairs(self:getTasks()) do self:cancelTask(task) end
    self:cancelPrefetch("plugin_teardown")
    local job = self.engine._active_job
    if job then self.engine:_releaseStandby(job) end
end

return Adapter

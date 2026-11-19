-- Validate the host adapter rather than retesting upstream's download engine.
package.path = "./?.lua;" .. package.path
local scheduled, launches, shown = {}, {}, {}
package.preload["ui/uimanager"] = function()
    return { scheduleIn = function(_, _, fn) scheduled[#scheduled + 1] = fn end,
        unschedule = function(_, fn)
            for i = #scheduled, 1, -1 do if scheduled[i] == fn then table.remove(scheduled, i) end end
        end }
end
package.preload["logger"] = function() return { warn = function() end } end
package.preload["weread.lib.content"] = function()
    return { fetch_catalog = function() return { { chapterUid = 1 }, { chapterUid = 2 } } end }
end
local Legacy = { MAX_FINISHED_TASKS = 20 }
function Legacy:new(options)
    options.tasks = {}
    options.task_order, options._next_task_id = {}, 0
    return setmetatable(options, self)
end
function Legacy:_newTask(kind, title, total)
    self._next_task_id = self._next_task_id + 1
    local task = { id = "test-" .. self._next_task_id, kind = kind, title = title, total = total, status = "queued" }
    self.tasks[task.id] = task
    table.insert(self.task_order, 1, task.id)
    return task
end
function Legacy:getTasks()
    local result = {}
    for _, id in ipairs(self.task_order) do result[#result + 1] = self.tasks[id] end
    return result
end
function Legacy:getActiveCount()
    local count = 0
    for _, task in pairs(self.tasks) do
        if task.status == "running" or task.status == "queued" then count = count + 1 end
    end
    return count
end
function Legacy:_updateTask(task, fields)
    for key, value in pairs(fields) do task[key] = value end
    if task.status == "done" or task.status == "failed" then task.dl = nil end
end
function Legacy:showTask(task) shown[#shown + 1] = task end
function Legacy:_trimFinishedTasks() end
function Legacy:cancelTask(task) task.cancelled = true; task.status = "cancelled" end
package.preload["lib.downloader"] = function() return Legacy end
local Engine = {}
function Engine:new(options) return setmetatable(options, { __index = self }) end
function Engine:cancelPrefetch() self.prefetch_cancelled = true end
function Engine:getActivePrefetch() return self.prefetch_job end
function Engine:isPrefetching(book, chapter)
    return self.prefetch_job and self.prefetch_job.book == book and self.prefetch_job.chapters[1] == chapter
end
function Engine:promotePrefetch()
    self.prefetch_job.promoted = true
    self:_ensureProgressDialog(self.prefetch_job)
    return true
end
function Engine:start(book, chapters, suffix, options)
    launches[#launches + 1] = { book = book, chapters = chapters, suffix = suffix, options = options }
    local job = { total = #chapters, stage_title = "Downloading" }
    self:_ensureProgressDialog(job)
    launches[#launches].job = job
    return true
end
package.preload["weread.lib.downloader"] = function() return Engine end
local adapter = require("lib.weread_downloader"):new{ require_login = function() return true end }
local first = adapter:start({ title = "first" }, { { chapterUid = 1 } }, "full")
local second = adapter:start({ title = "second" }, { { chapterUid = 2 } }, "chapter")
local third = adapter:start({ title = "third" }, { { chapterUid = 3 } }, "full")
assert(first.status == "running" and second.status == "queued" and #launches == 1)
assert(adapter.engine.prefetch_cancelled and #shown == 3)
launches[1].job.progress_dialog:reportProgress(1)
assert(first.progress == 1)
adapter:cancelTask(second)
assert(second.status == "cancelled" and #launches == 1)
launches[1].options.on_complete(true, "/tmp/first.epub")
assert(first.status == "done" and first.output_path == "/tmp/first.epub")
table.remove(scheduled, 1)()
assert(#launches == 2 and launches[2].book.title == "third")
local dismissed = false
launches[2].job.progress_dialog.dismiss_callback = function() dismissed = true end
adapter:cancelTask(third)
assert(dismissed and third.status == "cancelled" and launches[2].job.cancelled)
launches[2].options.on_complete(false, "cancelled")
assert(third.status == "cancelled" and adapter.current_task == nil)
adapter:cancelTask(first)
assert(first.status == "done", "terminal tasks must remain terminal")
assert(adapter:start({ title = "empty" }, {}, "full") == false)
adapter.require_login = function() return false end
assert(adapter:start({ title = "unauth" }, { {} }, "full") == false)
-- A callback failure must not strand the promoted task or block queued work.
local prefetched_book, prefetched_chapter = { title = "prefetched" }, { title = "next" }
adapter.engine.prefetch_job = { book = prefetched_book, chapters = { prefetched_chapter }, total = 1,
    on_complete = function() error("synthetic callback failure") end }
assert(adapter:promotePrefetch(prefetched_book, prefetched_chapter))
local promoted = adapter.current_task
assert(promoted.status == "running" and promoted.dl == adapter.engine.prefetch_job)
adapter.engine.prefetch_job.on_complete(true, "/tmp/prefetched.epub")
assert(promoted.status == "done" and promoted.output_path == "/tmp/prefetched.epub"
    and adapter.current_task == nil, "promoted callback stranded the task")
local persisted, flushes = {}, 0
local settings = {
    get = function(_, key, default) return persisted[key] or default end,
    set = function(_, key, value) persisted[key] = value end,
    flush = function() flushes = flushes + 1 end,
}
local function newSavedAdapter()
    return require("lib.weread_downloader"):new{
        settings = settings, require_login = function() return true end,
        run_online_task = function(_, fn) fn(); return true end,
        show_info = function(msg) error(msg) end,
    }
end
local saved_adapter = newSavedAdapter()
local running = saved_adapter:start({ book_id = "123", title = "saved", token = "must-not-persist" },
    { { chapterUid = 1 } }, "full", { foreground = false })
local queued = saved_adapter:start({ book_id = "234", title = "queued" },
    { { chapterUid = 2 } }, "full", { foreground = false })
assert(#persisted.download_tasks == 2 and persisted.download_tasks[2].status == "running")
assert(persisted.download_tasks[2].request.book.token == nil and persisted.download_tasks[2].dl == nil,
    "live job or auth data serialized")
local before_flush = flushes
for i = 1, 100 do saved_adapter:_updateTask(running, { progress = i / 100 }) end
assert(flushes == before_flush, "progress forced a settings write each tick")
saved_adapter:_saveTasks()
local restored = newSavedAdapter()
assert(#restored:getTasks() == 2 and restored:getActiveCount() == 0)
assert(restored.tasks[running.id].status == "interrupted"
    and restored.tasks[queued.id].status == "interrupted", "restart claimed tasks still running")
assert(restored:retryTask(restored.tasks[running.id]))
local retried = restored.current_task
assert(retried and retried.id ~= running.id and launches[#launches].chapters[1].chapterUid == 1,
    "resume did not preserve selected chapters")
launches[#launches].options.on_complete(true, "/tmp/restored.epub")
local reloaded = newSavedAdapter()
assert(reloaded.tasks[retried.id].status == "done" and reloaded.tasks[retried.id].output_path == "/tmp/restored.epub",
    "completion not persisted")
reloaded:clearFinishedTasks()
assert(#persisted.download_tasks == 0 and #reloaded:getTasks() == 0, "history clearing not persisted")
local evicted = reloaded:_newTask("book", "oldest", 1)
evicted.status = "done"
local closed = false
evicted.dialog = { close = function() closed = true end }
for i = 1, reloaded.MAX_FINISHED_TASKS do
    reloaded:_newTask("book", "history " .. i, 1).status = "interrupted"
end
reloaded:_trimFinishedTasks()
assert(closed and not reloaded.tasks[evicted.id] and #persisted.download_tasks == reloaded.MAX_FINISHED_TASKS,
    "bounded history retained the oldest task or its dialog")
print("WEREAD_DOWNLOAD_QUEUE_AND_PERSISTENCE_OK")

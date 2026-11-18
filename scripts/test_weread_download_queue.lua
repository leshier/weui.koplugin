-- Validate the host adapter rather than retesting upstream's download engine.
package.path = "./?.lua;" .. package.path
local scheduled, launches, shown = {}, {}, {}
package.preload["ui/uimanager"] = function()
    return { scheduleIn = function(_, _, fn) scheduled[#scheduled + 1] = fn end }
end
package.preload["logger"] = function() return { warn = function() end } end
package.preload["weread.lib.content"] = function() return {} end
local Legacy = { MAX_FINISHED_TASKS = 20 }
function Legacy:new(options)
    options.tasks = {}
    return setmetatable(options, self)
end
function Legacy:_newTask(kind, title, total)
    local task = { kind = kind, title = title, total = total, status = "queued" }
    self.tasks[#self.tasks + 1] = task
    return task
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
print("WEREAD_DOWNLOAD_QUEUE_OK")

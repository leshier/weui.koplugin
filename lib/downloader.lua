-- Book/chapter download engine.
--
-- Extracted from main.lua as an independent, dependency-injected object so the
-- plugin entry point keeps only thin menu wrappers. The host injects the API
-- client, settings, and a small set of UI/framework callbacks; the engine owns
-- the whole async download state machine and the device standby guard.
--
-- Standby guard: long downloads must not let the device suspend mid-transfer.
-- Every scheduled step runs through _scheduleGuarded, which wraps the step in
-- xpcall and always releases the guard (and closes the dialog + reports the
-- error) if the step throws. This is critical: a bare UIManager:scheduleIn that
-- threw would leak the guard and leave the device unable to sleep until reboot.

local ConfirmBox = require("ui/widget/confirmbox")
local Device = require("device")
local PluginShare = require("pluginshare")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local time = require("ui/time")
local T = require("ffi/util").template
local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")

local Content = require("lib.content")
local DownloadDialog = require("ui.download_dialog")
local I18n = require("lib.i18n")
local Thoughts = require("lib.thoughts")
local WeRead = require("lib.weread")

local LOG_MODULE = "[WeRead]"

local function _(text)
    return I18n.tr(text)
end

local function log_error(err)
    local text = tostring(err):gsub("[%c]+", " ")
    if #text > 500 then
        return text:sub(1, 500) .. "..."
    end
    return text
end

local function display_error(err)
    local text = tostring(err)
    text = text:match("^[^\r\n]+") or text
    if #text > 300 then
        return text:sub(1, 300) .. "..."
    end
    return text
end

local function dirname(path)
    if type(path) == "string" then
        return path:match("^(.*)/[^/]+$")
    end
end

local function basename(path)
    if type(path) == "string" then
        return path:match("([^/]+)$")
    end
end

local function normalize_dir(path)
    if type(path) ~= "string" or path == "" then return nil end
    return path:gsub("/+$", "")
end

local function file_exists(path)
    local file = type(path) == "string" and io.open(path, "rb") or nil
    if not file then return false end
    file:close()
    return true
end

local function copy_file(src, dst)
    local input, read_err = io.open(src, "rb")
    if not input then return nil, read_err end
    local output, write_err = io.open(dst, "wb")
    if not output then
        input:close()
        return nil, write_err
    end
    while true do
        local chunk = input:read(65536)
        if not chunk then break end
        local ok, err = output:write(chunk)
        if not ok then
            input:close()
            output:close()
            os.remove(dst)
            return nil, err
        end
    end
    input:close()
    output:close()
    return true
end

local function unique_path(dir, name)
    local base, ext = name:match("^(.*)(%.[^%.]*)$")
    if not base then
        base, ext = name, ""
    end
    local path = dir .. "/" .. name
    local index = 1
    while file_exists(path) do
        path = dir .. "/" .. base .. " (" .. tostring(index) .. ")" .. ext
        index = index + 1
    end
    return path
end

-- Block OS-level standby (Kindle powerd, Kobo lid/menu-suspend, etc.)
local function preventOsStandby()
    if Device:isKindle() then
        os.execute("lipc-set-prop com.lab126.powerd preventScreenSaver 1")
    end
    if Device:isCervantes() or Device:isKobo() then
        PluginShare.pause_auto_suspend = true
    end
end

local function allowOsStandby()
    if Device:isKindle() then
        os.execute("lipc-set-prop com.lab126.powerd preventScreenSaver 0")
    end
    if Device:isCervantes() or Device:isKobo() then
        PluginShare.pause_auto_suspend = false
    end
end

local Downloader = {}
Downloader.__index = Downloader
Downloader.MAX_FINISHED_TASKS = 20
Downloader.MAX_TASK_LOGS = 8

-- o = {
--   client, settings,                       -- injected dependencies
--   show_info(text), show_transient(text, timeout),
--   refresh_ui(), refresh_shelf(),
--   open_file(path), safe_callback(label, fn),
--   require_login(cookie, api_key), run_online_task(label, fn),  -- host framework
-- }
function Downloader:new(o)
    o = o or {}
    o.tasks = o.tasks or {}
    o.task_order = o.task_order or {}
    o._next_task_id = o._next_task_id or 0
    setmetatable(o, self)
    return o
end

function Downloader:_newTask(kind, title, total)
    self._next_task_id = (self._next_task_id or 0) + 1
    local id = tostring(os.time()) .. "-" .. tostring(self._next_task_id)
    local queued = _("Queued")
    local task = {
        id = id,
        kind = kind or "book",
        title = title or _("Download"),
        status = "queued",
        stage = queued,
        progress = 0,
        total = math.max(tonumber(total) or 1, 1),
        error = nil,
        output_path = nil,
        failed_count = 0,
        logs = { os.date("%H:%M:%S") .. " " .. queued },
        _last_log_text = queued,
        started_at = os.time(),
        updated_at = os.time(),
        hidden = true,
        cancelled = false,
    }
    self.tasks[id] = task
    table.insert(self.task_order, 1, id)
    return task
end

function Downloader:_trimFinishedTasks()
    local remove = {}
    local kept_finished = 0
    for i = 1, #self.task_order do
        local id = self.task_order[i]
        local task = self.tasks[id]
        if task and (task.status == "done" or task.status == "failed" or task.status == "cancelled") then
            kept_finished = kept_finished + 1
            if kept_finished > self.MAX_FINISHED_TASKS then
                remove[id] = true
            end
        elseif not task then
            remove[id] = true
        end
    end
    for i = #self.task_order, 1, -1 do
        local id = self.task_order[i]
        if remove[id] then
            local task = self.tasks[id]
            if task then
                if task.dialog then task.dialog:close() end
                self.tasks[id] = nil
            end
            table.remove(self.task_order, i)
        end
    end
end

function Downloader:_statusText(task)
    if not task then return "" end
    if task.status == "running" then return _("Downloading") end
    if task.status == "queued" then return _("Queued") end
    if task.status == "done" then return _("Completed") end
    if task.status == "failed" then return _("Failed") end
    if task.status == "cancelled" then return _("Cancelled") end
    return tostring(task.status or "")
end

function Downloader:_appendTaskLog(task, text)
    if not task then return end
    text = tostring(text or ""):gsub("[%c]+", " ")
    if text == "" or text == task._last_log_text then
        return
    end
    task._last_log_text = text
    task.logs = task.logs or {}
    table.insert(task.logs, os.date("%H:%M:%S") .. " " .. text)
    while #task.logs > self.MAX_TASK_LOGS do
        table.remove(task.logs, 1)
    end
end

function Downloader:_progressText(task)
    if not task then return "" end
    local progress = tonumber(task.progress) or 0
    local total = math.max(tonumber(task.total) or 1, 1)
    local percent = math.floor(math.max(0, math.min(1, progress / total)) * 100 + 0.5)
    local cur = tostring(math.floor(math.min(progress, total)))
    -- Single compact header line: status + count + percent. The progress bar
    -- already visualizes the percentage; this just gives the exact numbers.
    local lines = {
        self:_statusText(task) .. "  " ..
            T(_("%1/%2 (%3%)"), cur, tostring(total), tostring(percent)),
    }
    -- Only show the latest log line; previous log history is discarded so the
    -- subtitle stays a fixed, scroll-free area.
    if task.logs and #task.logs > 0 then
        lines[#lines + 1] = task.logs[#task.logs]
    end
    if task.error and task.error ~= "" then
        lines[#lines + 1] = T(_("Error: %1"), task.error)
    end
    if task.output_path and task.output_path ~= "" then
        lines[#lines + 1] = task.output_path
    end
    return table.concat(lines, "\n")
end

function Downloader:_syncTaskDialog(task)
    if not (task and task.dialog) then return end
    task.dialog.progress_max = math.max(tonumber(task.total) or 1, 1)
    task.dialog:setTitle(task.title or _("Download"))
    local status = task.status or ""
    -- Force the final subtitle update on terminal states so the throttled
    -- setSubtitle doesn't drop the last "completed/failed" message.
    local force = status == "done" or status == "failed" or status == "cancelled"
    task.dialog:setSubtitle(self:_progressText(task), force)
    task.dialog:reportProgress(task.progress or 0, force)
end

function Downloader:_updateTask(task, fields)
    if not task then return end
    local old_stage = task.stage
    local next_stage = fields and fields.stage
    local explicit_log = fields and fields.log
    for k, v in pairs(fields or {}) do
        if k ~= "log" then
            task[k] = v
        end
    end
    if explicit_log and explicit_log ~= "" then
        self:_appendTaskLog(task, explicit_log)
    elseif next_stage and next_stage ~= "" and next_stage ~= old_stage then
        self:_appendTaskLog(task, next_stage)
    end
    if fields and fields.error and fields.error ~= "" then
        self:_appendTaskLog(task, T(_("Error: %1"), fields.error))
    end
    if task.status == "done" or task.status == "failed" or task.status == "cancelled" then
        task.dl = nil
    end
    task.updated_at = os.time()
    self:_syncTaskDialog(task)
    -- Close the progress window on ANY terminal state, including "failed".
    -- Otherwise a failed download leaves the window open with a now-defunct
    -- "Cancel download" button (cancelTask is a no-op on terminal tasks),
    -- and the user cannot dismiss the window.
    if task.dialog and (task.status == "done" or task.status == "failed"
        or task.status == "cancelled"
        or (task.output_path and task.output_path ~= "")) then
        task.dialog:close()
        task.dialog = nil
    end
end

function Downloader:getTasks()
    local tasks = {}
    for _, id in ipairs(self.task_order or {}) do
        local task = self.tasks[id]
        if task then
            tasks[#tasks + 1] = task
        end
    end
    return tasks
end

function Downloader:getActiveCount()
    local count = 0
    for _, task in pairs(self.tasks or {}) do
        if task.status == "queued" or task.status == "running" then
            count = count + 1
        end
    end
    return count
end

function Downloader:_libraryHomeDir()
    if not ok_lfs or not lfs or not G_reader_settings then
        return nil
    end
    if type(G_reader_settings.has) == "function"
        and not G_reader_settings:has("home_dir") then
        return nil
    end
    local home = G_reader_settings:readSetting("home_dir")
    home = normalize_dir(home)
    if not home then
        return nil
    end
    if lfs.attributes(home, "mode") ~= "directory" then
        return nil, T(_("Library folder is not available: %1"), home)
    end
    return home
end

function Downloader:_moveToLibraryHome(path)
    local home, home_err = self:_libraryHomeDir()
    if not home then
        return path, home_err
    end
    local src_dir = normalize_dir(dirname(path))
    if src_dir == home then
        return path
    end
    local name = basename(path)
    if not name then
        return path, "missing file name"
    end
    local dst = unique_path(home, name)
    local ok, err = os.rename(path, dst)
    if ok then
        return dst
    end
    ok, err = copy_file(path, dst)
    if not ok then
        return path, err
    end
    os.remove(path)
    return dst
end

function Downloader:cancelTask(task)
    if not task then return end
    -- Don't touch a task that already reached a terminal state. The
    -- detail-dialog "Cancel download" button can linger after a download
    -- finished (that dialog doesn't auto-refresh/close on completion), and
    -- without this guard it would flip a "done"/"failed" task to "cancelled".
    if task.status == "done" or task.status == "failed" or task.status == "cancelled" then
        return
    end
    task.cancelled = true
    if task.dl then
        task.dl.cancelled = true
    end
    self:_updateTask(task, {
        status = "cancelled",
        stage = _("Download cancelled"),
    })
    if task.dialog then
        task.dialog:close()
        task.dialog = nil
    end
end

function Downloader:showTask(task)
    if not task then return end
    if task.dialog then
        self:_syncTaskDialog(task)
        return
    end
    local buttons = {}
    if not task.foreground then
        table.insert(buttons, {
            {
                text = _("Hide progress window"),
                callback = function()
                    task.hidden = true
                    if task.dialog then
                        task.dialog:close()
                        task.dialog = nil
                    end
                end,
            },
        })
    end
    if task.status == "queued" or task.status == "running" then
        table.insert(buttons, {
            {
                text = _("Cancel download"),
                callback = function()
                    self:cancelTask(task)
                    -- cancelTask is a no-op once the task reached a terminal
                    -- state (e.g. it failed while this window was open and
                    -- the window didn't auto-close yet). Close the window so
                    -- the user is never stuck on it.
                    if task.status ~= "queued" and task.status ~= "running" then
                        if task.dialog then
                            task.dialog:close()
                            task.dialog = nil
                        end
                    end
                end,
            },
        })
    end
    if task.output_path and task.output_path ~= "" then
        table.insert(buttons, {
            {
                text = _("Read now"),
                callback = function()
                    local path = task.output_path
                    if task.dialog then
                        task.dialog:close()
                        task.dialog = nil
                    end
                    self.open_file(path)
                end,
            },
        })
    end
    local dialog = DownloadDialog:new{
        title = task.title,
        subtitle = self:_progressText(task),
        progress_max = task.total,
        buttons = #buttons > 0 and buttons or nil,
    }
    task.dialog = dialog
    task.hidden = false
    dialog:show()
    self:_syncTaskDialog(task)
    self.refresh_ui()
end

function Downloader:clearFinishedTasks()
    for i = #self.task_order, 1, -1 do
        local id = self.task_order[i]
        local task = self.tasks[id]
        if task and (task.status == "done" or task.status == "failed" or task.status == "cancelled") then
            if task.dialog then task.dialog:close() end
            self.tasks[id] = nil
            table.remove(self.task_order, i)
        end
    end
end

-- Keep the device awake during long book downloads (reference counted so
-- multiple concurrent jobs share a single guard).
function Downloader:_beginStandby()
    self._standby_ref = (self._standby_ref or 0) + 1
    if self._standby_ref == 1 then
        UIManager:preventStandby()
        preventOsStandby()
    end
end

function Downloader:_endStandby()
    local ref = self._standby_ref or 0
    if ref <= 0 then
        return
    end
    self._standby_ref = ref - 1
    if self._standby_ref == 0 then
        UIManager:allowStandby()
        allowOsStandby()
    end
end

function Downloader:_releaseStandby(dl)
    if dl and dl.standby_guard then
        dl.standby_guard = nil
        self:_endStandby()
    end
end

-- Schedule any download step behind xpcall so an uncaught error always releases
-- the standby guard, closes the progress dialog, and reports the failure.
function Downloader:_scheduleGuarded(dl, step_fn, delay)
    UIManager:scheduleIn(delay or 0.1, function()
        local ok, err = xpcall(step_fn, debug.traceback)
        if ok then return end
        -- A step threw. Always log it. Release the standby guard only if the
        -- step hadn't already released it: the _step completion path calls
        -- _releaseStandby before its post-save work (flush, refresh_shelf,
        -- _updateTask, ConfirmBox), so a throw there leaves standby_guard nil
        -- and the old `if not ok and dl.standby_guard` gate would silently
        -- swallow the error, leaving the task stuck "running".
        if dl.standby_guard then
            self:_releaseStandby(dl)
        end
        logger.err(LOG_MODULE, "download step failed:", log_error(err))
        -- Only flip to "failed" if the task isn't already terminal. A throw
        -- in post-completion UI code (after a successful save) must not
        -- overwrite a "done" task whose EPUB was already written.
        local task = dl.task
        local terminal = task and (task.status == "done"
            or task.status == "failed" or task.status == "cancelled")
        if not terminal then
            self:_updateTask(task, {
                status = "failed",
                stage = _("Download failed"),
                error = display_error(err),
            })
            self.show_info(T(_("Download failed:\n%1"), display_error(err)))
        end
        self:_trimFinishedTasks()
    end)
end

-- Public entry: start downloading the given chapters as one EPUB.
function Downloader:start(book, chapters, suffix, options)
    options = options or {}
    if not self.require_login(true, false) then
        return
    end
    local task_label = options.single_chapter and _("Download chapter and read") or _("Download full book")
    local task = self:_newTask(
        options.single_chapter and "chapter" or "book",
        T(_("Downloading: %1"), book.title or ""),
        math.max(#chapters, 1)
    )
    task.foreground = options.foreground == true
    if task.foreground then
        task.hidden = false
        self:showTask(task)
    end
    local scheduled = self.run_online_task(task_label, function()
        local ok_init, err_init = pcall(function()
            Content.ensure_reader_state(self.client, book)
        end)
        if not ok_init then
            logger.err(LOG_MODULE, "initialize book download failed:", log_error(err_init))
            self:_updateTask(task, {
                status = "failed",
                stage = _("Download failed"),
                error = display_error(err_init),
            })
            self.show_info(T(_("Download failed:\n%1"), display_error(err_init)))
            self:_trimFinishedTasks()
            return
        end

        self:_beginStandby()
        local total = #chapters
        local dl = {
            task = task,
            book = book,
            chapters = chapters,
            suffix = suffix or "book",
            index = 1,
            cancelled = false,
            selected = {},
            bodies = {},
            assets = {},
            state = {},
            total = total,
            failed = {},
            annotation_failed_batches = 0,
            single_chapter = options.single_chapter == true,
            started_at = time.now(),
            standby_guard = true,
        }
        task.dl = dl
        self:_updateTask(task, {
            status = "running",
            stage = _("Starting download..."),
            progress = 0,
        })
        if not task.foreground then
            self.show_transient(_("Download started"), 2)
        end

        self:_scheduleGuarded(dl, function() self:_step(dl) end)
    end)
    if scheduled == false then
        self:_updateTask(task, {
            status = "failed",
            stage = _("Download failed"),
            error = _("No network connection. Please connect Wi-Fi and try again."),
        })
        self:_trimFinishedTasks()
    end
end

function Downloader:startMPArticle(book, article)
    if not self.require_login(true, false) then
        return
    end
    local title = article.title or _("Article")
    local task = self:_newTask("article", T(_("Downloading article: %1"), title), 1)
    local scheduled = self.run_online_task(_("Download article and read"), function()
        self:_updateTask(task, {
            status = "running",
            stage = T(_("Downloading article: %1"), title),
            progress = 0,
        })
        local ok, path_or_err = pcall(function()
            return Content.fetch_mp_article_html(self.client, self.settings, book, article, {
                progress = function(current, total)
                    self:_updateTask(task, {
                        status = "running",
                        total = math.max(tonumber(total) or 1, 1),
                        progress = tonumber(current) or 0,
                        stage = T(_("Downloading images: %1"), title),
                    })
                end,
            })
        end)
        if not ok then
            logger.err(LOG_MODULE, "download MP article failed:", log_error(path_or_err))
            self:_updateTask(task, {
                status = "failed",
                stage = _("Download failed"),
                error = display_error(path_or_err),
            })
            self.show_info(T(_("Download failed:\n%1"), display_error(path_or_err)))
            self:_trimFinishedTasks()
            return
        end
        local book_id = book.book_id or book.bookId
        if book_id and book.cache_dir then
            local books = self.settings:get("books", {})
            local record = books[book_id] or {}
            record.cache_dir = book.cache_dir
            books[book_id] = record
            self.settings:set("books", books)
            self.settings:flush()
        end
        logger.info(
            LOG_MODULE,
            "MP article downloaded:",
            "images=", self.settings:get("cache").download_mp_images and "embedded" or "removed"
        )
        self:_updateTask(task, {
            status = "done",
            stage = _("Download complete"),
            progress = task.total or 1,
            output_path = path_or_err,
        })
        self:_trimFinishedTasks()
        UIManager:show(ConfirmBox:new{
            text = T(_("Article saved:\n%1\n\nRead now?"), path_or_err),
            ok_text = _("Read now"),
            ok_callback = self.safe_callback(_("Read now"), function()
                self.open_file(path_or_err)
            end),
            cancel_text = _("Close"),
        })
    end)
    if scheduled == false then
        self:_updateTask(task, {
            status = "failed",
            stage = _("Download failed"),
            error = _("No network connection. Please connect Wi-Fi and try again."),
        })
        self:_trimFinishedTasks()
    end
end

function Downloader:_setStage(dl, title, progress)
    self:_updateTask(dl.task, {
        status = "running",
        stage = title,
        progress = progress or (dl.task and dl.task.progress) or 0,
    })
end

function Downloader:_perf(dl, stage, started, ...)
    local elapsed = tonumber(time.now() - started) / 1000
    logger.info(LOG_MODULE, "download_perf", "stage=", stage,
        "ms=", string.format("%.1f", elapsed),
        "chapter=", tostring(dl.index) .. "/" .. tostring(dl.total), ...)
end

function Downloader:_failChapter(dl, err)
    local chapter = dl.chapters[dl.index]
    local uid = tostring(chapter and chapter.chapterUid or dl.index)
    table.insert(dl.failed, uid)
    logger.warn(LOG_MODULE, "chapter download failed:",
        "index=", tostring(dl.index) .. "/" .. tostring(dl.total),
        "chapter_uid=", uid, "error=", log_error(err))
    dl.current = nil
    dl.annotation = nil
    dl.index = dl.index + 1
    self:_updateTask(dl.task, { progress = dl.index - 1 })
    self:_scheduleGuarded(dl, function() self:_step(dl) end)
end

function Downloader:_finishChapter(dl)
    if dl.cancelled or not dl.current then return end
    local chapter = dl.current.chapter
    local cache = self.settings:get("cache")
    local stage_text
    if cache.download_book_images then
        stage_text = T(_("Downloading images · chapter %1/%2"), tostring(dl.index), tostring(dl.total))
    else
        stage_text = T(_("Processing chapter %1/%2"), tostring(dl.index), tostring(dl.total))
    end
    self:_setStage(dl,
        stage_text, dl.index - 0.1)
    local started = time.now()
    local ok, xhtml, chapter_assets = pcall(function()
        return Content.finalize_single_chapter_content(
            self.client, self.settings, dl.book, chapter, dl.current.xhtml, dl.state
        )
    end)
    self:_perf(dl, "images_and_finalize", started, "ok=", tostring(ok))
    if not ok then
        self:_failChapter(dl, xhtml)
        return
    end
    local uid = tostring(chapter.chapterUid or dl.index)
    dl.bodies[uid] = xhtml
    table.insert(dl.selected, chapter)
    for _i, asset in ipairs(chapter_assets or {}) do
        table.insert(dl.assets, asset)
    end
    dl.current = nil
    dl.annotation = nil
    dl.index = dl.index + 1
    self:_updateTask(dl.task, { progress = dl.index - 1 })
    self:_scheduleGuarded(dl, function() self:_step(dl) end)
end

function Downloader:_applyAnnotations(dl)
    if dl.cancelled or not dl.current or not dl.annotation then return end
    local annotation = dl.annotation
    local chapter = dl.current.chapter
    local book_id = dl.book.book_id or dl.book.bookId
    self:_setStage(dl,
        T(_("Processing underlines and thoughts · chapter %1/%2"), tostring(dl.index), tostring(dl.total)),
        dl.index - 0.15)
    local started = time.now()
    local ok, processed, annotation_css = pcall(function()
        return Thoughts.apply_data(self.settings, book_id, chapter.chapterUid,
            dl.current.xhtml, annotation.underlines, annotation.reviews)
    end)
    self:_perf(dl, "apply_annotations", started, "ok=", tostring(ok),
        "reviews=", tostring(#annotation.reviews))
    if not ok then
        self:_failChapter(dl, processed)
        return
    end
    dl.current.xhtml = processed
    dl.state.annotation_css_seen = dl.state.annotation_css_seen or {}
    if annotation_css ~= "" and not dl.state.annotation_css_seen[annotation_css] then
        dl.state.css = Thoughts.merge_css(dl.state.css, annotation_css)
        dl.state.annotation_css_seen[annotation_css] = true
    end
    self:_finishChapter(dl)
end

function Downloader:_annotationBatch(dl)
    if dl.cancelled or (dl.task and dl.task.cancelled) then
        self:_releaseStandby(dl)
        self:_updateTask(dl.task, {
            status = "cancelled",
            stage = _("Download cancelled"),
        })
        self.show_transient(_("Download cancelled"), 2)
        self:_trimFinishedTasks()
        return
    end
    local annotation = dl.annotation
    if not annotation then
        self:_finishChapter(dl)
        return
    end
    if annotation.batch_index > #annotation.batches then
        self:_applyAnnotations(dl)
        return
    end

    local batch_index = annotation.batch_index
    local batch_total = #annotation.batches
    local fractional = dl.index - 0.85 + 0.7 * batch_index / math.max(1, batch_total)
    self:_setStage(dl,
        T(_("Downloading thoughts %1/%2 · chapter %3/%4"),
            tostring(batch_index), tostring(batch_total), tostring(dl.index), tostring(dl.total)),
        fractional)

    local started = time.now()
    local ok, result, err = self.client:get_chapter_reviews_batch(
        dl.book.book_id or dl.book.bookId,
        dl.current.chapter.chapterUid,
        annotation.batches[batch_index]
    )
    self:_perf(dl, "thought_batch", started,
        "batch=", tostring(batch_index) .. "/" .. tostring(batch_total),
        "ok=", tostring(ok), "retry=", tostring(annotation.retry))

    if not ok then
        if annotation.retry < 2 then
            annotation.retry = annotation.retry + 1
            self:_setStage(dl,
                T(_("Retrying thoughts %1/%2 · attempt %3"),
                    tostring(batch_index), tostring(batch_total), tostring(annotation.retry)),
                fractional)
            self:_scheduleGuarded(dl, function() self:_annotationBatch(dl) end, 0.6 * annotation.retry)
            return
        end
        dl.annotation_failed_batches = dl.annotation_failed_batches + 1
        logger.warn(LOG_MODULE, "thought batch skipped:",
            "batch=", tostring(batch_index) .. "/" .. tostring(batch_total),
            "error=", log_error(err or "unknown"))
    elseif result and type(result.reviews) == "table" then
        for _i, review in ipairs(result.reviews) do
            annotation.reviews[#annotation.reviews + 1] = review
        end
    end

    annotation.batch_index = batch_index + 1
    annotation.retry = 0
    self:_scheduleGuarded(dl, function() self:_annotationBatch(dl) end, 0.3)
end

function Downloader:_startAnnotations(dl)
    local chapter = dl.current.chapter
    local book_id = dl.book.book_id or dl.book.bookId
    self:_setStage(dl,
        T(_("Downloading underlines · chapter %1/%2"), tostring(dl.index), tostring(dl.total)),
        dl.index - 0.85)
    local started = time.now()
    local ok, underlines, ranges, err = Thoughts.fetch_underlines(
        self.client, self.settings, book_id, chapter.chapterUid
    )
    self:_perf(dl, "underlines", started, "ok=", tostring(ok),
        "ranges=", tostring(#(ranges or {})))
    if not ok or type(underlines) ~= "table" then
        logger.warn(LOG_MODULE, "skip chapter annotations:", log_error(err or "no data"))
        self:_finishChapter(dl)
        return
    end
    dl.annotation = {
        underlines = underlines,
        reviews = {},
        batches = self.client:build_chapter_review_batches(ranges),
        batch_index = 1,
        retry = 0,
    }
    if #dl.annotation.batches == 0 then
        self:_applyAnnotations(dl)
    else
        self:_scheduleGuarded(dl, function() self:_annotationBatch(dl) end, 0.1)
    end
end

function Downloader:_step(dl)
    if dl.cancelled or (dl.task and dl.task.cancelled) then
        self:_releaseStandby(dl)
        self:_updateTask(dl.task, {
            status = "cancelled",
            stage = _("Download cancelled"),
        })
        self.show_transient(_("Download cancelled"), 2)
        self:_trimFinishedTasks()
        return
    end

    if dl.index > dl.total then
        if #dl.selected == 0 then
            self:_releaseStandby(dl)
            logger.err(LOG_MODULE, "book download failed: no chapters downloaded")
            self:_updateTask(dl.task, {
                status = "failed",
                stage = _("No chapters were downloaded."),
                error = _("No chapters were downloaded."),
            })
            self.show_info(_("No chapters were downloaded."))
            self:_trimFinishedTasks()
            return
        end
        self:_setStage(dl, _("Building EPUB..."), dl.total)
        local save_started = time.now()
        local ok, path = pcall(function()
            if dl.single_chapter then
                local chapter = dl.selected[1]
                local uid = tostring(chapter.chapterUid or 1)
                return Content.save_chapter_epub(
                    self.settings, dl.book, chapter, dl.bodies[uid], dl.assets, dl.state.css
                )
            end
            local cover_data
            local cover_url = WeRead.normalize_cover_url(dl.book.cover)
            if cover_url and cover_url ~= "" then
                pcall(function() cover_data = self.client:get_binary(cover_url) end)
            end
            return Content.save_book_epub(
                self.settings, dl.book, dl.selected, dl.bodies,
                dl.suffix, dl.assets, dl.state.css, cover_data
            )
        end)
        self:_perf(dl, "save_epub", save_started, "ok=", tostring(ok),
            "single=", tostring(dl.single_chapter))
        if ok and path then
            local moved_path, move_err = self:_moveToLibraryHome(path)
            if moved_path and moved_path ~= path then
                logger.info(LOG_MODULE, "download moved to library:", moved_path)
                path = moved_path
            elseif move_err then
                logger.warn(LOG_MODULE, "move downloaded book to library failed:", log_error(move_err))
            end
        end
        self:_releaseStandby(dl)
        local books = self.settings:get("books", {})
        local book_id = dl.book.book_id or dl.book.bookId
        if book_id then
            dl.book.cached_chapters = dl.book.cached_chapters or {}
            for ci, ch in ipairs(dl.selected) do
                dl.book.cached_chapters[tostring(ch.chapterUid or ci)] = ok and path or nil
            end
            if ok then
                dl.book.cached_file = path
            end
            dl.book.reader_url = dl.book.reader_url or WeRead.reader_url(book_id)
            books[book_id] = dl.book
            self.settings:set("books", books)
            self.settings:flush()
        end
        self.refresh_shelf()
        if not ok then
            logger.err(LOG_MODULE, "save downloaded book failed:", log_error(path))
            self:_updateTask(dl.task, {
                status = "failed",
                stage = _("Download failed"),
                error = display_error(path),
            })
            self.show_info(T(_("Download failed:\n%1"), display_error(path)))
            self:_trimFinishedTasks()
            return
        end
        if #dl.failed > 0 then
            logger.warn(
                LOG_MODULE,
                "book download completed with skipped chapters:",
                "success=", tostring(#dl.selected),
                "failed=", tostring(#dl.failed)
            )
        else
            logger.info(LOG_MODULE, "book download completed:", "chapters=", tostring(#dl.selected))
        end
        local completion_text
        if #dl.failed > 0 then
            completion_text = T(
                _("Downloaded %1 chapters; %2 failed.\n\nBook saved:\n%3\n\nRead now?"),
                tostring(#dl.selected), tostring(#dl.failed), path
            )
        else
            completion_text = T(_("Downloaded %1 chapters.\n\nBook saved:\n%2\n\nRead now?"), tostring(#dl.selected), path)
        end
        if dl.annotation_failed_batches > 0 then
            completion_text = completion_text .. "\n\n" .. T(
                _("%1 thought batch(es) failed after retries; the EPUB contains the remaining available thoughts."),
                tostring(dl.annotation_failed_batches)
            )
        end
        self:_perf(dl, "download_total", dl.started_at,
            "success_chapters=", tostring(#dl.selected),
            "failed_chapters=", tostring(#dl.failed),
            "failed_thought_batches=", tostring(dl.annotation_failed_batches))
        self:_updateTask(dl.task, {
            status = (#dl.failed > 0 or dl.annotation_failed_batches > 0) and "failed" or "done",
            stage = (#dl.failed > 0 or dl.annotation_failed_batches > 0) and _("Download completed with failures") or _("Download complete"),
            progress = dl.total,
            output_path = path,
            failed_count = #dl.failed,
            error = (#dl.failed > 0 or dl.annotation_failed_batches > 0)
                and T(_("Failed chapters: %1; failed thought batches: %2"),
                    tostring(#dl.failed), tostring(dl.annotation_failed_batches))
                or nil,
        })
        self:_trimFinishedTasks()
        UIManager:show(ConfirmBox:new{
            text = completion_text,
            ok_text = _("Read now"),
            ok_callback = self.safe_callback(_("Read now"), function()
                self.open_file(path)
            end),
            cancel_text = _("Close"),
        })
        return
    end

    local chapter = dl.chapters[dl.index]
    self:_setStage(dl,
        T(_("Downloading chapter %1/%2: %3"), tostring(dl.index), tostring(dl.total),
            chapter.title or tostring(chapter.chapterUid)),
        dl.index - 1)
    local started = time.now()
    local ok, xhtml = pcall(function()
        return Content.fetch_single_chapter_source(
            self.client, self.settings, dl.book, chapter, dl.state
        )
    end)
    self:_perf(dl, "chapter_source", started, "ok=", tostring(ok))
    if not ok then
        self:_failChapter(dl, xhtml)
        return
    end
    dl.current = { chapter = chapter, xhtml = xhtml }
    if Thoughts.is_download_enabled(self.settings) then
        self:_startAnnotations(dl)
    else
        self:_finishChapter(dl)
    end
end

return Downloader

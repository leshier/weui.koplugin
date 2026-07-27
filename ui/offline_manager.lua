-- ui/offline_manager.lua — We UI
-- B2: WeRead 离线管理 (Offline Management)
-- A SUIWindow-based view of:
--   • Download tasks (active + completed)
--   • Cached books (list with sizes, open/clean actions)
--   • Storage overview + cleanup actions
--
-- Data sources:
--   • Downloader instance (in-memory task list)
--   • WeRead plugin's settings.books (book records with cached_file paths)
--   • Filesystem (for size computation, lazy)

local Blitbuffer     = require("ffi/blitbuffer")
local Device         = require("device")
local Font           = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom           = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan  = require("ui/widget/horizontalspan")
local LineWidget      = require("ui/widget/linewidget")
local TextWidget      = require("ui/widget/textwidget")
local UIManager       = require("ui/uimanager")
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")
local Screen          = Device.screen
local logger          = require("logger")
local _               = require("weui_i18n").translate
local N_              = require("weui_i18n").ngettext
local SUIStyle        = require("weui_style")
local UI              = require("weui_core")

local OfflineManager = {}

-- ---------------------------------------------------------------------------
-- Helpers — WeRead plugin access
-- ---------------------------------------------------------------------------
local function _getWeRead()
    local ok, WR = pcall(require, "weui_weread")
    if ok and WR and WR.instance then return WR.instance end
    -- Fallback: try package.loaded
    for key, mod in pairs(package.loaded) do
        if type(key) == "string" and key:find("weread", 1, true) and type(mod) == "table" then
            if type(mod.isBookDownloaded) == "function" then
                return mod
            end
        end
    end
    return nil
end

local function _getDownloader()
    local wr = _getWeRead()
    return wr and wr.downloader or nil
end

local function _getBooksSettings()
    local wr = _getWeRead()
    if not wr or not wr.settings then return {} end
    return wr.settings:get("books", {}) or {}
end

local function _fileExists(path)
    if type(path) ~= "string" or path == "" then return false end
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if not ok_lfs or not lfs then lfs = _G.lfs end
    if not lfs then return false end
    return lfs.attributes(path, "mode") ~= nil
end

-- ---------------------------------------------------------------------------
-- Size formatting
-- ---------------------------------------------------------------------------
local function _fmtSize(bytes)
    bytes = tonumber(bytes) or 0
    if bytes < 1024 then
        return string.format("%d B", bytes)
    elseif bytes < 1024 * 1024 then
        return string.format("%.1f KB", bytes / 1024)
    elseif bytes < 1024 * 1024 * 1024 then
        return string.format("%.1f MB", bytes / (1024 * 1024))
    else
        return string.format("%.2f GB", bytes / (1024 * 1024 * 1024))
    end
end

-- Compute directory size recursively.  Cached per path to avoid re-walking.
local _dir_size_cache = {}
local function _dirSize(path)
    if _dir_size_cache[path] ~= nil then return _dir_size_cache[path] end
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if not ok_lfs or not lfs then lfs = _G.lfs end
    if not lfs then return 0 end
    local total = 0
    local function walk(p)
        local mode = lfs.attributes(p, "mode")
        if mode == "file" then
            total = total + (lfs.attributes(p, "size") or 0)
        elseif mode == "directory" then
            for entry in lfs.dir(p) do
                if entry ~= "." and entry ~= ".." then
                    walk(p .. "/" .. entry)
                end
            end
        end
    end
    if lfs.attributes(path, "mode") then walk(path) end
    _dir_size_cache[path] = total
    return total
end

-- ---------------------------------------------------------------------------
-- Status label helpers
-- ---------------------------------------------------------------------------
local STATUS_LABELS = {
    queued    = "queued",
    running   = "running",
    done      = "completed",
    failed    = "failed",
    cancelled = "cancelled",
}

local function _statusLabel(status)
    return _(STATUS_LABELS[status] or status or "unknown")
end

-- ---------------------------------------------------------------------------
-- Offline Manager Window
-- ---------------------------------------------------------------------------
function OfflineManager.show()
    local wr = _getWeRead()
    if not wr then
        local InfoMessage = require("ui/widget/infomessage")
        UIManager:show(InfoMessage:new{ text = _("WeRead not available.") })
        return
    end

    local SUIWindow = require("weui_window")

    -- Cached data (recomputed on demand or when actions trigger refresh)
    local _cached_books = nil
    local _cached_total_size = nil

    local function _invalidateCache()
        _cached_books = nil
        _cached_total_size = nil
        _dir_size_cache = {}
    end

    -- Build the list of cached books from WeRead settings + filesystem check.
    local function _getCachedBooks()
        if _cached_books then return _cached_books end
        local books = _getBooksSettings()
        local result = {}
        for book_id, record in pairs(books) do
            if type(record) == "table" then
                local is_cached = _fileExists(record.cached_file)
                if is_cached then
                    result[#result + 1] = {
                        book_id = book_id,
                        title   = record.title or book_id,
                        author  = record.author or "",
                        cached_file = record.cached_file,
                        cache_dir = record.cache_dir,
                        updated_at = record.updated_at or 0,
                    }
                end
            end
        end
        -- Sort by title
        table.sort(result, function(a, b)
            return (a.title or "") < (b.title or "")
        end)
        _cached_books = result
        return result
    end

    local function _getTotalCacheSize()
        if _cached_total_size then return _cached_total_size end
        local books = _getCachedBooks()
        local total = 0
        local seen = {}
        for _i, b in ipairs(books) do
            local dir = b.cache_dir
            if not dir and b.cached_file then
                dir = b.cached_file:match("^(.*)/[^/]+$") or ""
            end
            if dir and dir ~= "" and not seen[dir] then
                seen[dir] = true
                total = total + _dirSize(dir)
            end
        end
        _cached_total_size = total
        return total
    end

    -- ======================================================================
    -- Screen 1: Downloads
    -- ======================================================================
    local function buildDownloadsScreen(ctx)
        local downloader = _getDownloader()
        local inner_w = ctx.inner_w
        local SZ = ctx.SZ

        local rows = {}

        -- Header: active count + clear finished button
        if downloader then
            local active = downloader:getActiveCount() or 0
            local tasks = downloader:getTasks() or {}
            local finished_count = 0
            for _i, t in ipairs(tasks) do
                if t.status == "done" or t.status == "failed" or t.status == "cancelled" then
                    finished_count = finished_count + 1
                end
            end

            -- Status summary row
            rows[#rows + 1] = SUIWindow.ListRow{
                inner_w     = inner_w,
                title       = _("Active downloads"),
                right_value = tostring(active),
                separator   = true,
                dim_only    = true,
            }
            rows[#rows + 1] = SUIWindow.ListRow{
                inner_w     = inner_w,
                title       = _("Completed downloads"),
                right_value = tostring(finished_count),
                separator   = true,
                dim_only    = true,
            }

            -- Clear finished
            if finished_count > 0 then
                rows[#rows + 1] = SUIWindow.ListRow{
                    inner_w   = inner_w,
                    title     = _("Clear finished tasks"),
                    on_tap    = function()
                        downloader:clearFinishedTasks()
                        _invalidateCache()
                        ctx.repaint()
                    end,
                    separator = true,
                }
            end

            -- Task list
            if #tasks == 0 then
                rows[#rows + 1] = SUIWindow.ListRow{
                    inner_w  = inner_w,
                    title    = _("No download tasks."),
                    dim_only = true,
                }
            else
                for _i, task in ipairs(tasks) do
                    local status_text = _statusLabel(task.status)
                    if task.status == "running" and type(task.progress) == "number"
                            and type(task.total) == "number" and task.total > 0 then
                        local pct = math.floor(task.progress / task.total * 100)
                        status_text = status_text .. "  " .. tostring(pct) .. "%"
                    end
                    rows[#rows + 1] = SUIWindow.ListRow{
                        inner_w      = inner_w,
                        title        = task.title or _("Download"),
                        subtitle     = task.stage or task.error,
                        right_value  = status_text,
                        show_chevron = true,
                        separator    = true,
                        on_tap       = function()
                            downloader:showTask(task)
                        end,
                    }
                end
            end
        else
            rows[#rows + 1] = SUIWindow.ListRow{
                inner_w  = inner_w,
                title    = _("Download manager not available."),
                dim_only = true,
            }
        end

        return rows
    end

    -- ======================================================================
    -- Screen 2: Cached Books
    -- ======================================================================
    local function buildCachedScreen(ctx)
        local inner_w = ctx.inner_w
        local books = _getCachedBooks()

        local rows = {}

        -- Summary
        rows[#rows + 1] = SUIWindow.ListRow{
            inner_w     = inner_w,
            title       = _("Cached books"),
            right_value = tostring(#books),
            separator   = true,
            dim_only    = true,
        }
        rows[#rows + 1] = SUIWindow.ListRow{
            inner_w     = inner_w,
            title       = _("Total cache size"),
            right_value = _fmtSize(_getTotalCacheSize()),
            separator   = true,
            dim_only    = true,
        }

        if #books == 0 then
            rows[#rows + 1] = SUIWindow.ListRow{
                inner_w  = inner_w,
                title    = _("No cached books."),
                dim_only = true,
            }
            return rows
        end

        for _i, book in ipairs(books) do
            local dir = book.cache_dir
            if not dir and book.cached_file then
                dir = book.cached_file:match("^(.*)/[^/]+$") or ""
            end
            local size_text = dir and dir ~= "" and _fmtSize(_dirSize(dir)) or ""
            rows[#rows + 1] = SUIWindow.ListRow{
                inner_w      = inner_w,
                title        = book.title,
                subtitle     = book.author,
                right_value  = size_text,
                show_chevron = true,
                separator    = true,
                on_tap       = function()
                    ctx.push("book_detail", { book = book })
                end,
            }
        end

        return rows
    end

    -- ======================================================================
    -- Screen 2b: Book detail (open / clean)
    -- ======================================================================
    local function buildBookDetailScreen(ctx)
        local inner_w = ctx.inner_w
        local params  = ctx.current().params
        local book    = params and params.book

        local rows = {}

        if not book then
            rows[#rows + 1] = SUIWindow.ListRow{
                inner_w  = inner_w,
                title    = _("Book not found."),
                dim_only = true,
            }
            return rows
        end

        -- Title / author info
        rows[#rows + 1] = SUIWindow.ListRow{
            inner_w   = inner_w,
            title     = book.title,
            subtitle  = book.author,
            separator = true,
            dim_only  = true,
        }

        -- Size
        local dir = book.cache_dir
        if not dir and book.cached_file then
            dir = book.cached_file:match("^(.*)/[^/]+$") or ""
        end
        local size_text = dir and dir ~= "" and _fmtSize(_dirSize(dir)) or _("Unknown")
        rows[#rows + 1] = SUIWindow.ListRow{
            inner_w     = inner_w,
            title       = _("Size"),
            right_value = size_text,
            separator   = true,
            dim_only    = true,
        }

        -- Open
        rows[#rows + 1] = SUIWindow.ListRow{
            inner_w   = inner_w,
            title     = _("Read now"),
            separator = true,
            on_tap    = function()
                local wr = _getWeRead()
                if wr and book.cached_file and _fileExists(book.cached_file) then
                    local ok, err = pcall(function()
                        wr:openFile(book.cached_file)
                    end)
                    if not ok then
                        logger.warn("weui: offline_manager: open failed:", err)
                    end
                end
            end,
        }

        -- Delete cache
        rows[#rows + 1] = SUIWindow.ListRow{
            inner_w   = inner_w,
            title     = _("Clear cache"),
            danger    = true,
            separator = true,
            on_tap    = function()
                local ConfirmBox = require("ui/widget/confirmbox")
                UIManager:show(ConfirmBox:new{
                    text = _("Clear cache for \"%1\"?"):gsub("%%1", book.title),
                    ok_text = _("Clear"),
                    ok_callback = function()
                        local wr = _getWeRead()
                        if wr and wr.clearBookCache then
                            pcall(function() wr:clearBookCache(book.book_id) end)
                        end
                        _invalidateCache()
                        ctx.pop()
                    end,
                })
            end,
        }

        return rows
    end

    -- ======================================================================
    -- Screen 3: Storage / Cleanup
    -- ======================================================================
    local function buildStorageScreen(ctx)
        local inner_w = ctx.inner_w
        local books = _getCachedBooks()
        local total_size = _getTotalCacheSize()

        local rows = {}

        -- Overview
        rows[#rows + 1] = SUIWindow.ListRow{
            inner_w     = inner_w,
            title       = _("Total cache"),
            right_value = _fmtSize(total_size),
            separator   = true,
            dim_only    = true,
        }
        rows[#rows + 1] = SUIWindow.ListRow{
            inner_w     = inner_w,
            title       = _("Cached books"),
            right_value = tostring(#books),
            separator   = true,
            dim_only    = true,
        }

        -- Count MP (public account) books
        local mp_count = 0
        for _i, b in ipairs(books) do
            if type(b.book_id) == "string" and b.book_id:sub(1, 7) == "MP_WXS_" then
                mp_count = mp_count + 1
            end
        end

        -- Clear MP cache
        rows[#rows + 1] = SUIWindow.ListRow{
            inner_w      = inner_w,
            title        = _("Clear all public account cache"),
            right_value  = tostring(mp_count),
            show_chevron = true,
            separator    = true,
            danger       = true,
            on_tap       = function()
                local ConfirmBox = require("ui/widget/confirmbox")
                UIManager:show(ConfirmBox:new{
                    text = _("Clear all public account cache? Downloaded articles and cached article lists will be deleted."),
                    ok_text = _("Clear"),
                    ok_callback = function()
                        local wr = _getWeRead()
                        if wr and wr.clearAllMPCache then
                            pcall(function() wr:clearAllMPCache() end)
                        end
                        _invalidateCache()
                        ctx.repaint()
                    end,
                })
            end,
        }

        -- Clear all cache
        rows[#rows + 1] = SUIWindow.ListRow{
            inner_w      = inner_w,
            title        = _("Clear all cache"),
            right_value  = _fmtSize(total_size),
            show_chevron = true,
            separator    = true,
            danger       = true,
            on_tap       = function()
                local ConfirmBox = require("ui/widget/confirmbox")
                UIManager:show(ConfirmBox:new{
                    text = _("Clear all cache? Downloaded books and articles will be deleted."),
                    ok_text = _("Clear"),
                    ok_callback = function()
                        local wr = _getWeRead()
                        if wr and wr.clearAllCache then
                            pcall(function() wr:clearAllCache() end)
                        end
                        _invalidateCache()
                        ctx.repaint()
                    end,
                })
            end,
        }

        -- Cache directory
        local wr = _getWeRead()
        if wr and wr.settings and wr.settings.cache_dir then
            rows[#rows + 1] = SUIWindow.ListRow{
                inner_w  = inner_w,
                title    = _("Cache directory"),
                subtitle = wr.settings.cache_dir,
                dim_only = true,
            }
        end

        return rows
    end

    -- ======================================================================
    -- Build the window
    -- ======================================================================
    local win = SUIWindow:new{
        name    = "weui_win_offline_manager",
        title   = _("Offline management"),
        height  = math.floor((select(2, UI.getPortraitDims())) * 23 / 30),
        position = "bottom",
        navpager_mode = require("weui_config").isNavpagerEnabled(),
        screens = {
            __root__      = buildDownloadsScreen,
            cached_books  = buildCachedScreen,
            book_detail   = buildBookDetailScreen,
            storage       = buildStorageScreen,
        },
        tabs = {
            { id = "__root__",     label = _("Downloads") },
            { id = "cached_books", label = _("Cached") },
            { id = "storage",      label = _("Storage") },
        },
    }

    win:show()
end

return OfflineManager

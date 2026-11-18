-- Deterministic regression tests for Z-Library download worker failures.

local root = (arg[0]:match("^(.*)/scripts/") or ".")
package.path = root .. "/?.lua;" .. package.path

local captured_error
local opened_book
local link_mode = "ok"
local trapper_mode = "fork_failure"
local download_calls = 0
local wifi_disable_calls = 0
local personal_lists = { downloaded = { { id = "old" } }, favorites = { { id = "favorite" } } }

local Api = {
    getDownloadTempPath = function(path) return path .. ".downloading" end,
    discardDownloadTempFile = function() end,
    isAuthenticationError = function() return false end,
    getDownloadLink = function()
        if link_mode == "empty" then return { download_link = "" } end
        return { download_link = "https://cdn.example/book.epub?token=secret" }
    end,
    downloadBook = function()
        download_calls = download_calls + 1
        return { success = true }
    end,
}

local Config = {
    DEFAULT_DOWNLOAD_DIR_FALLBACK = "/tmp",
    hasCredentials = function() return true end,
    getUserSession = function() return { user_id = "1", user_key = "key" } end,
    getDownloadDir = function() return "/tmp" end,
    getBookUrl = function() return nil end,
    disableRuntimeCacheWrites = function() end,
    getMultiSearchCache = function()
        return { remove = function(_, key) personal_lists[key] = nil end }
    end,
}

local Trapper = {}
function Trapper:wrap(fn) return fn() end
function Trapper:dismissableRunInSubprocess(task)
    if trapper_mode == "fork_failure" then return false end
    if trapper_mode == "empty_result" then return true end
    if trapper_mode == "throw" then
        error("worker exploded at https://cdn.example/book.epub?token=secret")
    end
    return true, task()
end

local Ui = {
    showBookDownloadProgress = function() return {} end,
    closeMessage = function() end,
    showErrorMessage = function(err) captured_error = tostring(err) end,
    showInfoMessage = function() end,
    confirmDownload = function(_, callback) callback() end,
    confirmOpenBook = function(filename, open_callback, close_callback)
        assert(type(open_callback) == "function")
        assert(type(close_callback) == "function")
        opened_book = filename
    end,
    showRetryErrorDialog = function(err)
        captured_error = tostring(err)
    end,
}

package.loaded["zlibrary.api"] = Api
package.loaded["zlibrary.async_helper"] = {}
package.loaded["zlibrary.config"] = Config
package.loaded["ui/network/manager"] = {
    willRerunWhenOnline = function() return false end,
    disableWifi = function()
        wifi_disable_calls = wifi_disable_calls + 1
    end,
}
package.loaded["apps/reader/readerui"] = {}
package.loaded["ui/trapper"] = Trapper
package.loaded["ui/uimanager"] = {
    nextTick = function() end,
    scheduleIn = function() end,
    unschedule = function() end,
}
package.loaded["zlibrary.ui"] = Ui
package.loaded["zlibrary.gettext"] = function(value) return value end
package.loaded["libs/libkoreader-lfs"] = {
    attributes = function(path, attr)
        if path == "/tmp" then
            if attr == "mode" then return "directory" end
            return { mode = "directory" }
        end
        return nil
    end,
    mkdir = function() return true end,
}
package.loaded.logger = { info = function() end, warn = function() end, err = function() end }
package.loaded["socket.url"] = {
    parse = function(url)
        local scheme, host, path = url:match("^(https?)://([^/]+)(/[^?]*)")
        return scheme and { scheme = scheme, host = host, path = path } or nil
    end,
    build = function(parts)
        return parts.scheme .. "://" .. parts.host .. (parts.path or "")
    end,
}
package.loaded.util = {
    trim = function(value) return value:match("^%s*(.-)%s*$") end,
}

local Download = dofile(root .. "/zlibrary/download.lua")
local plugin = {
    resetDownloadQuotaCache = function() end,
    login = function() end,
    dialog_manager = { closeAllDialogs = function() end },
}
local book = { id = "1", hash = "hash", format = "epub", title = "Title", author = "Author" }

-- A failed fork must transparently execute once in-process and succeed.
Download.run(plugin, book)
assert(download_calls == 1, "fork failure should fall back to one in-process download")
assert(opened_book == "Title - Author.epub")
assert(captured_error == nil)
assert(wifi_disable_calls == 0, "Z-Library completion must never disable Wi-Fi")
assert(personal_lists.downloaded == nil, "completed download must refresh My Books")
assert(personal_lists.favorites[1].id == "favorite", "download must retain the favorites list")

-- A child that exits without a serialized result gets an actionable error.
trapper_mode = "empty_result"
opened_book, captured_error = nil, nil
personal_lists.downloaded = { { id = "old" } }
Download.run(plugin, book)
assert(captured_error == "Download process ended unexpectedly. Please retry.")
assert(personal_lists.downloaded[1].id == "old", "failed download must retain existing history")

-- Exceptions retain the cause, but signed query parameters are redacted.
trapper_mode = "throw"
captured_error = nil
Download.run(plugin, book)
assert(captured_error:find("worker exploded", 1, true))
assert(captured_error:find("?<redacted>", 1, true))
assert(not captured_error:find("token=secret", 1, true))

-- A malformed link response is reported explicitly.
trapper_mode, link_mode = "inprocess", "empty"
captured_error = nil
Download.run(plugin, book)
assert(captured_error == "The server returned an empty download link.")

local function read(path)
    local fh = assert(io.open(path, "rb"))
    local data = fh:read("*a")
    fh:close()
    return data
end

assert(not read(root .. "/zlibrary/ui.lua"):find(
    "Turn off Wi%-Fi after closing this dialog"),
    "download completion UI must not offer to disable Wi-Fi")
assert(not read(root .. "/zlibrary/download.lua"):find("disableWifi", 1, true),
    "Z-Library download completion must not disable Wi-Fi")

print("ZLIBRARY_DOWNLOAD_RESILIENCE_OK")

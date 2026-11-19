local values = { home_dir = "/books" }
local zvalues, wrvalues = {}, {}
local writable, invalidations, updates = true, 0, 0
G_reader_settings = {
    readSetting = function(_, key) return values[key] end,
    saveSetting = function(_, key, value) values[key] = value end,
    flush = function() end,
}
package.loaded["libs/libkoreader-lfs"] = {
    currentdir = function() return "/runtime" end,
    attributes = function(path, field)
        if path == "/books" or path == "/new-books" or path == "/runtime" then
            return field == "mode" and "directory" or { mode = "directory" }
        end
    end,
}
package.loaded["ffi/util"] = { realpath = function(path)
    return path == "/alias" and "/new-books" or path
end }
package.loaded.device = { home_dir = "/device" }
package.loaded["weui_library"] = { invalidate = function() invalidations = invalidations + 1 end }
package.loaded["zlibrary.config"] = {
    SETTINGS_DOWNLOAD_DIR_KEY = "download", SETTINGS_FOLLOW_LIBRARY_KEY = "follow",
    saveSetting = function(key, value) zvalues[key] = value end,
}
package.loaded.datastorage = { getSettingsDir = function() return "/settings" end }
package.loaded.luasettings = { open = function(_, path)
    assert(path == "/settings/weread.lua")
    return { saveSetting = function(_, key, value) wrvalues[key] = value end, flush = function() end }
end }
local original_open, original_remove = io.open, os.remove
io.open = function(path)
    assert(path:find("/.weui-write-test-", 1, true))
    if not writable then return end
    return { write = function() return true end, close = function() end }
end
os.remove = function() return true end
local Directories = require("weui_directories")
assert(Directories.main() == "/books")
local plugin = { ui = {
    folder_shortcuts = { updateShortcut = function(_, key, path)
        assert(key == "home_dir" and path == "/new-books"); updates = updates + 1
    end },
    updateTitleBarPath = function() updates = updates + 1 end,
} }
assert(not Directories.setMain("/missing", plugin) and values.home_dir == "/books", "invalid root changed preferences")
assert(not Directories.setMain("/runtime", plugin), "runtime directory accepted")
writable = false
assert(not Directories.setMain("/alias", plugin) and zvalues.download == nil, "unwritable root changed download settings")
writable = true
local ok, path = Directories.setMain("/alias", plugin)
assert(ok and path == "/new-books" and values.home_dir == path)
assert(zvalues.download == path and zvalues.follow == true)
assert(wrvalues.download_dir == path and wrvalues.download_dir_follow_library == true, "lazy WeRead root missing")
assert(updates == 2 and invalidations == 1, "native home shortcut or shelf cache stale")
local live
plugin._weread_plugin = { settings = { set_download_dir = function(_, dir, follow)
    live = dir; assert(follow == true)
end } }
assert(Directories.setMain("/alias", plugin) and live == "/new-books", "live WeRead root stale")
values.home_dir = ""
assert(Directories.main() == "/device", "empty library root fallback")
io.open, os.remove = original_open, original_remove
print("LIBRARY_DIRECTORIES_OK: validation, alias, writable, persisted/lazy/live downloads, shortcuts, cache")

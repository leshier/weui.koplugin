-- Reset failure/one-shot contract, including unwritable completion markers.
-- Native QA separately checks actual LuaSettings, SQLite and plugin startup.
local root = (arg[0]:match("^(.*)/scripts/") or ".")
local module = assert(loadfile(root .. "/weui_initialize.lua"))
local marker = root .. "/weui-initialize.request"
local ack = "/profile/settings/.weui-initialize-completed"
local request = "weui-initialize-1.5.4\n"
local fs, fail_rename
local real_io, real_rename = io, os.rename

local function seed()
    fs = {
        ["/profile"] = true, ["/profile/settings"] = true,
        ["/profile/settings/weui"] = true,
        ["/profile/settings/weui/weui_settings.lua"] = "BROKEN LUA",
        ["/profile/settings/weui/weui_settings.lua.old"] = "old settings",
        ["/profile/settings/simpleui"] = true,
        ["/profile/settings/simpleui/sui_settings.lua"] = "legacy",
        ["/profile/settings/weread.lua"] = "old account",
        ["/profile/settings/weread.lua.old"] = "backup account",
        ["/profile/settings/zlibrary.lua"] = "old Z-Library account",
        ["/profile/settings.reader.lua"] = "original global",
        ["/profile/settings.reader.lua.old"] = "original global backup",
        ["/profile/library"] = true, ["/profile/library/book.epub"] = "EPUB",
        ["/profile/weread"] = true, ["/profile/weread/cache"] = true,
        ["/profile/weread/cache/book.epub"] = "downloaded EPUB",
        ["/profile/weread/library-old.db"] = "SQLite",
        ["/profile/weread/library-old.db-wal"] = "WAL",
    }
    fail_rename = nil
    G_reader_settings = {
        file = "/profile/settings.reader.lua",
        data = {
            home_dir = "/profile/library", language = "zh_CN",
            start_with = "homescreen_weui", weui_paper_home = false,
            navbar_tabs = "old", simpleui_layout = "old",
            weread_cookie = "old", zlibrary_username = "old",
            plugins_disabled = { statistics = true },
        },
    }
    package.loaded.pluginloader = {
        enabled_plugins = {
            { name = "simpleui" }, { name = "statistics" }, { name = "weui" },
            { name = "weread" }, { name = "zlibrary" },
        },
    }
end

io = {
    open = function(path, mode)
        if mode == "rb" and type(fs[path]) ~= "string" then return nil end
        if mode == "wb" then fs[path] = "" end
        return {
            read = function() return fs[path] end,
            write = function(self, ...)
                fs[path] = fs[path] .. table.concat({ ... })
                return self
            end,
            close = function() return true end,
        }
    end,
}
os.rename = function(from, to)
    if fail_rename == to then return nil, "injected write failure" end
    if fs[from] == nil then return nil, "missing source" end
    local changes = {}
    for path, value in pairs(fs) do
        if path == from or path:sub(1, #from + 1) == from .. "/" then
            changes[path] = { to .. path:sub(#from + 1), value }
        end
    end
    for path, change in pairs(changes) do fs[path] = nil; fs[change[1]] = change[2] end
    return true
end
local real_remove = os.remove
os.remove = function(path)
    if type(fs[path]) ~= "string" then return nil end
    fs[path] = nil
    return true
end
package.loaded["libs/libkoreader-lfs"] = {
    attributes = function(path, field)
        if fs[path] == nil then return nil end
        local mode = fs[path] == true and "directory" or "file"
        return field == "mode" and mode or { mode = mode }
    end,
    mkdir = function(path) fs[path] = true; return true end,
    rmdir = function(path)
        for child in pairs(fs) do
            if child:sub(1, #path + 1) == path .. "/" then return nil end
        end
        fs[path] = nil
        return true
    end,
    dir = function(path)
        local entries = {}
        for child in pairs(fs) do
            if child:sub(1, #path + 1) == path .. "/" then
                local entry = child:sub(#path + 2)
                if not entry:find("/", 1, true) then entries[#entries + 1] = entry end
            end
        end
        local i = 0
        return function() i = i + 1; return entries[i] end
    end,
}
package.loaded.datastorage = {
    getSettingsDir = function() return "/profile/settings" end,
    getFullDataDir = function() return "/profile" end,
}
package.loaded["ffi/util"] = { fsyncOpenedFile = function() end, fsyncDirectory = function() end }
package.loaded.dump = function(data)
    local function serialize(value)
        if type(value) == "string" then return string.format("%q", value) end
        if type(value) ~= "table" then return tostring(value) end
        local fields = {}
        for key, item in pairs(value) do
            fields[#fields + 1] = "[" .. serialize(key) .. "]=" .. serialize(item)
        end
        return "{" .. table.concat(fields, ",") .. "}"
    end
    return serialize(data)
end

seed()
assert(module().run())
assert(fs["/profile/settings/weui/weui_settings.lua"] == "BROKEN LUA", "ordinary install reset data")
assert(fs[ack] == nil)
seed()
fs[marker] = "return os.exit()\n"
assert(not module().run(), "invalid marker accepted")
assert(fs["/profile/settings/weread.lua"] == "old account")
seed()
fs[marker] = request
fail_rename = ack
assert(not module().run(), "reset must fail when acknowledgment cannot persist")
assert(fs[marker] == request and fs[ack] == nil)
assert(fs["/profile/settings/weui/weui_settings.lua"] == "BROKEN LUA", "rollback lost old settings")
assert(fs["/profile/settings/weread.lua.old"] == "backup account")
assert(fs["/profile/settings.reader.lua"] == "original global")
assert(fs["/profile/settings.reader.lua.old"] == "original global backup")
assert(G_reader_settings.data.weread_cookie == "old", "failed reset changed in-memory state")
fail_rename = nil
local initialized = module()
assert(initialized.run(), "failed reset cannot be retried")
assert(fs[marker] == nil and fs[ack] == request)
assert(fs["/profile/settings/weread.lua.old"] == nil)
assert(fs["/profile/settings.reader.lua.old"] == nil)
assert(fs["/profile/weread/library-old.db"] == nil and fs["/profile/weread/library-old.db-wal"] == nil)
assert(fs["/profile/weread/cache/book.epub"] == "downloaded EPUB" and fs["/profile/library/book.epub"] == "EPUB")
assert(G_reader_settings.data.home_dir == "/profile/library" and G_reader_settings.data.language == "zh_CN")
assert(G_reader_settings.data.start_with == "filemanager" and G_reader_settings.data.weread_cookie == nil)
assert(G_reader_settings.data.plugins_disabled.statistics and G_reader_settings.data.plugins_disabled.weread)
assert(#package.loaded.pluginloader.enabled_plugins == 2, "legacy classes still enabled")
fs["/profile/settings/weread.lua"] = "new login"
fs["/profile/settings/weui/weui_settings.lua"] = "new preferences"
fs[marker] = request -- simulate reinstallation, not just marker removal
assert(module().run())
assert(fs["/profile/settings/weread.lua"] == "new login")
assert(fs["/profile/settings/weui/weui_settings.lua"] == "new preferences")
assert(fs[marker] == nil)
io, os.rename, os.remove = real_io, real_rename, real_remove
print("INITIALIZE_OK: ordinary install, invalid request, rollback, retry, retained books, repeated install")

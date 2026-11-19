-- Explicit, one-shot clean installation. Normal release archives have no request.
-- Run before any WeUI module can open or migrate a legacy Lua settings file.
local Initialize = {}
Initialize.REQUEST = "weui-initialize-1.5.4"
Initialize.MARKER = "weui-initialize.request"
Initialize.ACK = ".weui-initialize-completed"
local lfs = require("libs/libkoreader-lfs")
local DataStorage = require("datastorage")
local ffiUtil = require("ffi/util")
local source = debug.getinfo(1, "S").source
local plugin_dir = source:match("^@(.+)/[^/]+$")
local settings_dir = DataStorage:getSettingsDir()
local log_path = settings_dir .. "/weui-initialize.log"
local legacy_plugins = { simpleui = true, lershierui = true, weread = true, zlibrary = true }

local function read(path)
    local file = io.open(path, "rb")
    if not file then return end
    local data = file:read("*a")
    file:close()
    return data
end

local function mkdir(path)
    if lfs.attributes(path, "mode") == "directory" then return end
    assert(lfs.mkdir(path))
end

local function write(path, data)
    local temporary = path .. ".initialize-tmp"
    local file, err = io.open(temporary, "wb")
    assert(file, err)
    local ok, write_err = file:write(data)
    if ok then ffiUtil.fsyncOpenedFile(file) end
    local closed, close_err = file:close()
    assert(ok and closed, write_err or close_err)
    assert(read(temporary) == data, "initialization write verification failed: " .. path)
    assert(os.rename(temporary, path))
    ffiUtil.fsyncDirectory(path)
end

function Initialize.record(stage)
    if not Initialize.clean_profile and not Initialize.requested then return end
    -- No cookies, settings values or account details enter the diagnostic log.
    local previous = read(log_path) or ""
    if #previous > 32768 then previous = previous:sub(-16384) end
    local file = io.open(log_path, "wb")
    if file then
        file:write(previous, os.date("%Y-%m-%d %H:%M:%S"), " ", stage, "\n")
        file:close()
    end
end

function Initialize.retireLegacyPlugins()
    if not Initialize.clean_profile then return end
    local loaded = package.loaded.pluginloader
    if not loaded or type(loaded.enabled_plugins) ~= "table" then return end
    for i = #loaded.enabled_plugins, 1, -1 do
        if legacy_plugins[loaded.enabled_plugins[i].name] then
            table.remove(loaded.enabled_plugins, i)
        end
    end
end

local function owned(key)
    if type(key) ~= "string" then return false end
    for _, prefix in ipairs({
        "weui_", "navbar_", "simpleui_", "lershierui_", "sui_",
        "weread_", "zlibrary_", "zlib_", "quote_deck_", "quote_hl_deck_", "quote_custom_deck_",
    }) do
        if key:sub(1, #prefix) == prefix then return true end
    end
    return false
end

function Initialize.run()
    if not plugin_dir then return true end
    local marker = plugin_dir .. "/" .. Initialize.MARKER
    local request = read(marker)
    local ack = settings_dir .. "/" .. Initialize.ACK
    if read(ack) == Initialize.REQUEST .. "\n" then
        Initialize.clean_profile = true
        -- A repeated copy of this archive must not erase newly saved settings.
        if request == Initialize.REQUEST .. "\n" then os.remove(marker) end
        Initialize.record("startup: initialized profile")
        Initialize.retireLegacyPlugins()
        return true
    end
    if not request then return true end
    Initialize.requested = true
    if request ~= Initialize.REQUEST .. "\n" then
        Initialize.record("reset rejected: invalid initialization request")
        return false
    end

    local moved, created = {}, {}
    local global = G_reader_settings
    local original_data = global and global.data
    local global_path = global and global.file
    local original_file = global_path and read(global_path)
    local backup
    local ok, err = pcall(function()
        assert(type(original_data) == "table" and global_path, "reader settings unavailable")
        local root = DataStorage:getFullDataDir()
        assert(root, "KOReader data directory unavailable")
        local base = settings_dir .. "/.weui-initialize-backup-" .. os.date("%Y%m%d-%H%M%S")
        backup = base
        local suffix = 0
        while lfs.attributes(backup) do
            suffix = suffix + 1
            backup = base .. "-" .. suffix
        end
        mkdir(backup)
        Initialize.record("reset: begin; backup=" .. backup)
        if original_file then write(backup .. "/settings.reader.lua", original_file) end

        local function quarantine(path)
            if not lfs.attributes(path) then return end
            local destination = backup .. "/" .. (#moved + 1) .. "-" .. path:match("[^/]+$")
            assert(os.rename(path, destination))
            moved[#moved + 1] = { path, destination }
            -- Keep a non-executable manifest for interrupted reset recovery.
            local manifest = {}
            for _, entry in ipairs(moved) do
                manifest[#manifest + 1] = entry[2] .. "\t" .. entry[1] .. "\n"
            end
            write(backup .. "/files.txt", table.concat(manifest))
            ffiUtil.fsyncDirectory(path)
        end
        for _, name in ipairs({ "weui", "simpleui", "lershierui", "weread_covers" }) do
            quarantine(settings_dir .. "/" .. name)
        end
        for _, name in ipairs({
            "weui_settings.lua", "sui_settings.lua", "lershierui_settings.lua",
            "weread.lua", "weread-mock.lua", "weread-environment.lua", "zlibrary.lua",
        }) do
            for _, extension in ipairs({ "", ".old", ".data", ".data.old" }) do
                quarantine(settings_dir .. "/" .. name .. extension)
            end
        end
        for _, directory in ipairs({ plugin_dir, plugin_dir .. "/../zlibrary.koplugin" }) do
            quarantine(directory .. "/zlibrary_credentials.lua")
            quarantine(directory .. "/zlibrary_credentials.lua.old")
        end
        quarantine(root .. "/cache/zlibrary")
        for _, name in ipairs({ "weread", "weread-mock" }) do
            local directory = root .. "/" .. name
            if lfs.attributes(directory, "mode") == "directory" then
                local entries = {}
                for entry in lfs.dir(directory) do
                    if entry:match("^library%-.+%.db") or entry == "external-annotations" then
                        entries[#entries + 1] = entry
                    end
                end
                for _, entry in ipairs(entries) do quarantine(directory .. "/" .. entry) end
            end
        end
        Initialize.record("reset: legacy settings isolated")
        -- Leave downloaded EPUBs and their native KOReader sidecars untouched.
        -- A fresh download root also avoids reusing old per-book JSON/SQLite.
        mkdir(root .. "/weread")
        local download_dir = root .. "/weread/cache-initialized-1.5.4"
        mkdir(download_dir)
        mkdir(settings_dir .. "/weui")
        local function settings(path, data)
            created[#created + 1] = path
            write(path, "return " .. require("dump")(data, nil, true) .. "\n")
        end
        settings(settings_dir .. "/weui/weui_settings.lua", {
            weui_onboarding_done = true,
            weui_weread_lazy_init = true,
            weui_initialized_version = "1.5.4",
        })
        settings(settings_dir .. "/weread.lua", { download_dir = download_dir })

        local clean = {}
        for key, value in pairs(original_data) do
            if not owned(key) then clean[key] = value end
        end
        local disabled = {}
        for key, value in pairs(type(clean.plugins_disabled) == "table" and clean.plugins_disabled or {}) do
            disabled[key] = value
        end
        for name in pairs(legacy_plugins) do disabled[name] = true end
        disabled.weui = nil
        clean.plugins_disabled = disabled
        clean.start_with = "filemanager"
        -- Skip the old plugin-folder assets/quote-key migration.
        clean.weui_userdata_migrated_v1 = true
        global.data = clean
        write(global_path, "return " .. require("dump")(clean, nil, true) .. "\n")
        -- Quarantine fallback too: it must never restore old plugin state.
        quarantine(global_path .. ".old")
        Initialize.record("reset: clean settings written")
        write(ack, Initialize.REQUEST .. "\n")
    end)
    if not ok then
        if global then global.data = original_data end
        for _, path in ipairs(created) do os.remove(path) end
        -- We never continue with a partially reset profile in this process.
        -- Preserve quarantined files if a filesystem problem blocks rollback.
        for i = #moved, 1, -1 do
            local entry = moved[i]
            if lfs.attributes(entry[1], "mode") == "directory" then lfs.rmdir(entry[1]) end
            os.rename(entry[2], entry[1])
        end
        if original_file then pcall(write, global_path, original_file) end
        Initialize.record("reset failed: " .. tostring(err))
        return false
    end
    Initialize.clean_profile = true
    os.remove(marker) -- ACK already persisted, so a failed removal is harmless.
    Initialize.record("reset complete; old data backup=" .. backup)
    Initialize.retireLegacyPlugins()
    return true
end

return Initialize

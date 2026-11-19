-- One library root for the shelf and both download sources.
local lfs = require("libs/libkoreader-lfs")
local realpath = require("ffi/util").realpath
local M = {}

function M.main()
    local path = G_reader_settings and G_reader_settings:readSetting("home_dir")
    if type(path) ~= "string" or path == "" then path = require("device").home_dir end
    return path and (realpath(path) or path)
end

function M.setMain(path, plugin)
    path = type(path) == "string" and realpath(path)
    if not path or lfs.attributes(path, "mode") ~= "directory" then
        return false, "请选择一个已有文件夹。"
    end
    if path == realpath(lfs.currentdir()) then
        return false, "请选择 KOReader 程序目录之外的文件夹。"
    end
    -- A unique, short-lived probe avoids overwriting a user's file.
    local probe = path .. "/.weui-write-test-" .. tostring({}):gsub("[^%w]", "")
    if lfs.attributes(probe) then return false, "请重新选择此文件夹。" end
    local file = io.open(probe, "w")
    if not file then return false, "这个文件夹不可写，请选择其他目录。" end
    local ok = file:write("WeUI")
    file:close()
    os.remove(probe)
    if not ok then return false, "无法写入这个文件夹。" end

    local ZConfig = require("zlibrary.config")
    local fm = plugin and plugin.ui
    if fm and fm.folder_shortcuts then fm.folder_shortcuts:updateShortcut("home_dir", path) end
    G_reader_settings:saveSetting("home_dir", path)
    G_reader_settings:flush()
    ZConfig.saveSetting(ZConfig.SETTINGS_DOWNLOAD_DIR_KEY, path)
    ZConfig.saveSetting(ZConfig.SETTINGS_FOLLOW_LIBRARY_KEY, true)
    local wr = plugin and plugin._weread_plugin
    if wr and wr.settings then
        wr.settings:set_download_dir(path, true)
    else
        -- WeRead initializes lazily; persist the choice without creating an
        -- account/session or loading its client on the UI thread.
        local settings = require("luasettings"):open(require("datastorage"):getSettingsDir() .. "/weread.lua")
        settings:saveSetting("download_dir", path)
        settings:saveSetting("download_dir_follow_library", true)
        settings:flush()
    end
    if fm and fm.updateTitleBarPath then fm:updateTitleBarPath() end
    require("weui_library").invalidate()
    return true, path
end

return M

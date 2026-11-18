-- Use the pinned upstream native annotation regression through the WeUI host.
-- The bootstrap is adapted; HTTP, SQLite, UIManager and CREngine stay real.
local UIManager = require("ui/uimanager")
local root = assert(os.getenv("WEUI_WEREAD_QA_ROOT"))
local home = assert(os.getenv("KO_HOME"))
G_reader_settings:saveSetting("home_dir", home .. "/library")
G_reader_settings:saveSetting("lastdir", home .. "/library")
G_reader_settings:saveSetting("last_migration_date", 20260623)
local started
require("userpatch").registerPatchPluginFunc("weui", function()
    if started then return end
    started = true
    UIManager:scheduleIn(1.5, function()
        local ok, err = xpcall(function()
            local FM = require("apps/filemanager/filemanager")
            local host = assert(FM.instance._weui_plugin)
            local wr = assert(host:_initWeReadModule())
            if not os.getenv("WEUI_WEREAD_READER_ONLY") then
                dofile(host.path .. "/scripts/qa/fixtures/weread_feature_checks.lua")(host, wr, root)
            end
            if os.getenv("WEUI_WEREAD_FEATURES_ONLY") then
                local marker = assert(io.open(root .. "/evidence/suite.pass", "w"))
                marker:write("PASS: WeUI native shelf/settings/download feature flows\n"); marker:close()
                UIManager:quit(); return
            end
            local file = assert(io.open(host.path .. "/weread/spec/koreader/weread_annotations_mock.lua"))
            local source = file:read("*a"); file:close()
            source = assert(source:match("(local socket = require%('socket'%).*)"))
            source = "local UIManager = require('ui/uimanager')\n"
                .. "local Screen = require('device').screen\n"
                .. "local home = assert(os.getenv('KO_HOME'))\n" .. source
            source = source:gsub("require%('weread%.lib%.client'%)", "require('lib.weread_client')")
            source = source:gsub("plugin = assert%(reader%.weread%)",
                "plugin = assert(reader.weread, 'host failed to initialize before ReaderReady')\n"
                .. "assert(plugin._reader_session_gen > 0, 'reader services missed ReaderReady')")
            source = source:gsub("local reader, plugin", [[
local reader, plugin
local function file_bytes(file)
    local handle = assert(io.open(file, "rb"))
    local bytes = handle:read("*a"); handle:close(); return bytes
end
local epub_hash = require("weread.lib.crypto").sha256_hex(file_bytes(path))
local native_annotations
]])
            source = source:gsub("open_reader%(%)\nlocal picker", [[
open_reader()
reader.annotation:addItem {
    page = reader.document:getPageXPointer(1), pageno = 1,
    text = "保留本地书签", note = "此笔记不能被微信读书匹配覆盖",
    datetime = "2026-11-17 12:00:00",
}
native_annotations = require("util").tableDeepCopy(reader.annotation.annotations)
local picker]])
            source = source:gsub("reader:onClose%(%)%; UIManager:quit%(%)", [[
assert(require("util").tableEquals(reader.annotation.annotations, native_annotations),
    "native annotations changed: " .. json.encode(native_annotations) .. " -> " .. json.encode(reader.annotation.annotations))
assert(require("weread.lib.crypto").sha256_hex(file_bytes(path)) == epub_hash, "EPUB bytes changed")
dofile(plugin.path .. "/scripts/qa/fixtures/weread_reader_checks.lua")(
    reader, plugin, book, chapters, path, pump_until, pump_for, shot, control, dismiss_info)
UIManager:quit()
]])
            if os.getenv("WEUI_WEREAD_READER_ONLY") then
                source = source:sub(1, assert(source:find("local picker = assert", 1, true)) - 1) .. [[
plugin:startUnifiedAnnotationSync { chapters = { chapters[1], chapters[2] } }
pump_until(function() return plugin._external_annotation_sync ~= nil end)
pump_until(function() return not plugin._external_annotation_sync end)
dismiss_info()
dofile(plugin.path .. "/scripts/qa/fixtures/weread_reader_checks.lua")(
    reader, plugin, book, chapters, path, pump_until, pump_for, shot, control, dismiss_info)
UIManager:quit()
]]
            end
            assert(loadstring(source, "@WeUI-native-annotation-regression"))()
            local marker = assert(io.open(root .. "/evidence/suite.pass", "w"))
            marker:write("PASS: WeUI feature flows and native annotation regression\n"); marker:close()
        end, debug.traceback)
        if not ok then
            print("FAIL: WeRead feature QA\n" .. tostring(err))
            UIManager:quit(1)
        end
    end)
end)

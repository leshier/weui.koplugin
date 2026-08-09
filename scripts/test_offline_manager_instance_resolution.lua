-- Offline management must resolve the embedded live WeRead instance.

local empty_modules = {
    "ffi/blitbuffer", "ui/font", "ui/geometry", "ui/widget/horizontalspan",
    "ui/widget/linewidget", "ui/widget/textwidget", "ui/uimanager",
    "ui/widget/verticalgroup", "ui/widget/verticalspan", "logger",
    "weui_style", "weui_core",
}
for _, name in ipairs(empty_modules) do
    package.preload[name] = function() return {} end
end
package.preload["device"] = function() return { screen = {} } end
package.preload["weui_i18n"] = function()
    return { translate = function(s) return s end, ngettext = function(s) return s end }
end
package.preload["weui_weread"] = function()
    return { isBookDownloaded = function() end }
end

local reader_instance = { settings = {}, downloader = {} }
package.loaded["apps/reader/readerui"] = {
    instance = { weui = { _weread_plugin = reader_instance } },
}
package.loaded["apps/filemanager/filemanager"] = nil

package.path = "./?.lua;" .. package.path
local OfflineManager = require("ui/offline_manager")
assert(OfflineManager._getWeRead() == reader_instance)

package.loaded["apps/reader/readerui"].instance = nil
local filemanager_instance = { settings = {}, downloader = {} }
package.loaded["apps/filemanager/filemanager"] = {
    instance = { weui = { weread = filemanager_instance } },
}
assert(OfflineManager._getWeRead() == filemanager_instance)

package.loaded["apps/filemanager/filemanager"].instance = nil
assert(OfflineManager._getWeRead() == nil, "class table must not be treated as a live instance")

print("OFFLINE_MANAGER_INSTANCE_RESOLUTION_OK")

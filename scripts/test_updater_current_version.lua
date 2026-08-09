-- Regression harness: the updater must read metadata after KOReader removed
-- support for the deprecated `_meta.lua` name field.

local root = (arg[0]:match("^(.*)/scripts/") or ".")
package.path = root .. "/?.lua;" .. package.path

G_reader_settings = {
    readSetting = function() end,
}

package.loaded["ui/uimanager"] = {}
package.loaded["ui/widget/infomessage"] = { new = function(_, value) return value end }
package.loaded["ui/widget/confirmbox"] = { new = function(_, value) return value end }
package.loaded.logger = {
    warn = function() end,
    err = function() end,
    info = function() end,
}
package.loaded.weui_i18n = { translate = function(value) return value end }

local updater = dofile(root .. "/weui_updater.lua")
local expected = assert(dofile(root .. "/_meta.lua").version)
assert(updater._currentVersion() == expected,
    "updater did not read the installed WeUI version")

print("UPDATER_CURRENT_VERSION_OK")

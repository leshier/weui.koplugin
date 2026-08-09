-- Structural regression harness for the true single-plugin distribution.

local root = (arg[0]:match("^(.*)/scripts/") or ".")

local function read(path)
    local fh = assert(io.open(root .. "/" .. path, "rb"), "missing " .. path)
    local body = fh:read("*a")
    fh:close()
    return body
end

for _, path in ipairs({
    "zlibrary/embedded_plugin.lua",
    "zlibrary/api.lua",
    "zlibrary/ui.lua",
    "zlibrary/download.lua",
    "zlibrary/config.lua",
    "zlibrary/gettext.lua",
    "zlibrary/runtime_locale.lua",
    "l10n/zh_CN/koreader.mo",
    "LICENSE.zlibrary",
}) do
    read(path)
end

local embedded = read("zlibrary/embedded_plugin.lua")
assert(not embedded:find('require%("zlibrary%.ota"%)'), "embedded module must not self-update")
assert(not embedded:find("registerToMainMenu", 1, true), "embedded module must not add a second plugin menu")

local main = read("main.lua")
assert(main:find('require, "zlibrary.embedded_plugin"', 1, true))
assert(main:find('registerModule("zlibrary"', 1, true))
assert(main:find('plugins_dir .. "/zlibrary.koplugin"', 1, true), "legacy migration missing")

local workflow = read(".github/workflows/release.yml")
assert(not workflow:find("ZLIBRARY_TAG", 1, true), "release must not build a second plugin")
assert(not workflow:find("weui%-with%-zlibrary"), "release must expose one asset")
assert(workflow:find("zip %-rq weui%.koplugin%.zip weui%.koplugin"))
assert(workflow:find("%-%-exclude='zlibrary_credentials%.lua'"), "credentials must not be packaged")

package.path = root .. "/?.lua;" .. package.path
package.loaded.logger = { warn = function() end }
package.loaded.weui_i18n = { translate = function(value) return value end }
local meta = assert(loadfile(root .. "/_meta.lua"))()
assert(type(meta.version) == "string" and meta.version:match("^%d+%.%d+%.%d+$"))
assert(type(meta.author) == "string" and meta.author ~= "")
local menu = read("weui_menu.lua")
assert(not menu:find('Meta.name ~= "weui"', 1, true),
    "About screen still rejects standard KOReader metadata")
assert(menu:find("Meta.version or", 1, true), "About screen does not display the version")
assert(menu:find("Meta.author or", 1, true), "About screen does not display the author")

print("EMBEDDED_ZLIBRARY_LAYOUT_OK")

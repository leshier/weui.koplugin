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

print("EMBEDDED_ZLIBRARY_LAYOUT_OK")

-- Regression audit for Simplified-Chinese Z-Library UI text.

local root = (arg[0]:match("^(.*)/scripts/") or ".")

local function read(path)
    local fh = assert(io.open(root .. "/" .. path, "rb"), "missing " .. path)
    local body = fh:read("*a")
    fh:close()
    return body
end

local language_names = assert(loadfile(root .. "/zlibrary/language_names_zh.lua"))()
local config = read("zlibrary/config.lua")
local language_section = assert(config:match("Config%.SUPPORTED_LANGUAGES = {(.-)\n}"))
local language_count = 0
for value in language_section:gmatch('value = "([^"]+)"') do
    language_count = language_count + 1
    local display_name = language_names[value]
    assert(display_name, "missing Chinese language name for API key: " .. value)
    assert(not display_name:find("[A-Za-z]"),
        "Chinese language name contains Latin UI text: " .. value .. " = " .. display_name)
end
assert(language_count == 191, "unexpected Z-Library language count: " .. language_count)

local mapped_count = 0
for _ in pairs(language_names) do mapped_count = mapped_count + 1 end
assert(mapped_count == language_count, "Chinese language map has stale or duplicate entries")

local ui = read("zlibrary/ui.lua")
assert(ui:find('T("%s by %s%s")', 1, true), "search result author format is not localizable")
assert(not ui:find('"similar books"', 1, true), "similar-books message has raw English text")
assert(ui:find("Config.getLanguageDisplayName", 1, true), "language picker is not localized")
assert(not ui:find("example@email.com", 1, true), "credentials dialog has an English placeholder")

local details = read("zlibrary/bookdetails_dialog.lua")
assert(not details:find("(Not available)", 1, true), "details button contains raw English status")
assert(details:find("Config.getLanguageDisplayName", 1, true), "book language metadata is not localized")

local browse = read("zlibrary/multisearch_dialog.lua")
assert(browse:find('T("%s by %s%s")', 1, true), "browse rows do not localize the author separator")

local api = read("zlibrary/api.lua")
assert(not api:find("data.message or", 1, true), "an API message can bypass Chinese localization")
assert(api:find("_userFacingApiMessage", 1, true), "API error localization guard is missing")

local zh = read("l10n/zh_CN/koreader.po")
assert(zh:find('msgid "Automatic server failover"', 1, true))
assert(zh:find('msgstr "服务器自动切换"', 1, true))

print("ZLIBRARY_CHINESE_UI_OK")

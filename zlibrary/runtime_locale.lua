-- KOReader applies UI-language changes after a restart, so the language can be
-- resolved once per process and shared by every embedded Z-Library module.
local GetText = require("gettext")

local language = GetText.current_lang
if not language and G_reader_settings then
    language = G_reader_settings:readSetting("language")
end

return {
    language = language,
    is_simplified_chinese = language == "zh_CN" or language == "zh_Hans",
}

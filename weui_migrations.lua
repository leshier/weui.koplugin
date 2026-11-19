-- Refresh presentation settings once per Paper layout revision. Account and
-- reading data, including legacy module layouts, remain in their own keys.
local M = {}
local REVISION = 1
local REVISION_KEY = "weui_paper_layout_revision"
local BACKUP_KEY = "weui_paper_layout_backup_v1"

local function copy(value)
    if type(value) ~= "table" then return value end
    local result = {}
    for key, item in pairs(value) do result[key] = copy(item) end
    return result
end

function M.paper(store, config)
    if (tonumber(store:get(REVISION_KEY)) or 0) >= REVISION then return false end
    -- v1.5.0's migration flag cannot guard this repair: first-run defaults
    -- were mistaken for a custom layout, and legacy font scaling survived.
    -- Run before patchFontGetFace captures the global scale at plugin init.
    local defaults = {
        weui_paper_home = true,
        weui_bar_tabs = config.DEFAULT_TABS,
        weui_bar_enabled = true,
        weui_topbar_enabled = true,
        weui_bar_mode = "both",
        weui_bar_navpager_enabled = false,
        weui_navbar_transparent = false,
        weui_statusbar_transparent = false,
        weui_style_font_scale_pct = 100,
        weui_bar_size_pct = 100,
        weui_topbar_size_pct = 100,
        weui_bar_bottom_margin_pct = 100,
        weui_bar_icon_scale_pct = 100,
        weui_bar_label_scale_pct = 100,
        weui_bar_rs_text_scale_pct = 100,
        weui_hs_module_scale = 100,
        weui_hs_label_scale = 100,
        weui_hs_scale_linked = false,
    }
    if store:get(BACKUP_KEY) == nil then
        local backup = { revision = REVISION, values = {}, absent = {} }
        for key in pairs(defaults) do
            local value = store:get(key)
            if value == nil then
                backup.absent[key] = true
            else
                backup.values[key] = copy(value)
            end
        end
        store:setNoFlush(BACKUP_KEY, backup)
    end
    for key, value in pairs(defaults) do
        store:setNoFlush(key, copy(value))
    end
    config.invalidateLayoutCaches()
    store:setNoFlush("weui_settings_migrated_v15_paper", true)
    store:setNoFlush(REVISION_KEY, REVISION)
    -- Persist the backup, refreshed values and completion marker together.
    store:flush()
    return true
end

return M

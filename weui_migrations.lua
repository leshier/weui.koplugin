-- Migrate released stock layouts directly to Paper without applying
-- intermediate dashboard experiments or overwriting personal display settings.
local M = {}
local PAPER_KEY = "weui_settings_migrated_v15_paper"

local function same(values, expected)
    if type(values) ~= "table" or #values ~= #expected then return false end
    for i, value in ipairs(expected) do
        if values[i] ~= value then return false end
    end
    return true
end

local function stockTabs(tabs)
    if type(tabs) ~= "table" then return true end
    if #tabs == 6 and tabs[1] == "home" and tabs[2] == "weui_settings"
            and tabs[3] == "homescreen" and tabs[4] == "weread" then
        return (tabs[5] == "history" and (tabs[6] == "power" or tabs[6] == "zlibrary"))
            or (tabs[5] == "zlibrary" and tabs[6] == "power")
    end
    return same(tabs, { "homescreen", "home", "weread", "stats_calendar", "weui_settings" })
        or same(tabs, { "homescreen", "home", "notes", "stats_calendar", "weui_settings" })
        or same(tabs, { "homescreen", "weread", "home", "stats_calendar", "weui_settings" })
end

function M.paper(store, config)
    if store:isTrue(PAPER_KEY) then return end
    if stockTabs(store:get("weui_bar_tabs")) then
        local tabs = {}
        for i, id in ipairs(config.DEFAULT_TABS) do tabs[i] = id end
        store:set("weui_bar_tabs", tabs)
        config.invalidateTabsCache()
    end
    -- Keep custom home layouts usable through the original module renderer.
    local layout = store:get("weui_layout")
    local pages = type(layout) == "table" and layout.pages
    local page = type(pages) == "table" and pages[1]
    local modules = type(page) == "table" and page.modules
    if type(modules) ~= "table" then modules = store:get("weui_hs_module_order") end
    local stock = type(modules) ~= "table" or #modules == 0
        or same(modules, { "clock", "currently", "recent" })
        or same(modules, { "dashboard_header", "currently", "quick_actions_row_000001", "recent" })
        or same(modules, { "dashboard_header", "currently", "reading_stats", "quick_actions_row_000001", "recent" })
    if type(pages) == "table" then
        for i = 2, #pages do
            local other = type(pages[i]) == "table" and pages[i].modules
            if i > 2 or (type(other) == "table" and #other > 0
                    and not same(other, { "quote", "new_books", "tbr" })
                    and not same(other, { "reading_stats", "quote", "new_books", "tbr" })) then
                stock = false
            end
        end
    end
    if store:get("weui_paper_home") == nil then store:set("weui_paper_home", stock) end
    store:set(PAPER_KEY, true)
    store:flush()
end

return M

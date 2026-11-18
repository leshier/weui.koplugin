-- Upgrades must preserve personal layouts, display options and book data.
local root = (arg[0]:match("^(.*)/scripts/") or ".")
local Migration = dofile(root .. "/weui_migrations.lua")
local defaults = { "homescreen", "home", "notes", "stats_calendar", "weui_settings" }
local function run(settings)
    local writes, flushes, invalidations = {}, 0, 0
    local store = {
        get = function(_, key) return settings[key] end,
        isTrue = function(_, key) return settings[key] == true end,
        set = function(_, key, value) settings[key] = value; writes[key] = true end,
        flush = function() flushes = flushes + 1 end,
    }
    Migration.paper(store, {
        DEFAULT_TABS = defaults,
        invalidateTabsCache = function() invalidations = invalidations + 1 end,
    })
    return writes, flushes, invalidations
end

for _, tabs in ipairs({
    { "home", "weui_settings", "homescreen", "weread", "history", "power" },
    { "home", "weui_settings", "homescreen", "weread", "zlibrary", "power" },
    { "homescreen", "home", "weread", "stats_calendar", "weui_settings" },
    { "homescreen", "weread", "home", "stats_calendar", "weui_settings" },
}) do
    local settings = {
        weui_bar_tabs = tabs,
        weui_layout = { pages = { { modules = { "clock", "currently", "recent" } } } },
        weui_hs_currently_scale = 113, weui_fc_enabled = false,
        weui_hs_reading_stats_items = { "today_time" },
    }
    local layout, items = settings.weui_layout, settings.weui_hs_reading_stats_items
    local _, flushes, invalidations = run(settings)
    assert(table.concat(settings.weui_bar_tabs, "|") == table.concat(defaults, "|"))
    assert(settings.weui_bar_tabs ~= defaults, "settings must not mutate the shared default")
    assert(settings.weui_paper_home == true and flushes == 1 and invalidations == 1)
    assert(settings.weui_layout == layout and settings.weui_hs_reading_stats_items == items)
    assert(settings.weui_hs_currently_scale == 113 and settings.weui_fc_enabled == false)
    local writes = run(settings)
    assert(next(writes) == nil, "second startup must not reset preferences")
end

local custom_tabs = { "power", "weread", "homescreen", "history", "zlibrary", "home" }
local custom_layout = { pages = { { modules = { "clock", "quote", "reading_stats" } } } }
local settings = { weui_bar_tabs = custom_tabs, weui_layout = custom_layout }
run(settings)
assert(settings.weui_bar_tabs == custom_tabs and settings.weui_layout == custom_layout)
assert(settings.weui_paper_home == false, "custom modules must keep their renderer")
settings = {
    weui_layout = { pages = {
        { modules = { "clock", "currently", "recent" } },
        { modules = { "reading_goals" } },
    } },
}
run(settings)
assert(settings.weui_paper_home == false, "custom second page must keep its renderer")
settings = { weui_hs_module_order = { "quote", "reading_stats" } }
run(settings)
assert(settings.weui_paper_home == false, "legacy custom module order must survive")
settings = { weui_paper_home = false }
run(settings)
assert(settings.weui_paper_home == false, "explicit legacy-home preference must survive")
settings = {}
run(settings)
assert(settings.weui_paper_home == true, "fresh installs must use Paper")
print("PAPER_MIGRATION_OK")

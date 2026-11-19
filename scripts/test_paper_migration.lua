-- Upgrade refresh must repair old display settings without touching book data.
local root = (arg[0]:match("^(.*)/scripts/") or ".")
local Migration = dofile(root .. "/weui_migrations.lua")
local defaults = { "homescreen", "home", "notes", "stats_calendar", "weui_settings" }
local scales = {
    "weui_style_font_scale_pct", "weui_bar_size_pct", "weui_topbar_size_pct",
    "weui_bar_bottom_margin_pct", "weui_bar_icon_scale_pct",
    "weui_bar_label_scale_pct", "weui_bar_rs_text_scale_pct",
    "weui_hs_module_scale", "weui_hs_label_scale",
}
local function run(settings)
    local writes, flushes, invalidations = {}, 0, 0
    local store = {
        get = function(_, key) return settings[key] end,
        setNoFlush = function(_, key, value) settings[key] = value; writes[#writes + 1] = key end,
        set = function() error("migration must batch settings in one flush") end,
        flush = function() flushes = flushes + 1 end,
    }
    local applied = Migration.paper(store, {
        DEFAULT_TABS = defaults,
        invalidateLayoutCaches = function() invalidations = invalidations + 1 end,
    })
    return writes, flushes, invalidations, applied
end

for _, migrated in ipairs({ false, true }) do
    local tabs = { "power", "weread", "homescreen", "history", "zlibrary", "home" }
    local layout = { pages = {
        { modules = { "clock", "quote", "reading_stats" } },
        { modules = { "reading_goals" } },
    } }
    local settings = {
        weui_settings_migrated_v15_paper = migrated,
        weui_bar_tabs = tabs, weui_layout = layout, weui_paper_home = false,
        weui_bar_mode = "icons", weui_bar_enabled = false, weui_topbar_enabled = false,
        weui_bar_navpager_enabled = true,
        weui_navbar_transparent = true, weui_statusbar_transparent = true,
        weui_hs_scale_linked = true,
    }
    for _, key in ipairs(scales) do settings[key] = 150 end
    local retained = {
        weui_hs_module_order = { "quote", "reading_stats" },
        weui_hs_currently_scale = 113, weui_fc_enabled = false,
        weui_hs_reading_stats_items = { "today_time" },
        weui_hs_tbr_books = { "/books/waiting.epub" },
        weui_private_books = { ["/books/private.epub"] = true },
        weui_privacy_password = "fixture-only",
        weui_reading_goal_physical = 42,
        weui_zlibrary_proxy_enabled = true,
        weui_zlibrary_proxy_url = "socks5://127.0.0.1:1080",
        weread_accounts = { { user_id = "fixture", token = "fixture-only" } },
        download_dir = "/books/downloads",
        annotations = { { text = "fixture note", page = 12 } },
        reading_progress = 0.42,
    }
    for key, value in pairs(retained) do settings[key] = value end
    local writes, flushes, invalidations, applied = run(settings)
    assert(applied and flushes == 1 and invalidations == 1)
    assert(writes[1] == "weui_paper_layout_backup_v1", "backup must precede reset")
    assert(writes[#writes] == "weui_paper_layout_revision", "completion marker must be last")
    assert(table.concat(settings.weui_bar_tabs, "|") == table.concat(defaults, "|"))
    assert(settings.weui_bar_tabs ~= defaults, "do not mutate shared defaults")
    assert(settings.weui_paper_home == true and settings.weui_bar_mode == "both")
    assert(settings.weui_bar_enabled and settings.weui_topbar_enabled)
    assert(not settings.weui_bar_navpager_enabled and not settings.weui_hs_scale_linked)
    assert(not settings.weui_navbar_transparent and not settings.weui_statusbar_transparent)
    assert(settings.weui_paper_layout_revision == 1 and settings.weui_settings_migrated_v15_paper)
    local backup = settings.weui_paper_layout_backup_v1
    assert(backup.revision == 1 and backup.values.weui_paper_home == false)
    assert(backup.values.weui_bar_tabs ~= tabs and backup.values.weui_bar_tabs[1] == "power")
    tabs[1] = "changed"; settings.weui_bar_tabs[1] = "changed"
    assert(backup.values.weui_bar_tabs[1] == "power", "backup must be independent")
    for _, key in ipairs(scales) do
        assert(settings[key] == 100 and backup.values[key] == 150, key)
    end
    assert(settings.weui_layout == layout, "legacy layout must remain stored")
    for key, value in pairs(retained) do
        assert(settings[key] == value, "personal data changed: " .. key)
        assert(backup.values[key] == nil and backup.absent[key] == nil, "backup must contain display keys only")
    end
    settings.weui_style_font_scale_pct = 120
    settings.weui_paper_home = false
    settings.weui_bar_mode = "labels"
    writes, flushes, invalidations, applied = run(settings)
    assert(not applied and #writes == 0 and flushes == 0 and invalidations == 0)
    assert(settings.weui_style_font_scale_pct == 120 and settings.weui_paper_home == false
        and settings.weui_bar_mode == "labels", "later preferences must survive restart")
    assert(settings.weui_paper_layout_backup_v1 == backup, "backup must never be overwritten")
end

-- The actual first-run default module order used to be mistaken for a custom
-- home. It must activate Paper, even if v1.5.0 already marked it migrated.
local order = { "quote", "currently", "recent", "clock", "coverdeck", "new_books",
    "tbr", "collections", "reading_goals", "reading_stats", "quick_actions_row_000001",
    "quick_actions_row_000002", "quick_actions_row_000003", "action_list" }
local settings = { weui_hs_module_order = order, weui_settings_migrated_v15_paper = true }
run(settings)
assert(settings.weui_paper_home == true and settings.weui_hs_module_order == order)
assert(settings.weui_paper_layout_backup_v1.absent.weui_paper_home == true)

settings = {}
run(settings)
assert(settings.weui_paper_home == true, "fresh installs must use Paper")
assert(settings.weui_paper_layout_backup_v1.absent.weui_bar_tabs == true)
assert(settings.weui_paper_layout_backup_v1.values.weui_bar_tabs == nil)

-- Replay of a partially attempted refresh must retain the original backup.
local backup = { revision = 1, values = { weui_style_font_scale_pct = 140 }, absent = {} }
settings = { weui_paper_layout_backup_v1 = backup, weui_style_font_scale_pct = 130 }
run(settings)
assert(settings.weui_style_font_scale_pct == 100 and settings.weui_paper_layout_backup_v1 == backup)

for _, revision in ipairs({ 1, 2, "2" }) do
    settings = { weui_paper_layout_revision = revision, weui_style_font_scale_pct = 110 }
    local writes, flushes, invalidations, applied = run(settings)
    assert(not applied and #writes == 0 and flushes == 0 and invalidations == 0)
    assert(settings.weui_style_font_scale_pct == 110, "same or newer revision must be left alone")
end
print("PAPER_MIGRATION_OK")

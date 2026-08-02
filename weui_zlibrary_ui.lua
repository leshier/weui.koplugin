-- weui_zlibrary_ui.lua — keep the WeUI navigation bars on Z-Library pages.
--
-- zlibrary.koplugin deliberately remains an independent companion plugin.
-- Its main browser (MultiSearchDialog) and result lists are fullscreen, but
-- they do not set KOReader's covers_fullscreen flag.  WeUI's generic bar
-- injector consequently used to treat them as ordinary dialogs and the
-- companion's white page covered the bottom navigation bar.
--
-- This adapter registers those two companion widget classes with WeUI's Bar
-- Injection API.  It contains no Z-Library business logic and does not patch
-- files in the companion plugin, so it works with both separate and combined
-- installations.

local logger = require("logger")
local Screen = require("device").screen

local M = {}

local DESCRIPTOR_ID = "zlibrary_full_page"
local GROUP_ID = "zlibrary"
local _installed = false

local function ensureDefaultDownloadDir()
    local ok_config, Config = pcall(require, "zlibrary.config")
    if not (ok_config and Config) then
        return false, "companion unavailable"
    end

    local key = Config.SETTINGS_DOWNLOAD_DIR_KEY or "zlibrary_download_dir"
    local existing = Config.getSetting and Config.getSetting(key)
    if type(existing) == "string" and existing ~= "" then
        return true, existing, false
    end

    -- KOReader's home_dir is the root shown by the Library tab. On Kindle it
    -- is normally /mnt/us; on desktop it is the directory selected as the
    -- library root. Fall back to KOReader's own default only when home_dir is
    -- unavailable.
    local root = G_reader_settings
        and G_reader_settings:readSetting("home_dir") or nil
    if type(root) ~= "string" or root == "" then
        local ok_fmu, FileManagerUtil =
            pcall(require, "apps/filemanager/filemanagerutil")
        if ok_fmu and FileManagerUtil
                and type(FileManagerUtil.getDefaultDir) == "function" then
            root = FileManagerUtil.getDefaultDir()
        end
    end
    if type(root) ~= "string" or root == "" then
        return false, "library root unavailable"
    end

    local ok_save, save_err = pcall(Config.saveSetting, key, root)
    if not ok_save then return false, tostring(save_err) end
    logger.info("weui: initialized Z-Library download directory to library root:", root)
    return true, root, true
end

local function inheritsFrom(widget, class)
    if type(widget) ~= "table" or type(class) ~= "table" then return false end
    local current = widget
    local seen = {}
    while type(current) == "table" and not seen[current] do
        if current == class then return true end
        seen[current] = true
        current = getmetatable(current)
    end
    return false
end

local function isZlibraryPage(widget)
    local SearchDialog = package.loaded["zlibrary.multisearch_dialog"]
    if SearchDialog and inheritsFrom(widget, SearchDialog) then
        return true
    end

    local ZlibraryMenu = package.loaded["zlibrary.menu"]
    if not (ZlibraryMenu and widget.is_popout == false
            and inheritsFrom(widget, ZlibraryMenu)) then
        return false
    end

    -- zlibrary.menu is also used for language/format selectors, timeout
    -- settings and base-URL diagnostics.  Some of those persist changes only
    -- from their custom onClose method, so treating every non-popout Menu as a
    -- navigation page would make a bottom-tab switch bypass that contract.
    -- Browser result rows carry stable book_data metadata; match those lists
    -- only. MultiSearchDialog itself is handled by the branch above.
    for _, item in ipairs(widget.item_table or {}) do
        if type(item) == "table" and type(item.book_data) == "table" then
            return true
        end
    end
    return false
end

local function setDimenHeight(target, height)
    if not target then return end
    if target.height ~= nil then target.height = height end
    if target.dimen then target.dimen.h = height end
end

local function clearNumericChildren(widget)
    for i = #widget, 1, -1 do widget[i] = nil end
end

local function rebuildNativeTitleBar(title_bar, width)
    if not title_bar or type(title_bar.init) ~= "function" then return end
    pcall(function() title_bar:free() end)
    clearNumericChildren(title_bar)
    title_bar.width = width
    title_bar.dimen = nil
    title_bar:init()
end

local function resizeTitleBarLayout(title_bar, width)
    if not title_bar then return end
    local screen_w = Screen:getWidth()
    -- A newly-created page already used the current Screen dimensions. Only
    -- rebuild on a later orientation change; this avoids needless churn on
    -- the normal portrait show path.
    if title_bar._weui_zlibrary_screen_w == nil then
        title_bar._weui_zlibrary_screen_w = screen_w
        return
    end
    if title_bar._weui_zlibrary_screen_w == screen_w then return end
    title_bar._weui_zlibrary_screen_w = screen_w

    if title_bar._titlebar then
        rebuildNativeTitleBar(title_bar._titlebar, width)

        local toggle = title_bar._toggle
        local refresh = title_bar._refresh
        if toggle and refresh and type(toggle.init) == "function" then
            local position = toggle.position
            local refresh_padding = tonumber(refresh.padding_right) or 0
            local toggle_w = math.max(1,
                width - (tonumber(refresh.width) or refresh:getSize().w) - refresh_padding)
            pcall(function() toggle:free() end)
            clearNumericChildren(toggle)
            toggle.width = toggle_w
            toggle.dimen = nil
            toggle:init()
            if position then toggle:setPosition(position) end
        end

        local filter_group = title_bar[2]
        if filter_group and filter_group.dimen then filter_group.dimen.w = width end
        title_bar.dimen = nil
    else
        rebuildNativeTitleBar(title_bar, width)
    end
end

local function resizeMenu(menu, height, width)
    if not menu or not height or height <= 0 then return end
    width = width or Screen:getWidth()

    menu.width = width
    menu.height = height
    menu.screen_w = Screen:getWidth()
    menu.screen_h = Screen:getHeight()
    if menu.dimen then
        menu.dimen.w = width
        menu.dimen.h = height
    end
    if menu.inner_dimen then
        local border = tonumber(menu.border_size) or 0
        menu.inner_dimen.w = math.max(1, width - 2 * border)
        menu.inner_dimen.h = math.max(1, height - 2 * border)
    end

    -- Menu:init copies inner_dimen into three private layout containers: the
    -- content overlap, the return-button BottomContainer and the pagination
    -- BottomContainer.  updateItems() does not resize those copies, so update
    -- the existing tree explicitly; otherwise the footer remains at the old
    -- screen bottom underneath the newly injected navigation bar.
    local frame = menu._navbar_inner or menu[1]
    local content = frame and frame[1]
    local inner_w = menu.inner_dimen and menu.inner_dimen.w or width
    local inner_h = menu.inner_dimen and menu.inner_dimen.h or height
    if frame then
        frame.width = width
        frame.height = height
        if frame.dimen then
            frame.dimen.w = width
            frame.dimen.h = height
        end
    end
    if content and content.dimen then
        content.dimen.w = inner_w
        content.dimen.h = inner_h
    end
    if content then
        local page_return = content[2]
        local footer = content[3]
        if page_return and page_return.dimen then
            page_return.dimen.w = inner_w
            page_return.dimen.h = inner_h
        end
        if page_return and page_return[1] and page_return[1].dimen then
            page_return[1].dimen.w = inner_w
        end
        if footer and footer.dimen then
            footer.dimen.w = inner_w
            footer.dimen.h = inner_h
        end
    end
    resizeTitleBarLayout(menu.title_bar, width)

    -- Recalculate before updateItems: zlibrary.menu derives its cover size in
    -- _recalculateDimen, and updateItems then rebuilds rows with that new size.
    pcall(function() menu:_recalculateDimen(false) end)
    pcall(function() menu:updateItems(nil, true) end)
end

local function frameVerticalInsets(frame)
    if not frame then return 0 end
    local padding = tonumber(frame.padding) or 0
    local padding_top = tonumber(frame.padding_top) or padding
    local padding_bottom = tonumber(frame.padding_bottom) or padding
    local margin = tonumber(frame.margin) or 0
    local border = tonumber(frame.bordersize) or 0
    return padding_top + padding_bottom + 2 * (margin + border)
end

local function frameHorizontalInsets(frame)
    if not frame then return 0 end
    local padding = tonumber(frame.padding) or 0
    local padding_left = tonumber(frame.padding_left) or padding
    local padding_right = tonumber(frame.padding_right) or padding
    local margin = tonumber(frame.margin) or 0
    local border = tonumber(frame.bordersize) or 0
    return padding_left + padding_right + 2 * (margin + border)
end

local function resizeZlibraryPage(widget)
    local UI = require("weui_core")
    local content_h = UI.getContentHeight()
    if content_h <= 0 then return end
    local screen_w = Screen:getWidth()

    widget.width = screen_w
    widget.height = content_h
    if widget.dimen then
        widget.dimen.w = screen_w
        widget.dimen.h = content_h
    end

    local SearchDialog = package.loaded["zlibrary.multisearch_dialog"]
    if SearchDialog and inheritsFrom(widget, SearchDialog) then
        -- MultiSearchDialog owns a fullscreen FrameContainer, which in turn
        -- embeds zlibrary.menu.  Resize both layers so pagination and the last
        -- row end above the WeUI bar rather than merely painting behind it.
        local frame = widget._navbar_inner
        if frame then
            frame.width = screen_w
            frame.height = content_h
            if frame.dimen then
                frame.dimen.w = screen_w
                frame.dimen.h = content_h
            end
        end
        local menu_h = math.max(1, content_h - frameVerticalInsets(frame))
        local menu_w = math.max(1, screen_w - frameHorizontalInsets(frame))
        resizeMenu(widget.menu_container, menu_h, menu_w)
    else
        -- Search results and similar-book lists are direct zlibrary.menu
        -- instances.
        resizeMenu(widget, content_h, screen_w)
        setDimenHeight(widget._navbar_inner, content_h)
    end
end

local function activateZlibraryTab(widget, context)
    context = context or {}
    local plugin = context.plugin
    local tabs = context.tabs
    if not (plugin and type(tabs) == "table") then return end

    local Bottombar = require("weui_bottombar")
    plugin.active_action = GROUP_ID

    local function activateOn(target, force_no_arrows)
        if not (target and target._navbar_container) then return end
        if force_no_arrows then target._navbar_force_no_arrows = true end
        Bottombar.replaceBar(target,
            Bottombar.buildBarWidget(GROUP_ID, tabs, nil, nil, force_no_arrows), tabs)
    end

    -- Keep the hidden FM in its own global pagination mode. The capability
    -- marker belongs only to the injected Z-Library page; persisting it on FM
    -- would leave visible Navpager arrows backed by plain-tab touch zones
    -- after Z-Library closes.
    activateOn(plugin.ui, false)
    activateOn(widget, true)
end

local function onInject(widget, context)
    widget._weui_full_page_group = GROUP_ID
    widget._weui_zlibrary_page = true
    widget._navbar_force_no_arrows = true

    -- UIManager closes the WeUI Homescreen after showing a different
    -- fullscreen page. Preserve what was below that Homescreen as the real
    -- Z-Library origin; otherwise leaving Z-Library for Homescreen and then
    -- closing Homescreen would restore a highlighted page that no longer
    -- exists. Do not rewrite ReaderUI origins: its suspended Homescreen may
    -- also remain in the stack while a book is open.
    local RUI = package.loaded["apps/reader/readerui"]
    local HS = package.loaded["weui_homescreen"]
    local hs = HS and HS._instance
    if not (RUI and RUI.instance) and hs
            and widget._navbar_prev_action == "homescreen" then
        widget._weui_zlibrary_opened_from_homescreen = true
        local origin = hs._navbar_prev_action
        if origin == nil then
            local tabs = context and context.tabs or {}
            origin = tabs[1] or "home"
            for _, id in ipairs(tabs) do
                if id == "home" then origin = "home"; break end
            end
        end
        widget._navbar_prev_action = origin
    end

    resizeZlibraryPage(widget)
    activateZlibraryTab(widget, context)
end

local function onRewrap(widget, context)
    resizeZlibraryPage(widget)
    activateZlibraryTab(widget, context)
end

local function untrackCompanionDialog(widget)
    -- zlibrary.koplugin tracks its fullscreen lists in DialogManager, but its
    -- generic Menu/MultiSearch close paths do not always remove them.  A tab
    -- switch closes live stack entries directly, so remove the same objects
    -- from both possible companion instances to avoid a later double-close.
    local instances = {}
    local FM = package.loaded["apps/filemanager/filemanager"]
    local ReaderUI = package.loaded["apps/reader/readerui"]
    if FM and FM.instance and FM.instance.zlibrary then
        instances[#instances + 1] = FM.instance.zlibrary
    end
    if ReaderUI and ReaderUI.instance and ReaderUI.instance.zlibrary
            and ReaderUI.instance.zlibrary ~= instances[1] then
        instances[#instances + 1] = ReaderUI.instance.zlibrary
    end
    for _, instance in ipairs(instances) do
        local manager = instance.dialog_manager
        if manager and type(manager.untrackDialog) == "function" then
            pcall(manager.untrackDialog, manager, widget)
        end
        if instance.active_results_menu == widget then
            instance.active_results_menu = nil
        end
    end
end

local function onClose(widget, context)
    untrackCompanionDialog(widget)
    if widget._navbar_closing_intentionally
            or not (widget._weui_zlibrary_opened_from_homescreen
                or widget._navbar_prev_action == "homescreen") then
        return
    end
    local plugin = context and context.plugin
    if not (plugin and type(plugin._navigate) == "function") then return end

    -- Opening a registered fullscreen page intentionally removes the HS from
    -- the stack. A native Z-Library Close must return to that exact origin even
    -- when the user's startup preference is FileManager (so the generic
    -- start-with-HS fallback is disabled).
    local UIManager = require("ui/uimanager")
    UIManager:scheduleIn(0, function()
        local HS = package.loaded["weui_homescreen"]
        if HS and HS._instance then return end
        local RUI = package.loaded["apps/reader/readerui"]
        if RUI and RUI.instance then return end
        local Config = require("weui_config")
        local pending_token = {}
        plugin._navbar_prev_action_pending = widget._navbar_prev_action
        plugin._navbar_prev_action_pending_token = pending_token
        plugin:_navigate("homescreen", plugin.ui, Config.loadTabConfig(), false)
        UIManager:scheduleIn(0, function()
            if plugin._navbar_prev_action_pending_token == pending_token then
                plugin._navbar_prev_action_pending = nil
                plugin._navbar_prev_action_pending_token = nil
            end
        end)
    end)
end

function M.install()
    local ok_default, default_result = ensureDefaultDownloadDir()
    if not ok_default and default_result ~= "companion unavailable" then
        logger.warn("weui: could not initialize Z-Library download directory:",
            tostring(default_result))
    end
    if _installed then return true end
    local UI = require("weui_core")
    UI.BarInjection.register{
        id = DESCRIPTOR_ID,
        match = isZlibraryPage,
        active_action_id = GROUP_ID,
        -- Z-Library manages its own pagination.  Keeping navpager arrows out
        -- of the shared bar avoids two competing page-state authorities.
        is_pageable = false,
        on_inject = onInject,
        on_rewrap = onRewrap,
        on_close = onClose,
    }
    _installed = true
    logger.info("weui: installed persistent navigation for Z-Library pages")
    return true
end

function M.uninstall()
    if not _installed then return end
    local ok, UI = pcall(require, "weui_core")
    if ok and UI and UI.BarInjection then
        UI.BarInjection.unregister(DESCRIPTOR_ID)
    end
    _installed = false
end

function M.isOpen()
    local UI = require("weui_core")
    for _, entry in ipairs(UI.getWindowStack()) do
        local widget = entry and entry.widget
        if widget and widget._weui_full_page_group == GROUP_ID then
            return true, widget
        end
    end
    return false
end

function M.closeOpenPages()
    local UI = require("weui_core")
    local UIManager = require("ui/uimanager")
    local to_close = {}
    local stack = UI.getWindowStack()
    for i = #stack, 1, -1 do
        local widget = stack[i] and stack[i].widget
        if widget and widget._weui_full_page_group == GROUP_ID then
            to_close[#to_close + 1] = widget
        end
    end
    for _, widget in ipairs(to_close) do
        widget._navbar_closing_intentionally = true
        local close_callback = widget.close_callback
        widget.close_callback = nil
        pcall(UIManager.close, UIManager, widget)
        widget.close_callback = close_callback
        widget._navbar_closing_intentionally = nil
        widget._navbar_injected = nil
        widget._weui_full_page_group = nil
        widget._weui_zlibrary_page = nil
        widget._weui_zlibrary_opened_from_homescreen = nil
        widget._weui_bi_forced_fullscreen = nil
        widget._weui_bi_desc = nil
        widget._navbar_force_no_arrows = nil
    end
    return #to_close
end

-- Exposed for deterministic harnesses; ordinary callers should use install().
M.matchesWidget = isZlibraryPage
M.resizeWidget = resizeZlibraryPage
M.ensureDefaultDownloadDir = ensureDefaultDownloadDir

return M

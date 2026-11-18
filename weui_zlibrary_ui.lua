-- weui_zlibrary_ui.lua — keep the WeUI navigation bars on Z-Library pages.
--
-- Z-Library is vendored as an embedded module under weui.koplugin/zlibrary/.
-- Its main browser (MultiSearchDialog) and result lists are fullscreen, but
-- they do not set KOReader's covers_fullscreen flag.  WeUI's generic bar
-- injector consequently used to treat them as ordinary dialogs and the
-- embedded page covered the bottom navigation bar.
--
-- This adapter registers those two widget classes with WeUI's Bar Injection
-- API. It contains no Z-Library business logic, keeping vendored source
-- upgrades isolated from WeUI's navigation layer.

local logger = require("logger")
local Screen = require("device").screen
local _ = require("weui_i18n").translate

local M = {}

local DESCRIPTOR_ID = "zlibrary_full_page"
local GROUP_ID = "zlibrary"
local _installed = false
local _button_class, _button_init_original, _button_init_wrapper
local _details_class, _details_buttons_original, _details_buttons_wrapper
local _details_download_original, _details_download_wrapper
local _details_favorite_original, _details_favorite_wrapper
local _details_budget_original, _details_budget_wrapper
local _details_build_original, _details_build_wrapper
local _zlibrary_ui_module, _credentials_original, _credentials_wrapper
local installCredentialsAdapter

local DETAIL_ICON_SIZE = Screen:scaleBySize(24)
local DETAIL_ICON_BOX = Screen:scaleBySize(40)

local function decorateBookDetailButton(button)
    local Config = require("weui_config")
    local mappings = {
        { prefix = "\u{F002}  ", icon = Config.ICON.weread_book },
        { prefix = "\u{F019}  ", icon = Config.ICON.weread_download },
        { prefix = "\u{F02D}  ", icon = Config.ICON.weread_notes },
        { prefix = "\u{F0E5}  ", icon = Config.ICON.weread_reviews },
        { prefix = "\u{2665}  ", icon = Config.ICON.zlibrary_favorite },
        { prefix = "\u{2661}  ", icon = Config.ICON.zlibrary_favorite },
        { prefix = "\u{F021}  ", icon = Config.ICON.zlibrary_refresh },
        { prefix = "\u{21A9}  ", icon = Config.ICON.weread_back },
    }
    if type(button) == "table" and type(button.text) == "string" then
        for _, mapping in ipairs(mappings) do
            if button.text:sub(1, #mapping.prefix) == mapping.prefix then
                button.text = button.text:sub(#mapping.prefix + 1)
                button.icon = mapping.icon
                button.icon_width = DETAIL_ICON_SIZE
                button.icon_height = DETAIL_ICON_SIZE
                break
            end
        end
    end
    return button
end

local function decorateBookDetailButtons(rows)
    for _, row in ipairs(type(rows) == "table" and rows or {}) do
        for _, button in ipairs(type(row) == "table" and row or {}) do
            decorateBookDetailButton(button)
        end
    end
    return rows
end

local function deferBookDownload(dialog, UIManager)
    local parent, book = dialog.parent_zlibrary, dialog.book
    UIManager:close(dialog)
    UIManager:nextTick(function()
        if parent and type(parent.downloadBook) == "function" then
            parent:downloadBook(book)
        end
    end)
end

-- KOReader's stock Button treats text and icon as mutually exclusive. Z-Library's
-- detail actions need both, so enhance only the otherwise-unused combination of
-- a text label plus a WeUI SVG path. Existing KOReader buttons are unchanged.
local function installTextIconButtons()
    local ok, Button = pcall(require, "ui/widget/button")
    if not ok or type(Button) ~= "table" or type(Button.init) ~= "function" then
        return false
    end
    if Button._weui_text_icon_owner == M
            and Button.init == Button._weui_text_icon_wrapper then
        return true
    end
    if Button._weui_text_icon_wrapper
            and Button.init == Button._weui_text_icon_wrapper
            and type(Button._weui_text_icon_original) == "function" then
        Button.init = Button._weui_text_icon_original
    end

    local original = Button.init
    local wrapper = function(self)
        original(self)
        if type(self.text) ~= "string" or type(self.icon) ~= "string"
                or not self.icon:find("/", 1, true)
                or not (self.label_container and self.label_widget) then
            return
        end

        local CenterContainer = require("ui/widget/container/centercontainer")
        local Geom = require("ui/geometry")
        local HorizontalGroup = require("ui/widget/horizontalgroup")
        local SUIStyle = require("weui_style")
        local label_h = self.label_container.dimen and self.label_container.dimen.h
            or self.label_widget:getSize().h
        local icon = SUIStyle.iconImage(self.icon,
            math.min(tonumber(self.icon_width) or DETAIL_ICON_SIZE, DETAIL_ICON_SIZE))
        if not icon then return end
        local icon_box = CenterContainer:new{
            dimen = Geom:new{ w = DETAIL_ICON_BOX, h = label_h },
            icon,
        }
        local group = HorizontalGroup:new{
            align = "center",
            icon_box,
            self.label_widget,
        }
        self.label_container[1] = group
        group.parent = self.label_container
        self._weui_text_icon_widget = icon
    end
    Button.init = wrapper
    Button._weui_text_icon_original = original
    Button._weui_text_icon_wrapper = wrapper
    Button._weui_text_icon_owner = M
    _button_class, _button_init_original, _button_init_wrapper = Button, original, wrapper
    return true
end

local function installBookDetailsAdapter()
    local ok, module = pcall(require, "zlibrary.bookdetails_dialog")
    local class = ok and module and module.BookDetailsDialog
    if type(class) ~= "table" or type(class._buildButtons) ~= "function"
            or type(class.onDownloadClick) ~= "function"
            or type(class._contentBudget) ~= "function"
            or type(class._buildInnerDialog) ~= "function" then
        return false
    end
    if class._weui_details_owner == M
            and class._buildButtons == class._weui_details_buttons_wrapper
            and class.onDownloadClick == class._weui_details_download_wrapper
            and class._contentBudget == class._weui_details_budget_wrapper
            and class._buildInnerDialog == class._weui_details_build_wrapper then
        return true
    end
    if class._weui_details_buttons_wrapper
            and class._buildButtons == class._weui_details_buttons_wrapper
            and type(class._weui_details_buttons_original) == "function" then
        class._buildButtons = class._weui_details_buttons_original
    end
    if class._weui_details_download_wrapper
            and class.onDownloadClick == class._weui_details_download_wrapper
            and type(class._weui_details_download_original) == "function" then
        class.onDownloadClick = class._weui_details_download_original
    end
    if class._weui_details_favorite_wrapper
            and class._generateFavoriteButtonDef == class._weui_details_favorite_wrapper
            and type(class._weui_details_favorite_original) == "function" then
        class._generateFavoriteButtonDef = class._weui_details_favorite_original
    end
    if class._weui_details_budget_wrapper
            and class._contentBudget == class._weui_details_budget_wrapper
            and type(class._weui_details_budget_original) == "function" then
        class._contentBudget = class._weui_details_budget_original
    end
    if class._weui_details_build_wrapper
            and class._buildInnerDialog == class._weui_details_build_wrapper
            and type(class._weui_details_build_original) == "function" then
        class._buildInnerDialog = class._weui_details_build_original
    end

    local original_buttons = class._buildButtons
    local buttons_wrapper = function(self)
        return decorateBookDetailButtons(original_buttons(self))
    end
    local original_download = class.onDownloadClick
    local download_wrapper = function(self)
        local UIManager = require("ui/uimanager")
        -- Let UIManager finish removing and repainting the details dialog
        -- before login() shows its MultiInputDialog. On Kindle, doing both in
        -- one callback can leave the credentials window underneath the closing
        -- dialog, so the user sees only the "set username/password" message.
        deferBookDownload(self, UIManager)
    end
    local original_favorite = class._generateFavoriteButtonDef
    local favorite_wrapper
    if type(original_favorite) == "function" then
        favorite_wrapper = function(self, ...)
            return decorateBookDetailButton(original_favorite(self, ...))
        end
        class._generateFavoriteButtonDef = favorite_wrapper
    end
    -- The vendored dialog budgets and centers itself against the full screen.
    -- WeUI reserves permanent status/navigation bars, so reduce the content
    -- budget by that chrome and center the popup in the remaining region.
    local original_budget = class._contentBudget
    local budget_wrapper = function(self, buttons)
        -- The floating cover's paint offset belongs to the standalone dialog.
        -- Keep it inside the content slot when WeUI reserves a status bar above.
        self.pop_out_offset = 0
        local budget = original_budget(self, buttons)
        local UI = require("weui_core")
        local reserved = math.max(0, Screen:getHeight() - UI.getContentHeight())
        return math.max(budget - reserved, Screen:scaleBySize(120))
    end
    local original_build = class._buildInnerDialog
    local build_wrapper = function(self)
        original_build(self)
        local center = self.inner_dialog and self.inner_dialog[1]
        if center and center.dimen then
            local UI = require("weui_core")
            center.dimen.x = 0
            center.dimen.y = UI.getContentTop()
            center.dimen.w = Screen:getWidth()
            center.dimen.h = UI.getContentHeight()
        end
    end
    class._buildButtons = buttons_wrapper
    class.onDownloadClick = download_wrapper
    class._contentBudget = budget_wrapper
    class._buildInnerDialog = build_wrapper
    class._weui_details_buttons_original = original_buttons
    class._weui_details_buttons_wrapper = buttons_wrapper
    class._weui_details_download_original = original_download
    class._weui_details_download_wrapper = download_wrapper
    class._weui_details_favorite_original = original_favorite
    class._weui_details_favorite_wrapper = favorite_wrapper
    class._weui_details_budget_original = original_budget
    class._weui_details_budget_wrapper = budget_wrapper
    class._weui_details_build_original = original_build
    class._weui_details_build_wrapper = build_wrapper
    class._weui_details_owner = M
    _details_class = class
    _details_buttons_original, _details_buttons_wrapper = original_buttons, buttons_wrapper
    _details_download_original, _details_download_wrapper = original_download, download_wrapper
    _details_favorite_original, _details_favorite_wrapper = original_favorite, favorite_wrapper
    _details_budget_original, _details_budget_wrapper = original_budget, budget_wrapper
    _details_build_original, _details_build_wrapper = original_build, build_wrapper
    return true
end

local function getZlibraryInstance()
    local ReaderUI = package.loaded["apps/reader/readerui"]
    if ReaderUI and ReaderUI.instance and ReaderUI.instance.zlibrary then
        return ReaderUI.instance.zlibrary
    end
    local FM = package.loaded["apps/filemanager/filemanager"]
    return FM and FM.instance and FM.instance.zlibrary or nil
end

function M.getAccountStatusText()
    local ok, Config = pcall(require, "zlibrary.config")
    if not ok or not Config then return _("Plugin unavailable") end
    if type(Config.hasCredentials) == "function" and Config.hasCredentials() then
        return _("Configured")
    end
    return _("Not configured")
end

function M.openCredentials()
    local instance = getZlibraryInstance()
    if not instance then
        return false, _("Embedded Z-Library module is unavailable.")
    end
    installCredentialsAdapter()
    if type(instance._promptForCredentials) == "function" then
        instance:_promptForCredentials(function() end)
        return true
    end

    -- Compatibility fallback for older vendored releases which only showed
    -- "Please set username and password" and offered no dialog from download.
    local ok_ui, Ui = pcall(require, "zlibrary.ui")
    local ok_config, Config = pcall(require, "zlibrary.config")
    if not (ok_ui and Ui and type(Ui.showCredentialsDialog) == "function"
            and ok_config and Config) then
        return false, _("Z-Library account settings are unavailable.")
    end
    Ui.showCredentialsDialog(function(email, password)
        Config.saveSetting(Config.SETTINGS_USERNAME_KEY, email)
        Config.saveSetting(Config.SETTINGS_PASSWORD_KEY, password)
        if type(Config.clearUserSession) == "function" then Config.clearUserSession() end
        return true
    end)
    return true
end

installCredentialsAdapter = function()
    local ok, Ui = pcall(require, "zlibrary.ui")
    if not ok or type(Ui) ~= "table"
            or type(Ui.showCredentialsDialog) ~= "function" then
        return false
    end
    if Ui._weui_credentials_owner == M
            and Ui.showCredentialsDialog == Ui._weui_credentials_wrapper then
        return true
    end
    if Ui._weui_credentials_wrapper
            and Ui.showCredentialsDialog == Ui._weui_credentials_wrapper
            and type(Ui._weui_credentials_original) == "function" then
        Ui.showCredentialsDialog = Ui._weui_credentials_original
    end

    local original = Ui.showCredentialsDialog
    local wrapper = function(...)
        local dialog = original(...)
        if dialog then
            local UIManager = require("ui/uimanager")
            UIManager:nextTick(function()
                if UIManager:isWidgetShown(dialog) then
                    if type(dialog.onShowKeyboard) == "function" then
                        pcall(dialog.onShowKeyboard, dialog)
                    end
                    UIManager:setDirty(dialog, "ui")
                end
            end)
        end
        return dialog
    end
    Ui.showCredentialsDialog = wrapper
    Ui._weui_credentials_original = original
    Ui._weui_credentials_wrapper = wrapper
    Ui._weui_credentials_owner = M
    _zlibrary_ui_module, _credentials_original, _credentials_wrapper = Ui, original, wrapper
    return true
end

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
    -- The embedded module tracks its fullscreen lists in DialogManager, but its
    -- generic Menu/MultiSearch close paths do not always remove them.  A tab
    -- switch closes live stack entries directly, so remove the same objects
    -- from both possible UI instances to avoid a later double-close.
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
    local text_icons_ok = installTextIconButtons()
    local details_ok = installBookDetailsAdapter()
    local credentials_ok = installCredentialsAdapter()
    if not details_ok or not credentials_ok then
        logger.warn("weui: incomplete Z-Library UI compatibility:",
            "details=", tostring(details_ok), "credentials=", tostring(credentials_ok))
    else
        logger.info("weui: installed Z-Library account and detail UI adapters",
            "text_icons=", tostring(text_icons_ok))
    end
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
    if _details_class then
        if _details_class._buildButtons == _details_buttons_wrapper then
            _details_class._buildButtons = _details_buttons_original
        end
        if _details_class.onDownloadClick == _details_download_wrapper then
            _details_class.onDownloadClick = _details_download_original
        end
        if _details_class._generateFavoriteButtonDef == _details_favorite_wrapper then
            _details_class._generateFavoriteButtonDef = _details_favorite_original
        end
        if _details_class._contentBudget == _details_budget_wrapper then
            _details_class._contentBudget = _details_budget_original
        end
        if _details_class._buildInnerDialog == _details_build_wrapper then
            _details_class._buildInnerDialog = _details_build_original
        end
        if _details_class._weui_details_owner == M then
            _details_class._weui_details_buttons_original = nil
            _details_class._weui_details_buttons_wrapper = nil
            _details_class._weui_details_download_original = nil
            _details_class._weui_details_download_wrapper = nil
            _details_class._weui_details_favorite_original = nil
            _details_class._weui_details_favorite_wrapper = nil
            _details_class._weui_details_budget_original = nil
            _details_class._weui_details_budget_wrapper = nil
            _details_class._weui_details_build_original = nil
            _details_class._weui_details_build_wrapper = nil
            _details_class._weui_details_owner = nil
        end
    end
    if _zlibrary_ui_module
            and _zlibrary_ui_module.showCredentialsDialog == _credentials_wrapper then
        _zlibrary_ui_module.showCredentialsDialog = _credentials_original
    end
    if _zlibrary_ui_module and _zlibrary_ui_module._weui_credentials_owner == M then
        _zlibrary_ui_module._weui_credentials_original = nil
        _zlibrary_ui_module._weui_credentials_wrapper = nil
        _zlibrary_ui_module._weui_credentials_owner = nil
    end
    if _button_class and _button_class.init == _button_init_wrapper then
        _button_class.init = _button_init_original
    end
    if _button_class and _button_class._weui_text_icon_owner == M then
        _button_class._weui_text_icon_original = nil
        _button_class._weui_text_icon_wrapper = nil
        _button_class._weui_text_icon_owner = nil
    end
    _details_class, _details_buttons_original, _details_buttons_wrapper = nil, nil, nil
    _details_download_original, _details_download_wrapper = nil, nil, nil
    _details_favorite_original, _details_favorite_wrapper = nil, nil
    _details_budget_original, _details_budget_wrapper = nil, nil
    _details_build_original, _details_build_wrapper = nil, nil
    _zlibrary_ui_module, _credentials_original, _credentials_wrapper = nil, nil, nil
    _button_class, _button_init_original, _button_init_wrapper = nil, nil, nil
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
M.decorateBookDetailButtons = decorateBookDetailButtons
M.deferBookDownload = deferBookDownload

return M

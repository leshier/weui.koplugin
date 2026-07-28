-- weui_privacy.lua — private-book access control for We UI.
--
-- This module deliberately keeps the persisted data small:
--   weui_privacy_password      string
--   weui_private_books         table: { [filepath] = true }
--
-- The password is stored in the plugin settings file. It is an access gate for
-- local UI use, not cryptographic protection of the EPUB/PDF file on disk.

local ConfirmBox   = require("ui/widget/confirmbox")
local InfoMessage  = require("ui/widget/infomessage")
local InputDialog  = require("ui/widget/inputdialog")
local ButtonDialog = require("ui/widget/buttondialog")
local UIManager    = require("ui/uimanager")
local _            = require("weui_i18n").translate

local SUISettings = require("weui_store")

local M = {}

local KEY_PASSWORD = "weui_privacy_password"
local KEY_BOOKS    = "weui_private_books"
local KEY_COLLS    = "weui_private_collections"
local KEY_AUTOLOCK = "weui_privacy_autolock_minutes"  -- 0 = disabled (prompt every time)

-- Session unlock state.  nil/0 = locked, otherwise a timestamp (os.time()) of
-- the last successful unlock.  The session expires after autolock_minutes.
local _unlocked_at = nil
local _relock_timer = nil  -- UIManager scheduled function handle

local unpack_args = unpack or table.unpack
local _real_show_reader = nil
local _title_cache = {}

-- Forward declaration: _scheduleRelock / markUnlocked / lockNow (defined
-- below) call invalidateBookCaches, which is itself defined further down.
-- Without this forward declaration those callers would resolve to a nil
-- global at runtime (Lua binds the reference lexically at definition time).
local invalidateBookCaches

-- Set briefly by the history onMenuSelect patch while it re-dispatches an open
-- after the user just unlocked, so the showReader patch doesn't re-prompt.
M._bypass_privacy = false

local function norm(path)
    return type(path) == "string" and path or ""
end

local function normalizeTitle(title)
    if type(title) ~= "string" then return "" end
    title = title:gsub("^%s+", ""):gsub("%s+$", "")
    title = title:gsub("%s+", " ")
    return title:lower()
end

local function titleKey(title)
    local normalized = normalizeTitle(title)
    return normalized ~= "" and ("title:" .. normalized) or nil
end

local function basename(path)
    return norm(path):match("([^/]+)$") or norm(path)
end

local function sameBook(a, b)
    a, b = norm(a), norm(b)
    if a == "" or b == "" then return false end
    if a == b then return true end
    return basename(a) == basename(b)
end

local function filename(path)
    return norm(path):match("([^/]+)$") or _("Private book")
end

local function filenameTitle(path)
    local name = filename(path)
    return name:gsub("%.[^%.]+$", "")
end

local function getBooks()
    local books = SUISettings:get(KEY_BOOKS)
    if type(books) ~= "table" then
        books = {}
    end
    return books
end

local function saveBooks(books)
    SUISettings:set(KEY_BOOKS, books)
end

-- ---------------------------------------------------------------------------
-- Private collections
-- ---------------------------------------------------------------------------
local function getCollections()
    local colls = SUISettings:get(KEY_COLLS)
    if type(colls) ~= "table" then colls = {} end
    return colls
end

local function saveCollections(colls)
    SUISettings:set(KEY_COLLS, colls)
end

-- Returns true if the collection with this name is marked private.
local function isPrivateCollection(coll_name)
    if type(coll_name) ~= "string" or coll_name == "" then return false end
    local colls = getCollections()
    return colls[coll_name] == true
end

-- ---------------------------------------------------------------------------
-- Auto-relock / session unlock
-- ---------------------------------------------------------------------------
local function getAutoLockMinutes()
    local v = tonumber(SUISettings:get(KEY_AUTOLOCK))
    if v == nil then return 0 end  -- default: no session, prompt every time
    return math.max(0, math.floor(v))
end

local function setAutoLockMinutes(minutes)
    minutes = math.max(0, math.floor(tonumber(minutes) or 0))
    SUISettings:set(KEY_AUTOLOCK, minutes)
    -- Reset the session timer when the setting changes.
    _scheduleRelock()
end

-- Schedule (or reschedule) the auto-relock timer.
-- If autolock is disabled or we're not unlocked, clears the timer.
function _scheduleRelock()
    if _relock_timer then
        pcall(function()
            local UIM = require("ui/uimanager")
            UIM:unschedule(_relock_timer)
        end)
        _relock_timer = nil
    end
    local minutes = getAutoLockMinutes()
    if minutes <= 0 or not _unlocked_at then return end
    local UIM = require("ui/uimanager")
    _relock_timer = UIM:scheduleIn(minutes * 60, function()
        _unlocked_at = nil
        _relock_timer = nil
        invalidateBookCaches()
        logger.dbg("weui: privacy: auto-relocked after", minutes, "minutes")
    end)
end

-- Returns true if the user is currently in an unlocked session.
-- When autolock is disabled (0), always returns false (prompt every time).
local function isUnlocked()
    local minutes = getAutoLockMinutes()
    if minutes <= 0 then return false end
    if not _unlocked_at then return false end
    local elapsed = os.time() - _unlocked_at
    if elapsed >= minutes * 60 then
        _unlocked_at = nil
        return false
    end
    return true
end

-- Records a successful unlock: starts the session and arms the relock timer.
-- NOTE: we intentionally do NOT call invalidateBookCaches here. Doing so during
-- the open-book flow (promptUnlock -> markUnlocked) refreshes the homescreen
-- mid-open, which yanks the homescreen to the foreground ("jumps to home").
-- The homescreen re-renders naturally on return from the book, revealing
-- private covers then. lockNow() still refreshes on the reverse transition.
local function markUnlocked()
    _unlocked_at = os.time()
    _scheduleRelock()
end

-- Immediately re-lock: clears session state and refreshes caches.
local function lockNow()
    _unlocked_at = nil
    _scheduleRelock()
    invalidateBookCaches()
end

local function readBookTitle(path)
    path = norm(path)
    if path == "" then return "" end
    if _title_cache[path] ~= nil then return _title_cache[path] end

    local title = ""
    pcall(function()
        local DS = require("docsettings")
        local ok, ds = pcall(DS.open, DS, path)
        if ok and ds then
            local rp = ds:readSetting("doc_props") or {}
            if type(rp.title) == "string" and rp.title ~= "" then
                title = rp.title
            end
            pcall(function() ds:close() end)
        end
    end)
    if title == "" then
        pcall(function()
            local BIM = require("bookinfomanager")
            local ok, bi = pcall(BIM.getBookInfo, BIM, path, false)
            if ok and bi and type(bi.title) == "string" and bi.title ~= "" then
                title = bi.title
            end
        end)
    end
    if title == "" then
        title = filenameTitle(path)
    end
    _title_cache[path] = title
    return title
end

--- Fetch book metadata for the confirmation dialog.
--- Returns { title=..., authors=..., cover=ImageWidget|nil }.
local function getBookMeta(path)
    path = norm(path)
    local meta = { title = filenameTitle(path), authors = "", cover = nil }
    if path == "" then return meta end

    -- title / authors
    pcall(function()
        local DS = require("docsettings")
        local ok, ds = pcall(DS.open, DS, path)
        if ok and ds then
            local rp = ds:readSetting("doc_props") or {}
            if type(rp.title) == "string" and rp.title ~= "" then
                meta.title = rp.title
            end
            if type(rp.authors) == "string" and rp.authors ~= "" then
                meta.authors = rp.authors
            end
            pcall(function() ds:close() end)
        end
    end)
    if meta.authors == "" then
        pcall(function()
            local BIM = require("bookinfomanager")
            local ok, bi = pcall(BIM.getBookInfo, BIM, path, false)
            if ok and bi then
                if type(bi.title) == "string" and bi.title ~= "" then
                    meta.title = bi.title
                end
                if type(bi.authors) == "string" and bi.authors ~= "" then
                    meta.authors = bi.authors
                end
            end
        end)
    end

    -- cover thumbnail (small, for the dialog). This dialog is only shown AFTER
    -- the user unlocked, so fetch the REAL cover, bypassing our BookInfoManager
    -- hook (which strips covers for locked private books). SH.getBookCover can't
    -- be used: it routes through Config.getCoverBB -> the hooked BIM and would
    -- come back empty. Go straight to the original BIM.getBookInfo instead.
    pcall(function()
        local ok_bim, BIM = pcall(require, "bookinfomanager")
        if not ok_bim or not BIM then return end
        local getinfo = BIM._weui_privacy_orig_getBookInfo or BIM.getBookInfo
        local ok_i, info = pcall(getinfo, BIM, path, true)
        if not (ok_i and info and info.has_cover and info.cover_bb) then return end
        local Screen        = require("device").screen
        local ImageWidget   = require("ui/widget/imagewidget")
        local FrameContainer = require("ui/widget/container/framecontainer")
        local Size          = require("ui/size")
        local Blitbuffer    = require("ffi/blitbuffer")
        local cw = Screen:scaleBySize(120)
        local ch = Screen:scaleBySize(160)
        local img = ImageWidget:new{
            image            = info.cover_bb,
            image_disposable = false,  -- bb is owned by BIM's cache; do not free
            width            = cw,
            height           = ch,
            scale_factor     = 1,      -- ImageWidget scales the bb to cw×ch
        }
        meta.cover = FrameContainer:new{
            padding    = 0,
            margin     = 0,
            bordersize = Size.border.thin,
            background = Blitbuffer.COLOR_WHITE,
            img,
        }
    end)

    return meta
end

-- Forward declaration: showInfo is defined later in this file but referenced by
-- showBookDetailsAndConfirm below. Without this, the closure would capture a nil
-- global instead of the local function.
local showInfo

--- Show a confirmation dialog with book details (cover + title/author/file) before
--- opening. Calls on_confirm() if the user taps Open, on_cancel() otherwise.
--- Also offers a "Remove from private" option.
local function showBookDetailsAndConfirm(path, on_confirm, on_cancel)
    local meta = getBookMeta(path)
    local Screen = require("device").screen
    local Font = require("ui/font")
    local Geom = require("ui/geometry")
    local Size = require("ui/size")
    local TextBoxWidget = require("ui/widget/textboxwidget")
    local HorizontalGroup = require("ui/widget/horizontalgroup")
    local VerticalGroup = require("ui/widget/verticalgroup")
    local FrameContainer = require("ui/widget/container/framecontainer")
    local HorizontalSpan = require("ui/widget/horizontalspan")
    local VerticalSpan = require("ui/widget/verticalspan")
    local CenterContainer = require("ui/widget/container/centercontainer")
    local Blitbuffer = require("ffi/blitbuffer")

    -- Cover thumbnail size
    local cw = Screen:scaleBySize(120)
    local ch = Screen:scaleBySize(160)

    -- Build cover widget (or placeholder)
    local cover_widget
    if meta.cover then
        cover_widget = FrameContainer:new{
            padding = 0,
            margin = 0,
            bordersize = Size.border.thin,
            background = Blitbuffer.COLOR_WHITE,
            meta.cover,
        }
    else
        -- Placeholder when no cover available
        cover_widget = FrameContainer:new{
            padding = 0,
            margin = 0,
            bordersize = Size.border.thin,
            background = Blitbuffer.COLOR_WHITE,
            dimen = Geom:new{ w = cw, h = ch },
            CenterContainer:new{
                dimen = Geom:new{ w = cw, h = ch },
                TextBoxWidget:new{
                    text = _("No cover"),
                    face = Font:getFace("x_smallinfofont"),
                    width = cw - 20,
                    alignment = "center",
                },
            },
        }
    end

    -- Right side: title, author, filename
    local text_width = Screen:getWidth() * 0.55
    local title_face = Font:getFace("smalltfont")
    local info_face = Font:getFace("x_smallinfofont")

    local text_group = VerticalGroup:new{ align = "left" }

    -- Title
    local title_text = meta.title ~= "" and meta.title or filename(path)
    text_group[#text_group + 1] = TextBoxWidget:new{
        text = title_text,
        face = title_face,
        width = text_width,
        max_lines = 2,
        fgcolor = Blitbuffer.COLOR_BLACK,
    }

    text_group[#text_group + 1] = VerticalSpan:new{ width = Size.padding.small }

    -- Author
    if meta.authors ~= "" then
        text_group[#text_group + 1] = TextBoxWidget:new{
            text = _("Author: ") .. meta.authors,
            face = info_face,
            width = text_width,
            max_lines = 1,
            fgcolor = Blitbuffer.COLOR_DARK_GRAY,
        }
        text_group[#text_group + 1] = VerticalSpan:new{ width = Size.padding.small }
    end

    -- Filename
    text_group[#text_group + 1] = TextBoxWidget:new{
        text = _("File: ") .. filename(path),
        face = info_face,
        width = text_width,
        max_lines = 2,
        fgcolor = Blitbuffer.COLOR_DARK_GRAY,
    }

    -- Combine cover + text horizontally
    local content = HorizontalGroup:new{ align = "top" }
    content[#content + 1] = cover_widget
    content[#content + 1] = HorizontalSpan:new{ width = Size.padding.large }
    content[#content + 1] = text_group

    local dialog
    local buttons = {
        {  -- row 1: Open (primary action, full width)
            {
                text = _("Open"),
                is_enter_default = true,
                callback = function()
                    UIManager:close(dialog)
                    if on_confirm then on_confirm() end
                end,
            },
        },
        {  -- row 2: Cancel + Remove from private
            {
                text = _("Cancel"),
                callback = function()
                    UIManager:close(dialog)
                    if on_cancel then on_cancel() end
                end,
            },
            {
                text = _("Remove from private"),
                callback = function()
                    UIManager:close(dialog)
                    M.setPrivateBook(path, false)
                    showInfo(_("Removed from private books."))
                    -- Do NOT open the book here: un-privating only clears the flag
                    -- and returns to the previous view.
                end,
            },
        },
    }
    dialog = ButtonDialog:new{
        title = _("Private book"),
        title_align = "center",
        _added_widgets = { content },
        buttons = buttons,
        width_factor = 0.85,
    }
    UIManager:show(dialog)
end

function invalidateBookCaches(path)
    _title_cache[norm(path)] = nil
    pcall(function() SUISettings:del("weui_stale_books_v1") end)
    local SH = package.loaded["desktop_modules/module_books_shared"]
    if SH and type(SH.invalidateSidecarCache) == "function" then
        pcall(function() SH.invalidateSidecarCache() end)
    end
    for _, mod_name in ipairs({
        "desktop_modules/weui_book_row",
        "desktop_modules/module_book_rows",
        "desktop_modules/module_coverdeck",
        "desktop_modules/module_currently",
        "desktop_modules/module_tbr",
    }) do
        local mod = package.loaded[mod_name]
        if mod and type(mod.reset) == "function" then
            pcall(mod.reset)
        end
    end
    local HS = package.loaded["weui_homescreen"]
    if HS then
        HS._cached_books_state = nil
        if HS._instance then
            HS._instance._cached_books_state = nil
            HS._instance._ctx_cache = nil
            HS._instance._enabled_mods_cache = nil
            if type(HS._instance._refreshImmediate) == "function" then
                pcall(function() HS._instance:_refreshImmediate(false) end)
            elseif type(HS._instance._refresh) == "function" then
                pcall(function() HS._instance:_refresh(false) end)
            end
        end
    end
    local ok_fm, FM = pcall(require, "apps/filemanager/filemanager")
    if ok_fm and FM and FM.instance and FM.instance.file_chooser then
        pcall(function() FM.instance.file_chooser:refreshPath() end)
    end
    local ok_hist, FMH = pcall(require, "apps/filemanager/filemanagerhistory")
    if ok_hist and FMH and FMH.getMenuInstance then
        local menu = FMH.getMenuInstance()
        if menu and type(menu.updateItemTable) == "function" then
            pcall(function() menu:updateItemTable() end)
        end
    end
end

function M.privateTitle()
    return _("Private book")
end

function M.privateAuthor()
    return _("Hidden")
end

function M.getBookTitle(path, fallback_title)
    local fallback_norm = normalizeTitle(fallback_title)
    if fallback_norm ~= "" and fallback_norm ~= normalizeTitle(M.privateTitle())
            and fallback_norm ~= normalizeTitle(M.privateAuthor()) then
        return fallback_title
    end
    return readBookTitle(path)
end

function M.isPrivateBook(path, title)
    path = norm(path)
    if path == "" and normalizeTitle(title) == "" then return false end
    local books = getBooks()
    -- Fast path: nothing is marked private at all -> never private. Avoids the
    -- (potentially DS.open-ing) title read below for the common case where
    -- privacy is not in use, so getBookCover / BookInfoManager hooks stay cheap.
    if next(books) == nil and next(getCollections()) == nil then return false end
    if path ~= "" and books[path] == true then return true end
    local book_title = M.getBookTitle(path, title)
    local key = titleKey(book_title)
    if key and books[key] == true then return true end
    for fp, enabled in pairs(books) do
        if enabled == true and type(fp) == "string" and fp:sub(1, 6) ~= "title:" and sameBook(fp, path) then
            return true
        end
        if enabled == true and type(fp) == "string" and fp:sub(1, 6) ~= "title:" then
            local legacy_title = readBookTitle(fp)
            if normalizeTitle(legacy_title) ~= "" and normalizeTitle(legacy_title) == normalizeTitle(book_title) then
                return true
            end
        end
    end
    -- Also check private collections: if any private collection contains this book,
    -- the book is treated as private.
    local colls = getCollections()
    local has_private_coll = false
    for _cn, enabled in pairs(colls) do
        if enabled == true then has_private_coll = true; break end
    end
    if has_private_coll and path ~= "" then
        local ok_rc, RC = pcall(require, "readcollection")
        if ok_rc and RC then
            local rc = RC.instance or RC
            if rc and rc.coll then
                for coll_name, _ in pairs(colls) do
                    if colls[coll_name] == true and rc.coll[coll_name] then
                        if rc.coll[coll_name][path] then
                            return true
                        end
                        -- Also check by title match (same pattern as per-book).
                        if book_title and book_title ~= "" then
                            for fp, _info in pairs(rc.coll[coll_name]) do
                                if type(fp) == "string" then
                                    local t = readBookTitle(fp)
                                    if normalizeTitle(t) == normalizeTitle(book_title) then
                                        return true
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    return false
end

function M.setPrivateBook(path, enabled, title)
    path = norm(path)
    if path == "" and normalizeTitle(title) == "" then return end
    local books = getBooks()
    local book_title = M.getBookTitle(path, title)
    local key = titleKey(book_title)
    if enabled then
        if key then
            books[key] = true
            if path ~= "" then books[path] = nil end
        elseif path ~= "" then
            books[path] = true
        end
    else
        if key then books[key] = nil end
        if path ~= "" then books[path] = nil end
        for fp, value in pairs(books) do
            if value == true and type(fp) == "string" and fp:sub(1, 6) ~= "title:" then
                if sameBook(fp, path) or normalizeTitle(readBookTitle(fp)) == normalizeTitle(book_title) then
                    books[fp] = nil
                end
            end
        end
    end
    saveBooks(books)
    invalidateBookCaches(path)
end

function M.hasPassword()
    local password = SUISettings:get(KEY_PASSWORD)
    return type(password) == "string" and password ~= ""
end

function M.verifyPassword(password)
    return type(password) == "string"
        and password ~= ""
        and password == SUISettings:get(KEY_PASSWORD)
end

showInfo = function(text)
    UIManager:show(InfoMessage:new{ text = text, timeout = 3 })
end

local function promptSetPassword(on_done)
    local dialog
    dialog = InputDialog:new{
        title       = _("Set private-book password"),
        input       = "",
        input_hint  = _("Password"),
        text_type   = "password",
        description = _("Set the password used to open private books."),
        buttons = {{
            {
                text = _("Cancel"),
                callback = function()
                    UIManager:close(dialog)
                end,
            },
            {
                text = _("Set"),
                is_enter_default = true,
                callback = function()
                    local password = dialog:getInputText()
                    if not password or password == "" then
                        showInfo(_("Password cannot be empty."))
                        return
                    end
                    SUISettings:set(KEY_PASSWORD, password)
                    UIManager:close(dialog)
                    showInfo(_("Private-book password set."))
                    if on_done then on_done() end
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function M.ensurePassword(on_ready)
    if M.hasPassword() then
        if on_ready then on_ready() end
        return
    end
    promptSetPassword(on_ready)
end

-- Three-step password change: verify current -> enter new -> confirm new.
-- Each step blocks the next until it passes, so the password is only replaced
-- when the user proves knowledge of the old one AND enters the new one twice.
function M.changePassword(on_done)
    if not M.hasPassword() then
        showInfo(_("No private-book password is set. Set one first."))
        return
    end
    local cur_dialog
    cur_dialog = InputDialog:new{
        title       = _("Change password"),
        input       = "",
        input_hint  = _("Current password"),
        text_type   = "password",
        description = _("Enter the current private-book password."),
        buttons = {{
            {
                text = _("Cancel"),
                callback = function()
                    UIManager:close(cur_dialog)
                end,
            },
            {
                text = _("Next"),
                is_enter_default = true,
                callback = function()
                    if not M.verifyPassword(cur_dialog:getInputText()) then
                        showInfo(_("Incorrect password."))
                        return
                    end
                    UIManager:close(cur_dialog)
                    local new_dialog
                    new_dialog = InputDialog:new{
                        title       = _("Change password"),
                        input       = "",
                        input_hint  = _("New password"),
                        text_type   = "password",
                        description = _("Enter the new password."),
                        buttons = {{
                            {
                                text = _("Cancel"),
                                callback = function()
                                    UIManager:close(new_dialog)
                                end,
                            },
                            {
                                text = _("Next"),
                                is_enter_default = true,
                                callback = function()
                                    local new_pw = new_dialog:getInputText()
                                    if not new_pw or new_pw == "" then
                                        showInfo(_("Password cannot be empty."))
                                        return
                                    end
                                    UIManager:close(new_dialog)
                                    local conf_dialog
                                    conf_dialog = InputDialog:new{
                                        title       = _("Change password"),
                                        input       = "",
                                        input_hint  = _("Confirm new password"),
                                        text_type   = "password",
                                        description = _("Re-enter the new password to confirm."),
                                        buttons = {{
                                            {
                                                text = _("Cancel"),
                                                callback = function()
                                                    UIManager:close(conf_dialog)
                                                end,
                                            },
                                            {
                                                text = _("Confirm"),
                                                is_enter_default = true,
                                                callback = function()
                                                    if conf_dialog:getInputText() ~= new_pw then
                                                        showInfo(_("Passwords do not match."))
                                                        return
                                                    end
                                                    SUISettings:set(KEY_PASSWORD, new_pw)
                                                    UIManager:close(conf_dialog)
                                                    showInfo(_("Private-book password changed."))
                                                    if on_done then on_done() end
                                                end,
                                            },
                                        }},
                                    }
                                    UIManager:show(conf_dialog)
                                    conf_dialog:onShowKeyboard()
                                end,
                            },
                        }},
                    }
                    UIManager:show(new_dialog)
                    new_dialog:onShowKeyboard()
                end,
            },
        }},
    }
    UIManager:show(cur_dialog)
    cur_dialog:onShowKeyboard()
end

local function promptUnlock(path, on_success)
    local dialog
    dialog = InputDialog:new{
        title       = _("Private book"),
        input       = "",
        input_hint  = _("Password"),
        text_type   = "password",
        description = _("Enter the password to open this private book."),
        buttons = {{
            {
                text = _("Cancel"),
                callback = function()
                    UIManager:close(dialog)
                end,
            },
            {
                text = _("Open"),
                is_enter_default = true,
                callback = function()
                    local password = dialog:getInputText()
                    if not M.verifyPassword(password) then
                        showInfo(_("Incorrect password."))
                        return
                    end
                    UIManager:close(dialog)
                    markUnlocked()
                    -- Show book details and ask for confirmation before opening,
                    -- so the user can see which book it is. Cancelling is silent
                    -- (the user already unlocked; no "locked" nag).
                    showBookDetailsAndConfirm(path, on_success, nil)
                end,
            },
        }},
    }
    -- Defer to the next UI tick: showReader runs after onMenuSelect's
    -- close_callback has closed the history menu, so the underlying FM/home
    -- is mid-reveal and would paint over a synchronously-shown dialog.
    UIManager:scheduleIn(0, function()
        UIManager:show(dialog)
        dialog:onShowKeyboard()
    end)
end

local function promptConfirmPassword(on_success)
    local dialog
    dialog = InputDialog:new{
        title       = _("Private book"),
        input       = "",
        input_hint  = _("Password"),
        text_type   = "password",
        description = _("Enter the password to continue."),
        buttons = {{
            {
                text = _("Cancel"),
                callback = function()
                    UIManager:close(dialog)
                end,
            },
            {
                text = _("Confirm"),
                is_enter_default = true,
                callback = function()
                    local password = dialog:getInputText()
                    if not M.verifyPassword(password) then
                        showInfo(_("Incorrect password."))
                        return
                    end
                    UIManager:close(dialog)
                    markUnlocked()
                    if on_success then on_success() end
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function M.requirePassword(on_success)
    M.ensurePassword(function()
        -- If already unlocked, skip the prompt.
        if isUnlocked() then
            markUnlocked()  -- refresh the timer
            if on_success then on_success() end
            return
        end
        promptConfirmPassword(on_success)
    end)
end

function M.requestAccess(path, on_success)
    path = norm(path)
    if path == "" then return end
    if not M.isPrivateBook(path) then
        if on_success then on_success() end
        return
    end
    if not M.hasPassword() then
        showInfo(_("Private-book password is not set."))
        return
    end
    -- If already unlocked (auto-relock session), grant access immediately,
    -- but still show the book-details confirmation so the user sees which book.
    if isUnlocked() then
        -- Refresh the session timer.
        markUnlocked()
        showBookDetailsAndConfirm(path, on_success, nil)
        return
    end
    promptUnlock(path, on_success)
end

function M.openBook(path, after_open)
    path = norm(path)
    M.requestAccess(path, function()
        local ReaderUI = package.loaded["apps/reader/readerui"]
            or require("apps/reader/readerui")
        local show_reader = _real_show_reader or ReaderUI.showReader
        show_reader(ReaderUI, path)
        if after_open then after_open() end
    end)
end

function M.patchReaderUI()
    local ok, ReaderUI = pcall(require, "apps/reader/readerui")
    if not ok or not ReaderUI or ReaderUI._weui_privacy_showReader_patched then
        return
    end
    local orig_show_reader = ReaderUI.showReader
    _real_show_reader = orig_show_reader
    ReaderUI._weui_privacy_showReader_patched = true
    ReaderUI._weui_privacy_orig_showReader = orig_show_reader
    ReaderUI.showReader = function(self_reader, path, ...)
        if type(self_reader) == "string" and path == nil then
            path = self_reader
            self_reader = ReaderUI
        end
        local filepath = norm(path)
        if filepath ~= "" and M.isPrivateBook(filepath) and not M._bypass_privacy then
            local args = { ... }
            M.requestAccess(filepath, function()
                orig_show_reader(self_reader, path, unpack_args(args))
            end)
            return
        end
        return orig_show_reader(self_reader, path, ...)
    end
end

function M.patchHistory()
    local ok_hist, FMH = pcall(require, "apps/filemanager/filemanagerhistory")
    if not ok_hist or not FMH or FMH._weui_privacy_history_patched then
        return
    end
    local orig_update = FMH.updateItemTable
    FMH._weui_privacy_history_patched = true
    FMH._weui_privacy_orig_updateItemTable = orig_update
    FMH.updateItemTable = function(self_hist, ...)
        -- Unlocked session: show real titles/authors in history.
        if M.isUnlocked() then
            return orig_update(self_hist, ...)
        end
        local RH = require("readhistory")
        local hist = RH and RH.hist
        if type(hist) ~= "table" then
            return orig_update(self_hist, ...)
        end
        local display_hist = {}
        local changed = false
        for _, item in ipairs(hist) do
            local display_item = item
            if item and item.file and M.isPrivateBook(item.file) then
                display_item = {}
                for k, v in pairs(item) do display_item[k] = v end
                display_item.text = M.privateTitle()
                display_item.author = M.privateAuthor()
                display_item.mandatory = M.privateAuthor()
                changed = true
            end
            display_hist[#display_hist + 1] = display_item
        end
        if not changed then
            return orig_update(self_hist, ...)
        end
        local original_hist = RH.hist
        RH.hist = display_hist
        local ok, result = pcall(orig_update, self_hist, ...)
        RH.hist = original_hist
        if not ok then error(result) end
        if self_hist.booklist_menu and self_hist.booklist_menu.item_table then
            for _, item in ipairs(self_hist.booklist_menu.item_table) do
                if item and item.file and M.isPrivateBook(item.file) then
                    item.text = M.privateTitle()
                    item.author = M.privateAuthor()
                    item.mandatory = M.privateAuthor()
                end
            end
        end
        return result
    end

    -- Pre-check privacy in onMenuSelect so the password dialog shows OVER the
    -- history menu (before close_callback closes it). Without this, showReader
    -- runs only after close_callback -> menu closes -> homescreen reveals ->
    -- dialog appears on the homescreen ("jumps to home to enter password").
    local orig_onMenuSelect = FMH.onMenuSelect
    if type(orig_onMenuSelect) == "function" and not FMH._weui_privacy_onMenuSelect_patched then
        FMH._weui_privacy_onMenuSelect_patched = true
        FMH._weui_privacy_orig_onMenuSelect = orig_onMenuSelect
        FMH.onMenuSelect = function(self_hist, item)
            local file = item and item.file
            if file and M.isPrivateBook(file) and not M.isUnlocked() and not M._bypass_privacy then
                M.requestAccess(file, function()
                    -- Bypass the showReader patch's re-prompt on the open that
                    -- follows (the user just authenticated).
                    M._bypass_privacy = true
                    orig_onMenuSelect(self_hist, item)
                    M._bypass_privacy = false
                end)
                return
            end
            return orig_onMenuSelect(self_hist, item)
        end
    end
end

function M.maskBookListItems(item_table)
    -- Intentionally a no-op. Item-copy masking broke CoverBrowser mosaic tap
    -- handling (a single tap fired onMenuSelect for multiple items). Private
    -- books are hidden instead via the BookInfoManager hook (placeholder cover
    -- + masked bookinfo.title) in mosaic/cover views, and via getBookCover on
    -- the homescreen. Kept (and called by patchBookList) as a harmless
    -- pass-through so a future list-view-only masking approach can hook here.
    if type(item_table) ~= "table" then return item_table end
    return item_table
end

function M.patchBookList()
    local ok_bl, BookList = pcall(require, "ui/widget/booklist")
    if not ok_bl or not BookList or BookList._weui_privacy_switch_patched then
        return
    end
    local ok_menu, Menu = pcall(require, "ui/widget/menu")
    local orig_switch = BookList.switchItemTable or (ok_menu and Menu and Menu.switchItemTable)
    if type(orig_switch) ~= "function" then return end
    BookList._weui_privacy_switch_patched = true
    BookList._weui_privacy_orig_switchItemTable = BookList.switchItemTable
    BookList.switchItemTable = function(self_list, new_title, new_item_table, ...)
        if new_item_table ~= nil then
            new_item_table = M.maskBookListItems(new_item_table)
        elseif self_list.item_table ~= nil then
            self_list.item_table = M.maskBookListItems(self_list.item_table)
        end
        return orig_switch(self_list, new_title, new_item_table, ...)
    end
end

-- A single unified placeholder cover image (rendered once, cached) for private
-- books in native views. Returned as a COPY per getBookInfo call because
-- CoverBrowser's ImageWidget frees the cover_bb it receives (image_disposable
-- defaults to true), so the cached original must never be handed out directly.
local _private_cover_bb = nil
local _PC_W, _PC_H = 480, 720  -- large enough that CoverBrowser won't discard it as "too small for the grid"

function M.getPrivateCoverBB()
    if _private_cover_bb then return _private_cover_bb end
    local ok, bb = pcall(function()
        local Blitbuffer = require("ffi/blitbuffer")
        local w, h = _PC_W, _PC_H
        local b = Blitbuffer
        local out = b.new(w, h, b.TYPE_BB8)
        -- NOTE: Blitbuffer.gray(level) is INVERTED (0=white, 1=black).
        local bg = b.gray(0.15)  -- light grey
        out:paintRect(0, 0, w, h, bg)
        -- Cute line-art padlock: small, rounded body, prominent arc shackle,
        -- tiny keyhole. Centered with generous margin so it scales fully on
        -- the homescreen without being cropped or overwhelming the cover.
        local line = b.gray(0.5)  -- medium grey: softer than black, lower contrast vs the light bg
        local lw = math.max(4, math.floor(w / 75))
        local size = math.floor(math.min(w, h) * 0.34)
        local cx = math.floor(w / 2)
        local top = math.floor((h - size) / 2)
        local body_w = math.floor(size * 0.72)
        local body_h = math.floor(size * 0.56)
        local body_x = cx - math.floor(body_w / 2)
        local body_y = top + size - body_h
        local body_r = math.floor(body_h * 0.34)  -- very round, cute
        local shackle_r = math.floor(size * 0.24)
        -- Full shackle ring; bottom half hidden by the body.
        out:paintCircle(cx, body_y, shackle_r, line, lw)
        out:paintRect(body_x, body_y, body_w, body_h, bg)  -- erase ring bottom
        out:paintBorder(body_x, body_y, body_w, body_h, lw, line, body_r)
        -- Tiny keyhole dot.
        local kh_r = math.max(2, math.floor(body_h * 0.09))
        out:paintCircle(cx, body_y + math.floor(body_h * 0.40), kh_r, line)
        return out
    end)
    if ok and bb then _private_cover_bb = bb end
    return _private_cover_bb
end

-- Suppress real covers for private books in native views (FileManager mosaic,
-- history, search) that fetch covers via BookInfoManager. Returns a shallow
-- copy with cover fields cleared while locked, so BIM's cached bookinfo object
-- is never mutated. When unlocked, the real cover is shown. BookInfoManager is
-- a singleton module, so this patch is global (covers CoverBrowser too, which
-- routes through BIM).
function M.patchBookInfoManager()
    local ok_bim, BIM = pcall(require, "bookinfomanager")
    if not ok_bim or not BIM or BIM._weui_privacy_bim_patched then
        return
    end
    local orig_getBookInfo = BIM.getBookInfo
    if type(orig_getBookInfo) ~= "function" then return end
    BIM._weui_privacy_bim_patched = true
    BIM._weui_privacy_orig_getBookInfo = orig_getBookInfo
    BIM.getBookInfo = function(self_bim, path, want_cover, ...)
        local info = orig_getBookInfo(self_bim, path, want_cover, ...)
        if info and want_cover
                and type(path) == "string" and path ~= ""
                and M.isPrivateBook(path) and not M.isUnlocked() then
            -- Shallow copy so we never mutate BIM's cached bookinfo. Replace
            -- the real cover with the unified private placeholder image and
            -- mask title/authors. Using a real cover_bb (has_cover=true) makes
            -- CoverBrowser render it at full width like any other cover, so the
            -- frame size matches non-private books (no narrower FakeCover).
            local masked = {}
            for k, v in pairs(info) do masked[k] = v end
            local pcbb = M.getPrivateCoverBB()
            if pcbb then
                masked.cover_bb = pcbb:copy()
                masked.cover_w = _PC_W
                masked.cover_h = _PC_H
                masked.has_cover = true
                masked.ignore_cover = false
                masked.cover_fetched = "Y"
            else
                masked.cover_bb = nil
                masked.has_cover = false
                masked.ignore_cover = true
            end
            masked.title = M.privateTitle()
            masked.authors = M.privateAuthor()
            info = masked
        end
        return info
    end
end

-- Mask the displayed filename of private books in the native file browser
-- (书库). FileChooser sets item.text = filename; CoverBrowser's mosaic FakeCover
-- uses item.text as the filename line, so without this the real filename leaks
-- even though the cover/title are masked. Only masks while locked. The file
-- path (item.path) is untouched, so opening still works.
function M.patchFileChooser()
    local ok_fc, FC = pcall(require, "ui/widget/filechooser")
    if not ok_fc or not FC or FC._weui_privacy_getListItem_patched then
        return
    end
    local orig_getListItem = FC.getListItem
    if type(orig_getListItem) ~= "function" then return end
    FC._weui_privacy_getListItem_patched = true
    FC._weui_privacy_orig_getListItem = orig_getListItem
    FC.getListItem = function(self_fc, dirpath, f, fullpath, attributes, collate, ...)
        local item = orig_getListItem(self_fc, dirpath, f, fullpath, attributes, collate, ...)
        if item and item.is_file and fullpath
                and not M.isUnlocked()
                and M.isPrivateBook(fullpath) then
            item.text = M.privateTitle()
        end
        return item
    end
end

function M.genPrivacyButton(path, close_refresh)
    path = norm(path)
    if path == "" then return nil end
    local title = readBookTitle(path)
    local is_private = M.isPrivateBook(path, title)
    return {
        text = is_private and _("Remove private book") or _("Set as private book"),
        callback = function()
            local function finish(enabled)
                M.setPrivateBook(path, enabled, title)
                if close_refresh then close_refresh() end
                showInfo(enabled and _("This book is now private.") or _("This book is no longer private."))
            end
            M.requirePassword(function() finish(not is_private) end)
        end,
    }
end

function M.installHistoryDialogButtons()
    local ok_hist, FMH = pcall(require, "apps/filemanager/filemanagerhistory")
    if not ok_hist or not FMH then return end
    FMH.file_dialog_added_buttons = FMH.file_dialog_added_buttons or { index = {} }
    if FMH.file_dialog_added_buttons.index["weui_privacy"] ~= nil then
        return
    end
    table.insert(FMH.file_dialog_added_buttons, function(file, is_file, _book_props)
        if not is_file then return nil end
        return {
            M.genPrivacyButton(file, function()
                local menu = FMH.getMenuInstance and FMH.getMenuInstance()
                if menu then
                    -- The long-press file_dialog lives on the booklist_menu
                    -- (menu.file_dialog), not on the FMH manager. Closing
                    -- menu._manager.file_dialog (nil) left the dialog open.
                    local dlg = menu.file_dialog
                        or (menu._manager and menu._manager.file_dialog)
                    if dlg then UIManager:close(dlg) end
                    -- Defer the refresh so it runs after the file_dialog close
                    -- is processed; otherwise the re-render happens behind the
                    -- dialog and the history list doesn't visibly update.
                    UIManager:scheduleIn(0, function()
                        local mgr = menu._manager
                        if mgr and mgr.updateItemTable then
                            pcall(function() mgr:updateItemTable() end)
                        end
                        if menu.updateItems then
                            pcall(function() menu:updateItems() end)
                        end
                        UIManager:setDirty(menu, "ui")
                    end)
                end
            end),
        }
    end)
    FMH.file_dialog_added_buttons.index["weui_privacy"] = #FMH.file_dialog_added_buttons
end

function M.installFileDialogButtons()
    local ok_fm, FM = pcall(require, "apps/filemanager/filemanager")
    if ok_fm and FM and FM.instance then
        FM.instance:addFileDialogButtons("weui_privacy", function(file, is_file, _book_props)
            if not is_file then return nil end
            local ok_dr, DR = pcall(require, "document/documentregistry")
            local ok_bl, BL = pcall(require, "ui/widget/booklist")
            local is_book = (ok_dr and DR and DR:hasProvider(file))
                or (ok_bl and BL and BL.hasBookBeenOpened(file))
            if not is_book then return nil end
            local close_refresh = function()
                local fc = FM.instance and FM.instance.file_chooser
                local dlg = fc and fc.file_dialog
                if dlg then UIManager:close(dlg) end
                if fc then fc:refreshPath() end
            end
            return { M.genPrivacyButton(file, close_refresh) }
        end)
    end

    local ok_fs, FS = pcall(require, "apps/filemanager/filemanagerfilesearcher")
    if ok_fs and FS then
        FS.file_dialog_added_buttons = FS.file_dialog_added_buttons or { index = {} }
        if FS.file_dialog_added_buttons.index["weui_privacy"] == nil then
            table.insert(FS.file_dialog_added_buttons, function(file, is_file, _book_props, close_cb)
                if not is_file then return nil end
                local ok_dr, DR = pcall(require, "document/documentregistry")
                local ok_bl, BL = pcall(require, "ui/widget/booklist")
                local is_book = (ok_dr and DR and DR:hasProvider(file))
                    or (ok_bl and BL and BL.hasBookBeenOpened(file))
                if not is_book then return nil end
                return { M.genPrivacyButton(file, close_cb) }
            end)
            FS.file_dialog_added_buttons.index["weui_privacy"] = #FS.file_dialog_added_buttons
        end
    end
end

-- ---------------------------------------------------------------------------
-- Public API — auto-relock / session
-- ---------------------------------------------------------------------------
function M.isUnlocked()
    return isUnlocked()
end

function M.lockNow()
    lockNow()
end

function M.getAutoLockMinutes()
    return getAutoLockMinutes()
end

function M.setAutoLockMinutes(minutes)
    setAutoLockMinutes(minutes)
end

-- ---------------------------------------------------------------------------
-- Public API — private collections
-- ---------------------------------------------------------------------------
function M.isPrivateCollection(coll_name)
    return isPrivateCollection(coll_name)
end

function M.setPrivateCollection(coll_name, enabled)
    if type(coll_name) ~= "string" or coll_name == "" then return end
    local colls = getCollections()
    if enabled then
        colls[coll_name] = true
    else
        colls[coll_name] = nil
    end
    saveCollections(colls)
    invalidateBookCaches()
end

function M.getPrivateCollections()
    local colls = getCollections()
    local result = {}
    for name, enabled in pairs(colls) do
        if enabled == true then result[#result + 1] = name end
    end
    table.sort(result)
    return result
end

-- Returns true if a collection should show its real content (not disguised).
-- A collection is "revealed" when the user is in an unlocked session AND
-- the collection is private.  For non-private collections, always true.
function M.isCollectionRevealed(coll_name)
    if not isPrivateCollection(coll_name) then return true end
    return isUnlocked()
end

function M.install(_plugin)
    M.patchReaderUI()
    M.patchHistory()
    M.patchBookList()
    M.patchBookInfoManager()
    M.patchFileChooser()
    -- Core modules (ReaderUI/FilemanagerHistory/BookList/FileChooser) may not be
    -- loaded yet at plugin init; re-apply on the next tick once they are. All
    -- patch* are idempotent (guarded by a _weui_privacy_*_patched flag).
    UIManager:scheduleIn(0, function()
        M.patchReaderUI()
        M.patchHistory()
        M.patchBookList()
        M.patchFileChooser()
        M.installFileDialogButtons()
        M.installHistoryDialogButtons()
    end)
end

function M.teardown()
    local ReaderUI = package.loaded["apps/reader/readerui"]
    if ReaderUI and ReaderUI._weui_privacy_showReader_patched then
        ReaderUI.showReader = ReaderUI._weui_privacy_orig_showReader
        ReaderUI._weui_privacy_orig_showReader = nil
        ReaderUI._weui_privacy_showReader_patched = nil
    end
    _real_show_reader = nil
    local FMH = package.loaded["apps/filemanager/filemanagerhistory"]
    if FMH and FMH._weui_privacy_history_patched then
        FMH.updateItemTable = FMH._weui_privacy_orig_updateItemTable
        FMH._weui_privacy_orig_updateItemTable = nil
        FMH._weui_privacy_history_patched = nil
    end
    if FMH and FMH._weui_privacy_onMenuSelect_patched then
        FMH.onMenuSelect = FMH._weui_privacy_orig_onMenuSelect
        FMH._weui_privacy_orig_onMenuSelect = nil
        FMH._weui_privacy_onMenuSelect_patched = nil
    end
    if FMH and FMH.file_dialog_added_buttons then
        local idxp = FMH.file_dialog_added_buttons.index
            and FMH.file_dialog_added_buttons.index["weui_privacy"]
        if idxp then
            table.remove(FMH.file_dialog_added_buttons, idxp)
            FMH.file_dialog_added_buttons.index["weui_privacy"] = nil
            for id, i in pairs(FMH.file_dialog_added_buttons.index) do
                if i > idxp then
                    FMH.file_dialog_added_buttons.index[id] = i - 1
                end
            end
            if #FMH.file_dialog_added_buttons == 0 then
                FMH.file_dialog_added_buttons = nil
            end
        end
    end
    local BL = package.loaded["ui/widget/booklist"]
    if BL and BL._weui_privacy_switch_patched then
        BL.switchItemTable = BL._weui_privacy_orig_switchItemTable
        BL._weui_privacy_orig_switchItemTable = nil
        BL._weui_privacy_switch_patched = nil
    end
    local BIM = package.loaded["bookinfomanager"]
    if BIM and BIM._weui_privacy_bim_patched then
        BIM.getBookInfo = BIM._weui_privacy_orig_getBookInfo
        BIM._weui_privacy_orig_getBookInfo = nil
        BIM._weui_privacy_bim_patched = nil
    end
    local FC = package.loaded["ui/widget/filechooser"]
    if FC and FC._weui_privacy_getListItem_patched then
        FC.getListItem = FC._weui_privacy_orig_getListItem
        FC._weui_privacy_orig_getListItem = nil
        FC._weui_privacy_getListItem_patched = nil
    end
end

return M

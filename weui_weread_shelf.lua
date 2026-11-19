-- weui_weread_shelf.lua — We UI
-- Icon-based WeRead shelf page. Replaces the old single-column menu shelf
-- with the 4-column card grid used by the redesign, while keeping the legacy
-- list (sort / filter / download toolbar) one tap away.

local Blitbuffer      = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device          = require("device")
local Font            = require("ui/font")
local FrameContainer  = require("ui/widget/container/framecontainer")
local Geom            = require("ui/geometry")
local GestureRange    = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan  = require("ui/widget/horizontalspan")
local ImageWidget     = require("ui/widget/imagewidget")
local InputContainer  = require("ui/widget/container/inputcontainer")
local LineWidget      = require("ui/widget/linewidget")
local OverlapGroup    = require("ui/widget/overlapgroup")
local TextWidget      = require("ui/widget/textwidget")
local UIManager       = require("ui/uimanager")
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")

local Screen      = Device.screen
local _           = require("weui_i18n").translate
local Config      = require("weui_config")
local SUIStyle    = require("weui_style")
local UI          = require("weui_core")

local M = {}

local CLR_BLACK = Blitbuffer.COLOR_BLACK
local CLR_GRAY  = Blitbuffer.gray(0.52)
local CLR_LINE  = Blitbuffer.gray(0.78)
local CLR_LIGHT = Blitbuffer.gray(0.92)

local function _badge(text)
    local label = TextWidget:new{
        text    = text,
        face    = Font:getFace(SUIStyle.FACE_REGULAR, UI.SZ(9)),
        fgcolor = Blitbuffer.COLOR_WHITE,
        bold    = true,
    }
    return FrameContainer:new{
        bordersize = 0,
        padding    = Screen:scaleBySize(2),
        padding_left = Screen:scaleBySize(4),
        padding_right = Screen:scaleBySize(4),
        background = CLR_BLACK,
        radius     = Screen:scaleBySize(5),
        label,
    }
end

local function _textButton(text, active, on_tap, min_w)
    local label = TextWidget:new{
        text    = text,
        face    = Font:getFace(SUIStyle.FACE_REGULAR, UI.SZ(12)),
        fgcolor = active and Blitbuffer.COLOR_WHITE or CLR_BLACK,
        bold    = active,
        max_width = (min_w or Screen:scaleBySize(54)) - Screen:scaleBySize(8),
    }
    local box = FrameContainer:new{
        bordersize = active and 0 or 1,
        color      = CLR_LINE,
        background = active and CLR_BLACK or nil,
        radius     = Screen:scaleBySize(9),
        padding    = Screen:scaleBySize(3),
        padding_left = Screen:scaleBySize(10),
        padding_right = Screen:scaleBySize(10),
        CenterContainer:new{
            dimen = Geom:new{
                w = min_w or Screen:scaleBySize(54),
                h = Screen:scaleBySize(28),
            },
            label,
        },
    }
    if not on_tap then return box end
    local btn = InputContainer:new{ dimen = box:getSize(), box }
    btn.ges_events = {
        TapWereadShelfButton = {
            GestureRange:new{
                ges   = "tap",
                range = function() return btn.dimen end,
            },
        },
    }
    function btn:onTapWereadShelfButton()
        on_tap()
        return true
    end
    return btn
end

local function _sortBooks(books)
    local out = {}
    for i, b in ipairs(books or {}) do out[i] = b end
    table.sort(out, function(a, b)
        return (tonumber(a.readUpdateTime) or 0) > (tonumber(b.readUpdateTime) or 0)
    end)
    return out
end

local function _filteredBooks(plugin, tab)
    local source = (tab == "mp") and plugin.shelf_mp or plugin.shelf_regular
    local books = {}
    local saved = plugin.settings and plugin.settings:get("books", {}) or {}
    for _, book in ipairs(source or {}) do
        local keep = true
        if plugin.bookMatchesFilters and type(plugin.bookMatchesFilters) == "function" then
            local ok, matched = pcall(plugin.bookMatchesFilters, plugin, book, saved, {})
            keep = ok and matched
        end
        if keep then books[#books + 1] = book end
    end
    return _sortBooks(books)
end

local function _close(root)
    if root then pcall(UIManager.close, UIManager, root) end
end

function M.show(plugin, page, tab)
    tab = tab or plugin._weread_shelf_tab or "books"
    page = tonumber(page) or plugin._weread_shelf_page or 1
    plugin._weread_shelf_tab = tab
    plugin._weread_shelf_page = page

    _close(plugin._weread_shelf_root)

    local sw = Screen:getWidth()
    local sh = Screen:getHeight()
    local top = (UI.getContentTop and UI.getContentTop()) or 0
    local content_h = (UI.getContentHeight and UI.getContentHeight()) or sh
    local pad = Screen:scaleBySize(16)
    local inner_w = sw - 2 * pad

    local root = InputContainer:new{
        dimen = Geom:new{ x = 0, y = top, w = sw, h = content_h },
        covers_fullscreen = true,
        _weread_full_page = true,
    }
    plugin._weread_shelf_root = root

    local face_title  = Font:getFace(SUIStyle.FACE_BOLD, UI.SZ(24))
    local face_sub    = Font:getFace(SUIStyle.FACE_REGULAR, UI.SZ(12))
    local face_body   = Font:getFace(SUIStyle.FACE_REGULAR, UI.SZ(13))
    local face_small  = Font:getFace(SUIStyle.FACE_REGULAR, UI.SZ(10))

    local books = _filteredBooks(plugin, tab)

    -- First open after login: fetch the shelf once. showBookshelf() calls
    -- showShelfGrid() again when the data arrives.
    local has_any = (plugin.shelf_regular and #plugin.shelf_regular > 0)
        or (plugin.shelf_mp and #plugin.shelf_mp > 0)
    if not has_any and not plugin._weread_shelf_loading then
        plugin._weread_shelf_loading = true
        UIManager:scheduleIn(0.2, function()
            plugin:showBookshelf()
            plugin._weread_shelf_loading = false
        end)
    end

    -- Header ---------------------------------------------------------------
    local header_copy = VerticalGroup:new{ align = "left",
        TextWidget:new{
            text = _("WeRead"),
            face = face_title,
            bold = true,
            fgcolor = CLR_BLACK,
            max_width = inner_w - Screen:scaleBySize(150),
        },
        VerticalSpan:new{ width = Screen:scaleBySize(2) },
        TextWidget:new{
            text = string.format(_("Shelf · %d books"), #books),
            face = face_sub,
            fgcolor = CLR_GRAY,
            max_width = inner_w - Screen:scaleBySize(150),
        },
    }
    local header_right = HorizontalGroup:new{ align = "center",
        _textButton(_("List"), false, function()
            _close(root)
            plugin:showShelfPage()
        end, Screen:scaleBySize(42)),
        HorizontalSpan:new{ width = Screen:scaleBySize(8) },
        _textButton(_("Menu"), false, function()
            _close(root)
            plugin:showMainMenu()
        end, Screen:scaleBySize(42)),
    }
    local header = HorizontalGroup:new{ align = "center",
        header_copy,
        HorizontalSpan:new{ width = math.max(Screen:scaleBySize(8), inner_w - header_copy:getSize().w - header_right:getSize().w) },
        header_right,
    }

    -- Sync card ------------------------------------------------------------
    local sync_btn = _textButton(_("Get latest"), true, function()
        _close(root)
        plugin:showBookshelf()
    end, Screen:scaleBySize(72))
    local sync_card = FrameContainer:new{
        bordersize = 1,
        color      = CLR_LINE,
        radius     = Screen:scaleBySize(12),
        padding    = Screen:scaleBySize(10),
        width      = inner_w,
        HorizontalGroup:new{ align = "center",
            VerticalGroup:new{ align = "left",
                TextWidget:new{ text = _("Shelf synced"), face = face_body, bold = true },
                VerticalSpan:new{ width = Screen:scaleBySize(2) },
                TextWidget:new{
                    text = string.format(_("%d books · updated just now"), #books),
                    face = face_small,
                    fgcolor = CLR_GRAY,
                },
            },
            HorizontalSpan:new{ width = math.max(Screen:scaleBySize(8), inner_w - Screen:scaleBySize(220) - sync_btn:getSize().w) },
            sync_btn,
        },
    }

    -- Segmented tabs -------------------------------------------------------
    local function tabButton(label, id)
        return _textButton(label, tab == id, function()
            if id == "search" then
                _close(root)
                plugin:showSearch()
            else
                _close(root)
                M.show(plugin, 1, id)
            end
        end, math.floor((inner_w - Screen:scaleBySize(16)) / 3))
    end
    local segmented = HorizontalGroup:new{ align = "center",
        tabButton(_("Books"), "books"),
        HorizontalSpan:new{ width = Screen:scaleBySize(8) },
        tabButton(_("Public accounts"), "mp"),
        HorizontalSpan:new{ width = Screen:scaleBySize(8) },
        tabButton(_("Search"), "search"),
    }

    -- Grid -----------------------------------------------------------------
    local cols = 4
    local rows = 2
    local per_page = cols * rows
    local page_count = math.max(1, math.ceil(#books / per_page))
    page = math.max(1, math.min(page, page_count))
    plugin._weread_shelf_page = page

    local gap = Screen:scaleBySize(10)
    local cell_w = math.floor((inner_w - (cols - 1) * gap) / cols)
    local cover_h = math.floor(cell_w * 1.35)
    local cell_h = cover_h + Screen:scaleBySize(48)
    local start_idx = (page - 1) * per_page + 1

    local grid = VerticalGroup:new{ align = "left" }
    for r = 0, rows - 1 do
        local row = HorizontalGroup:new{ align = "top" }
        for c = 0, cols - 1 do
            local idx = start_idx + r * cols + c
            local book = books[idx]
            if book then
                local title = book.title or book.bookId or _("Untitled")
                local author = book.author or ""
                local icon_size = math.floor(math.min(cell_w, cover_h) * 0.4)
                local cover = ImageWidget:new{ file = Config.ICON.weread_book,
                    width = icon_size, height = icon_size, is_icon = true, alpha = true }

                local cover_box = CenterContainer:new{
                    dimen = Geom:new{ w = cell_w, h = cover_h },
                    cover,
                }
                local cover_stack = OverlapGroup:new{
                    dimen = Geom:new{ w = cell_w, h = cover_h },
                    cover_box,
                }
                local badge_text
                if book.finishReading == 1 then
                    badge_text = _("Done")
                elseif plugin.isBookDownloaded and plugin:isBookDownloaded(book, plugin.settings:get("books", {}), {}) then
                    badge_text = _("Cached")
                end
                if badge_text then
                    local b = _badge(badge_text)
                    local bs = b:getSize()
                    b.overlap_offset = {
                        math.max(0, cell_w - bs.w - Screen:scaleBySize(4)),
                        Screen:scaleBySize(4),
                    }
                    cover_stack[#cover_stack + 1] = b
                end

                local cell_vg = VerticalGroup:new{ align = "left",
                    cover_stack,
                    VerticalSpan:new{ width = Screen:scaleBySize(6) },
                    TextWidget:new{
                        text     = title,
                        face     = Font:getFace(SUIStyle.FACE_REGULAR, UI.SZ(13)),
                        bold     = true,
                        max_width = cell_w,
                    },
                    TextWidget:new{
                        text     = author,
                        face     = face_small,
                        fgcolor  = CLR_GRAY,
                        max_width = cell_w,
                    },
                }
                local cell = InputContainer:new{
                    dimen = Geom:new{ w = cell_w, h = cell_h },
                    cell_vg,
                }
                cell.ges_events = {
                    TapWereadShelfBook = {
                        GestureRange:new{
                            ges   = "tap",
                            range = function() return cell.dimen end,
                        },
                    },
                }
                function cell:onTapWereadShelfBook()
                    plugin:showBookRecord(book)
                    return true
                end
                row[#row + 1] = cell
            else
                row[#row + 1] = HorizontalSpan:new{ width = cell_w }
            end
            if c < cols - 1 then
                row[#row + 1] = HorizontalSpan:new{ width = gap }
            end
        end
        grid[#grid + 1] = row
        if r < rows - 1 then
            grid[#grid + 1] = VerticalSpan:new{ width = Screen:scaleBySize(12) }
        end
    end

    -- Pager ----------------------------------------------------------------
    local prev = _textButton("‹", page > 1, function()
        _close(root)
        M.show(plugin, page - 1, tab)
    end, Screen:scaleBySize(34))
    local nxt = _textButton("›", page < page_count, function()
        _close(root)
        M.show(plugin, page + 1, tab)
    end, Screen:scaleBySize(34))
    local pager = HorizontalGroup:new{ align = "center",
        prev,
        HorizontalSpan:new{ width = Screen:scaleBySize(12) },
        TextWidget:new{
            text = string.format("%d / %d", page, page_count),
            face = face_small,
            fgcolor = CLR_GRAY,
        },
        HorizontalSpan:new{ width = Screen:scaleBySize(12) },
        nxt,
    }

    local empty
    if #books == 0 then
        empty = TextWidget:new{
            text = (tab == "mp") and _("No public-account books.") or _("Your WeRead shelf is empty."),
            face = face_body,
            fgcolor = CLR_GRAY,
        }
    end

    local content = VerticalGroup:new{ align = "left",
        header,
        VerticalSpan:new{ width = Screen:scaleBySize(10) },
        sync_card,
        VerticalSpan:new{ width = Screen:scaleBySize(10) },
        segmented,
        VerticalSpan:new{ width = Screen:scaleBySize(10) },
        empty or grid,
        VerticalSpan:new{ width = Screen:scaleBySize(8) },
        pager,
    }
    local frame = FrameContainer:new{
        bordersize = 0,
        padding_left = pad,
        padding_right = pad,
        padding_top = Screen:scaleBySize(8),
        content,
    }
    -- Opaque backdrop: InputContainer/WidgetContainer paints only its first
    -- child, so the backdrop and the content must live in an OverlapGroup.
    -- Without it the FileManager's pagination artefacts show through the
    -- gaps below the pager.
    root[1] = OverlapGroup:new{
        dimen = Geom:new{ w = sw, h = content_h },
        LineWidget:new{
            dimen      = Geom:new{ w = sw, h = content_h },
            background = Blitbuffer.COLOR_WHITE,
        },
        frame,
    }
    UIManager:show(root)

    -- Keep the bottom bar's indicator on WeRead when this page was opened
    -- from a quick action or the More hub rather than the tab itself.
    -- setTempTabActive is the same helper the Stats tab uses: it walks every
    -- widget on the window stack, so whichever bar is actually painted gets
    -- the WeRead indicator (replacing only the FileManager's bar is not
    -- enough when a full-page host owns the visible chrome).
    pcall(function()
        local fm = plugin.ui
        -- `plugin` here is the WeRead sub-plugin; the bar reads its active
        -- action from the owning WeUI plugin (fm._weui_plugin).
        local weui_plugin = (fm and fm._weui_plugin) or plugin
        weui_plugin.active_action = "weread"
        local ok_bb, BB = pcall(require, "weui_bottombar")
        if not (ok_bb and BB and BB.setTempTabActive) then return end
        local function refresh()
            weui_plugin.active_action = "weread"
            -- setTempTabActive walks every widget on the window stack, which
            -- is what the Stats tab uses; replacing only the FileManager's
            -- bar misses the bar actually painted by the full-page host.
            BB.setTempTabActive(weui_plugin, "weread", true, nil)
        end
        refresh()
        -- The FileManager may repaint its own bar once right after show().
        UIManager:scheduleIn(0.15, refresh)
    end)

end

return M

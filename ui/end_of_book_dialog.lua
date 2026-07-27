-- ui/end_of_book_dialog.lua — WeRead end-of-chapter navigation dialog.
--
-- Pure presentation layer: given navigation options and callbacks, it builds a
-- ButtonDialog offering bookshelf / chapter-list / next-chapter navigation when
-- a WeRead book reaches the end of a chapter. It performs no network, settings,
-- or book-store I/O; the controller (main.lua) computes the options and supplies
-- the callbacks.

local ButtonDialog = require("ui/widget/buttondialog")
local UIManager = require("ui/uimanager")
local I18n = require("lib.i18n")

local function _(text)
    return I18n.tr(text)
end

local M = {}

-- Show the end-of-chapter dialog. The title already carries the WeRead brand,
-- so the buttons use plain labels (书架 / 搜索 / 目录 / 下一章).
--   opts.show_chapter_nav : boolean — show the chapter-list/next-chapter row
--                           (true only for single-chapter files, not full books)
--   opts.has_next         : boolean — whether the "next chapter" button shows
--   callbacks             : { on_bookshelf, on_search, on_chapter_list, on_next,
--                             on_book_details, on_read_stats, on_close_book }
-- Returns the dialog widget instance.
function M.show(opts, callbacks)
    opts = opts or {}
    callbacks = callbacks or {}

    local dialog

    -- Close the dialog first, then defer the action so the UI has a chance to
    -- repaint before a potentially blocking navigation (scheduleIn(0.1) keeps
    -- the event loop cooperative — see CLAUDE.md).
    local function dismiss_then(action)
        UIManager:close(dialog)
        if action then
            UIManager:scheduleIn(0.1, action)
        end
    end

    local buttons = {}

    -- Row 1: chapter list / next chapter — shown only when a single downloaded
    -- chapter (not a full-book EPUB) reaches its end. The "next chapter" button
    -- additionally requires a successor chapter to exist.
    if opts.show_chapter_nav then
        local nav_row = {
            {
                text = _("Chapter list"),
                callback = function() dismiss_then(callbacks.on_chapter_list) end,
            },
        }
        if opts.has_next then
            table.insert(nav_row, {
                text = _("Next chapter"),
                callback = function() dismiss_then(callbacks.on_next) end,
            })
        end
        table.insert(buttons, nav_row)
    end

    -- Row 2: book details / reading statistics
    table.insert(buttons, {
        {
            text = _("Book details"),
            callback = function() dismiss_then(callbacks.on_book_details) end,
        },
        {
            text = _("Reading statistics"),
            callback = function() dismiss_then(callbacks.on_read_stats) end,
        },
    })

    -- Row 3: bookshelf / search
    table.insert(buttons, {
        {
            text = _("Bookshelf"),
            callback = function() dismiss_then(callbacks.on_bookshelf) end,
        },
        {
            text = _("Search"),
            callback = function() dismiss_then(callbacks.on_search) end,
        },
    })

    -- Row 4: cancel / close book
    table.insert(buttons, {
        {
            text = _("Cancel"),
            callback = function() UIManager:close(dialog) end,
        },
        {
            text = _("Close book"),
            callback = function() dismiss_then(callbacks.on_close_book) end,
        },
    })

    dialog = ButtonDialog:new{
        title = _("WeRead: Reached end of chapter"),
        buttons = buttons,
    }

    UIManager:show(dialog)
    return dialog
end

return M

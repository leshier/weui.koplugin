-- Deterministic tests for the Z-Library detail/login adapter.

package.preload["logger"] = function()
    return { info = function() end, warn = function() end }
end
package.preload["device"] = function()
    return {
        screen = {
            scaleBySize = function(_, value) return value end,
            getWidth = function() return 758 end,
            getHeight = function() return 1024 end,
        },
    }
end
package.preload["weui_i18n"] = function()
    return { translate = function(value) return value end }
end
package.preload["weui_config"] = function()
    return { ICON = {
        weread_book = "book.svg",
        weread_download = "download.svg",
        weread_notes = "notes.svg",
        weread_reviews = "reviews.svg",
        zlibrary_favorite = "favorite.svg",
        zlibrary_refresh = "refresh.svg",
        weread_back = "back.svg",
    } }
end
local account_values = {}
package.preload["zlibrary.config"] = function()
    return {
        SETTINGS_USERNAME_KEY = "username",
        SETTINGS_PASSWORD_KEY = "password",
        hasCredentials = function()
            return account_values.username ~= nil and account_values.password ~= nil
        end,
        saveSetting = function(key, value) account_values[key] = value end,
        clearUserSession = function() account_values.session_cleared = true end,
    }
end
package.preload["zlibrary.ui"] = function()
    return {
        showCredentialsDialog = function(callback)
            callback("reader@example.test", "secret")
        end,
    }
end

package.path = "./?.lua;" .. package.path
local Adapter = require("weui_zlibrary_ui")

local rows = {
    {{ text = "\u{F002}  Similar" }},
    {{ text = "\u{F019}  Download" }},
    {{ text = "\u{F02D}  Profile" }},
    {{ text = "\u{F0E5}  Comments" }},
    {{ text = "\u{2661}  Favorite" }},
    {{ text = "\u{2665}  Unfavorite" }},
    {{ text = "\u{F021}  Refresh" }},
    {{ text = "\u{21A9}  Back" }},
}
Adapter.decorateBookDetailButtons(rows)
local expected = {
    { "Similar", "book.svg" },
    { "Download", "download.svg" },
    { "Profile", "notes.svg" },
    { "Comments", "reviews.svg" },
    { "Favorite", "favorite.svg" },
    { "Unfavorite", "favorite.svg" },
    { "Refresh", "refresh.svg" },
    { "Back", "back.svg" },
}
for i, pair in ipairs(expected) do
    local button = rows[i][1]
    assert(button.text == pair[1], "unexpected label at row " .. i)
    assert(button.icon == pair[2], "unexpected icon at row " .. i)
    assert(button.icon_width == 24 and button.icon_height == 24)
end

local sequence, deferred = {}, nil
local manager = {
    close = function(_, dialog)
        assert(dialog.marker == "details")
        sequence[#sequence + 1] = "close"
    end,
    nextTick = function(_, callback)
        sequence[#sequence + 1] = "schedule"
        deferred = callback
    end,
}
local dialog = {
    marker = "details",
    book = { id = 42 },
    parent_zlibrary = {
        downloadBook = function(_, book)
            assert(book.id == 42)
            sequence[#sequence + 1] = "download"
        end,
    },
}
Adapter.deferBookDownload(dialog, manager)
assert(table.concat(sequence, ",") == "close,schedule")
assert(type(deferred) == "function")
deferred()
assert(table.concat(sequence, ",") == "close,schedule,download")

local prompt_count = 0
package.loaded["apps/filemanager/filemanager"] = {
    instance = { zlibrary = {
        _promptForCredentials = function(_, callback)
            prompt_count = prompt_count + 1
            callback(false)
        end,
    } },
}
assert(Adapter.openCredentials())
assert(prompt_count == 1)

-- Older companion versions have no prompt broker. The adapter must still
-- provide a credentials window and persist both fields through Config.
package.loaded["apps/filemanager/filemanager"].instance.zlibrary = {}
assert(Adapter.openCredentials())
assert(account_values.username == "reader@example.test")
assert(account_values.password == "secret")
assert(account_values.session_cleared == true)
assert(Adapter.getAccountStatusText() == "Configured")

print("ZLIBRARY_UI_ADAPTER_OK")

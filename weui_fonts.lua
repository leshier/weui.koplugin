-- Bundled UI fonts must also work with KOReader versions that prepend fontdir.
local Font = require("ui/font")
local FontList = require("fontlist")
local realpath = require("ffi/util").realpath
local M = {}

function M.fontName(path)
    local file, root = realpath(path), realpath(FontList.fontdir)
    if not file or not root then return end
    local target, base = {}, {}
    for part in file:gmatch("[^/]+") do target[#target + 1] = part end
    for part in root:gmatch("[^/]+") do base[#base + 1] = part end
    local common = 0
    while target[common + 1] and target[common + 1] == base[common + 1] do
        common = common + 1
    end
    local relative = {}
    for _ = common + 1, #base do relative[#relative + 1] = ".." end
    for i = common + 1, #target do relative[#relative + 1] = target[i] end
    return table.concat(relative, "/")
end

function M.bundledFace(path, fallback)
    -- Resolve once, not on every text widget or redraw.
    local name = M.fontName(path) or fallback
    return function(size)
        local face = Font:getFace(name, size)
        if face or name == fallback then return face end
        -- An unreadable/unsupported bundle must not break startup, nor be
        -- retried (and rescan all fonts) for every heading.
        require("logger").warn("weui: bundled font unavailable:", path)
        name = fallback
        return Font:getFace(name, size)
    end
end

return M

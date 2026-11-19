-- Paper refresh bounds. Keep only values, never old widgets or cover buffers.
-- Waveforms, night mode and periodic clearing remain owned by KOReader.
local Device = require("device")
local Geom = require("ui/geometry")
local UIManager = require("ui/uimanager")
local M = {}

local function values(...)
    local out = {}
    for i = 1, select("#", ...) do
        local value = tostring(select(i, ...))
        out[#out + 1] = #value .. ":" .. value
    end
    return table.concat(out)
end

local function widgetKey(w)
    local size = w:getSize()
    if w.face and w.text ~= nil then
        -- Keep the immutable text string separately: concatenating a long
        -- chapter into every signature would duplicate it on a Kindle.
        return values("text", size.w, size.h, w.face.hash, w.face.size,
            w.bold, w.fgcolor, w.bgcolor, w.padding, w.max_width,
            w.truncate_with_ellipsis, w.truncate_left, w.forced_baseline,
            w.line_height, w.alignment, w.virtual_line_num, w.height_adjust,
            w.height_overflow_show_ellipsis, w.lang, w.para_direction_rtl), w.text
    elseif w.file or w.image then
        -- File images use KOReader's shared image cache; data images use the
        -- cover cache's BB identity. tostring does not retain the native buffer.
        return values("image", size.w, size.h, w.file, w.image or w._bb,
            w.alpha, w.dim, w.invert, w.rotation_angle, w._offset_x, w._offset_y)
    elseif w.bordersize ~= nil and w[1] then
        local child_key, child_text = widgetKey(w[1])
        return values("frame", size.w, size.h, w.bordersize, w.color, w.background,
            w.padding, w.margin, w.radius, child_key), child_text
    end
    -- New/unsupported drawing widgets are conservatively considered changed.
    return values("widget", size.w, size.h, w)
end

function M.capture(page)
    local d = page.dimen
    local layout = { x = d.x, y = d.y, w = d.w, h = d.h, offset = page.offset,
        padding = math.max(2, page:px(2)), items = {} }
    for _, item in ipairs(page.items) do
        local x, y = d.x + page.offset + item.x, d.y + item.y
        local w, h, key, text
        if item.widget then
            local size = item.widget:getSize()
            w, h = size.w, size.h
            key, text = widgetKey(item.widget)
        elseif item.circle then
            x, y = x - item.radius, y - item.radius
            w, h = item.radius * 2 + 1, item.radius * 2 + 1
            key = values("circle", item.radius, item.color)
        else
            w, h = item.w, math.max(1, item.h)
            key = values("rect", item.color, item.border)
        end
        layout.items[#layout.items + 1] = { x = x, y = y, w = w, h = h, key = key, text = text }
    end
    return layout
end

local function equal(a, b)
    return a and b and a.x == b.x and a.y == b.y and a.w == b.w and a.h == b.h
        and a.key == b.key and a.text == b.text
end

function M.region(old, new)
    if not old or old.x ~= new.x or old.y ~= new.y or old.w ~= new.w
            or old.h ~= new.h or old.offset ~= new.offset then
        return Geom:new{ x = new.x, y = new.y, w = new.w, h = new.h }
    end
    local left, top, right, bottom
    local function include(item)
        if not item or item.w <= 0 or item.h <= 0 then return end
        left = math.min(left or item.x, item.x)
        top = math.min(top or item.y, item.y)
        right = math.max(right or item.x + item.w, item.x + item.w)
        bottom = math.max(bottom or item.y + item.h, item.y + item.h)
    end
    local before, after = old.items, new.items
    if #before == #after then
        for i, item in ipairs(after) do
            if not equal(before[i], item) then include(before[i]); include(item) end
        end
    else
        -- Preserve unchanged headers/footers when a cover or progress bar adds
        -- drawing items in the middle of the page.
        local first, a, b = 1, #before, #after
        while first <= math.min(a, b) and equal(before[first], after[first]) do first = first + 1 end
        while a >= first and b >= first and equal(before[a], after[b]) do a = a - 1; b = b - 1 end
        for i = first, a do include(before[i]) end
        for i = first, b do include(after[i]) end
    end
    if not left then return end
    local pad = new.padding
    left, top = math.max(new.x, left - pad), math.max(new.y, top - pad)
    right, bottom = math.min(new.x + new.w, right + pad), math.min(new.y + new.h, bottom + pad)
    if right > left and bottom > top then
        return Geom:new{ x = left, y = top, w = right - left, h = bottom - top }
    end
end

function M.awake(plugin)
    return not (plugin and plugin._weui_suspended) and not Device.screen_saver_mode
end

-- Mirrors UIManager's full-screen occlusion rule. Translucent sheets still
-- need their underlying page painted so native alpha composition stays correct.
function M.visible(widget, stack)
    for i = #(stack or UIManager._window_stack), 1, -1 do
        local w = (stack or UIManager._window_stack)[i].widget
        if w == widget then return true end
        if w.covers_fullscreen then return false end
    end
    return false
end

function M.top(widget)
    return UIManager:getTopmostVisibleWidget() == widget
end

function M.update(page)
    page._refresh_layout = M.capture(page)
    if not M.awake(page.plugin) or not M.visible(page) then return end
    -- Compare with the last paint, not the last rebuild: several asynchronous
    -- callbacks may rebuild before the native queue gets a chance to paint.
    local region = M.region(page._painted_layout, page._refresh_layout)
    if not region then return end
    local mode = region.w * region.h >= page.dimen.w * page.dimen.h / 4 and "partial" or "ui"
    UIManager:setDirty(page, mode, region)
end

function M.painted(page)
    page._painted_layout = page._refresh_layout
end

return M

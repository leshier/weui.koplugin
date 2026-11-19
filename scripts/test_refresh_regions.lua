local device = { screen_saver_mode = false }
local manager = { _window_stack = {}, calls = {} }
function manager:getTopmostVisibleWidget()
    for i = #self._window_stack, 1, -1 do
        if not self._window_stack[i].widget.invisible then return self._window_stack[i].widget end
    end
end
function manager:setDirty(widget, mode, region)
    self.calls[#self.calls + 1] = { widget = widget, mode = mode, region = region }
end
package.loaded.device = device
package.loaded["ui/uimanager"] = manager
package.loaded["ui/geometry"] = { new = function(_, props) return props end }
local Refresh = require("weui_refresh")
local page = { dimen = { x = 0, y = 0, w = 536, h = 724 }, offset = 0, plugin = {}, items = {} }
function page:px(n) return math.floor(n + 0.5) end
local function text(value, width)
    return { text = value, face = { hash = "test12", size = 12 },
        getSize = function() return { w = width, h = 16 } end }
end
local function clear() manager.calls = {} end
local function covers(region, x, y)
    return x >= region.x and y >= region.y and x < region.x + region.w and y < region.y + region.h
end
manager._window_stack = { { widget = page } }
page.items = { { x = 28, y = 40, widget = text("long title", 200) },
    { x = 28, y = 100, w = 480, h = 3, color = "black" } }
Refresh.update(page); Refresh.painted(page); clear()
page.items[1].widget = text("short", 50)
page.items[2].w = 80
Refresh.update(page)
assert(#manager.calls == 1)
local r = manager.calls[1].region
assert(covers(r, 227, 40) and covers(r, 507, 102), "old text/progress pixels excluded")
Refresh.painted(page); clear()
Refresh.update(page)
assert(#manager.calls == 0, "identical layout refreshed")
-- Two rebuilds arrive before a paint: both must include the last painted text.
page.items[1].widget = text("A", 220); Refresh.update(page)
page.items[1].widget = text("B", 10); Refresh.update(page)
assert(covers(manager.calls[2].region, 77, 40), "pending rebuild replaced last painted bounds")
Refresh.painted(page); clear()
-- Removing a drawing item must clear its old pixels without touching the footer.
page.items = { { x = 28, y = 40, widget = text("B", 10) },
    { x = 28, y = 660, widget = text("footer", 100) } }
Refresh.update(page); Refresh.painted(page); clear()
table.insert(page.items, 2, { x = 28, y = 220, w = 60, h = 80, color = "black" })
Refresh.update(page)
assert(manager.calls[1].region.y > 200 and manager.calls[1].region.y + manager.calls[1].region.h < 660,
    "insertion refreshed unchanged header/footer")
Refresh.painted(page); clear()
table.remove(page.items, 2); Refresh.update(page)
assert(covers(manager.calls[1].region, 87, 299), "removed item's old pixels excluded")
Refresh.painted(page); clear()
manager._window_stack[2] = { widget = { covers_fullscreen = true } }
page.items[1].widget = text("covered", 90); Refresh.update(page)
assert(#manager.calls == 0 and not Refresh.visible(page), "opaque cover did not suppress refresh")
manager._window_stack[2].widget.covers_fullscreen = false
Refresh.update(page)
assert(#manager.calls == 1, "transparent cover suppressed background refresh")
clear()
page.plugin._weui_suspended = true; Refresh.update(page)
assert(#manager.calls == 0, "suspended plugin refreshed")
page.plugin._weui_suspended = false
device.screen_saver_mode = true; Refresh.update(page)
assert(#manager.calls == 0, "screensaver refreshed")
device.screen_saver_mode = false
page.dimen.w = 724; Refresh.update(page)
assert(manager.calls[1].mode == "partial" and manager.calls[1].region.w == 724, "resize did not refresh full new viewport")
-- Snapshot values must not keep widget/image/font owners alive after freeItems.
local old_widget = page.items[1].widget
local weak = setmetatable({ old_widget }, { __mode = "v" })
page._refresh_layout, page._painted_layout = Refresh.capture(page), nil
page.items, old_widget = {}, nil
manager.calls = {}
collectgarbage("collect")
assert(weak[1] == nil, "visual snapshot retains native widget owner")
local chapter = ("长章节正文。"):rep(100000)
page.items = { { x = 28, y = 40, widget = text(chapter, 480) } }
local snapshot = Refresh.capture(page)
assert(snapshot.items[1].text == chapter and #snapshot.items[1].key < 500,
    "snapshot duplicated a long chapter into its signature")
print("REFRESH_REGIONS_OK: old pixels, pending paints, insertion, visibility, suspend, resize, ownership")

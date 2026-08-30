-- Kindle Wi-Fi quick-action regression: hardware state may lag behind taps.

local root = (arg[0]:match("^(.*)/scripts/") or ".")
package.path = root .. "/?.lua;" .. package.path

local shown = {}
local config = { wifi_optimistic = nil }
local state = true
local on_calls, off_calls, raw_on_calls, raw_off_calls = 0, 0, 0, 0
local on_callback, off_callback
local NetworkMgr = {
    -- Simulate Kindle's sysfs interface still reporting ON after turn-off was
    -- requested. The intended/optimistic state must win on the next tap.
    isWifiOn = function() return state end,
    getWifiState = function() return state end,
    toggleWifiOn = function(_, callback, long_press, interactive)
        assert(long_press == false and interactive == true)
        on_calls = on_calls + 1
        on_callback = callback
    end,
    toggleWifiOff = function(_, callback, interactive)
        assert(interactive == true)
        off_calls = off_calls + 1
        off_callback = callback
    end,
    turnOnWifi = function() raw_on_calls = raw_on_calls + 1 end,
    turnOffWifi = function() raw_off_calls = raw_off_calls + 1 end,
}

package.loaded.device = { hasWifiToggle = function() return true end }
package.loaded["ui/uimanager"] = { show = function(_, widget) shown[#shown + 1] = widget.text end }
package.loaded["ui/widget/infomessage"] = {
    new = function(_, options) return options end,
}
package.loaded.weui_config = config
package.loaded.logger = { warn = function() end }
package.loaded.weui_i18n = {
    translate = function(value) return value end,
}
package.loaded["ui/network/manager"] = NetworkMgr
package.loaded.weui_wifi = nil

local Wifi = require("weui_wifi")
local refreshes = 0
local refresh = function() refreshes = refreshes + 1 end

-- First tap sees Wi-Fi on and starts the official OFF flow.
assert(Wifi.toggle(refresh) == false)
assert(off_calls == 1 and on_calls == 0)
assert(config.wifi_optimistic == false)

-- Before Kindle's sysfs state changes, a second tap must start ON rather than
-- repeating OFF. The old callback must not erase the newer intended state.
assert(Wifi.toggle(refresh) == true)
assert(off_calls == 1 and on_calls == 1)
assert(config.wifi_optimistic == true)
off_callback()
assert(config.wifi_optimistic == true, "stale OFF callback erased the newer ON state")
on_callback()
assert(config.wifi_optimistic == nil)
assert(raw_on_calls == 0 and raw_off_calls == 0, "low-level Wi-Fi methods were used")
assert(refreshes == 3, "indicators were not refreshed for both taps and completion")

-- A settled OFF state starts ON directly.
config.wifi_optimistic = nil
state = false
assert(Wifi.toggle(refresh) == true)
assert(on_calls == 2)

assert(#shown == 0)
print("WIFI_TOGGLE_OK")

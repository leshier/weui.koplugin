-- Regression harness for the manual updater's network gate.
-- A connected Kindle must not be rejected because KOReader's external
-- isOnline() probe is unavailable.

local root = (arg[0]:match("^(.*)/scripts/") or ".")
package.path = root .. "/?.lua;" .. package.path

G_reader_settings = nil

package.loaded["ui/uimanager"] = {}
package.loaded["ui/widget/infomessage"] = { new = function(_, value) return value end }
package.loaded["ui/widget/confirmbox"] = { new = function(_, value) return value end }
package.loaded.logger = { warn = function() end, err = function() end, info = function() end, dbg = function() end }
package.loaded.weui_i18n = { translate = function(value) return value end }

local connected_calls = 0
local online_calls = 0
package.loaded["ui/network/manager"] = {
    runWhenConnected = function(_, callback)
        connected_calls = connected_calls + 1
        callback()
    end,
    runWhenOnline = function()
        online_calls = online_calls + 1
        error("manual updater must not use KOReader's external online probe")
    end,
}

local updater = dofile(root .. "/weui_updater.lua")
local checked_version
updater._doManualCheck = function(version)
    checked_version = version
end

updater.checkForUpdates()

assert(connected_calls == 1, "manual updater should use runWhenConnected")
assert(online_calls == 0, "manual updater should not use runWhenOnline")
assert(type(checked_version) == "string", "manual update callback should run")

-- The actual WeUI store controls the opt-in, rather than a missing module.
local opted_in, scheduled = false, {}
package.loaded.weui_store = { isTrue = function() return opted_in end }
package.loaded["ui/uimanager"].scheduleIn = function(_, delay, callback)
    scheduled[#scheduled + 1] = { delay = delay, callback = callback }
end
updater.scheduleAutoCheck()
assert(#scheduled == 0, "automatic checks must remain opt-in")
opted_in = true
updater.scheduleAutoCheck()
assert(#scheduled == 1 and scheduled[1].delay == 5, "enabled automatic check was not scheduled")
package.loaded["ui/network/manager"].isOnline = function() return false end
package.loaded["ui/network/manager"].isConnected = function() return false end
scheduled[1].callback()
assert(connected_calls == 1 and online_calls == 0, "background check must not enable Wi-Fi")

print("UPDATER_NETWORK_GATE_OK")

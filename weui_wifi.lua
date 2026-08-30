-- Wi-Fi quick-action controller.
--
-- Kindle's sysfs radio state can lag behind a tap for a short while. Keep the
-- intended state until KOReader's own toggle callback/network event settles,
-- and always use NetworkMgr's high-level wrappers so it owns connection menus,
-- persistence, connectivity checks and NetworkConnected/Disconnected events.

local Device = require("device")
local UIManager = require("ui/uimanager")
local Config = require("weui_config")
local logger = require("logger")
local _ = require("weui_i18n").translate

local Wifi = {}
local generation = 0

local function showMessage(text)
    local InfoMessage = require("ui/widget/infomessage")
    UIManager:show(InfoMessage:new{ text = text, timeout = 2 })
end

function Wifi.getState(NetworkMgr)
    if Config.wifi_optimistic ~= nil then
        return Config.wifi_optimistic == true
    end

    local ok, value = pcall(function() return NetworkMgr:isWifiOn() end)
    if ok then return value == true end

    if type(NetworkMgr.getWifiState) == "function" then
        ok, value = pcall(function() return NetworkMgr:getWifiState() end)
        if ok then return value == true end
    end
    return false
end

-- Returns the intended new state, or nil if the toggle could not be started.
function Wifi.toggle(refresh)
    local ok_hw, has_wifi = pcall(function() return Device:hasWifiToggle() end)
    if not (ok_hw and has_wifi) then
        showMessage(_("WiFi not available on this device."))
        return nil
    end

    local ok_nm, NetworkMgr = pcall(require, "ui/network/manager")
    if not ok_nm or not NetworkMgr then
        showMessage(_("Network manager unavailable."))
        return nil
    end

    local previous_optimistic = Config.wifi_optimistic
    local desired_on = not Wifi.getState(NetworkMgr)
    generation = generation + 1
    local this_generation = generation
    Config.wifi_optimistic = desired_on
    if refresh then pcall(refresh) end

    local function complete()
        -- A rapid second tap may start the opposite operation before the
        -- first asynchronous callback arrives. Only the newest operation is
        -- allowed to clear its intended state.
        if this_generation ~= generation then return end
        Config.wifi_optimistic = nil
        if refresh then pcall(refresh) end
    end

    local ok_toggle, status = pcall(function()
        if desired_on then
            if type(NetworkMgr.toggleWifiOn) == "function" then
                return NetworkMgr:toggleWifiOn(complete, false, true)
            end
            return NetworkMgr:turnOnWifi(complete, true)
        end
        if type(NetworkMgr.toggleWifiOff) == "function" then
            return NetworkMgr:toggleWifiOff(complete, true)
        end
        return NetworkMgr:turnOffWifi(complete)
    end)

    if not ok_toggle or status == false then
        generation = generation + 1
        Config.wifi_optimistic = previous_optimistic
        if refresh then pcall(refresh) end
        logger.warn("weui: Wi-Fi toggle error:", tostring(status))
        showMessage(_("Wi-Fi switch failed."))
        return nil
    end
    return desired_on
end

return Wifi

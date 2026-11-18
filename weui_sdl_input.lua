-- Align macOS SDL3's synthetic input timestamps with KOReader's UI clock.
-- CLOCK_MONOTONIC_COARSE is a Linux clock id; its macOS alias can refer to
-- a different timescale. A 500ms hold may otherwise expire on mouse-down.
local M = {}

function M.install()
    local ffi = require("ffi")
    local Device = require("device")
    if ffi.os ~= "OSX" or not Device:isSDL() then return end
    local backend = package.loaded["ffi/input_SDL3"]
    if not backend then return end
    local existing = backend._weui_clock_patch
    if existing then existing.active = true; return end

    local time = require("ui/time")
    require("ffi/posix_h")
    local ts = ffi.new("struct timespec")
    local state = { active = true, original = backend.waitForEvent }
    local function rawNow()
        if ffi.C.clock_gettime(ffi.C.CLOCK_MONOTONIC_COARSE, ts) ~= 0 then return end
        return time.s(tonumber(ts.tv_sec)) + time.us(math.floor(tonumber(ts.tv_nsec) / 1000))
    end
    state.wrapper = function(...)
        local ok, events = state.original(...)
        if state.active and ok and type(events) == "table" and #events > 0 then
            -- Calibrate after polling: SDL synthesizes the entire batch here.
            -- Shift every timestamp equally, preserving contact durations and
            -- event ordering instead of replacing individual times with now().
            local before = time.now()
            local raw = rawNow()
            local after = time.now()
            if raw then
                local ui_now = math.floor((before + after) / 2)
                local offset = ui_now - raw
                local newest = events[#events].time
                if not state.source and newest and math.abs(offset) > time.ms(2) then
                    local timestamp = time.timeval(newest)
                    local raw_distance = math.abs(timestamp - raw)
                    local ui_distance = math.abs(timestamp - ui_now)
                    -- Recognize the source only from a freshly generated batch.
                    -- An upstream SDL fix using the UI clock needs no conversion.
                    if math.min(raw_distance, ui_distance) < time.ms(25) then
                        state.source = raw_distance < ui_distance and "raw" or "ui"
                        if state.source == "raw" then
                            require("logger").info("weui: aligned macOS SDL input clock; offset_ms=",
                                time.to_ms(offset))
                        end
                    end
                end
                if state.source == "raw" then
                    for _, event in ipairs(events) do
                        if event.time then
                            event.time.sec, event.time.usec = time.split_s_us(time.timeval(event.time) + offset)
                        end
                    end
                end
            end
        end
        return ok, events
    end
    backend._weui_clock_patch = state
    backend.waitForEvent = state.wrapper
end

function M.uninstall()
    local backend = package.loaded["ffi/input_SDL3"]
    local state = backend and backend._weui_clock_patch
    if not state then return end
    state.active = false
    -- Keep a later plugin's wrapper intact; our inner wrapper becomes a NOP.
    if backend.waitForEvent == state.wrapper then
        backend.waitForEvent = state.original
        backend._weui_clock_patch = nil
    end
end

return M

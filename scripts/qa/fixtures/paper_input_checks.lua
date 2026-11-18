-- Exercise the real Input polling loop, GestureDetector and hold timers.
-- Only the OS event source is scripted; no page callback substitutes for a tap.
return function(ctx)
    local ffi = require("ffi")
    local C = ffi.C
    local time = require("ui/time")
    local Device = require("device")
    local Input = require("device/input")
    local Patch = require("weui_sdl_input")
    local Event = require("ui/event")
    if ffi.os ~= "OSX" or not Device:isSDL() then return end
    local original_backend = package.loaded["ffi/input_SDL3"]
    local ts = ffi.new("struct timespec")
    local function rawNow()
        assert(C.clock_gettime(C.CLOCK_MONOTONIC_COARSE, ts) == 0)
        return time.s(tonumber(ts.tv_sec)) + math.floor(tonumber(ts.tv_nsec) / 1000)
    end
    local function press(duration_ms, patched, source)
        local started, phase, gestures = time.now(), 0, {}
        local backend = {}
        function backend.waitForEvent(sec, usec)
            local elapsed = time.now() - started
            local next_at = phase == 0 and 0 or phase == 1 and time.ms(duration_ms) or time.huge
            local timeout = sec and time.s(sec) + time.us(usec) or time.s(1)
            local delay = math.max(0, next_at - elapsed)
            if delay > timeout then
                if timeout > 0 then C.usleep(time.to_us(timeout)) end
                return false, C.ETIME
            end
            if delay > 0 then C.usleep(time.to_us(delay)) end
            local timestamp = source == "ui" and time.now() or rawNow()
            local events = {}
            local function ev(kind, code, value, at)
                local s, us = time.split_s_us(at or timestamp)
                events[#events + 1] = { type = kind, code = code, value = value, time = { sec = s, usec = us } }
            end
            ev(C.EV_ABS, C.ABS_MT_SLOT, 0)
            ev(C.EV_ABS, C.ABS_MT_TRACKING_ID, phase == 0 and 1 or -1)
            if phase == 0 then
                ev(C.EV_ABS, C.ABS_MT_POSITION_X, 100)
                ev(C.EV_ABS, C.ABS_MT_POSITION_Y, 100)
            end
            ev(C.EV_SYN, C.SYN_REPORT, 0, timestamp + time.us(10))
            backend.last_batch = events
            phase = phase + 1
            return true, events
        end
        package.loaded["ffi/input_SDL3"] = backend
        if patched then
            Patch.install()
            local wrapper = backend.waitForEvent
            Patch.install()
            assert(backend.waitForEvent == wrapper, "clock wrappers stacked on reinstall")
        end
        local input = Input:new{ init = Input.init, device = Device, input = backend }
        local detector = input.gesture_detector
        detector.active_contacts, detector.previous_tap, detector.contact_count = {}, {}, 0
        detector.clock_id, detector.ges_hold_interval = nil, time.ms(500)
        for _ = 1, 8 do
            local events = input:waitEvent(time.now(), started + time.ms(duration_ms + 80))
            local batch = backend.last_batch
            if batch then
                assert(time.timeval(batch[#batch].time) - time.timeval(batch[1].time) == time.us(10),
                    "timestamp conversion changed ordering or relative times")
            end
            for _, event in ipairs(events or {}) do
                if event.handler == "onGesture" then gestures[event.args[1].ges] = time.now() - started end
            end
            if phase == 2 and #input.timer_callbacks == 0 then break end
        end
        input:resetState()
        if patched then
            local state = assert(backend._weui_clock_patch)
            if math.abs(time.now() - rawNow()) > time.ms(2) then
                assert(state.source == source, "wrong SDL timestamp source")
            end
            Patch.uninstall()
            assert(backend.waitForEvent == state.original and not backend._weui_clock_patch,
                "clock teardown did not restore backend")
        end
        return gestures
    end
    local ok, err = xpcall(function()
        if time.now() - rawNow() > time.ms(500) then
            local broken = press(100, false, "raw")
            assert(broken.hold and not broken.tap, "old timestamp mismatch did not reproduce")
        end
        local tap = press(100, true, "raw")
        assert(tap.tap and not tap.hold, "100ms mouse click became a hold")
        local hold = press(650, true, "raw")
        assert(hold.hold and hold.hold_release and not hold.tap, "650ms hold lost its native gesture")
        assert(hold.hold >= time.ms(480) and hold.hold < time.ms(620), "hold did not fire near 500ms")
        local upstream = press(100, true, "ui")
        assert(upstream.tap and not upstream.hold, "already aligned SDL timestamps were changed")

        local page = ctx.Paper.navigate(ctx.plugin, "home")
        page.state.page = 1; page:rebuild()
        page._wheel_direction, page._wheel_time = nil, nil
        assert(page.pages == 2, "wheel fixture needs two pages")
        local sec, usec = time.split_s_us(time.now())
        Device.input:handleSdlEv{
            code = require("ffi/SDL3").SDL.SDL_EVENT_MOUSE_WHEEL,
            value = { integer_x = 0, integer_y = -1 },
            time = { sec = sec, usec = usec },
        }
        assert(page.state.page == 2, "native SDL wheel did not reach the paper page")
        for _ = 1, 5 do page:handleEvent(Event:new("Pan", nil, { mousewheel_direction = -1 })) end
        assert(page.state.page == 2, "wheel burst jumped pages")
        page:handleEvent(Event:new("Pan", nil, { mousewheel_direction = 1 }))
        assert(page.state.page == 1, "reverse wheel was throttled")
        assert(not page:onPan(nil, { direction = "north" }), "touchscreen pan was consumed")
        -- A synthetic three-page view proves the limiter at an interior page.
        local view = setmetatable({ state = { page = 1 }, pages = 3, rebuild = function() end },
            { __index = page })
        view._wheel_direction, view._wheel_time = nil, nil
        view:onPan(nil, { mousewheel_direction = -1 })
        for _ = 1, 5 do view:onPan(nil, { mousewheel_direction = -1 }) end
        assert(view.state.page == 2, "wheel burst limiter did not stop at the interior page")
        view._wheel_time = time.now() - time.ms(181)
        view:onPan(nil, { mousewheel_direction = -1 })
        assert(view.state.page == 3, "later wheel event was blocked")
    end, debug.traceback)
    package.loaded["ffi/input_SDL3"] = original_backend
    assert(ok, err)
end

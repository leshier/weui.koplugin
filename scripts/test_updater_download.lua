-- Regression harness for We UI updater download routing.

local root = (arg[0]:match("^(.*)/scripts/") or ".")
package.path = root .. "/?.lua;" .. package.path

local settings = {}
G_reader_settings = {
    readSetting = function(_, key) return settings[key] end,
    saveSetting = function(_, key, value) settings[key] = value end,
    flush = function() end,
}

package.loaded["ui/uimanager"] = {}
package.loaded["ui/widget/infomessage"] = { new = function(_, value) return value end }
package.loaded["ui/widget/confirmbox"] = { new = function(_, value) return value end }
package.loaded.logger = { warn = function() end, err = function() end, info = function() end }
package.loaded.weui_i18n = { translate = function(value) return value end }

local timeout_calls = {}
package.loaded.socketutil = {
    TIMEOUT_CODE = "timeout",
    SSL_HANDSHAKE_CODE = "ssl handshake timeout",
    SINK_TIMEOUT_CODE = "sink timeout",
    set_timeout = function(_, block, total)
        timeout_calls[#timeout_calls + 1] = { block, total }
    end,
    reset_timeout = function() end,
}

package.loaded.ltn12 = {
    sink = {
        file = function(fh)
            return function(chunk)
                if chunk then fh:write(chunk) else fh:close() end
                return 1
            end
        end,
    },
}
package.loaded.socket = {}
package.loaded["socket.url"] = {
    absolute = function(_, location) return location end,
}

local requests = {}
local http = {}
package.loaded["socket/http"] = http

local updater = dofile(root .. "/weui_updater.lua")
local dest = os.tmpname()

-- Direct mode: retry once after a timeout, then stream the successful body.
settings.weui_upd_use_zlibrary_proxy = false
http.request = function(request)
    requests[#requests + 1] = request.url
    if #requests == 1 then return nil, "timeout" end
    request.sink("direct-ok")
    request.sink(nil)
    return 1, 200, {}, "OK"
end
assert(updater._httpGetToFile("https://github.com/release.zip", dest))
local fh = assert(io.open(dest, "rb"))
assert(fh:read("*a") == "direct-ok")
fh:close()
assert(#requests == 2, "direct download should retry exactly once")
assert(timeout_calls[1][1] == 30 and timeout_calls[1][2] == 180)
os.remove(dest)

-- Proxy mode: follow the GitHub HTTPS redirect manually so every hop keeps
-- using the configured CONNECT/SOCKS transport.
requests = {}
settings.weui_upd_use_zlibrary_proxy = true
package.loaded.weui_zlibrary_proxy = {
    _readConfig = function() return { scheme = "socks5", host = "proxy", port = 1080 } end,
    _proxyHttpRequest = function(request, _, base_request)
        return base_request(request)
    end,
}
http.request = function(request)
    requests[#requests + 1] = request.url
    if #requests == 1 then
        return 1, 302, { location = "https://release-assets.githubusercontent.com/file.zip" }, "Found"
    end
    request.sink("proxy-ok")
    request.sink(nil)
    return 1, 200, {}, "OK"
end
assert(updater._httpGetToFile("https://github.com/release.zip", dest))
fh = assert(io.open(dest, "rb"))
assert(fh:read("*a") == "proxy-ok")
fh:close()
assert(#requests == 2, "proxy download should follow one redirect")
assert(requests[2]:match("^https://release%-assets%.githubusercontent%.com/"))
os.remove(dest)

print("UPDATER_DOWNLOAD_OK")

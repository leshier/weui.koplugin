-- Regression harness for We UI updater version-check routing.

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
        table = function(chunks)
            return function(chunk)
                if chunk then chunks[#chunks + 1] = chunk end
                return 1
            end
        end,
    },
}
package.loaded["socket.url"] = {
    absolute = function(_, location) return location end,
}

local requests = {}
local http = {}
package.loaded["socket/http"] = http

local updater = dofile(root .. "/weui_updater.lua")

-- Direct checks still work and use bounded check-specific timeouts.
settings.weui_upd_use_zlibrary_proxy = false
http.request = function(request)
    requests[#requests + 1] = { url = request.url, proxy = false }
    request.sink('version = "1.4.2"')
    request.sink(nil)
    return 1, 200, {}, "OK"
end
assert(updater._httpGet("https://raw.githubusercontent.com/meta.lua")
    == 'version = "1.4.2"')
assert(#requests == 1 and requests[1].proxy == false)
assert(timeout_calls[1][1] == 10 and timeout_calls[1][2] == 20)

-- Proxy checks follow every HTTPS redirect through the selected transport.
requests = {}
settings.weui_upd_use_zlibrary_proxy = true
package.loaded.weui_zlibrary_proxy = {
    _readConfig = function()
        return { scheme = "socks5", host = "proxy", port = 1080 }
    end,
    _proxyHttpRequest = function(request, _, base_request)
        requests[#requests + 1] = { url = request.url, proxy = true }
        return base_request(request)
    end,
}
local hop = 0
http.request = function(request)
    hop = hop + 1
    if hop == 1 then
        return 1, 302, { location = "https://mirror.example/meta.lua" }, "Found"
    end
    request.sink('version = "1.4.2"')
    request.sink(nil)
    return 1, 200, {}, "OK"
end
assert(updater._httpGet("https://raw.githubusercontent.com/meta.lua")
    == 'version = "1.4.2"')
assert(#requests == 2, "both version-check hops should use the proxy")
assert(requests[1].proxy and requests[2].proxy)
assert(requests[2].url == "https://mirror.example/meta.lua")

-- Default checks do not depend on raw.githubusercontent.com. If the Releases API is blocked,
-- they immediately fall back to the jsDelivr copy of _meta.lua.
settings.weui_upd_use_zlibrary_proxy = false
requests = {}
http.request = function(request)
    requests[#requests + 1] = { url = request.url, proxy = false }
    if request.url:find("api.github.com", 1, true) then
        return 1, 503, {}, "Service Unavailable"
    end
    assert(request.url:find("fastly.jsdelivr.net", 1, true),
        "first metadata fallback must use the Fastly jsDelivr edge")
    assert(request.url:find("@latest/_meta.lua", 1, true),
        "CDN fallback must follow the latest release tag instead of a stale branch cache")
    request.sink('version = "9.8.7"')
    request.sink(nil)
    return 1, 200, {}, "OK"
end
local release = updater._doFetch()
assert(release.version == "9.8.7")
assert(release.download_url:find("/releases/download/v9.8.7/weui.koplugin.zip", 1, true))
assert(#requests == 2, "API failure should advance to the first CDN without retrying")

print("UPDATER_CHECK_OK")

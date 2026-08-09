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
local expected_version = assert(dofile(root .. "/_meta.lua").version)
assert(updater._currentVersion() == expected_version,
    "updater did not read the installed WeUI version")

assert(updater._isValidAssetUrl(
    "https://github.com/leshier/weui.koplugin/releases/download/v1.2.3/weui.koplugin.zip"))
assert(not updater._isValidAssetUrl(
    "http://github.com/leshier/weui.koplugin/releases/download/v1.2.3/weui.koplugin.zip"))
assert(not updater._isValidAssetUrl(
    "https://evil.example/releases/download/v1.2.3/weui.koplugin.zip"))

for _, item in ipairs({
    { "weui.koplugin", "directory", true },
    { "weui.koplugin/main.lua", "file", true },
    { "../weui.koplugin/main.lua", "file", false },
    { "weui.koplugin/../escape", "file", false },
    { "/weui.koplugin/main.lua", "file", false },
    { "other.koplugin/main.lua", "file", false },
    { "weui.koplugin/link", "link", false },
}) do
    local ok = updater._isSafeArchiveEntry(item[1], item[2])
    assert(ok == item[3], "unexpected archive policy for " .. item[1])
end

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

-- If GitHub's Releases API is blocked, the immutable jsDelivr tag index is the first fallback.
settings.weui_upd_use_zlibrary_proxy = false
requests = {}
http.request = function(request)
    requests[#requests + 1] = { url = request.url, proxy = false }
    if request.url:find("api.github.com", 1, true) then
        return 1, 503, {}, "Service Unavailable"
    end
    assert(request.url:find("data.jsdelivr.com/v1/package/gh", 1, true),
        "first fallback must use jsDelivr's immutable tag index")
    request.sink('{"versions":["9.8.7","9.8.6"]}')
    request.sink(nil)
    return 1, 200, {}, "OK"
end
local release = updater._doFetch()
assert(release.version == "9.8.7")
assert(release.download_url:find("/releases/download/v9.8.7/weui.koplugin.zip", 1, true))
assert(#requests == 2, "API failure should advance to the first CDN without retrying")

-- The edge metadata remains available if both version APIs fail.
requests = {}
http.request = function(request)
    requests[#requests + 1] = { url = request.url, proxy = false }
    if request.url:find("api.github.com", 1, true)
            or request.url:find("data.jsdelivr.com", 1, true) then
        return 1, 503, {}, "Service Unavailable"
    end
    assert(request.url:find("fastly.jsdelivr.net", 1, true))
    assert(request.url:find("@latest/_meta.lua", 1, true))
    request.sink('version = "9.8.6"')
    request.sink(nil)
    return 1, 200, {}, "OK"
end
release = updater._doFetch()
assert(release.version == "9.8.6")
assert(#requests == 3, "version check did not reach Fastly metadata fallback")

print("UPDATER_CHECK_OK")

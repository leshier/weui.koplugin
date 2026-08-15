-- Deterministic mirror-pool and request failover regression coverage.

local root = (arg[0]:match("^(.*)/scripts/") or ".")
package.path = root .. "/?.lua;" .. package.path

local function parse_url(value)
    if type(value) ~= "string" then return nil end
    local scheme, authority, tail = value:match("^([%w+.-]+)://([^/]+)(.*)$")
    if not scheme then return nil end
    local host, port = authority:match("^([^:]+):(%d+)$")
    host = host or authority
    local path_query, fragment = tail:match("^(.-)#(.*)$")
    tail = path_query or tail
    local path, query = tail:match("^([^?]*)%?(.*)$")
    path = path or tail
    return {
        scheme = scheme,
        host = host,
        port = port and tonumber(port) or nil,
        path = path ~= "" and path or nil,
        query = query,
        fragment = fragment,
    }
end

local function build_url(parts)
    local value = tostring(parts.scheme) .. "://" .. tostring(parts.host)
    if parts.port then value = value .. ":" .. tostring(parts.port) end
    value = value .. (parts.path or "")
    if parts.params then value = value .. ";" .. parts.params end
    if parts.query then value = value .. "?" .. parts.query end
    if parts.fragment then value = value .. "#" .. parts.fragment end
    return value
end

package.loaded["socket.url"] = {
    parse = parse_url,
    build = build_url,
    absolute = function(base, location)
        if location:match("^https?://") then return location end
        local parsed = assert(parse_url(base))
        return parsed.scheme .. "://" .. parsed.host .. location
    end,
}
package.loaded.logger = { dbg = function() end, info = function() end,
    warn = function() end, err = function() end }

local active_base
local automatic = true
local Config = {
    USER_AGENT = "mirror-test",
    getBaseUrl = function(ignore_runtime)
        return ignore_runtime and "https://a.example" or (active_base or "https://a.example")
    end,
    getSeedUrls = function()
        return {
            { url = "https://b.example" },
            { url = "https://c.example" },
            { url = "https://d.example" },
        }
    end,
    setRuntimeBaseUrl = function(value)
        active_base = value
        return true
    end,
    getRuntimeBaseUrl = function() return active_base end,
    getAutoMirrorFailover = function() return automatic end,
    clearCacheRealUrlIfPinned = function(value)
        if active_base and value:find(active_base, 1, true) == 1 then
            active_base = nil
            return true
        end
        return false
    end,
    setCacheRealUrl = function(_, value) active_base = value return true end,
}
package.loaded["zlibrary.config"] = Config
package.loaded["zlibrary.mirror_pool"] = nil

local MirrorPool = require("zlibrary.mirror_pool")
assert(MirrorPool.origin("HTTPS://A.Example:443/a") == "https://a.example:443")
assert(MirrorPool.rewriteUrl("https://a.example/eapi/book/1?x=2#f", "https://b.example")
    == "https://b.example/eapi/book/1?x=2#f")

local attempted = {}
local rewritten, selected = MirrorPool.failover(
    "https://a.example/eapi/info/ok?x=1", attempted, "timeout", 1000)
assert(selected == "https://b.example", "first healthy seed should be selected")
assert(rewritten == "https://b.example/eapi/info/ok?x=1")
assert(attempted["https://a.example"] and attempted["https://b.example"])

MirrorPool.recordSuccess("https://b.example/eapi/info/ok", 120, 1001)
MirrorPool.recordFailure("https://c.example/eapi/info/ok", "server", 1001)
local state = MirrorPool.exportTransportState()
MirrorPool.reset()
active_base = nil
MirrorPool.applyTransportState(state)
assert(active_base == "https://b.example", "selected mirror did not return to parent state")
local next_url, next_base = MirrorPool.failover(
    "https://d.example/eapi/info/ok", {}, "transport", 1002)
assert(next_base == "https://b.example", "known healthy mirror should outrank an untested seed")
assert(next_url == "https://b.example/eapi/info/ok")

-- Minimal KOReader network stubs for testing Api.makeHttpRequest itself.
local clock = 0
package.loaded["ui/time"] = {
    now = function() clock = clock + 1 return clock end,
    since = function(start) return clock - start end,
    to_ms = function(value) return value * 10 end,
}
package.loaded.util = {
    trim = function(value) return tostring(value):match("^%s*(.-)%s*$") end,
    urlEncode = function(value) return tostring(value) end,
}
package.loaded.ltn12 = {
    source = { string = function(value)
        local sent = false
        return function() if sent then return nil end sent = true return value end
    end },
}
local json_decode = setmetatable({ simple = {} }, {
    __call = function(_, body)
        if body == '{"success":1}' then return { success = 1 } end
        if body == '{"error":"bad credentials"}' then return { error = "bad credentials" } end
        error("invalid json")
    end,
})
package.loaded.json = { decode = json_decode, encode = function() return "{}" end }
package.loaded["zlibrary.gettext"] = function(value) return value end
package.loaded["zlibrary.runtime_locale"] = {
    localizeApiMessage = function(value) return value end,
}

local responses = {}
local requested = {}
local function table_sink(target)
    return function(chunk)
        if chunk then target[#target + 1] = chunk end
        return 1
    end
end
package.loaded.socketutil = {
    table_sink = table_sink,
    set_timeout = function() end,
    reset_timeout = function() end,
}
package.loaded["socket.http"] = {
    request = function(params)
        requested[#requested + 1] = params.url
        local response = table.remove(responses, 1)
        assert(response, "unexpected extra HTTP request")
        if response.raise then error(response.raise) end
        if response.body then params.sink(response.body) end
        return response.ok == false and nil or 1,
            response.code, response.headers or {}, response.status or tostring(response.code)
    end,
}

package.loaded["zlibrary.api"] = nil
MirrorPool.reset()
active_base = nil
local Api = require("zlibrary.api")

local function request(response_list, opts)
    responses, requested = response_list, {}
    opts = opts or {}
    opts.url = opts.url or "https://a.example/eapi/info/ok"
    opts.mirror_failover = opts.mirror_failover ~= false
    if opts.expect_json == nil then opts.expect_json = true end
    return Api.makeHttpRequest(opts), requested
end

local result, urls = request({
    { code = 503, body = "service unavailable" },
    { code = 200, body = '{"success":1}' },
})
assert(result.status_code == 200 and #urls == 2)
assert(urls[1]:find("a.example", 1, true) and urls[2]:find("b.example", 1, true))
assert(active_base == "https://b.example")

-- Authentication and other business 4xx responses prove the host is alive.
MirrorPool.reset()
active_base = nil
result, urls = request({
    { code = 401, body = '{"error":"bad credentials"}' },
})
assert(result.status_code == 401 and #urls == 1 and active_base == nil)

-- A browser/WAF challenge is a mirror failure even if it answers HTTP 200.
MirrorPool.reset()
active_base = nil
result, urls = request({
    { code = 200, body = "<html>DiamWall security check</html>" },
    { code = 200, body = '{"success":1}' },
})
assert(result.status_code == 200 and #urls == 2)
assert(urls[2]:find("b.example", 1, true))

-- Retry is bounded: the initial request plus at most two alternate mirrors.
MirrorPool.reset()
active_base = nil
result, urls = request({
    { code = 503, body = "down-a" },
    { code = 503, body = "down-b" },
    { code = 503, body = "down-c" },
})
assert(result.status_code == 503 and #urls == 3)
local failed_state = MirrorPool.exportTransportState()
assert(failed_state.active_base == nil, "last failed mirror must not remain pinned")

automatic = false
MirrorPool.reset()
active_base = nil
result, urls = request({ { code = 503, body = "down" } })
assert(result.status_code == 503 and #urls == 1)
automatic = true

-- Streaming sinks cannot be replayed safely after bytes have been written.
MirrorPool.reset()
active_base = nil
local external_chunks = {}
result, urls = request({ { code = 503, body = "partial" } }, {
    sink = table_sink(external_chunks),
    expect_json = false,
})
assert(result.status_code == 503 and #urls == 1)

print("ZLIBRARY_MIRROR_POOL_OK")

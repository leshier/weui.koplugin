-- Deterministic transport tests for weui_zlibrary_proxy.lua.
-- Run with any Lua 5.1+ interpreter; all KOReader/network modules are stubbed.

local settings = {}
local http = { TIMEOUT = 30 }
local next_socket

local function parse_url(raw)
    local scheme, authority, tail = raw:match("^([%a][%w+.-]*)://([^/]+)(.*)$")
    if not scheme then return nil end
    local userinfo, hostport = authority:match("^(.-)@(.+)$")
    hostport = hostport or authority
    local host, port
    if hostport:sub(1, 1) == "[" then
        host, port = hostport:match("^%[([^]]+)%]:(%d+)$")
    else
        host, port = hostport:match("^(.-):(%d+)$")
    end
    if not host then host = hostport end
    local path, query = tail:match("^([^?]*)(.*)$")
    return {
        scheme = scheme,
        host = host,
        port = port,
        path = path,
        query = query ~= "" and query or nil,
        userinfo = userinfo,
        user = userinfo and userinfo:match("^([^:]+)"),
    }
end

local socket = {
    tcp = function()
        assert(next_socket, "test did not provide a socket")
        local value = next_socket
        next_socket = nil
        return value
    end,
    gettime = function() return 0 end,
}

package.preload["socket"] = function() return socket end
package.preload["socket.http"] = function() return http end
package.preload["socket.url"] = function() return { parse = parse_url } end
package.preload["ssl.https"] = function() return { TIMEOUT = 30 } end
package.preload["ssl"] = function()
    return {
        wrap = function(sock)
            function sock:sni() return true end
            function sock:dohandshake() return true end
            return sock
        end,
    }
end
package.preload["ltn12"] = function()
    return { sink = { null = function() return function() return 1 end end } }
end
package.preload["logger"] = function()
    return { info = function() end, warn = function() end }
end
package.preload["mime"] = function()
    return { b64 = function(value)
        assert(value == "alice:secret")
        return "YWxpY2U6c2VjcmV0"
    end }
end
package.preload["socketutil"] = function()
    return {
        USER_AGENT = "test",
        block_timeout = 30,
        total_timeout = 30,
        set_timeout = function() end,
    }
end
package.preload["weui_i18n"] = function()
    return { translate = function(value) return value end }
end
package.preload["weui_store"] = function()
    return {
        get = function(_, key) return settings[key] end,
        set = function(_, key, value) settings[key] = value end,
        del = function(_, key) settings[key] = nil end,
        isTrue = function(_, key) return settings[key] == true end,
    }
end
package.preload["ui/network/manager"] = function()
    local manager = {}
    function manager:willRerunWhenOnline(callback) return callback and false end
    function manager:willRerunWhenConnected(callback) return callback and false end
    return manager
end

local Api = {}
package.preload["zlibrary.api"] = function() return Api end

package.path = "./?.lua;" .. package.path
local Proxy = require("weui_zlibrary_proxy")

local function fake_socket(receives)
    local sent, closed = {}, false
    local methods = {}
    function methods:settimeout() return true end
    function methods:connect(host, port)
        self.connected_host, self.connected_port = host, port
        return true
    end
    function methods:send(data, first)
        first = first or 1
        sent[#sent + 1] = data:sub(first)
        return #data
    end
    function methods:receive()
        local value = table.remove(receives, 1)
        if value == nil then return nil, "closed" end
        return value
    end
    function methods:close() closed = true return true end
    local sock = setmetatable({}, { __index = methods })
    return sock, sent, function() return closed end
end

local function test_http_connect()
    local sock, sent = fake_socket({ "HTTP/1.1 200 Connection Established", "" })
    next_socket = sock
    local create = Proxy._tunnelCreate({
        scheme = "http", host = "proxy.lan", port = 7890,
        username = "alice", password = "secret",
    }, false, {})
    local conn = assert(create())
    assert(conn:connect("example.org", 443))
    local request = table.concat(sent)
    assert(request:find("CONNECT example.org:443 HTTP/1.1", 1, true))
    assert(request:find("Proxy-Authorization: Basic YWxpY2U6c2VjcmV0", 1, true))
    assert(sock.connected_host == "proxy.lan" and sock.connected_port == 7890)
end

local function test_http_connect_rejection()
    local sock, _, is_closed = fake_socket({ "HTTP/1.1 407 Authentication Required", "" })
    next_socket = sock
    local conn = assert(Proxy._tunnelCreate({
        scheme = "http", host = "proxy.lan", port = 7890,
        username = "", password = "",
    }, false, {})())
    local ok, err = conn:connect("example.org", 443)
    assert(not ok and err:find("407", 1, true))
    assert(is_closed())
end

local function test_socks5_remote_dns()
    local sock, sent = fake_socket({ "\5\0", "\5\0\0\1", "\0\0\0\0\0\0" })
    next_socket = sock
    local conn = assert(Proxy._tunnelCreate({
        scheme = "socks5", host = "proxy.lan", port = 1080,
        username = "", password = "",
    }, false, {})())
    assert(conn:connect("books.example", 443))
    assert(sent[1] == "\5\1\0")
    assert(sent[2] == "\5\1\0\3\13books.example\1\187")
end

local function test_request_scope_and_fail_closed_redirect()
    settings.weui_zlibrary_proxy_enabled = true
    settings.weui_zlibrary_proxy_url = "http://proxy.lan:7890"
    settings.weui_zlibrary_proxy_username = ""
    settings.weui_zlibrary_proxy_password = ""

    Api.makeHttpRequest = function(options)
        -- Simulate a companion redirect from an HTTPS origin to HTTP. The
        -- wrapper must reject it before the original network request runs.
        return http.request({ url = options.redirect_target })
    end
    assert(Proxy.install())
    local result, err = Api.makeHttpRequest({
        url = "https://books.example/start",
        redirect_target = "http://books.example/downgrade",
    })
    assert(result == nil)
    assert(type(err) == "string" and err:find("HTTPS%-to%-HTTP redirect"), tostring(err))
    Proxy.uninstall()
end

test_http_connect()
test_http_connect_rejection()
test_socks5_remote_dns()
test_request_scope_and_fail_closed_redirect()
print("ZLIBRARY_PROXY_TRANSPORT_OK")

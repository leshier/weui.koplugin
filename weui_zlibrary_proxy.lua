-- weui_zlibrary_proxy.lua — a fail-closed, Z-Library-only proxy transport.
--
-- KOReader's global socket.http.PROXY support is an HTTP forward proxy.  It
-- does not establish CONNECT tunnels for HTTPS, so using it for Z-Library
-- would expose cookies, login bodies and downloads to the proxy as plaintext.
-- This module instead wraps Z-Library's single HTTP entry point and injects a
-- standards-compliant HTTP CONNECT or SOCKS5 transport for that request only.
-- Other KOReader traffic is never changed.

local http        = require("socket.http")
local https       = require("ssl.https")
local ltn12       = require("ltn12")
local logger      = require("logger")
local mime        = require("mime")
local socket      = require("socket")
local socket_url  = require("socket.url")
local socketutil  = require("socketutil")
local ssl         = require("ssl")

local SUISettings = require("weui_store")
local _           = require("weui_i18n").translate

local M = {}

local KEY_ENABLED  = "weui_zlibrary_proxy_enabled"
local KEY_URL      = "weui_zlibrary_proxy_url"
local KEY_USERNAME = "weui_zlibrary_proxy_username"
local KEY_PASSWORD = "weui_zlibrary_proxy_password"

local unpack_args = unpack or table.unpack

local _api_depth = 0
local _active_http_request
local _require_https = false
local _installed_api, _api_original, _api_wrapper
local _installed_network_mgr, _network_original, _network_wrapper
local _transport_ready = false

local function trim(value)
    if type(value) ~= "string" then return "" end
    return value:gsub("^%s+", ""):gsub("%s+$", "")
end

local function hostPort(host, port)
    if host:find(":", 1, true) and host:sub(1, 1) ~= "[" then
        host = "[" .. host .. "]"
    end
    return host .. ":" .. tostring(port)
end

local function proxyLabel(cfg)
    if not cfg then return _("Not configured") end
    local kind = cfg.scheme == "http" and _("HTTP CONNECT") or _("SOCKS5")
    return kind .. " · " .. hostPort(cfg.host, cfg.port)
end

-- Credentials deliberately live in separate settings, never in the URL.  In
-- addition to keeping menu labels and logs safe, this prevents LuaSocket from
-- accidentally forwarding Proxy-Authorization through a target TLS tunnel.
local function readConfig()
    local raw = trim(SUISettings:get(KEY_URL))
    if raw == "" then
        return nil, _("Set a proxy server first.")
    end
    if not raw:match("^[%a][%w+.-]*://") then
        raw = "http://" .. raw
    end

    local parsed = socket_url.parse(raw)
    if type(parsed) ~= "table" then
        return nil, _("The proxy address is invalid.")
    end

    local scheme = type(parsed.scheme) == "string" and parsed.scheme:lower() or ""
    if scheme == "socks5h" then scheme = "socks5" end
    if scheme ~= "http" and scheme ~= "socks5" then
        return nil, _("Use http:// or socks5:// for the proxy address.")
    end

    local host = trim(parsed.host)
    local port = tonumber(parsed.port)
    if host == "" or host:find("[%c%s]") then
        return nil, _("The proxy host is invalid.")
    end
    if not port or port ~= math.floor(port) or port < 1 or port > 65535 then
        return nil, _("The proxy port must be between 1 and 65535.")
    end
    if parsed.user or parsed.password or parsed.userinfo then
        return nil, _("Enter proxy credentials in the separate username and password fields.")
    end
    if (parsed.path and parsed.path ~= "" and parsed.path ~= "/")
            or parsed.params or parsed.query or parsed.fragment then
        return nil, _("The proxy address must not contain a path, query, or fragment.")
    end

    local username = trim(SUISettings:get(KEY_USERNAME))
    local password = SUISettings:get(KEY_PASSWORD)
    if type(password) ~= "string" then password = "" end
    if #username > 255 or #password > 255 then
        return nil, _("Proxy username and password must each be at most 255 bytes.")
    end

    return {
        scheme = scheme,
        host = host,
        port = port,
        username = username,
        password = password,
        url = scheme .. "://" .. hostPort(host, port),
    }
end

function M.isEnabled()
    return SUISettings:isTrue(KEY_ENABLED)
end

function M.isReady()
    return _transport_ready
end

function M.getStatusText()
    if not M.isEnabled() then return _("Off") end
    local cfg = readConfig()
    return cfg and _("On") or _("Invalid configuration")
end

local function closeQuietly(sock)
    if sock then pcall(function() sock:close() end) end
end

local function sendAll(sock, data)
    local first = 1
    while first <= #data do
        local sent, err, last = sock:send(data, first)
        if sent then
            first = sent + 1
        elseif last and last >= first then
            first = last + 1
        else
            return nil, err or "send failed"
        end
    end
    return 1
end

local function receiveExact(sock, length)
    local parts, received = {}, 0
    while received < length do
        local chunk, err, partial = sock:receive(length - received)
        chunk = chunk or partial
        if chunk and #chunk > 0 then
            parts[#parts + 1] = chunk
            received = received + #chunk
        end
        if not chunk or #chunk == 0 then
            return nil, err or "connection closed"
        end
    end
    return table.concat(parts)
end

local function basicCredentials(cfg)
    if cfg.username == "" and cfg.password == "" then return nil end
    return (mime.b64(cfg.username .. ":" .. cfg.password) or ""):gsub("%s", "")
end

local function httpConnect(sock, cfg, target_host, target_port)
    local authority = hostPort(target_host, target_port)
    local lines = {
        "CONNECT " .. authority .. " HTTP/1.1",
        "Host: " .. authority,
        "Proxy-Connection: Keep-Alive",
    }
    local credentials = basicCredentials(cfg)
    if credentials then
        lines[#lines + 1] = "Proxy-Authorization: Basic " .. credentials
    end
    lines[#lines + 1] = ""
    lines[#lines + 1] = ""

    local ok, err = sendAll(sock, table.concat(lines, "\r\n"))
    if not ok then return nil, "HTTP proxy CONNECT send failed: " .. tostring(err) end

    local status_line, status_err = sock:receive("*l")
    if not status_line then
        return nil, "HTTP proxy CONNECT response failed: " .. tostring(status_err)
    end
    local status = tonumber(status_line:match("^HTTP/%d+%.%d+%s+(%d%d%d)"))
    if not status then
        return nil, "HTTP proxy returned a malformed CONNECT response"
    end

    -- Drain the CONNECT response headers, with a defensive size cap.
    local total = #status_line
    for _i = 1, 100 do
        local line, line_err = sock:receive("*l")
        if not line then
            return nil, "HTTP proxy CONNECT headers failed: " .. tostring(line_err)
        end
        total = total + #line
        if total > 65536 then
            return nil, "HTTP proxy CONNECT headers are too large"
        end
        if line == "" then break end
        if _i == 100 then
            return nil, "HTTP proxy CONNECT returned too many headers"
        end
    end

    if status ~= 200 then
        if status == 407 then
            return nil, "HTTP proxy authentication failed (407)"
        end
        return nil, "HTTP proxy refused CONNECT (status " .. tostring(status) .. ")"
    end
    return 1
end

local function ipv4Bytes(host)
    local a, b, c, d = host:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
    if not a then return nil end
    a, b, c, d = tonumber(a), tonumber(b), tonumber(c), tonumber(d)
    if a > 255 or b > 255 or c > 255 or d > 255 then return nil end
    return string.char(a, b, c, d)
end

local function socks5Connect(sock, cfg, target_host, target_port)
    local wants_auth = cfg.username ~= "" or cfg.password ~= ""
    local greeting = wants_auth and "\5\2\0\2" or "\5\1\0"
    local ok, err = sendAll(sock, greeting)
    if not ok then return nil, "SOCKS5 greeting failed: " .. tostring(err) end

    local choice, choice_err = receiveExact(sock, 2)
    if not choice then return nil, "SOCKS5 greeting response failed: " .. tostring(choice_err) end
    if choice:byte(1) ~= 5 then return nil, "SOCKS5 proxy returned an invalid version" end
    local method = choice:byte(2)
    if method == 255 then return nil, "SOCKS5 proxy rejected all authentication methods" end
    if method == 2 then
        if not wants_auth then return nil, "SOCKS5 proxy requires a username and password" end
        local auth = "\1" .. string.char(#cfg.username) .. cfg.username
            .. string.char(#cfg.password) .. cfg.password
        local auth_ok, auth_err = sendAll(sock, auth)
        if not auth_ok then return nil, "SOCKS5 authentication send failed: " .. tostring(auth_err) end
        local auth_reply, reply_err = receiveExact(sock, 2)
        if not auth_reply then return nil, "SOCKS5 authentication response failed: " .. tostring(reply_err) end
        if auth_reply:byte(1) ~= 1 or auth_reply:byte(2) ~= 0 then
            return nil, "SOCKS5 authentication failed"
        end
    elseif method ~= 0 then
        return nil, "SOCKS5 proxy selected an unsupported authentication method"
    end

    local address
    local ipv4 = ipv4Bytes(target_host)
    if ipv4 then
        address = "\1" .. ipv4
    else
        -- ATYP=DOMAIN makes the proxy resolve the Z-Library/CDN hostname.  No
        -- target DNS lookup is performed on the Kindle.
        if target_host:find(":", 1, true) then
            return nil, "SOCKS5 IPv6-literal targets are not supported"
        end
        if #target_host == 0 or #target_host > 255 then
            return nil, "SOCKS5 target hostname is invalid"
        end
        address = "\3" .. string.char(#target_host) .. target_host
    end
    local port_bytes = string.char(math.floor(target_port / 256), target_port % 256)
    local request_ok, request_err = sendAll(sock, "\5\1\0" .. address .. port_bytes)
    if not request_ok then return nil, "SOCKS5 CONNECT send failed: " .. tostring(request_err) end

    local reply, reply_err = receiveExact(sock, 4)
    if not reply then return nil, "SOCKS5 CONNECT response failed: " .. tostring(reply_err) end
    if reply:byte(1) ~= 5 then return nil, "SOCKS5 proxy returned an invalid version" end
    local reply_code, atyp = reply:byte(2), reply:byte(4)
    if reply_code ~= 0 then
        local labels = {
            [1] = "general failure", [2] = "connection not allowed", [3] = "network unreachable",
            [4] = "host unreachable", [5] = "connection refused", [6] = "TTL expired",
            [7] = "command unsupported", [8] = "address type unsupported",
        }
        return nil, "SOCKS5 proxy refused CONNECT: " .. (labels[reply_code] or tostring(reply_code))
    end

    local trailing
    if atyp == 1 then
        trailing = 4 + 2
    elseif atyp == 3 then
        local size, size_err = receiveExact(sock, 1)
        if not size then return nil, "SOCKS5 response address failed: " .. tostring(size_err) end
        trailing = size:byte(1) + 2
    elseif atyp == 4 then
        trailing = 16 + 2
    else
        return nil, "SOCKS5 proxy returned an invalid address type"
    end
    local _, trailing_err = receiveExact(sock, trailing)
    if trailing_err then return nil, "SOCKS5 response address failed: " .. tostring(trailing_err) end
    return 1
end

local function forwardSocketMethods(conn, response_state)
    local mt = getmetatable(conn.sock)
    local methods = mt and mt.__index
    if type(methods) ~= "table" then return end
    for name, method in pairs(methods) do
        if type(method) == "function" then
            conn[name] = function(self, ...)
                return method(self.sock, ...)
            end
        end
    end
    -- socket.http reads the status line as receive(5) followed by
    -- receive("*l", "HTTP/"). Capturing it here lets the sink wrapper below
    -- discard a redirect body without closing the caller's streamed file.
    local receive = methods.receive
    if response_state and type(receive) == "function" then
        conn.receive = function(self, pattern, prefix)
            local value, err, partial = receive(self.sock, pattern, prefix)
            local line = value or partial
            if pattern == "*l" and type(prefix) == "string"
                    and prefix:sub(1, 5) == "HTTP/" and type(line) == "string" then
                response_state.status = tonumber(line:match("^HTTP/%d*%.%d* (%d%d%d)"))
            end
            return value, err, partial
        end
    end
end

local TLS_CONFIG = {
    mode = "client",
    protocol = "any",
    options = { "all", "no_sslv2", "no_sslv3", "no_tlsv1" },
    verify = "none",
}

local function tunnelCreate(cfg, use_tls, response_state)
    return function()
        local raw_sock, raw_err = socket.tcp()
        if not raw_sock then return nil, raw_err end
        local conn = {
            sock = raw_sock,
            timeout = http.TIMEOUT,
        }

        function conn:settimeout(value, mode)
            self.timeout = value or self.timeout
            return self.sock:settimeout(value, mode)
        end

        function conn:close()
            if self.sock then return self.sock:close() end
        end

        function conn:connect(target_host, target_port)
            local connected, connect_err = self.sock:connect(cfg.host, cfg.port)
            if not connected then
                return nil, "Z-Library proxy connection failed: " .. tostring(connect_err)
            end

            local tunnel_ok, tunnel_err
            if cfg.scheme == "http" then
                tunnel_ok, tunnel_err = httpConnect(self.sock, cfg, target_host, target_port)
            else
                tunnel_ok, tunnel_err = socks5Connect(self.sock, cfg, target_host, target_port)
            end
            if not tunnel_ok then
                closeQuietly(self.sock)
                return nil, tunnel_err
            end

            if use_tls then
                local tls_sock, wrap_err = ssl.wrap(self.sock, TLS_CONFIG)
                if not tls_sock then
                    closeQuietly(self.sock)
                    return nil, "TLS setup through the Z-Library proxy failed: " .. tostring(wrap_err)
                end
                self.sock = tls_sock
                local sni_ok, sni_err = pcall(function() return self.sock:sni(target_host) end)
                if not sni_ok then
                    closeQuietly(self.sock)
                    return nil, "TLS SNI through the Z-Library proxy failed: " .. tostring(sni_err)
                end
                self.sock:settimeout(self.timeout or https.TIMEOUT)
                local handshake_ok, handshake_err = self.sock:dohandshake()
                if not handshake_ok then
                    closeQuietly(self.sock)
                    return nil, "TLS handshake through the Z-Library proxy failed: " .. tostring(handshake_err)
                end
            end

            forwardSocketMethods(self, response_state)
            return 1
        end

        return conn
    end
end

-- HTTP forward-proxy mode still needs our response observer, but not a
-- CONNECT/SOCKS handshake. socket.http changes connect(host, port) to the
-- proxy endpoint because request.proxy is present; this connector simply
-- opens that endpoint and records the returned status line.
local function forwardProxyCreate(response_state)
    return function()
        local raw_sock, raw_err = socket.tcp()
        if not raw_sock then return nil, raw_err end
        local conn = { sock = raw_sock }
        function conn:settimeout(value, mode)
            return self.sock:settimeout(value, mode)
        end
        function conn:close()
            if self.sock then return self.sock:close() end
        end
        function conn:connect(host, port)
            local ok, err = self.sock:connect(host, port)
            if not ok then return nil, "Z-Library proxy connection failed: " .. tostring(err) end
            forwardSocketMethods(self, response_state)
            return 1
        end
        return conn
    end
end

local function copyHeaders(headers)
    local copy = {}
    for key, value in pairs(type(headers) == "table" and headers or {}) do
        if type(key) ~= "string" or key:lower() ~= "proxy-authorization" then
            copy[key] = value
        end
    end
    return copy
end

local function proxyHttpRequest(params, cfg, base_request)
    if type(params) ~= "table" then
        return nil, "Z-Library proxy requires a table-form HTTP request"
    end
    cfg = cfg or readConfig()
    if not cfg then
        local _, config_err = readConfig()
        return nil, "Z-Library proxy configuration invalid: " .. tostring(config_err)
    end

    local parsed = socket_url.parse(params.url or "")
    local target_scheme = parsed and type(parsed.scheme) == "string" and parsed.scheme:lower() or ""
    if not parsed or (target_scheme ~= "http" and target_scheme ~= "https")
            or type(parsed.host) ~= "string" or parsed.host == ""
            or parsed.host:find("[%c%s]") then
        return nil, "Z-Library proxy refused an invalid target URL"
    end
    if _require_https and target_scheme ~= "https" then
        return nil, "Z-Library proxy refused an HTTPS-to-HTTP redirect"
    end
    local request = {}
    for key, value in pairs(params) do request[key] = value end
    request.headers = copyHeaders(params.headers)

    local response_state = {}
    if request.sink then
        local target_sink = request.sink
        request.sink = function(chunk, err)
            local status = response_state.status
            if status == 301 or status == 302 or status == 303
                    or status == 307 or status == 308 then
                -- Z-Library will follow this response itself. Do not write its
                -- body and, critically, do not forward the terminating nil
                -- that would close an external cover/book/update file sink.
                return 1
            end
            return target_sink(chunk, err)
        end
    end

    -- Never let LuaSocket follow a redirect by itself: when a redirect changes
    -- scheme it silently deletes a custom create function.  Z-Library's own
    -- redirect loop will re-enter this function and build a fresh tunnel for
    -- every hop instead.
    request.redirect = false

    if cfg.scheme == "http" and target_scheme == "http" then
        -- Standard forward mode for an unencrypted HTTP target.  The target
        -- hostname stays in the absolute URI and is resolved by the proxy.
        request.proxy = cfg.url
        request.create = forwardProxyCreate(response_state)
        local credentials = basicCredentials(cfg)
        if credentials then
            request.headers["Proxy-Authorization"] = "Basic " .. credentials
        end
    else
        request.proxy = nil
        request.create = tunnelCreate(cfg, target_scheme == "https", response_state)
    end

    return base_request(request)
end

local function pack(...)
    return { n = select("#", ...), ... }
end

local function protectedCall(fn)
    local values
    local ok, err = xpcall(function()
        values = pack(fn())
    end, debug.traceback)
    return ok, values or err
end

local function callerIsZlibrary()
    for level = 2, 7 do
        local info = debug.getinfo(level, "S")
        local source = info and info.source or ""
        if source:find("zlibrary.koplugin", 1, true)
                or source:find("/zlibrary/", 1, true) then
            return true
        end
    end
    return false
end

local function installNetworkGate()
    local ok, NetworkMgr = pcall(require, "ui/network/manager")
    if not ok or type(NetworkMgr) ~= "table"
            or type(NetworkMgr.willRerunWhenOnline) ~= "function"
            or type(NetworkMgr.willRerunWhenConnected) ~= "function" then
        return false
    end
    if NetworkMgr._weui_zlibrary_proxy_gate_owner == M
            and type(NetworkMgr._weui_zlibrary_proxy_gate_wrapper) == "function"
            and NetworkMgr.willRerunWhenOnline
                == NetworkMgr._weui_zlibrary_proxy_gate_wrapper then
        return true
    end

    -- Recover cleanly from a previously loaded WeUI proxy module before
    -- installing the current owner (relevant to hot plugin updates).
    if NetworkMgr._weui_zlibrary_proxy_gate_wrapper
            and NetworkMgr.willRerunWhenOnline == NetworkMgr._weui_zlibrary_proxy_gate_wrapper
            and type(NetworkMgr._weui_zlibrary_proxy_gate_original) == "function" then
        NetworkMgr.willRerunWhenOnline = NetworkMgr._weui_zlibrary_proxy_gate_original
    end

    local original = NetworkMgr.willRerunWhenOnline
    local wrapper = function(self, callback)
        -- isOnline() performs a direct dns.msftncsi.com lookup.  In strict
        -- proxy mode Z-Library only needs an active Wi-Fi connection; its
        -- actual reachability is determined by the proxy request itself.
        if M.isEnabled() and callerIsZlibrary() then
            -- If a future vendored version no longer exposes the
            -- audited API entry point, abort its known network actions rather
            -- than letting the user's strict proxy setting degrade to direct.
            if not _transport_ready then return true end
            return self:willRerunWhenConnected(callback)
        end
        return original(self, callback)
    end
    NetworkMgr.willRerunWhenOnline = wrapper
    NetworkMgr._weui_zlibrary_proxy_gate_installed = true
    NetworkMgr._weui_zlibrary_proxy_gate_original = original
    NetworkMgr._weui_zlibrary_proxy_gate_wrapper = wrapper
    NetworkMgr._weui_zlibrary_proxy_gate_owner = M
    _installed_network_mgr, _network_original, _network_wrapper = NetworkMgr, original, wrapper
    return true
end

function M.install()
    installNetworkGate()

    local ok, Api = pcall(require, "zlibrary.api")
    if not ok or type(Api) ~= "table" or type(Api.makeHttpRequest) ~= "function" then
        _transport_ready = false
        return false, _("Embedded Z-Library module is unavailable.")
    end
    if Api._weui_zlibrary_proxy_owner == M
            and type(Api._weui_zlibrary_proxy_wrapper) == "function"
            and Api.makeHttpRequest == Api._weui_zlibrary_proxy_wrapper then
        _transport_ready = true
        return true
    end

    if Api._weui_zlibrary_proxy_wrapper
            and Api.makeHttpRequest == Api._weui_zlibrary_proxy_wrapper
            and type(Api._weui_zlibrary_proxy_original) == "function" then
        Api.makeHttpRequest = Api._weui_zlibrary_proxy_original
    end

    local original = Api.makeHttpRequest
    local wrapper = function(options)
        if not M.isEnabled() then
            return original(options)
        end

        -- Recursive redirects and the one-shot stall retry call the public API
        -- again.  The outer frame already owns the temporary transport and
        -- guarantees restoration, so inner frames simply reuse it.
        if _api_depth > 0 then
            return original(options)
        end

        _api_depth = 1
        local saved_http_request = http.request
        local saved_http_proxy = http.PROXY
        local saved_redirect = type(options) == "table" and options.redirect or nil
        local first_url = type(options) == "table" and socket_url.parse(options.url or "") or nil
        local first_scheme = first_url and type(first_url.scheme) == "string"
            and first_url.scheme:lower() or ""
        _active_http_request = saved_http_request
        _require_https = first_scheme == "https"
        http.PROXY = nil
        http.request = function(params)
            local cfg, config_err = readConfig()
            if not cfg then
                return nil, "Z-Library proxy configuration invalid: " .. tostring(config_err)
            end
            return proxyHttpRequest(params, cfg, _active_http_request)
        end
        if type(options) == "table" then
            -- Force Z-Library's own safe, per-hop redirect handling even for
            -- callers which normally ask LuaSocket to follow automatically.
            options.redirect = false
        end

        local ok_call, values_or_err = protectedCall(function()
            return original(options)
        end)

        if type(options) == "table" then options.redirect = saved_redirect end
        http.request = saved_http_request
        http.PROXY = saved_http_proxy
        _active_http_request = nil
        _require_https = false
        _api_depth = 0

        if not ok_call then error(values_or_err, 0) end
        return unpack_args(values_or_err, 1, values_or_err.n)
    end
    Api.makeHttpRequest = wrapper
    Api._weui_zlibrary_proxy_installed = true
    Api._weui_zlibrary_proxy_original = original
    Api._weui_zlibrary_proxy_wrapper = wrapper
    Api._weui_zlibrary_proxy_owner = M
    _installed_api, _api_original, _api_wrapper = Api, original, wrapper
    _transport_ready = true
    logger.info("weui: installed fail-closed Z-Library proxy transport")
    return true
end

function M.uninstall()
    if _installed_api and _installed_api.makeHttpRequest == _api_wrapper then
        _installed_api.makeHttpRequest = _api_original
    end
    if _installed_api and _installed_api._weui_zlibrary_proxy_owner == M then
        _installed_api._weui_zlibrary_proxy_installed = nil
        _installed_api._weui_zlibrary_proxy_original = nil
        _installed_api._weui_zlibrary_proxy_wrapper = nil
        _installed_api._weui_zlibrary_proxy_owner = nil
    end
    if _installed_network_mgr
            and _installed_network_mgr.willRerunWhenOnline == _network_wrapper then
        _installed_network_mgr.willRerunWhenOnline = _network_original
    end
    if _installed_network_mgr
            and _installed_network_mgr._weui_zlibrary_proxy_gate_owner == M then
        _installed_network_mgr._weui_zlibrary_proxy_gate_installed = nil
        _installed_network_mgr._weui_zlibrary_proxy_gate_original = nil
        _installed_network_mgr._weui_zlibrary_proxy_gate_wrapper = nil
        _installed_network_mgr._weui_zlibrary_proxy_gate_owner = nil
    end
    _installed_api, _api_original, _api_wrapper = nil, nil, nil
    _installed_network_mgr, _network_original, _network_wrapper = nil, nil, nil
    _active_http_request = nil
    _api_depth = 0
    _require_https = false
    _transport_ready = false
end

-- A credential-free probe.  Any numeric HTTP status proves that the proxy,
-- tunnel (for HTTPS), target TLS and target HTTP response all completed.
function M.probe()
    local cfg, config_err = readConfig()
    if not cfg then return { ok = false, error = config_err } end

    local target
    local ok_config, ZConfig = pcall(require, "zlibrary.config")
    if ok_config and ZConfig and type(ZConfig.getBaseUrl) == "function" then
        target = ZConfig.getBaseUrl(true) or ZConfig.getBaseUrl()
    end
    if type(target) ~= "string" or target == "" then
        return { ok = false, error = _("No Z-Library server address is available.") }
    end
    -- Probe the same small API endpoint used by Z-Library health checks.
    -- Some mirrors stall HEAD requests to their public website indefinitely.
    target = target:gsub("/+$", "") .. "/eapi/info/ok"

    local old_block, old_total = socketutil.block_timeout, socketutil.total_timeout
    local saved_proxy = http.PROXY
    local started = socket.gettime and socket.gettime() or os.time()
    socketutil:set_timeout(8, 15)
    http.PROXY = nil
    local ok_request, response = protectedCall(function()
        local _, code = proxyHttpRequest({
            url = target,
            method = "GET",
            headers = { ["User-Agent"] = socketutil.USER_AGENT },
            sink = ltn12.sink.null(),
            redirect = false,
        }, cfg, http.request)
        return code
    end)
    http.PROXY = saved_proxy
    socketutil:set_timeout(old_block, old_total)

    local elapsed = math.floor((((socket.gettime and socket.gettime() or os.time()) - started) * 1000) + 0.5)
    if not ok_request then
        return { ok = false, error = tostring(response), elapsed = elapsed }
    end
    local code = response[1]
    if type(code) ~= "number" then
        return { ok = false, error = tostring(code or _("No HTTP response received.")), elapsed = elapsed }
    end
    if code == 407 then
        return { ok = false, error = "HTTP proxy authentication failed (407)", elapsed = elapsed }
    end
    return { ok = true, status = code, elapsed = elapsed, label = proxyLabel(cfg) }
end

local function showInfo(text, timeout, scrollable)
    local UIManager = require("ui/uimanager")
    local InfoMessage = require("ui/widget/infomessage")
    local height
    if scrollable then
        local Screen = require("device").screen
        height = math.floor(Screen:getHeight() * 0.58)
    end
    UIManager:show(InfoMessage:new{
        text = text,
        timeout = timeout,
        height = height,
        show_icon = not scrollable,
    })
end

local function editSetting(opts)
    local UIManager = require("ui/uimanager")
    local InputDialog = require("ui/widget/inputdialog")
    local dialog
    dialog = InputDialog:new{
        title = opts.title,
        input = opts.input or "",
        input_hint = opts.hint,
        text_type = opts.password and "password" or nil,
        description = opts.description,
        buttons = {{
            {
                text = _("Cancel"),
                callback = function() UIManager:close(dialog) end,
            },
            {
                text = _("Save"),
                is_enter_default = true,
                callback = function()
                    local value = dialog:getInputText() or ""
                    local accepted, err = opts.save(value)
                    if accepted == false then
                        showInfo(err or _("The value is invalid."), 4)
                        return
                    end
                    UIManager:close(dialog)
                    if opts.on_change then opts.on_change() end
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

local function editAddress(on_change)
    editSetting{
        on_change = on_change,
        title = _("Z-Library proxy server"),
        input = SUISettings:get(KEY_URL) or "",
        hint = "socks5://192.168.1.2:1080",
        description = _("HTTP CONNECT: http://host:port\nSOCKS5 with remote DNS: socks5://host:port"),
        save = function(value)
            value = trim(value)
            if value == "" then
                return false, _("Proxy address cannot be empty.")
            end
            if not value:match("^[%a][%w+.-]*://") then value = "socks5://" .. value end
            local old = SUISettings:get(KEY_URL)
            SUISettings:set(KEY_URL, value)
            local cfg, err = readConfig()
            if not cfg then
                if old == nil then SUISettings:del(KEY_URL) else SUISettings:set(KEY_URL, old) end
                return false, err
            end
            SUISettings:set(KEY_URL, cfg.url)
            return true
        end,
    }
end

local function editUsername(on_change)
    editSetting{
        on_change = on_change,
        title = _("Proxy username"),
        input = SUISettings:get(KEY_USERNAME) or "",
        hint = _("Optional"),
        description = _("Leave empty when the proxy does not require authentication."),
        save = function(value)
            value = trim(value)
            if #value > 255 then return false, _("Proxy username is too long.") end
            if value == "" then SUISettings:del(KEY_USERNAME) else SUISettings:set(KEY_USERNAME, value) end
            return true
        end,
    }
end

local function editPassword(on_change)
    local configured = type(SUISettings:get(KEY_PASSWORD)) == "string"
        and SUISettings:get(KEY_PASSWORD) ~= ""
    editSetting{
        on_change = on_change,
        title = _("Proxy password"),
        input = "",
        hint = configured and _("Enter a replacement, or leave empty to clear") or _("Optional"),
        password = true,
        description = _("The password is stored in plain text in the local We UI settings file. It is never shown in menus or logs."),
        save = function(value)
            if #value > 255 then return false, _("Proxy password is too long.") end
            if value == "" then SUISettings:del(KEY_PASSWORD) else SUISettings:set(KEY_PASSWORD, value) end
            return true
        end,
    }
end

local function friendlyProxyError(err)
    local raw = tostring(err or "")
    local lower = raw:lower()
    if lower:find("authentication", 1, true) or lower:find("407", 1, true) then
        return _("Proxy authentication failed. Check the username and password.")
    elseif lower:find("proxy connection failed", 1, true) then
        return _("Could not connect to the proxy server. Check its address, port, and LAN access.")
    elseif lower:find("timeout", 1, true) or lower:find("wantread", 1, true)
            or lower:find("wantwrite", 1, true) then
        return _("The proxy connection timed out.")
    elseif lower:find("refused connect", 1, true) then
        return _("The proxy refused the connection to Z-Library.")
    elseif lower:find("tls", 1, true) then
        return _("The proxy tunnel was created, but the TLS connection to Z-Library failed.")
    end
    return raw ~= "" and raw or _("Unknown error")
end

function M.testFromUI()
    local cfg, err = readConfig()
    if not cfg then
        showInfo(err, 4)
        return
    end

    local NetworkMgr = require("ui/network/manager")
    if NetworkMgr:willRerunWhenConnected(function() M.testFromUI() end) then return end

    local Trapper = require("ui/trapper")
    Trapper:wrap(function()
        local completed, result = Trapper:dismissableRunInSubprocess(function()
            return M.probe()
        end, _("Testing Z-Library proxy…"))
        if not completed then return end
        if result and result.ok then
            showInfo(string.format(
                _("Proxy test succeeded.\n\n%s\nHTTP status: %d\nTime: %d ms"),
                result.label or proxyLabel(cfg), result.status, result.elapsed or 0))
        else
            showInfo(string.format(
                _("Proxy test failed. No direct connection was attempted.\n\n%s"),
                friendlyProxyError(result and result.error)))
        end
    end)
end

local function clearSettings(on_change)
    local UIManager = require("ui/uimanager")
    local ConfirmBox = require("ui/widget/confirmbox")
    UIManager:show(ConfirmBox:new{
        text = _("Clear the Z-Library proxy server and credentials?"),
        ok_text = _("Clear"),
        ok_callback = function()
            SUISettings:set(KEY_ENABLED, false)
            SUISettings:del(KEY_URL)
            SUISettings:del(KEY_USERNAME)
            SUISettings:del(KEY_PASSWORD)
            if on_change then on_change() end
            showInfo(_("Z-Library proxy settings cleared."), 3)
        end,
    })
end

function M.getMenuItems(on_change)
    return {
        {
            text = _("Use proxy for all Z-Library traffic"),
            checked_func = function() return M.isEnabled() end,
            keep_menu_open = true,
            callback = function()
                if M.isEnabled() then
                    SUISettings:set(KEY_ENABLED, false)
                    if on_change then on_change() end
                    showInfo(_("Z-Library proxy disabled."), 3)
                    return
                end
                local cfg, err = readConfig()
                if not cfg then
                    showInfo(err, 4)
                    return
                end
                SUISettings:set(KEY_ENABLED, true)
                M.install()
                if on_change then on_change() end
                showInfo(_("Z-Library proxy enabled. If the proxy fails, Z-Library will not connect directly."), 4)
            end,
        },
        {
            text_func = function()
                local cfg = readConfig()
                return _("Proxy server") .. ": " .. (cfg and proxyLabel(cfg) or _("Not configured"))
            end,
            callback = function() editAddress(on_change) end,
        },
        {
            text_func = function()
                local value = trim(SUISettings:get(KEY_USERNAME))
                return _("Proxy username") .. ": " .. (value ~= "" and _("Set") or _("Not set"))
            end,
            callback = function() editUsername(on_change) end,
        },
        {
            text_func = function()
                local value = SUISettings:get(KEY_PASSWORD)
                return _("Proxy password") .. ": "
                    .. (type(value) == "string" and value ~= "" and _("Set") or _("Not set"))
            end,
            callback = function() editPassword(on_change) end,
        },
        {
            text = _("Test proxy connection"),
            callback = M.testFromUI,
            separator = true,
        },
        {
            text = _("Proxy behavior and Kindle tips"),
            callback = function()
                showInfo(_([[Only Z-Library traffic uses this proxy, including login, search, covers, book downloads, mirror discovery, favorites, and Z-Library updates.

HTTP proxies use CONNECT for HTTPS. SOCKS5 sends target hostnames to the proxy for remote DNS resolution. A proxy failure always blocks the request; there is no direct fallback. Use only a proxy server you trust.

127.0.0.1 means the Kindle itself. For a proxy running on a computer, phone, or router, enter its LAN IP and allow LAN connections. Using a proxy IP also avoids a local DNS lookup for the proxy server.]]), nil, true)
            end,
            separator = true,
        },
        {
            text = _("Clear proxy settings"),
            callback = function() clearSettings(on_change) end,
        },
    }
end

-- Exposed only for deterministic transport harnesses; production callers use
-- install(), probe() and getMenuItems().
M._readConfig = readConfig
M._proxyHttpRequest = proxyHttpRequest
M._tunnelCreate = tunnelCreate

return M

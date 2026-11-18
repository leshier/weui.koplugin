-- Credential-free requests through the user's authorized local SOCKS5 service.
require("setupkoenv")
local repo = assert(os.getenv("WEUI_PROXY_REPO"))
local root = assert(os.getenv("WEUI_PROXY_ROOT"))
package.path = repo .. "/?.lua;" .. package.path
G_reader_settings = require("luasettings"):open(root .. "/settings.reader.lua")
G_reader_settings:saveSetting("home_dir", root)
package.loaded.device = { model = "ProxyQA", isAndroid = function() return false end }
package.loaded["ui/network/manager"] = {
    willRerunWhenOnline = function() return false end,
    willRerunWhenConnected = function() return false end,
}
local Store = require("weui_store")
local Config = require("zlibrary.config")
local Api = require("zlibrary.api")
local Proxy = require("weui_zlibrary_proxy")
local socket = require("socket")
local http = require("socket.http")
local sample = assert(socket.tcp())
local methods = getmetatable(sample).__index
sample:close()
local connect = methods.connect
local direct, connections, failures = 0, 0, 0
methods.connect = function(self, host, port, ...)
    if host ~= "127.0.0.1" then direct = direct + 1; error("unexpected direct connection") end
    connections = connections + 1
    return connect(self, host, port, ...)
end
Config.saveSetting(Config.SETTINGS_AUTO_MIRROR_FAILOVER_KEY, false)
Store:set("weui_zlibrary_proxy_url", "socks5://127.0.0.1:10808")
Store:set("weui_zlibrary_proxy_enabled", true)
assert(Proxy.install())
local native_request = http.request
local output = assert(io.open(root .. "/results.tsv", "w"))
local function result(name, ok, detail)
    if not ok then failures = failures + 1 end
    output:write(ok and "PASS" or "FAIL", "\t", name, "\t", detail or "", "\n"); output:flush()
end
local probe = Proxy.probe()
result("local-socks5-tunnel-tls-http", probe.ok,
    "status=" .. tostring(probe.status) .. " elapsed_ms=" .. tostring(probe.elapsed)
        .. (probe.ok and "" or " error=" .. tostring(probe.error)))
local health = Api.healthCheck(Config.getBaseUrl(true), true)
result("zlibrary-live-health", health.success, health.success and "success=1" or tostring(health.error))
local response = Api.makeHttpRequest{
    url = "https://example.com/", timeout = { 8, 15 }, redirect = true,
}
result("api-live-https", not response.error and response.status_code == 200,
    "status=" .. tostring(response.status_code) .. " bytes=" .. tostring(#(response.body or "")))
Store:set("weui_zlibrary_proxy_url", "socks5://127.0.0.1:1")
local failed = Api.makeHttpRequest{ url = Config.getBaseUrl(true), timeout = { 1, 2 } }
result("proxy-unavailable-fail-closed", failed.error ~= nil and direct == 0)
result("global-http-restored", http.request == native_request)
result("no-direct-connect", direct == 0, "proxy_connections=" .. connections .. " direct_attempts=" .. direct)
Proxy.uninstall()
methods.connect = connect
output:close()
os.exit(failures == 0 and 0 or 1)

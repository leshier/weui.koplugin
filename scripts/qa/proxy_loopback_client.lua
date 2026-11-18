-- Native LuaSocket/LuaSec and the actual vendored API; UI only is stubbed.
require("setupkoenv")
local repo, root = assert(os.getenv("WEUI_PROXY_REPO")), assert(os.getenv("WEUI_PROXY_ROOT"))
package.path = repo .. "/?.lua;" .. package.path
G_reader_settings = require("luasettings"):open(root .. "/settings.reader.lua")
G_reader_settings:saveSetting("home_dir", root)
package.loaded.device = { model = "ProxyQA", isAndroid = function() return false end }
package.loaded["ui/network/manager"] = {
    willRerunWhenOnline = function() return false end,
    willRerunWhenConnected = function() return false end,
}
local socket = require("socket")
local http = require("socket.http")
local Store = require("weui_store")
local Config = require("zlibrary.config")
local Api = require("zlibrary.api")
local Proxy = require("weui_zlibrary_proxy")
local results = assert(io.open(root .. "/results.tsv", "w"))
local count, connections, direct = 0, 0, 0
local function check(name, callback)
    callback()
    count = count + 1
    results:write("PASS\t", name, "\n"); results:flush()
end
local function accepted(result)
    assert(result and not result.error, result and result.error or "missing API result")
end
-- Catch even attempted direct target connections before C code resolves them.
local sample = assert(socket.tcp())
local methods = getmetatable(sample).__index
local connect = methods.connect
sample:close()
methods.connect = function(self, host, port, ...)
    if host ~= "127.0.0.1" then direct = direct + 1; error("direct target connection attempted: " .. tostring(host)) end
    connections = connections + 1
    return connect(self, host, port, ...)
end
local base = "https://api.invalid"
Config.saveSetting(Config.SETTINGS_BASE_URL_KEY, base)
Config.saveSetting(Config.SETTINGS_AUTO_MIRROR_FAILOVER_KEY, false)
Store:set("weui_zlibrary_proxy_url", "socks5://127.0.0.1:" .. assert(os.getenv("WEUI_PROXY_PORT")))
Store:set("weui_zlibrary_proxy_enabled", true)
assert(Proxy.install())
local native_request = http.request
for _, auth in ipairs({ false, true }) do
    Store:set("weui_zlibrary_proxy_username", auth and "qa-user" or "")
    Store:set("weui_zlibrary_proxy_password", auth and "qa-secret" or "")
    local suffix = auth and "-authenticated" or "-anonymous"
    check("login" .. suffix, function() accepted(Api.login("synthetic@example.invalid", "synthetic")) end)
    check("search" .. suffix, function() accepted(Api.search("纸页", "qa", "key", {}, {}, {}, 1)) end)
    for _, spec in ipairs({
        { "recommended", "getRecommendedBooks" }, { "popular", "getMostPopularBooks" },
        { "details", "getBookDetails", "1", "hash" }, { "download-link", "getDownloadLink", "1", "hash" },
        { "similar", "getSimilarBooks", "1", "hash" }, { "downloaded", "getDownloadedBooks", 1 },
        { "favorites", "getFavoriteBooks", 1 }, { "favorite-ids", "getFavoriteBookIds" },
        { "quota", "getDownloadQuotaStatus" }, { "comments", "getBookComments", "1" },
        { "favorite", "favoriteBook", { id = "1" } }, { "unfavorite", "unfavoriteBook", { id = "1" } },
        { "remove-history", "deleteDownloadedBook", { id = "1" } },
    }) do
        check(spec[1] .. suffix, function() accepted(Api[spec[2]]("qa", "key", unpack(spec, 3))) end)
    end
    check("cover" .. suffix, function() accepted(Api.downloadBookCover("https://cover.invalid/cover", root .. "/cover")) end)
    check("download" .. suffix, function()
        accepted(Api.downloadBook("https://download.invalid/redirect", root .. "/book", "qa", "key"))
        local file = assert(io.open(root .. "/book", "rb"))
        assert(file:read("*a") == "BOOK-CONTENT"); file:close()
    end)
    check("health" .. suffix, function() accepted(Api.healthCheck(base, true)) end)
    check("domains" .. suffix, function() accepted(Api.fetchDynamicDomains()) end)
    check("http-remote-dns" .. suffix, function() accepted(Api.makeHttpRequest{ url = "http://plain.invalid/plain" }) end)
    assert(http.request == native_request, "temporary proxy transport escaped API scope")
end
check("socks-authentication-failure", function()
    Store:set("weui_zlibrary_proxy_password", "wrong")
    local result = Api.makeHttpRequest{ url = base .. "/failure", timeout = { 1, 2 } }
    assert(result.error, "bad proxy credentials succeeded")
    Store:set("weui_zlibrary_proxy_password", "qa-secret")
end)
check("socks-connect-refusal", function()
    local result = Api.makeHttpRequest{ url = "https://refused.invalid/failure", timeout = { 1, 2 } }
    assert(result.error, "SOCKS5 refusal bypassed")
end)
check("https-downgrade-blocked", function()
    local result = Api.makeHttpRequest{ url = base .. "/downgrade" }
    assert(result.error, "HTTPS downgrade accepted")
end)
check("invalid-config-fail-closed", function()
    Store:set("weui_zlibrary_proxy_url", "socks5://127.0.0.1:99999")
    local before = connections
    assert(Api.makeHttpRequest{ url = base .. "/invalid" }.error, "invalid proxy config succeeded")
    assert(connections == before, "invalid proxy config opened socket")
end)
check("unavailable-proxy-fail-closed", function()
    Store:set("weui_zlibrary_proxy_url", "socks5://127.0.0.1:" .. os.getenv("WEUI_PROXY_CLOSED_PORT"))
    assert(Api.makeHttpRequest{ url = base .. "/offline", timeout = { 1, 2 } }.error, "offline proxy succeeded")
end)
check("global-http-restored", function()
    assert(http.request == native_request and direct == 0, "direct fallback or un-restored global HTTP")
    Proxy.uninstall()
end)
methods.connect = connect
results:write("PASS\tsuite\tcases=", count, " proxy_connections=", connections, " direct_attempts=", direct, "\n")
results:close()

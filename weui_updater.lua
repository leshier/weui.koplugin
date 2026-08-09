-- weui_updater.lua — We UI OTA Updater
--
-- Two modes of operation:
--   1. Silent automatic check on startup (24 h throttle via G_reader_settings).
--      If an update is available, a banner appears at the top of the About menu.
--   2. Manual check triggered by the user ("Check for Updates" menu item).
--      Always hits the network, ignores the throttle.
--
-- Technical stack:
--   • socketutil with timeouts (avoids hangs on unstable networks)
--   • ltn12.sink.file for downloads (streams directly to disk, no ZIP in RAM)
--   • Native KOReader json.decode; regex fallback if unavailable
--   • Release notes shown before confirming install
--   • Trapper:dismissableRunInSubprocess (non-blocking UI, cancellable)
--   • State persisted in G_reader_settings (survives between sessions;
--     the "update available" banner appears immediately on next startup)

local UIManager   = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local ConfirmBox  = require("ui/widget/confirmbox")
local logger      = require("logger")
local _           = require("weui_i18n").translate

-- ---------------------------------------------------------------------------
-- Configuration
-- ---------------------------------------------------------------------------
local GITHUB_OWNER = "leshier"
local GITHUB_REPO  = "weui.koplugin"
local ASSET_NAME   = "weui.koplugin.zip"

local AUTO_CHECK_INTERVAL = 24 * 3600  -- seconds between automatic checks

-- G_reader_settings keys — prefixed with "weui_upd_" to avoid collisions.
local GS_LAST_CHECK = "weui_upd_last_check"  -- number (timestamp)
local GS_HAS_UPDATE = "weui_upd_has_update"  -- boolean
local GS_LATEST_VER = "weui_upd_latest_ver"  -- string without "v"
local GS_DL_URL     = "weui_upd_dl_url"      -- string URL
local GS_CUSTOM_API = "weui_upd_custom_api"  -- string custom API URL
local GS_USE_ZLIB_PROXY = "weui_upd_use_zlibrary_proxy" -- boolean

-- GitHub Release assets are noticeably less reliable than the lightweight
-- version probe on some networks.  KOReader's generic file limits (15/60 s)
-- are a little aggressive for a Kindle on a slow route, so updater downloads
-- get their own limits and one clean retry.  These values remain bounded so a
-- dead route can still be cancelled instead of hanging indefinitely.
local DOWNLOAD_BLOCK_TIMEOUT = 30
local DOWNLOAD_TOTAL_TIMEOUT = 180
local DOWNLOAD_ATTEMPTS = 2
local MAX_DOWNLOAD_REDIRECTS = 8
-- A version response is only a few kilobytes. Long per-host waits made a blocked GitHub host
-- hold the About page for minutes before any fallback was tried, so checks use a short bounded
-- attempt per source instead. Downloads retain their larger budgets below.
local CHECK_BLOCK_TIMEOUT = 10
local CHECK_TOTAL_TIMEOUT = 20
local CHECK_ATTEMPTS = 1

local _DEFAULT_API_URL = string.format(
    "https://api.github.com/repos/%s/%s/releases/latest",
    GITHUB_OWNER, GITHUB_REPO
)

-- raw _meta.lua on the default branch. The default check flow reads the
-- version from here instead of hitting api.github.com, whose anonymous
-- rate limit (60 req/h/IP) surfaces as HTTP 403 after just a few checks.
-- raw.githubusercontent.com is not subject to that API rate limit.
local _RAW_META_URL = string.format(
    "https://raw.githubusercontent.com/%s/%s/main/_meta.lua",
    GITHUB_OWNER, GITHUB_REPO
)

-- jsDelivr's package index lists immutable repository tags and is usually
-- reachable even when GitHub's API is not. Unlike the @latest alias it does
-- not depend on an edge cache having refreshed _meta.lua already.
local _JSDELIVR_PACKAGE_URL = string.format(
    "https://data.jsdelivr.com/v1/package/gh/%s/%s",
    GITHUB_OWNER, GITHUB_REPO
)

-- Mainland networks often reach api.github.com or a jsDelivr edge while raw.githubusercontent.com
-- and github.com time out. These are alternate delivery paths for this repository's public
-- metadata, not alternate update authorities: the package still comes from the tagged GitHub
-- release and its fixed asset name.
local _FASTLY_META_URL = string.format(
    "https://fastly.jsdelivr.net/gh/%s/%s@latest/_meta.lua",
    GITHUB_OWNER, GITHUB_REPO
)
local _JSDELIVR_META_URL = string.format(
    "https://cdn.jsdelivr.net/gh/%s/%s@latest/_meta.lua",
    GITHUB_OWNER, GITHUB_REPO
)

-- Resolve the effective API URL: custom if set, otherwise default.
local function _apiUrl()
    local ok_gs, gs = pcall(require, "luasettings")
    if ok_gs and gs and G_reader_settings then
        local custom = G_reader_settings:readSetting(GS_CUSTOM_API)
        if type(custom) == "string" and custom ~= "" then
            return custom
        end
    end
    return _DEFAULT_API_URL
end

-- ---------------------------------------------------------------------------
-- Internals
-- ---------------------------------------------------------------------------

local M = {}

-- In-memory cache for the current session.
-- Initialised lazily by _load_persisted_state().
local _state_loaded = false
local _has_update   = false
local _latest_ver   = nil  -- string without "v", or nil
local _dl_url       = nil  -- URL for the asset ZIP, or nil

-- Plugin directory — resolved once at module load time.
local _plugin_dir = (debug.getinfo(1, "S").source or ""):match("^@?(.+)/[^/]+$")
    or "/mnt/us/extensions/weui.koplugin"

-- ---------------------------------------------------------------------------
-- Helpers: version
-- ---------------------------------------------------------------------------

local function _currentVersion()
    -- Use dofile with the absolute path to guarantee we read *this* plugin's
    -- _meta.lua, not a stale cached entry from another plugin (require caches
    -- by module name, so require("_meta") may return the wrong table).
    local ok, meta = pcall(dofile, _plugin_dir .. "/_meta.lua")
    if ok and type(meta) == "table" and meta.version then return meta.version end
    local rok, rmeta = pcall(require, "_meta")
    if rok and type(rmeta) == "table" and rmeta.version then return rmeta.version end
    return "0.0.0"
end

-- Returns true if version `a` is strictly greater than `b`.
-- Supports "v1.2.3", "1.2.3", "1.2.3-beta1" (suffixes are ignored).
local function _versionGt(a, b)
    local function parts(v)
        v = (v or ""):match("^v?(.-)[-+]") or (v or ""):match("^v?(.+)$") or ""
        local t = {}
        for n in (v .. "."):gmatch("(%d+)%.") do t[#t + 1] = tonumber(n) or 0 end
        while #t < 3 do t[#t + 1] = 0 end
        return t
    end
    local pa, pb = parts(a), parts(b)
    for i = 1, 3 do
        if pa[i] > pb[i] then return true end
        if pa[i] < pb[i] then return false end
    end
    return false
end

local function _normaliseReleaseVersion(value)
    if type(value) ~= "string" then return nil end
    return value:match("^v?(%d+%.%d+%.%d+[%w%.%+%-]*)$")
end

local function _isValidAssetUrl(url)
    if type(url) ~= "string" then return false end
    local expected_prefix = string.format(
        "https://github.com/%s/%s/releases/download/",
        GITHUB_OWNER, GITHUB_REPO
    )
    if url:sub(1, #expected_prefix) ~= expected_prefix then return false end
    local suffix = url:sub(#expected_prefix + 1)
    local tag, asset = suffix:match("^([^/]+)/([^/]+)$")
    return tag ~= nil and tag ~= "" and asset == ASSET_NAME
end

-- ---------------------------------------------------------------------------
-- G_reader_settings accessor — guarded for use outside KOReader (e.g. tests)
-- ---------------------------------------------------------------------------

local function _gs()
    local ok, gs = pcall(function() return G_reader_settings end)
    return ok and gs or nil
end

-- Automatic fallback is deliberately narrower than the explicit updater-proxy switch. It is
-- available only when the user has enabled and configured the Z-Library proxy; merely having an
-- old proxy address stored is not permission to use it. The explicit switch continues to force
-- every update request through that proxy with no direct attempt.
local function _canAutoFallbackToProxy()
    local ok_store, Store = pcall(require, "weui_store")
    if not ok_store or not Store or type(Store.isTrue) ~= "function" then
        return false
    end
    local ok_enabled, enabled = pcall(Store.isTrue, Store, "weui_zlibrary_proxy_enabled")
    if not ok_enabled or not enabled then return false end
    local ok_proxy, Proxy = pcall(require, "weui_zlibrary_proxy")
    if not ok_proxy or not Proxy or type(Proxy._readConfig) ~= "function" then
        return false
    end
    local ok_config, config = pcall(Proxy._readConfig)
    return ok_config and type(config) == "table"
end

-- ---------------------------------------------------------------------------
-- Persistence
-- ---------------------------------------------------------------------------

local function _load_persisted_state()
    if _state_loaded then return end
    _state_loaded = true

    local gs = _gs()
    if not gs then return end

    _has_update = gs:readSetting(GS_HAS_UPDATE) == true
    local ver   = gs:readSetting(GS_LATEST_VER)
    _latest_ver = (type(ver) == "string" and ver ~= "") and ver or nil
    local url   = gs:readSetting(GS_DL_URL)
    _dl_url     = _isValidAssetUrl(url) and url or nil

    -- Discard stale state (e.g. update already installed).
    if _has_update and not _versionGt(_latest_ver or "", _currentVersion()) then
        _has_update = false
        _latest_ver = nil
        _dl_url     = nil
        gs:saveSetting(GS_HAS_UPDATE, false)
        gs:saveSetting(GS_LATEST_VER, "")
        gs:saveSetting(GS_DL_URL,     "")
        pcall(gs.flush, gs)
    end
end

local function _persist_state(now)
    local gs = _gs()
    if not gs then return end
    if now then gs:saveSetting(GS_LAST_CHECK, now) end
    gs:saveSetting(GS_HAS_UPDATE, _has_update)
    gs:saveSetting(GS_LATEST_VER, _latest_ver or "")
    gs:saveSetting(GS_DL_URL,     _dl_url     or "")
    pcall(gs.flush, gs)
end

local function _clear_update_state()
    _has_update = false
    _latest_ver = nil
    _dl_url     = nil
    local gs = _gs()
    if not gs then return end
    gs:saveSetting(GS_HAS_UPDATE, false)
    gs:saveSetting(GS_LATEST_VER, "")
    gs:saveSetting(GS_DL_URL,     "")
    pcall(gs.flush, gs)
end

-- ---------------------------------------------------------------------------
-- HTTP
-- ---------------------------------------------------------------------------

local function _httpGet(url, options)
    options = options or {}
    local ok_su, socketutil = pcall(require, "socketutil")
    local http   = require("socket/http")
    local ltn12  = require("ltn12")
    local gs = _gs()
    local use_proxy = options.use_proxy
    if use_proxy == nil then
        use_proxy = gs and gs:readSetting(GS_USE_ZLIB_PROXY) == true
    end

    local function requestOnce(request_url)
        local chunks = {}
        local request = {
            url     = request_url,
            method  = "GET",
            headers = {
                ["User-Agent"] = "KOReader-WeUI-Updater/2.2",
                ["Accept"]     = "application/vnd.github.v3+json",
            },
            sink     = ltn12.sink.table(chunks),
            -- In proxy mode every redirect is followed explicitly below so
            -- each hop receives a new CONNECT/SOCKS5 tunnel.
            redirect = not use_proxy,
        }

        if ok_su then
            socketutil:set_timeout(CHECK_BLOCK_TIMEOUT, CHECK_TOTAL_TIMEOUT)
        end

        local ok_request, first, code, headers, status
        if use_proxy then
            local ok_proxy, Proxy = pcall(require, "weui_zlibrary_proxy")
            if not ok_proxy or not Proxy
                    or type(Proxy._proxyHttpRequest) ~= "function"
                    or type(Proxy._readConfig) ~= "function" then
                if ok_su then socketutil:reset_timeout() end
                return nil, nil, _("Z-Library proxy transport is unavailable."), nil
            end
            local cfg, cfg_err = Proxy._readConfig()
            if not cfg then
                if ok_su then socketutil:reset_timeout() end
                return nil, nil, tostring(cfg_err), nil
            end
            ok_request, first, code, headers, status = pcall(
                Proxy._proxyHttpRequest, request, cfg, http.request
            )
        else
            ok_request, first, code, headers, status = pcall(http.request, request)
        end

        if ok_su then socketutil:reset_timeout() end
        if not ok_request then
            return nil, nil, "network error (" .. tostring(first) .. ")", nil
        end
        return code, headers, status or first, chunks
    end

    local function performAttempt()
        local request_url = url
        for _redirect_count = 0, MAX_DOWNLOAD_REDIRECTS do
            local code, headers, status, chunks = requestOnce(request_url)
            if code == 200 then return table.concat(chunks or {}) end

            if use_proxy and tonumber(code) and tonumber(code) >= 300
                    and tonumber(code) < 400 and type(headers) == "table" then
                local location = headers.location or headers.Location
                if type(location) ~= "string" or location == "" then
                    return nil, "redirect without location"
                end
                local ok_url, socket_url = pcall(require, "socket.url")
                request_url = ok_url and socket_url.absolute(request_url, location) or location
                if request_url:sub(1, 8) ~= "https://" then
                    return nil, "refused non-HTTPS redirect"
                end
            else
                if ok_su and (
                    code == socketutil.TIMEOUT_CODE or
                    code == socketutil.SSL_HANDSHAKE_CODE or
                    code == socketutil.SINK_TIMEOUT_CODE
                ) then
                    return nil, "timeout (" .. tostring(code) .. ")"
                end
                if headers == nil then
                    return nil, "network error (" .. tostring(code or status) .. ")"
                end
                return nil, string.format("HTTP %s", tostring(code))
            end
        end
        return nil, "too many redirects"
    end

    local last_err
    local attempts = math.max(1, tonumber(options.attempts) or CHECK_ATTEMPTS)
    for attempt = 1, attempts do
        local body, err = performAttempt()
        if body then return body end
        last_err = err
        logger.warn(string.format("weui updater: check attempt %d/%d failed: %s",
            attempt, attempts, tostring(err)))
    end
    return nil, last_err or "update check failed"
end

local function _httpGetToFile(url, dest_path)
    local ok_su, socketutil = pcall(require, "socketutil")
    local http   = require("socket/http")
    local ltn12  = require("ltn12")
    local socket = require("socket")

    local gs = _gs()
    local force_proxy = gs and gs:readSetting(GS_USE_ZLIB_PROXY) == true

    local function requestOnce(request_url, follow_redirects)
        local fh, err_open = io.open(dest_path, "wb")
        if not fh then return nil, nil, "cannot create file: " .. tostring(err_open) end

        if ok_su then
            socketutil:set_timeout(DOWNLOAD_BLOCK_TIMEOUT, DOWNLOAD_TOTAL_TIMEOUT)
        end

        local request = {
            url      = request_url,
            method   = "GET",
            headers  = { ["User-Agent"] = "KOReader-WeUI-Updater/2.1" },
            sink     = ltn12.sink.file(fh), -- stream directly to disk
            redirect = follow_redirects,
        }
        local ok_request, first, code, headers, status = pcall(http.request, request)
        pcall(fh.close, fh) -- proxy redirect bodies intentionally do not close the sink
        if ok_su then socketutil:reset_timeout() end

        if not ok_request then
            return nil, nil, "network error (" .. tostring(first) .. ")"
        end
        -- Match socket.skip(1, http.request(...)) without losing errors from
        -- the protected call above.
        return code, headers, status or first
    end

    local function requestViaProxy(request_url)
        local ok_proxy, Proxy = pcall(require, "weui_zlibrary_proxy")
        if not ok_proxy or not Proxy or type(Proxy._proxyHttpRequest) ~= "function" then
            return nil, nil, _("Z-Library proxy transport is unavailable.")
        end
        local cfg, cfg_err = Proxy._readConfig()
        if not cfg then return nil, nil, tostring(cfg_err) end

        local fh, err_open = io.open(dest_path, "wb")
        if not fh then return nil, nil, "cannot create file: " .. tostring(err_open) end
        if ok_su then
            socketutil:set_timeout(DOWNLOAD_BLOCK_TIMEOUT, DOWNLOAD_TOTAL_TIMEOUT)
        end
        local request = {
            url      = request_url,
            method   = "GET",
            headers  = { ["User-Agent"] = "KOReader-WeUI-Updater/2.1" },
            sink     = ltn12.sink.file(fh),
            redirect = false,
        }
        local ok_request, first, code, headers, status = pcall(
            Proxy._proxyHttpRequest, request, cfg, http.request
        )
        pcall(fh.close, fh)
        if ok_su then socketutil:reset_timeout() end
        if not ok_request then
            return nil, nil, "network error (" .. tostring(first) .. ")"
        end
        return code, headers, status or first
    end

    local function performAttempt(use_proxy)
        local request_url = url
        for redirect_count = 0, MAX_DOWNLOAD_REDIRECTS do
            local code, headers, status
            if use_proxy then
                code, headers, status = requestViaProxy(request_url)
            else
                -- LuaSocket safely handles the complete GitHub redirect chain
                -- for direct downloads.
                code, headers, status = requestOnce(request_url, true)
            end

            if code == 200 then return true end
            if use_proxy and tonumber(code) and tonumber(code) >= 300
                    and tonumber(code) < 400 and type(headers) == "table" then
                local location = headers.location or headers.Location
                if type(location) == "string" and location ~= "" then
                    local ok_url, socket_url = pcall(require, "socket.url")
                    request_url = ok_url and socket_url.absolute(request_url, location) or location
                    if request_url:sub(1, 8) ~= "https://" then
                        return nil, "refused non-HTTPS redirect"
                    end
                    pcall(os.remove, dest_path)
                else
                    return nil, "redirect without location"
                end
            else
                if ok_su and (
                    code == socketutil.TIMEOUT_CODE or
                    code == socketutil.SSL_HANDSHAKE_CODE or
                    code == socketutil.SINK_TIMEOUT_CODE
                ) then
                    return nil, "timeout (" .. tostring(code) .. ")"
                end
                if headers == nil then
                    return nil, "network error (" .. tostring(code or status) .. ")"
                end
                return nil, string.format("HTTP %s", tostring(code))
            end
        end
        return nil, "too many redirects"
    end

    local transports = force_proxy and { true } or { false }
    if not force_proxy and _canAutoFallbackToProxy() then
        transports[#transports + 1] = true
    end

    local last_err
    for _, use_proxy in ipairs(transports) do
        local transport_name = use_proxy and "proxy" or "direct"
        for attempt = 1, DOWNLOAD_ATTEMPTS do
            pcall(os.remove, dest_path)
            local ok, err = performAttempt(use_proxy)
            if ok then
                logger.info("weui updater: package downloaded via " .. transport_name)
                return true
            end
            last_err = err
            logger.warn(string.format(
                "weui updater: %s download attempt %d/%d failed: %s",
                transport_name, attempt, DOWNLOAD_ATTEMPTS, tostring(err)))
        end
    end
    pcall(os.remove, dest_path)
    return nil, last_err or "download failed"
end

-- ---------------------------------------------------------------------------
-- GitHub API response parsing
-- ---------------------------------------------------------------------------

-- Parse the version field out of a raw _meta.lua body.
-- _meta.lua contains:  version = "1.0.1"
local function _parseMetaVersion(body)
    return _normaliseReleaseVersion(
        tostring(body):match('version%s*=%s*"([^"]+)"')
    )
end

local function _parseJsdelivrVersion(body)
    local ok_j, json = pcall(require, "json")
    if ok_j then
        local ok_d, data = pcall(json.decode, body)
        if ok_d and type(data) == "table" and type(data.versions) == "table" then
            local version = data.versions[1]
            version = _normaliseReleaseVersion(version)
            if version then return version end
        end
    end
    return _normaliseReleaseVersion(
        tostring(body):match('"versions"%s*:%s*%[%s*"([^"]+)"')
    )
end

-- Construct the release asset download URL for a given version.
-- Tag scheme is v<version> (see .github/workflows/release.yml), so the
-- asset lives at .../releases/download/v<version>/<ASSET_NAME>.
local function _assetUrlForVersion(ver)
    return string.format(
        "https://github.com/%s/%s/releases/download/v%s/%s",
        GITHUB_OWNER, GITHUB_REPO, ver, ASSET_NAME
    )
end

local function _parseRelease(body)
    local ok_j, json = pcall(require, "json")

    if not ok_j then
        -- Regex fallback for KOReader builds that lack the json module.
        logger.warn("weui updater: json module unavailable, using regex fallback")
        local function jsonStr(key)
            return body:match('"' .. key .. '"%s*:%s*"([^"]*)"')
        end
        local tag = jsonStr("tag_name")
        if not tag then return nil, "could not parse tag_name" end
        local asset_pat = '"browser_download_url"%s*:%s*"([^"]*'
            .. ASSET_NAME:gsub("%.", "%%.") .. '[^"]*)"'
        local download_url = body:match(asset_pat)
        local notes = body:match('"body"%s*:%s*"(.-)"%s*[,}]')
        if notes then
            notes = notes:gsub("\\n", "\n"):gsub("\\r", "")
                        :gsub('\\"', '"'):gsub("\\\\", "\\")
        end
        return {
            version      = _normaliseReleaseVersion(tag),
            download_url = download_url,
            notes        = (notes and notes ~= "") and notes or nil,
        }
    end

    local ok_d, data = pcall(json.decode, body)
    if not ok_d or type(data) ~= "table" then
        return nil, "JSON parse error: " .. tostring(data)
    end

    local tag = data.tag_name
    if not tag then return nil, "tag_name missing from API response" end
    local version = _normaliseReleaseVersion(tag)
    if not version then return nil, "invalid release version" end

    local download_url
    for _, asset in ipairs(data.assets or {}) do
        if asset.name == ASSET_NAME then
            download_url = asset.browser_download_url
            break
        end
    end

    local notes = data.body
    if notes and notes ~= "" then
        notes = notes:gsub("#+%s*", "")           -- headings markdown
        notes = notes:gsub("%*%*(.-)%*%*", "%1")  -- bold **
        notes = notes:gsub("`(.-)`", "%1")         -- code inline
        notes = notes:gsub("\r\n", "\n"):gsub("\r", "\n")
        if #notes > 600 then notes = notes:sub(1, 597) .. "..." end
        notes = notes:match("^%s*(.-)%s*$")        -- trim
    end

    return {
        version      = version,
        download_url = download_url,
        notes        = (notes and notes ~= "") and notes or nil,
        html_url     = data.html_url,
    }
end

-- ---------------------------------------------------------------------------
-- Unzip
-- ---------------------------------------------------------------------------

local function _isSafeArchiveEntry(path, mode)
    if type(path) ~= "string" or path == "" then
        return false, "archive contains an empty path"
    end
    if path:find("%z") or path:find("\\", 1, true)
            or path:sub(1, 1) == "/" or path:match("^%a:") then
        return false, "archive contains an invalid path"
    end
    local plugin_root = "weui.koplugin"
    if path ~= plugin_root and path:sub(1, #plugin_root + 1) ~= plugin_root .. "/" then
        return false, "archive contains files outside weui.koplugin"
    end
    for segment in path:gmatch("[^/]+") do
        if segment == "." or segment == ".." then
            return false, "archive contains a traversal path"
        end
    end
    if mode ~= "file" and mode ~= "directory" then
        return false, "archive contains unsupported entry type: " .. tostring(mode)
    end
    return true
end

M._isSafeArchiveEntry = _isSafeArchiveEntry

local function _unzip(zip_path, dest_dir)
    -- KOReader bundles libarchive on every supported platform. Keeping update
    -- extraction inside that implementation avoids shelling out to a binary
    -- that Kindles do not provide and lets us reject unsafe archive entries
    -- before any file is written.
    local ok_arch, Archiver = pcall(require, "ffi/archiver")
    if not (ok_arch and Archiver and Archiver.Reader) then
        return nil, "KOReader archive support is unavailable"
    end

    local ok_util, util = pcall(require, "util")
    if ok_util and util and util.makePath then util.makePath(dest_dir) end

    local arc = Archiver.Reader:new()
    local ok = arc:open(zip_path)
    local extract_err
    if ok then
        local required = {}
        for entry in arc:iterate() do
            local safe, reason = _isSafeArchiveEntry(entry.path, entry.mode)
            if not safe then
                ok = false
                extract_err = reason
                break
            end
            required[entry.path] = true
        end
        if ok and not (required["weui.koplugin/main.lua"]
                and required["weui.koplugin/_meta.lua"]
                and required["weui.koplugin/zlibrary/embedded_plugin.lua"]) then
            ok = false
            extract_err = "archive is missing required plugin files"
        end
        -- Validate the complete archive before writing the first file. iterate()
        -- resets the reader after the validation pass.
        if ok then
            for entry in arc:iterate() do
                if not arc:extractToPath(entry.path, dest_dir .. "/" .. entry.path) then
                    ok = false
                    extract_err = arc.err or "archive extraction failed"
                    break
                end
            end
        end
        if arc.err then ok = false end
    end
    local err = extract_err or arc.err
    arc:close()
    if ok then return true end
    return nil, tostring(err or "could not open update archive")
end

-- ---------------------------------------------------------------------------
-- Temporary path for the update ZIP
-- ---------------------------------------------------------------------------

local function _tmpZipPath()
    -- Candidate paths in preference order.
    -- Each is probed with "wb" (binary write) — the same mode used by the
    -- actual download — so a successful probe guarantees the download will
    -- also succeed.  Using "w" (text) for the probe masked failures on some
    -- devices where text-mode open succeeded but binary-mode open did not.
    local candidates = {}

    local ok, DS = pcall(require, "datastorage")
    if ok and DS then
        local dir = DS:getSettingsDir()
        if dir then candidates[#candidates + 1] = dir .. "/weui_update.zip" end
    end
    candidates[#candidates + 1] = "/tmp/weui_update.zip"
    candidates[#candidates + 1] = _plugin_dir .. "/weui_update.zip"

    for _, path in ipairs(candidates) do
        local fh = io.open(path, "wb")
        if fh then fh:close(); os.remove(path); return path end
    end

    -- Last-resort fallback: return the plugin dir path even without a
    -- successful probe (the download will fail with a clear error if it
    -- really is not writable, rather than returning nil here).
    return _plugin_dir .. "/weui_update.zip"
end

-- ---------------------------------------------------------------------------
-- UI helpers
-- ---------------------------------------------------------------------------

local function _toast(msg, timeout)
    local w = InfoMessage:new{ text = msg, timeout = timeout or 4 }
    UIManager:show(w)
    return w
end

local function _closeWidget(w)
    if w then UIManager:close(w) end
end

-- ---------------------------------------------------------------------------
-- Pure fetch — intended to run inside a subprocess
-- ---------------------------------------------------------------------------

local function _doFetch()
    local api_url = _apiUrl()
    local custom_source = api_url ~= _DEFAULT_API_URL
    local sources = custom_source and {
        { label = "custom", url = api_url, kind = "release" },
    } or {
        -- The Releases API is authoritative and supplies notes plus the exact asset URL. A 403
        -- (anonymous rate limit) is cheap to detect and immediately falls through to the CDNs.
        { label = "github-api", url = _DEFAULT_API_URL, kind = "release" },
        { label = "jsdelivr-package", url = _JSDELIVR_PACKAGE_URL, kind = "versions" },
        { label = "fastly-jsdelivr", url = _FASTLY_META_URL, kind = "meta" },
        { label = "jsdelivr", url = _JSDELIVR_META_URL, kind = "meta" },
    }

    local gs = _gs()
    local force_proxy = gs and gs:readSetting(GS_USE_ZLIB_PROXY) == true
    local transports = force_proxy and { true } or { false }
    if not force_proxy and _canAutoFallbackToProxy() then
        transports[#transports + 1] = true
    end

    local errors = {}
    for _, use_proxy in ipairs(transports) do
        local transport_name = use_proxy and "proxy" or "direct"
        for _, source in ipairs(sources) do
            local body, err = _httpGet(source.url, { use_proxy = use_proxy, attempts = 1 })
            if body then
                if source.kind == "release" then
                    local release, parse_err = _parseRelease(body)
                    if release and release.version then
                        logger.info("weui updater: version source " .. source.label
                            .. " via " .. transport_name)
                        return release
                    end
                    err = "parse error: " .. tostring(parse_err)
                else
                    local ver = source.kind == "versions"
                        and _parseJsdelivrVersion(body) or _parseMetaVersion(body)
                    if ver then
                        logger.info("weui updater: version source " .. source.label
                            .. " via " .. transport_name)
                        return {
                            version      = ver,
                            download_url = _assetUrlForVersion(ver),
                            notes        = nil,
                            html_url     = string.format(
                                "https://github.com/%s/%s/releases/tag/v%s",
                                GITHUB_OWNER, GITHUB_REPO, ver),
                        }
                    end
                    err = "version missing from " .. source.kind
                end
            end
            errors[#errors + 1] = source.label .. "/" .. transport_name
                .. ": " .. tostring(err or "unknown error")
        end

        -- raw.githubusercontent.com is useful through a configured proxy, but it is omitted from
        -- direct mode because on affected mainland networks it consumes the whole timeout without
        -- returning a status. Trying it here gives proxy users an independent final source.
        if use_proxy and not custom_source then
            local body, err = _httpGet(_RAW_META_URL, { use_proxy = true, attempts = 1 })
            local ver = body and _parseMetaVersion(body) or nil
            if ver then
                logger.info("weui updater: version source github-raw via proxy")
                return {
                    version      = ver,
                    download_url = _assetUrlForVersion(ver),
                    notes        = nil,
                    html_url     = string.format(
                        "https://github.com/%s/%s/releases/tag/v%s",
                        GITHUB_OWNER, GITHUB_REPO, ver),
                }
            end
            errors[#errors + 1] = "github-raw/proxy: "
                .. tostring(err or "version missing from metadata")
        end
    end

    logger.warn("weui updater: all version sources failed: " .. table.concat(errors, "; "))
    return { error = _("All update sources failed. Please check the network or proxy settings.") }
end

-- ---------------------------------------------------------------------------
-- Download and installation
-- ---------------------------------------------------------------------------

local function _applyUpdate(download_url, new_version)
    local tmp_zip    = _tmpZipPath()
    local parent_dir = _plugin_dir:match("^(.+)/[^/]+$") or _plugin_dir

    local progress_msg = _toast(
        string.format(_("Downloading We UI %s…"), new_version), 360
    )

    local ok_tr, Trapper = pcall(require, "ui/trapper")

    local function doDownloadAndInstall()
        local dl_ok, dl_err = _httpGetToFile(download_url, tmp_zip)
        if not dl_ok then
            return { success = false, stage = "download", err = dl_err }
        end
        local uz_ok, uz_err = _unzip(tmp_zip, parent_dir)
        os.remove(tmp_zip)
        if not uz_ok then
            return { success = false, stage = "unzip", err = uz_err }
        end
        return { success = true }
    end

    local function handleInstallResult(result)
        _closeWidget(progress_msg)
        if not result or not result.success then
            local stage = result and result.stage or "unknown"
            local err   = result and result.err   or "unknown error"
            logger.err("weui updater: failed in", stage, "-", err)
            _toast(
                stage == "download"
                    and (_("Download error: ") .. tostring(err))
                    or  (_("Extraction error: ") .. tostring(err))
            )
            return
        end
        _clear_update_state()
        UIManager:show(ConfirmBox:new{
            text        = string.format(
                _("We UI %s installed.\n\nRestart KOReader to apply the update?"),
                new_version
            ),
            ok_text     = _("Restart"),
            cancel_text = _("Later"),
            ok_callback = function() UIManager:restartKOReader() end,
        })
    end

    if ok_tr and Trapper and Trapper.dismissableRunInSubprocess then
        -- We run from a menu/ConfirmBox callback (no Trapper:wrap), so
        -- dismissableRunInSubprocess falls back to a blocking in-process run.
        -- The 3rd arg is task_returns_simple_string (bool), not a callback;
        -- the result is handled via the return value below. Paint the toast
        -- before the blocking network call so the user sees "Downloading…".
        UIManager:forceRePaint()
        local completed, result = Trapper:dismissableRunInSubprocess(
            doDownloadAndInstall,
            progress_msg
        )
        if completed and result then
            UIManager:scheduleIn(0.2, function() handleInstallResult(result) end)
        elseif completed == false then
            _closeWidget(progress_msg)
            pcall(os.remove, tmp_zip)
            _toast(_("Update cancelled."))
        end
    else
        -- Synchronous fallback (no Trapper): avoids blocking the UI via scheduleIn.
        UIManager:scheduleIn(0.3, function()
            handleInstallResult(doDownloadAndInstall())
        end)
    end
end

-- ---------------------------------------------------------------------------
-- Confirmation dialog with release notes
-- ---------------------------------------------------------------------------

local function _showUpdateDialog(release, current)
    local latest       = release.version
    local download_url = _isValidAssetUrl(release.download_url) and release.download_url or nil
    local notes        = release.notes

    if not _versionGt(latest, current) then
        logger.info("weui updater: already up to date (" .. current .. ")")
        _toast(string.format(_("We UI is up to date (%s)."), current))
        return
    end

    logger.info("weui updater: new version available:", latest)

    local header     = string.format(_("We UI %s is available!\nYou have %s."), latest, current)
    local notes_block = notes and ("\n\n" .. _("What's new:") .. "\n" .. notes) or ""

    if not download_url then
        UIManager:show(ConfirmBox:new{
            text        = header .. notes_block
                       .. "\n\n" .. _("No download file found.\n\nOpen the releases page?"),
            ok_text     = _("Open in browser"),
            cancel_text = _("Cancel"),
            ok_callback = function()
                local Device = require("device")
                if Device:canOpenLink() then
                    Device:openLink(string.format(
                        "https://github.com/%s/%s/releases/latest",
                        GITHUB_OWNER, GITHUB_REPO
                    ))
                end
            end,
        })
        return
    end

    UIManager:show(ConfirmBox:new{
        text        = header .. notes_block .. "\n\n" .. _("Download and install now?"),
        ok_text     = _("Download and install"),
        cancel_text = _("Cancel"),
        ok_callback = function() _applyUpdate(download_url, latest) end,
    })
end

-- ---------------------------------------------------------------------------
-- Network check with result persistence
-- ---------------------------------------------------------------------------

local function _doNetworkCheck()
    local release = _doFetch()
    if release.error then
        logger.warn("weui updater: check error:", release.error)
        return false, release.error
    end

    local current = _currentVersion()
    _latest_ver   = release.version
    _dl_url       = _isValidAssetUrl(release.download_url) and release.download_url or nil
    _has_update   = _versionGt(_latest_ver, current)

    logger.info(string.format(
        "weui updater: current=%s latest=%s has_update=%s",
        current, _latest_ver or "?", tostring(_has_update)
    ))

    _persist_state(os.time())
    return true, release
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

--- Returns true when a newer version has been detected.
--- Uses the in-memory cache (no I/O after the first call).
function M.hasUpdate()
    _load_persisted_state()
    return _has_update
end

--- Returns the latest detected version string (without "v" prefix), or nil.
function M.latestVersion()
    _load_persisted_state()
    return _latest_ver
end

--- Silent automatic check — called once on plugin startup.
---
--- • Always loads persisted state so hasUpdate() is correct immediately.
--- • Only hits the network if more than AUTO_CHECK_INTERVAL seconds have
---   elapsed since the last successful check.
--- • Never shows any UI — the result is written to G_reader_settings;
---   the banner is built by build_update_banner_item() when the menu opens.
function M.scheduleAutoCheck()
    -- Opt-in only: skip silently if the user has not enabled auto-check.
    -- SUISettings:isTrue() returns false for missing keys → disabled by default.
    local ok_s, SUISettings = pcall(require, "weui_settings")
    if not ok_s or not SUISettings then return end
    if not SUISettings:isTrue("weui_updater_auto_check") then
        logger.dbg("weui updater: auto-check disabled — skipping")
        return
    end

    _load_persisted_state()

    local gs   = _gs()
    local now  = os.time()
    local last = (gs and gs:readSetting(GS_LAST_CHECK)) or 0
    if type(last) ~= "number" then last = 0 end

    if (now - last) < AUTO_CHECK_INTERVAL then
        logger.dbg("weui updater: auto-check within throttle — skip")
        return
    end

    -- Network call: runs 5 s after startup to avoid delaying the first paint.
    -- IMPORTANT: for the silent auto-check we must NEVER prompt the user to
    -- connect Wi-Fi. runWhenOnline calls beforeWifiAction when offline, which
    -- shows a dialog or turns Wi-Fi on automatically — both are unacceptable
    -- for a background check the user did not explicitly trigger.
    -- Instead: only proceed if the network is already online. If it is not,
    -- skip silently. The 24-hour throttle ensures we try again on the next
    -- startup where the device happens to be connected already.
    UIManager:scheduleIn(5, function()
        local ok_nm, NetworkMgr = pcall(require, "ui/network/manager")
        local already_online = ok_nm and NetworkMgr
            and (NetworkMgr.isOnline and NetworkMgr:isOnline()
                or (NetworkMgr.isConnected and NetworkMgr:isConnected()))
        if not already_online then
            logger.dbg("weui updater: auto-check skip — network not online")
            return
        end
        _doNetworkCheck()
    end)

end

--- Manual check — triggered by the "Check for Updates" menu item.
--- Always hits the network (ignores throttle) and shows UI with the result.
function M.checkForUpdates()
    local current = _currentVersion()
    local ok_nm, NetworkMgr = pcall(require, "ui/network/manager")
    -- Do not use runWhenOnline() here. KOReader's isOnline() performs an
    -- external connectivity probe which may be unreachable on otherwise
    -- healthy networks (notably on Kindles used in mainland China). In that
    -- case runWhenOnline() asks the user to enable Wi-Fi again and, when the
    -- device already has an IP address, never invokes our callback at all.
    --
    -- The updater only needs a connected interface. The actual GitHub request
    -- below is the authoritative reachability check and reports its own error.
    if ok_nm and NetworkMgr and NetworkMgr.runWhenConnected then
        NetworkMgr:runWhenConnected(function()
            M._doManualCheck(current)
        end)
        return
    end
    M._doManualCheck(current)
end

--- Internal logic for the manual check (kept separate to keep checkForUpdates
--- clean and to allow direct calls in tests).
function M._doManualCheck(current)
    local ok_tr, Trapper = pcall(require, "ui/trapper")
    local checking_msg   = _toast(_("Checking for updates…"), 15)

    local function handleCheckResult(release)
        _closeWidget(checking_msg)
        if not release then
            _toast(_("Error checking for updates."))
            return
        end
        if release.error then
            logger.err("weui updater:", release.error)
            _toast(_("Error checking for updates: ") .. tostring(release.error))
            return
        end
        -- Persist the result so the next startup can show the banner
        -- without needing a network request.
        _latest_ver = release.version
        _dl_url     = _isValidAssetUrl(release.download_url) and release.download_url or nil
        _has_update = _versionGt(_latest_ver, current)
        _persist_state(os.time())

        _showUpdateDialog(release, current)
    end

    if ok_tr and Trapper and Trapper.dismissableRunInSubprocess then
        -- See _applyUpdate: blocking in-process fallback (no Trapper:wrap).
        -- Paint "Checking for updates…" before the blocking call.
        UIManager:forceRePaint()
        local completed, result = Trapper:dismissableRunInSubprocess(
            _doFetch,
            checking_msg
        )
        if completed and result then
            UIManager:scheduleIn(0.2, function() handleCheckResult(result) end)
        elseif completed == false then
            _closeWidget(checking_msg)
            _toast(_("Update check cancelled."))
        end
    else
        UIManager:scheduleIn(0.3, function()
            handleCheckResult(_doFetch())
        end)
    end
end

--- Returns a menu item when an update is available; nil otherwise.
--- Called when building the About menu — uses in-memory cache (zero I/O).
function M.build_update_banner_item()
    _load_persisted_state()
    if not _has_update then return nil end
    local label = _latest_ver and ("v" .. _latest_ver) or _("latest")
    return {
        text           = string.format(_("⬆ Update available: %s"), label),
        keep_menu_open = true,
        callback       = function()
            M.checkForUpdates()
        end,
    }
end

-- ---------------------------------------------------------------------------
-- Custom update source URL
-- ---------------------------------------------------------------------------

function M.getCustomApiUrl()
    if not G_reader_settings then return "" end
    local v = G_reader_settings:readSetting(GS_CUSTOM_API)
    return type(v) == "string" and v or ""
end

function M.setCustomApiUrl(url)
    if not G_reader_settings then return end
    if type(url) ~= "string" or url == "" then
        G_reader_settings:delSetting(GS_CUSTOM_API)
    else
        G_reader_settings:saveSetting(GS_CUSTOM_API, url)
    end
    -- Invalidate cached state so next check uses new URL.
    _state_loaded = false
end

function M.getUseZlibraryProxy()
    local gs = _gs()
    return gs and gs:readSetting(GS_USE_ZLIB_PROXY) == true or false
end

function M.setUseZlibraryProxy(enabled)
    local gs = _gs()
    if not gs then return end
    gs:saveSetting(GS_USE_ZLIB_PROXY, enabled == true)
    pcall(gs.flush, gs)
end

-- Deterministic download harness entry point. Production callers use
-- _applyUpdate(); exposing this avoids real network traffic in regression
-- tests while exercising retries, redirects, proxy selection and cleanup.
M._httpGet = _httpGet
M._httpGetToFile = _httpGetToFile
M._currentVersion = _currentVersion
M._doFetch = _doFetch
M._isValidAssetUrl = _isValidAssetUrl

return M

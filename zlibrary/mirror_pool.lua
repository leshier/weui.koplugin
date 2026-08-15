-- Session-scoped health and bounded failover for Z-Library API mirrors.
--
-- The configured base URL remains the user's preferred address. A successful
-- failover is pinned through Config's short-lived runtime base instead of
-- overwriting that preference, so the next request benefits while a restart
-- or cache expiry naturally gives the preferred address another chance.

local socket_url = require("socket.url")
local Config = require("zlibrary.config")
local logger = require("logger")

local M = {}

M.MAX_FAILOVERS = 2

local health = {}

local COOLDOWN_SECONDS = {
    challenge = 6 * 3600,
    dns = 60 * 60,
    redirect = 60 * 60,
    invalid_response = 30 * 60,
    server = 10 * 60,
    timeout = 5 * 60,
    transport = 5 * 60,
}

local function now(value)
    return tonumber(value) or os.time()
end

local function origin(url)
    if type(url) ~= "string" or url == "" then return nil end
    local parsed = socket_url.parse(url)
    if not (parsed and parsed.scheme and parsed.host) then return nil end
    local scheme = parsed.scheme:lower()
    if scheme ~= "https" and scheme ~= "http" then return nil end
    return socket_url.build({
        scheme = scheme,
        host = parsed.host:lower(),
        port = parsed.port,
    }):gsub("/$", "")
end

M.origin = origin

function M.rewriteUrl(url, new_base)
    local parsed = type(url) == "string" and socket_url.parse(url) or nil
    local base = origin(new_base)
    local parsed_base = base and socket_url.parse(base) or nil
    if not (parsed and parsed_base) then return nil end
    return socket_url.build({
        scheme = parsed_base.scheme,
        host = parsed_base.host,
        port = parsed_base.port,
        path = parsed.path,
        params = parsed.params,
        query = parsed.query,
        fragment = parsed.fragment,
    })
end

function M.recordFailure(url, reason, at)
    local key = origin(url)
    if not key then return end
    local timestamp = now(at)
    local item = health[key] or {}
    item.consecutive_failures = math.min(8, (tonumber(item.consecutive_failures) or 0) + 1)
    item.last_failure = timestamp
    item.last_reason = reason or "transport"
    local base_cooldown = COOLDOWN_SECONDS[item.last_reason] or COOLDOWN_SECONDS.transport
    local multiplier = math.min(4, 2 ^ (item.consecutive_failures - 1))
    item.cooldown_until = timestamp + base_cooldown * multiplier
    health[key] = item
end

function M.recordSuccess(url, elapsed, at)
    local key = origin(url)
    if not key then return end
    local item = health[key] or {}
    item.consecutive_failures = 0
    item.cooldown_until = 0
    item.last_reason = nil
    item.last_success = now(at)
    item.elapsed = tonumber(elapsed) or item.elapsed
    health[key] = item
end

local function collectCandidates(current_url, attempted, at)
    local current = origin(current_url)
    local timestamp = now(at)
    local seen, candidates = {}, {}
    if current then seen[current] = true end
    for key in pairs(attempted or {}) do
        local normalized = origin(key) or key
        seen[normalized] = true
    end

    local function add(raw, priority)
        local key = origin(type(raw) == "table" and raw.url or raw)
        if not key or seen[key] then return end
        seen[key] = true
        local item = health[key] or {}
        if (tonumber(item.cooldown_until) or 0) > timestamp then return end
        candidates[#candidates + 1] = {
            url = key,
            priority = priority,
            success = tonumber(item.last_success) or 0,
            failures = tonumber(item.consecutive_failures) or 0,
            elapsed = tonumber(item.elapsed) or math.huge,
        }
    end

    -- The user's configured address is always the first address reconsidered
    -- after a temporary runtime mirror fails.
    add(Config.getBaseUrl(true), 0)
    for index, item in ipairs(Config.getSeedUrls() or {}) do
        add(item, index)
    end

    table.sort(candidates, function(a, b)
        local a_worked, b_worked = a.success > 0, b.success > 0
        if a_worked ~= b_worked then return a_worked end
        if a.failures ~= b.failures then return a.failures < b.failures end
        if a.elapsed ~= b.elapsed then return a.elapsed < b.elapsed end
        if a.success ~= b.success then return a.success > b.success end
        return a.priority < b.priority
    end)
    return candidates
end

function M.failover(current_url, attempted, reason, at)
    attempted = attempted or {}
    local current = origin(current_url)
    if current then
        attempted[current] = true
        M.recordFailure(current, reason, at)
    end

    local candidate = collectCandidates(current_url, attempted, at)[1]
    if not candidate then return nil end
    attempted[candidate.url] = true

    local rewritten = M.rewriteUrl(current_url, candidate.url)
    if not rewritten then return nil end
    local ok = Config.setRuntimeBaseUrl(candidate.url)
    if not ok then return nil end

    logger.info(string.format(
        "Zlibrary mirror pool: switching %s -> %s (%s)",
        tostring(current or "?"), candidate.url, tostring(reason or "transport")))
    return rewritten, candidate.url
end

function M.exportState()
    local copy = {}
    for key, item in pairs(health) do
        copy[key] = {
            consecutive_failures = tonumber(item.consecutive_failures) or 0,
            cooldown_until = tonumber(item.cooldown_until) or 0,
            last_failure = tonumber(item.last_failure),
            last_success = tonumber(item.last_success),
            last_reason = type(item.last_reason) == "string" and item.last_reason or nil,
            elapsed = tonumber(item.elapsed),
        }
    end
    return copy
end

function M.importState(state)
    if type(state) ~= "table" then return end
    for key, item in pairs(state) do
        local normalized = origin(key)
        if normalized and type(item) == "table" then
            health[normalized] = {
                consecutive_failures = math.max(0, tonumber(item.consecutive_failures) or 0),
                cooldown_until = math.max(0, tonumber(item.cooldown_until) or 0),
                last_failure = tonumber(item.last_failure),
                last_success = tonumber(item.last_success),
                last_reason = type(item.last_reason) == "string" and item.last_reason or nil,
                elapsed = tonumber(item.elapsed),
            }
        end
    end
end

function M.exportTransportState()
    return {
        -- Only export a base explicitly selected in this process. Falling
        -- back to the inherited cache could re-pin a mirror that this child
        -- just proved unavailable but was forbidden to remove from disk.
        active_base = Config.getRuntimeBaseUrl(true),
        health = M.exportState(),
    }
end

function M.applyTransportState(state)
    if type(state) ~= "table" then return end
    M.importState(state.health)
    if state.active_base then Config.setRuntimeBaseUrl(state.active_base) end
end

function M.reset()
    health = {}
end

return M

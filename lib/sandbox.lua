-- lib/sandbox.lua — We UI
-- Lua sandbox for user-script modules (B4 自定义主屏模块).
--
-- Runs user-supplied Lua chunks in a restricted environment built from a
-- whitelist.  The chunk has no access to io/os.execute/os.remove/debug/
-- loadfile/dofile of arbitrary paths, or the global _G / _ENV table of
-- the host.  It can return a module descriptor table (matching the
-- moduleregistry contract) or a function that builds one.
--
-- Pure logic — no UI / KOReader dependency, fully unit-testable.

local M = {}

-- ---------------------------------------------------------------------------
-- Whitelisted global identifiers.
-- Everything NOT on this list is absent from the sandbox environment.
-- ---------------------------------------------------------------------------
-- Safe entries from the `os` table.
local SAFE_OS_KEYS = {
    "date", "time", "difftime", "clock", "setlocale",
    "getenv",   -- read-only env access; low risk
}

-- ---------------------------------------------------------------------------
-- M.load_safe(code, [env_overrides]) → ok, result_or_err
--
-- Compiles `code` as a Lua chunk, sandboxes it, and runs it.
--
-- On success:  returns true, <chunk return value>
-- On failure:  returns false, <error message string>
--
-- env_overrides: optional table of extra values to inject into the
--   sandbox environment (e.g. a custom `require` that resolves only
--   approved modules, or helper libraries).  Keys in this table
--   override any defaults from the whitelist.
-- ---------------------------------------------------------------------------
function M.load_safe(code, env_overrides)
    if type(code) ~= "string" then
        return false, "sandbox: code must be a string"
    end

    -- Build the sandbox environment.
    local env = {}

    -- ── basic library ──────────────────────────────────────────────────────
    local basic_keys = {
        assert = assert, error = error, ipairs = ipairs, pairs = pairs,
        pcall = pcall, xpcall = xpcall, select = select,
        tonumber = tonumber, tostring = tostring, type = type,
        unpack = table.unpack or unpack,
        next = next, rawequal = rawequal, rawget = rawget, rawset = rawset,
        setmetatable = setmetatable, getmetatable = getmetatable,
        print = function(...)
            -- Sandboxed print — sends to logger.dbg if available, else no-op.
            -- Prevents the user script from writing stdout.
            local ok, logger_mod = pcall(require, "logger")
            if ok and logger_mod and logger_mod.dbg then
                logger_mod.dbg("weui: user-script:", ...)
            end
        end,
    }
    for k, v in pairs(basic_keys) do env[k] = v end

    -- ── string / table / math / utf8 / bit ────────────────────────────────
    if type(string) == "table" then
        local safe_str = {}
        for k, v in pairs(string) do safe_str[k] = v end
        env.string = safe_str
    end
    if type(table) == "table" then
        local safe_tbl = {}
        for k, v in pairs(table) do safe_tbl[k] = v end
        env.table = safe_tbl
    end
    if type(math) == "table" then
        local safe_math = {}
        for k, v in pairs(math) do safe_math[k] = v end
        env.math = safe_math
    end
    if type(utf8) == "table" then
        local safe_u8 = {}
        for k, v in pairs(utf8) do safe_u8[k] = v end
        env.utf8 = safe_u8
    end
    if type(bit) == "table" then
        local safe_bit = {}
        for k, v in pairs(bit) do safe_bit[k] = v end
        env.bit = safe_bit
    end
    if type(bit32) == "table" then
        local safe_b32 = {}
        for k, v in pairs(bit32) do safe_b32[k] = v end
        env.bit32 = safe_b32
    end

    -- ── os (only safe keys) ───────────────────────────────────────────────
    if type(os) == "table" then
        local safe_os = {}
        for _, k in ipairs(SAFE_OS_KEYS) do
            if os[k] ~= nil then safe_os[k] = os[k] end
        end
        env.os = safe_os
    end

    -- ── coroutine (safe — no escape from Lua state) ───────────────────────
    if type(coroutine) == "table" then
        local safe_co = {}
        for k, v in pairs(coroutine) do safe_co[k] = v end
        env.coroutine = safe_co
    end

    -- ── Self-reference for modules that want to access their own env. ─────
    -- We give them `_ENV` pointing to their own sandbox table — NOT the
    -- real global _G.
    env._ENV = env
    env._G   = env   -- some old code expects _G

    -- ── Custom `require` — only allows pre-approved modules. ──────────────
    -- By default, require is absent from the sandbox.  Callers can inject
    -- their own via env_overrides.require if they want to expose specific
    -- modules (e.g. weui_i18n, weui_config).

    -- ── Apply overrides AFTER building defaults. ──────────────────────────
    if type(env_overrides) == "table" then
        for k, v in pairs(env_overrides) do
            env[k] = v
        end
    end

    -- ── Compile ───────────────────────────────────────────────────────────
    local chunk, err
    if setfenv then
        -- Lua 5.1 / LuaJIT
        chunk, err = loadstring(code)
        if not chunk then return false, "sandbox: compile error: " .. tostring(err) end
        setfenv(chunk, env)
    elseif load then
        -- Lua 5.2+
        chunk, err = load(code, "user-script", "t", env)
        if not chunk then return false, "sandbox: compile error: " .. tostring(err) end
    else
        return false, "sandbox: no load function available"
    end

    -- ── Run ───────────────────────────────────────────────────────────────
    local ok, result = pcall(chunk)
    if not ok then
        return false, "sandbox: runtime error: " .. tostring(result)
    end
    return true, result
end

-- ---------------------------------------------------------------------------
-- M.load_file(path, [env_overrides]) → ok, result_or_err
--
-- Reads a file from disk and sandbox-loads it.  The caller is responsible
-- for validating that `path` points to an allowed location (this function
-- does not enforce path restrictions — it just reads the file).
-- ---------------------------------------------------------------------------
function M.load_file(path, env_overrides)
    if type(path) ~= "string" then
        return false, "sandbox: path must be a string"
    end
    local f, err = io.open(path, "r")
    if not f then
        return false, "sandbox: cannot open '" .. tostring(path) .. "': " .. tostring(err)
    end
    local code = f:read("*a")
    f:close()
    return M.load_safe(code, env_overrides)
end

return M

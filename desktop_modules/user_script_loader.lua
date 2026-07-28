-- desktop_modules/user_script_loader.lua - We UI
-- Discovers and loads user-supplied Lua module scripts from the
-- settings directory, sandboxing each one before registering it with
-- moduleregistry so it appears on the homescreen alongside built-ins.
--
-- SECURITY MODEL
-- ==============
-- User scripts live in:
--   <settings_dir>/weui/user_modules/*.lua
-- They are loaded with lib/sandbox.lua, which strips io / os.execute /
-- os.remove / os.exit / debug / loadfile / dofile / arbitrary require.
-- The sandbox exposes a CURATED require proxy that resolves ONLY the
-- modules on SAFE_REQUIRE_WHITELIST - mostly KOReader UI widgets and
-- weui helpers that a module legitimately needs to render.  Anything
-- else (e.g. "ffi", "ffi.load", "os.execute") is unavailable.
--
-- A script may return:
--   • a single module descriptor table  { id=, name=, build=, getHeight=, ... }
--   • a table with sub_modules = { <descriptor>, ... }  (multiple modules)
--   • a function() -> descriptor   (factory, called once)
-- Descriptors must have a string `id` (unique, prefixed "user_" for safety)
-- and a `build(w, ctx)` function; getHeight/getMenuItems are optional.
--
-- This loader is invoked once at plugin init (see main.lua).  It is
-- deliberately NOT lazy - discovery happens up front so a broken user
-- script logs its error immediately rather than surprising the user
-- mid-render.

local logger   = require("logger")
local Sandbox  = require("lib.sandbox")
local Registry = require("desktop_modules/moduleregistry")
local I18n     = require("weui_i18n")
local _        = I18n.translate

local M = {}

-- Directory name under <settings>/weui/ that holds user scripts.
local USER_MODULES_SUBDIR = "user_modules"

-- Prefix applied to every user-script module id.  This guarantees user
-- modules can never collide with a built-in id (e.g. "clock") and makes
-- them easy to identify in the Arrange menu.
local ID_PREFIX = "user_"

-- ---------------------------------------------------------------------------
-- SAFE_REQUIRE_WHITELIST
--
-- Modules a user script may require.  Anything not on this list is refused.
-- Kept deliberately conservative: KOReader UI widgets, geometry, fonts,
-- blitbuffer, datetime, and the weui helper modules.  No ffi, no io, no
-- datastorage, no luasettings, no os.
-- ---------------------------------------------------------------------------
local SAFE_REQUIRE_WHITELIST = {
    -- KOReader UI widgets
    ["ui/widget/textwidget"]        = true,
    ["ui/widget/textboxwidget"]     = true,
    ["ui/widget/button"]            = true,
    ["ui/widget/infomessage"]       = true,
    ["ui/widget/verticalgroup"]     = true,
    ["ui/widget/horizontalgroup"]   = true,
    ["ui/widget/verticalspan"]      = true,
    ["ui/widget/horizontalspan"]    = true,
    ["ui/widget/linewidget"]        = true,
    ["ui/widget/iconwidget"]        = true,
    ["ui/widget/imagewidget"]       = true,
    ["ui/widget/progresswidget"]    = true,
    ["ui/widget/framecontainer"]    = true,
    ["ui/widget/container/centercontainer"] = true,
    ["ui/widget/container/leftcontainer"]   = true,
    ["ui/widget/container/rightcontainer"]  = true,
    ["ui/widget/container/topcontainer"]    = true,
    ["ui/widget/container/bottomcontainer"] = true,
    ["ui/widget/container/framecontainer"]  = true,
    ["ui/widget/container/widgetcontainer"] = true,
    ["ui/widget/container/margincontainer"] = true,
    ["ui/widget/container/inputcontainer"]  = true,
    ["ui/geometry"]                 = true,
    ["ui/font"]                     = true,
    ["ui/uimanager"]                = true,
    ["ui/scale"]                    = true,
    ["ffi/blitbuffer"]              = true,
    ["datetime"]                    = true,
    ["device"]                      = true,
    ["logger"]                      = true,
    ["util"]                        = true,
    ["gettext"]                     = true,
    -- weui helpers
    ["weui_i18n"]                   = true,
    ["weui_config"]                 = true,
    ["weui_core"]                   = true,
    ["weui_store"]                  = true,
    ["weui_style"]                  = true,
}

-- Build a `require` closure that honours the whitelist.
local function _makeSafeRequire()
    return function(modname)
        if not SAFE_REQUIRE_WHITELIST[modname] then
            error("sandbox: require('" .. tostring(modname)
                .. "') is not allowed in user scripts", 2)
        end
        return require(modname)
    end
end

-- ---------------------------------------------------------------------------
-- _resolveUserDir() -> string | nil
--
-- Returns the absolute path to <settings>/weui/user_modules/, creating
-- it if missing.  Returns nil (and logs) if the settings dir cannot be
-- resolved - in which case user scripts are simply not loaded.
-- ---------------------------------------------------------------------------
local function _resolveUserDir()
    local ok_ds, DataStorage = pcall(require, "datastorage")
    if not ok_ds or not DataStorage then
        logger.warn("weui: user_script_loader: DataStorage unavailable")
        return nil
    end
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if not ok_lfs or not lfs then
        -- lfs is also exposed as a global in KOReader.
        lfs = lfs or _G.lfs
    end
    if not lfs then
        logger.warn("weui: user_script_loader: lfs unavailable")
        return nil
    end
    local dir = DataStorage:getSettingsDir() .. "/weui/" .. USER_MODULES_SUBDIR
    if lfs.attributes(dir, "mode") ~= "directory" then
        lfs.mkdir(dir)
    end
    if lfs.attributes(dir, "mode") ~= "directory" then
        logger.warn("weui: user_script_loader: cannot create", dir)
        return nil
    end
    return dir
end

-- ---------------------------------------------------------------------------
-- _validateDescriptor(d, source) -> bool
--
-- Checks that `d` is a usable module descriptor: a table with a string
-- `id` and a `build` function.  Mutates `id` to carry the user_ prefix
-- and stamps `d._user_script = true` so the homescreen can flag it.
-- ---------------------------------------------------------------------------
local function _validateDescriptor(d, source)
    if type(d) ~= "table" then
        logger.warn("weui: user_script_loader: " .. source .. " did not return a table")
        return false
    end
    if type(d.id) ~= "string" or d.id == "" then
        logger.warn("weui: user_script_loader: " .. source .. " descriptor has no string id")
        return false
    end
    if type(d.build) ~= "function" then
        logger.warn("weui: user_script_loader: " .. source .. " ('" .. d.id .. "') has no build() function")
        return false
    end
    -- Force the user_ prefix (strip any existing prefix to avoid user_user_).
    local bare = d.id
    if bare:sub(1, ID_PREFIX:len()) == ID_PREFIX then
        bare = bare:sub(ID_PREFIX:len() + 1)
    end
    -- Keep only safe id characters: alnum + underscore.
    bare = bare:gsub("[^%w_]", "_")
    if bare == "" then bare = "mod" end
    d.id = ID_PREFIX .. bare
    -- Stamp so other code can detect user-script modules.
    d._user_script = true
    if type(d.name) ~= "string" or d.name == "" then
        d.name = d.id
    end
    -- User modules default to off until the user explicitly enables them,
    -- to avoid surprising auto-enable of untrusted code.
    if d.default_on == nil then d.default_on = false end
    return true
end

-- ---------------------------------------------------------------------------
-- _absorbResult(result, source, into)
--
-- Normalises the raw return value of a sandboxed script into a list of
-- validated descriptors, appending them to `into`.
-- ---------------------------------------------------------------------------
local function _absorbResult(result, source, into)
    -- Factory function: call it once.
    if type(result) == "function" then
        local ok, r = pcall(result)
        if not ok then
            logger.warn("weui: user_script_loader: " .. source .. " factory() error: " .. tostring(r))
            return
        end
        result = r
    end
    -- sub_modules: multiple descriptors from one script.
    if type(result) == "table" and type(result.sub_modules) == "table" then
        for _, d in ipairs(result.sub_modules) do
            if _validateDescriptor(d, source) then
                into[#into + 1] = d
            end
        end
        return
    end
    -- Single descriptor.
    if _validateDescriptor(result, source) then
        into[#into + 1] = result
    end
end

-- ---------------------------------------------------------------------------
-- M.loadAll()
--
-- Discover every *.lua under <settings>/weui/user_modules/, sandbox-load
-- each, validate, and register with moduleregistry.  Idempotent: calling
-- twice re-registers (replacing by id).  Safe to call when the directory
-- is empty or missing - just no-ops.
-- ---------------------------------------------------------------------------
function M.loadAll()
    local dir = _resolveUserDir()
    if not dir then return 0 end

    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if not ok_lfs or not lfs then lfs = _G.lfs end
    if not lfs then return 0 end

    local descriptors = {}
    local count = 0
    for fname in lfs.dir(dir) do
        -- Only .lua files; skip dotfiles and the sample.
        if fname:sub(-4) == ".lua" and fname:sub(1, 1) ~= "." then
            local path = dir .. "/" .. fname
            if lfs.attributes(path, "mode") == "file" then
                local env_overrides = {
                    require = _makeSafeRequire(),
                    _       = _,                 -- translation helper
                    I18n    = I18n,
                }
                local ok, result = Sandbox.load_file(path, env_overrides)
                if not ok then
                    logger.warn("weui: user_script_loader: failed to load '"
                        .. fname .. "': " .. tostring(result))
                else
                    local before = #descriptors
                    _absorbResult(result, fname, descriptors)
                    local added = #descriptors - before
                    if added > 0 then
                        count = count + added
                        logger.info("weui: user_script_loader: loaded '"
                            .. fname .. "' (" .. added .. " module(s))")
                    else
                        logger.warn("weui: user_script_loader: '" .. fname
                            .. "' produced no valid descriptors")
                    end
                end
            end
        end
    end

    -- Register each descriptor.  Registry.register dedups by id and
    -- invalidates the cache so the next homescreen render picks them up.
    for _, d in ipairs(descriptors) do
        Registry.register(d)
    end

    if count > 0 then
        logger.info("weui: user_script_loader: registered " .. count .. " user module(s)")
    end
    return count
end

-- ---------------------------------------------------------------------------
-- M.userModulesDir() -> string | nil
--
-- Returns the absolute path to the user modules directory (creating it if
-- missing).  Exposed so settings UI can show / open the folder.
-- ---------------------------------------------------------------------------
function M.userModulesDir()
    return _resolveUserDir()
end

-- ---------------------------------------------------------------------------
-- M.sampleScript() -> string
--
-- Returns the text of a sample user module that users can copy into the
-- directory as a starting point.  Kept inline so there is no extra file
-- to ship.
-- ---------------------------------------------------------------------------
function M.sampleScript()
    return [[-- A sample WeUI user module.
-- Copy this file into the user_modules directory and edit it.
-- The module must return a table with at least `id` and `build`.
--
-- Available globals inside the sandbox:
--   _          translation helper (weui_i18n)
--   require()  KOReader UI widgets + weui helpers (whitelisted only)
--   math, string, table, os.date, os.time  (safe stdlib subset)
--
-- Blocked:  io, os.execute, os.remove, debug, loadfile, dofile, ffi.

local TextWidget = require("ui/widget/textwidget")
local CenterContainer = require("ui/widget/container/centercontainer")
local Font = require("ui/font")
local Screen = require("device").screen

local M = {}
M.id   = "hello"
M.name = "Hello (user)"
M.label = "My first user module"

function M.build(w, ctx)
    -- ctx.pfx is the settings prefix for this homescreen page.
    local text = TextWidget:new{
        text = "Hello from a user script!",
        face = Font:getFace("cfont", 22),
        fgcolor = Screen.bb and require("ffi/blitbuffer").COLOR_BLACK or nil,
    }
    return CenterContainer:new{
        dimen = ctx and ctx.dimen or Screen:getSize(),
        text,
    }
end

function M.getHeight(ctx)
    return Screen:scaleBySize(60)
end

function M.getMenuItems(ctx_menu)
    -- Return nil to hide the settings sub-menu, or return a table of
    -- Config items (see weui_config.lua) to customise this module.
    return nil
end

return M
]]
end

return M

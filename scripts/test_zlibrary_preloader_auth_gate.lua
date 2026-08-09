-- Account-only background warmers must remain silent on public Z-Library pages.

local network_calls = 0
local pushed_tasks = 0
local has_credentials = false

package.preload["logger"] = function()
    return { info = function() end, warn = function() end, err = function() end, dbg = function() end }
end
package.preload["ui/renderimage"] = function() return {} end
package.preload["ui/network/manager"] = function()
    return { isConnected = function() network_calls = network_calls + 1; return true end }
end
package.preload["util"] = function() return {} end
package.preload["zlibrary.api"] = function()
    return {
        isAuthenticationError = function() return false end,
        getDownloadQuotaStatus = function() error("must not run") end,
        getFavoriteBookIds = function() error("must not run") end,
        getRecommendedBooks = function() error("must not run") end,
    }
end
package.preload["zlibrary.cache"] = function()
    return { new = function()
        return { get = function() return nil end, insert = function() end }
    end }
end
local runtime_cache = { get = function() return nil end, insert = function() end }
local multi_cache = { get = function() return nil end, insert = function() end }
package.preload["zlibrary.config"] = function()
    return {
        hasCredentials = function() return has_credentials end,
        getConfigRuntimeCache = function() return runtime_cache end,
        getMultiSearchCache = function() return multi_cache end,
        getUserSession = function() return nil end,
        getSetting = function() return nil end,
    }
end
package.preload["zlibrary.async_helper"] = function()
    return { createChannel = function()
        return { pushTask = function() pushed_tasks = pushed_tasks + 1 end }
    end }
end

package.path = "./?.lua;" .. package.path
local Preloader = require("zlibrary.preloader").Preloader

local callbacks = {}
Preloader.getDownloadQuotaStatus(function(ok) callbacks[#callbacks + 1] = ok end)
Preloader.getFavoriteBookIds(function(ok) callbacks[#callbacks + 1] = ok end)
Preloader.getRecommendedBooks(function(ok) callbacks[#callbacks + 1] = ok end)

assert(#callbacks == 3)
assert(callbacks[1] == false and callbacks[2] == false and callbacks[3] == false)
assert(network_calls == 0, "no-credential warmers must not query network state")
assert(pushed_tasks == 0, "no-credential warmers must not enqueue network work")

has_credentials = true
Preloader.getDownloadQuotaStatus()
Preloader.getFavoriteBookIds()
Preloader.getRecommendedBooks()
assert(network_calls == 3)
assert(pushed_tasks == 3)

print("ZLIBRARY_PRELOADER_AUTH_GATE_OK")

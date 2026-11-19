-- UI callbacks stay in the parent; only buffered HTTP runs in a subprocess.
local Trapper = require("ui/trapper")
local contexts = setmetatable({}, { __mode = "k" })
local M = {}

local function current()
    local co = coroutine.running()
    return co and contexts[co]
end

function M.cancelled()
    local ctx = current()
    return ctx and (ctx.cancelled or ctx.origin and (ctx.origin._closed
        or require("weui_paper")._instance ~= ctx.origin or ctx.origin.view ~= ctx.view))
end

function M.run(plugin, callback, origin, view, on_error)
    Trapper:wrap(function()
        local co = coroutine.running()
        local ctx = { plugin = plugin, origin = origin, view = view }
        contexts[co] = ctx
        local ok, err = xpcall(callback, debug.traceback)
        if not ok and not M.cancelled() then on_error(err) end
        if M.cancelled() then plugin:closeBusy() end
        contexts[co] = nil
    end)
end

function M.request(client, options, request)
    local ctx = current()
    -- Streaming sinks carry caller-owned state and are handled by the native
    -- download worker. Do not fork those closures.
    if not ctx or options and options.sink then return request(client, options) end
    if M.cancelled() then error("request_cancelled", 0) end
    local opts = {}
    for key, value in pairs(options or {}) do opts[key] = value end
    opts.persist_response_cookies = false
    if type(opts.timeout) == "number" then
        opts.timeout = { opts.timeout, opts.timeout }
    elseif not opts.timeout then
        opts.timeout = { 10, 20 }
    end
    local busy = ctx.plugin.busy_message
    local dismiss = busy and busy.dismiss_callback
    local completed, ok, response, code, headers, status = Trapper:dismissableRunInSubprocess(function()
        return pcall(request, client, opts)
    end, busy)
    if busy then busy.dismiss_callback = dismiss end
    if not completed or M.cancelled() then
        ctx.cancelled = true
        if busy and ctx.plugin.busy_message == busy then ctx.plugin.busy_message = nil end
        error("request_cancelled", 0)
    end
    if not ok then error(response or "network_worker_failed", 0) end
    -- Persist new cookies in the parent only, and only for their origin.
    local host = tostring(opts.url or ""):match("^https?://([^/:]+)")
    if not client.settings.mock_endpoint and not opts.skip_cookie
        and (host == "weread.qq.com" or host == "i.weread.qq.com")
        and (not options or options.persist_response_cookies ~= false) then
        for key, value in pairs(headers or {}) do
            if tostring(key):lower() == "set-cookie" then client.settings:merge_set_cookie(value) end
        end
    end
    return response, code, headers, status
end

return M

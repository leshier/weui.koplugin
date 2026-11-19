-- Exercise slow storage and slow HTTP in the real native event loop.
return function(ctx)
    local UIManager = require("ui/uimanager")
    local socket = require("socket")
    local Library = require("weui_library")
    local Config = require("weui_config")
    local Paper, plugin = ctx.Paper, ctx.plugin
    local function metric(name, value)
        local file = assert(io.open(ctx.root .. "/artifacts/responsiveness.tsv", "a"))
        file:write(name, "\t", string.format("%.1f", value), "\n"); file:close()
    end
    ctx.add("106ra-slow-library-storage", function()
        local lfs = require("libs/libkoreader-lfs")
        local original = lfs.attributes
        Library.invalidate()
        lfs.attributes = function(path, ...)
            if type(path) == "string" and path:find(ctx.root, 1, true) then
                require("ffi/util").usleep(5000)
            end
            return original(path, ...)
        end
        local started = socket.gettime()
        local ok, result = pcall(Library.books, plugin, false, true)
        local elapsed = (socket.gettime() - started) * 1000
        metric("slow-storage-call-ms", elapsed)
        if not ok or elapsed >= 150 then lfs.attributes = original end
        assert(ok, result)
        assert(elapsed < 150, "slow storage blocked UI for " .. elapsed .. "ms")
        local heartbeat
        UIManager:scheduleIn(0.2, function()
            heartbeat = (socket.gettime() - started) * 1000
            metric("slow-storage-input-ms", heartbeat)
        end)
        return function()
            if Library.isScanning() or not heartbeat then return false end
            lfs.attributes = original
            assert(heartbeat < 450, "background scan blocked native input")
            return true
        end
    end)
    ctx.add("106rba-cancel-slow-http", function()
        local wr = plugin._weread_plugin
        local http = require("socket.http")
        local original, original_online = http.request, wr.isNetworkOnline
        local finished, returned
        wr.isNetworkOnline = function() return true end
        http.request = function()
            require("ffi/util").usleep(3000000)
            return 1, 200, {}, "HTTP/1.1 200 OK"
        end
        wr:showBusy("取消慢请求测试")
        local busy = wr.busy_message
        wr:runOnlineTask("cancel-http-qa", function()
            local ok = pcall(wr.client.request, wr.client, { url = "https://weread.qq.com/qa" })
            returned, finished = ok, true
        end)
        UIManager:scheduleIn(0.25, function() busy:onTapClose() end)
        local started = socket.gettime()
        return function()
            if not finished then return false end
            http.request, wr.isNetworkOnline = original, original_online
            assert(not returned and not wr.busy_message, "cancelled request returned a stale response")
            assert(socket.gettime() - started < 1.5, "cancel waited for slow server")
            return true
        end
    end)
    ctx.add("106raa-runtime-root-skipped", function()
        local lfs = require("libs/libkoreader-lfs")
        local runtime = require("ffi/util").realpath(lfs.currentdir())
        local original, old_home = lfs.dir, G_reader_settings:readSetting("home_dir")
        local calls = 0
        lfs.dir = function(path)
            if require("ffi/util").realpath(path) == runtime then calls = calls + 1; error("runtime enumeration") end
            return original(path)
        end
        G_reader_settings:saveSetting("home_dir", runtime)
        local ok, err = pcall(Library.books, plugin, true)
        G_reader_settings:saveSetting("home_dir", old_home)
        lfs.dir = original
        Library.invalidate()
        assert(ok, err)
        assert(calls == 0, "KOReader runtime was treated as the book library")
    end)
    ctx.add("106rb-slow-http-input", function()
        local wr = plugin._weread_plugin
        local http = require("socket.http")
        local original, original_online = http.request, wr.isNetworkOnline
        local completed, heartbeat
        wr.isNetworkOnline = function() return true end
        http.request = function()
            require("ffi/util").usleep(800000)
            return 1, 200, {}, "HTTP/1.1 200 OK"
        end
        local started = socket.gettime()
        wr:runOnlineTask("slow-http-qa", function()
            wr.client:request{ url = "https://weread.qq.com/qa" }
            completed = true
        end)
        UIManager:scheduleIn(0.2, function()
            heartbeat = (socket.gettime() - started) * 1000
            metric("slow-http-input-ms", heartbeat)
        end)
        return function()
            if not completed or not heartbeat then return false end
            http.request, wr.isNetworkOnline = original, original_online
            assert(heartbeat < 450, "slow HTTP blocked input for " .. heartbeat .. "ms")
            return true
        end
    end)
    ctx.add("106rc-cover-worker-failure", function()
        local original = Config.getBookInfoManager
        local calls = 0
        Config.getBookInfoManager = function()
            return {
                isExtractingInBackground = function() return false end,
                extractInBackground = function() calls = calls + 1; return false end,
            }
        end
        local path = ctx.root .. "/library/山海小记.txt"
        Config._cover_extract_pending[path] = true
        Config._cover_extract_specs[path] = {}
        Config._cover_extract_queue = { path }
        local launched = Config.flushCoverQueue()
        Config.getBookInfoManager = original
        assert(calls == 1 and launched == false and not Config._cover_extract_pending[path],
            "failed cover worker retained pending work")
    end)
    ctx.add("106rd-native-action-icons", function()
        local page = Paper.navigate(plugin, "home")
        local function icon(path)
            for _, item in ipairs(page.items) do
                if item.widget and item.widget.file == path then return true end
            end
        end
        assert(icon(Config.ICON.group) and icon(Config.ICON.weui_import), "shelf action icons missing")
        local wr = plugin._weread_plugin
        wr:showShelfGrid(1, "books"); page = Paper._instance
        assert(icon(Config.ICON.zlibrary_refresh) and icon(Config.ICON.weread_filter)
            and icon(Config.ICON.weread_sort), "WeRead action icons missing")
        wr:showMainMenu()
        local sheet = ctx.topWidget()
        assert(#sheet.view.items <= 7, "legacy total menu exposed on paper shelf")
        for _, entry in ipairs(sheet.entries) do
            assert(entry.icon_path, "menu row lost its icon: " .. entry.label)
        end
        ctx.geometry(sheet)
        UIManager:forceRePaint()
        require("device").screen:shot(ctx.root .. "/artifacts/106rd-weread-menu-icons.png")
        sheet:dismiss()
    end)
end

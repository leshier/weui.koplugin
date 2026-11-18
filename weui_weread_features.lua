-- Host adapters for finlater/weread.koplugin 1.7.0. Keep WeUI navigation,
-- task history and additional note/review APIs; reuse its reader services.
local UIManager = require("ui/uimanager")
local Content = require("weread.lib.content")
local Library = require("weread.ui.library")
local UpstreamMenu = require("weread.ui.menu")
local M = {}

function M.init(self)
    math.randomseed(os.time())
    self.settings = require("weread.lib.settings"):new()
    self.client = require("lib.weread_client"):new(self.settings)
    self.external_annotations_db = require("weread.lib.external_annotations_db"):new(self.settings)
    self.library_db = require("weread.lib.library_db"):new(self.settings)
    self.prefetch_worker = require("weread.lib.background_worker"):new{
        temp_dir = self.settings.data_dir .. "/workers", min_available_kb = 64 * 1024,
    }
    self.downloader = require("lib.weread_downloader"):new{
        settings = self.settings, client = self.client, background_worker = self.prefetch_worker,
        show_info = function(text) self:showInfo(text) end,
        show_transient = function(text, timeout) self:showTransientInfo(text, timeout) end,
        refresh_ui = function() self:refreshUI() end,
        refresh_shelf = function() self:refreshShelfCacheIndicators() end,
        open_file = function(path) self:openFile(path) end,
        safe_callback = function(label, fn) return self:safeCallback(label, fn) end,
        require_login = function(cookie, api) return self:requireLogin(cookie, api) end,
        run_online_task = function(label, fn) return self:runOnlineTask(label, fn, nil, true) end,
        is_connected = function() return self:isNetworkConnected() end,
        show_task = function(task) return self:showPaperDownloadTask(task) end,
        task_updated = function(task)
            local page = require("weui_paper").weReadOrigin(self)
            if page and page.view and page.view.task == task then page:rebuild() end
        end,
    }
    require("weread.lib.migrations").run(self.settings, self.client)
    self.external_annotations_db:migrateLegacySettings()
    self.downloader:recover()
    self.qr_login = require("weread.lib.qr_login"):new(self, self.client, self.settings)
    self.read_report = require("weread.lib.read_report"):new{
        settings = self.settings, client = self.client, library_db = self.library_db, scheduler = UIManager,
        get_document = function() return self.ui and self.ui.document end,
        detect_book = function() return self:detectWeReadBook() end,
        position_provider = function(id)
            if not self.progress_sync then return nil, "progress_sync_initializing", true end
            return self.progress_sync:position_for_report(id)
        end,
        is_online = function() return self:isNetworkConnected() end,
    }
    self.progress_sync = require("weread.lib.progress_sync"):new{
        settings = self.settings, client = self.client, scheduler = UIManager,
        get_document = function() return self.ui and self.ui.document end,
        get_footer = function() return self.ui and self.ui.view and self.ui.view.footer end,
        detect_book = function() return self:detectWeReadBook() end,
        get_book = function(id) return self.settings:get("books", {})[tostring(id)] end,
        get_chapters = function(book) return self:ensureChaptersLoaded(book) end,
        refresh_catalog = function(id)
            local book = self.settings:get("books", {})[tostring(id)]
            if not book then return nil, "book_not_found" end
            Content.ensure_reader_state(self.client, book)
            local chapters = Content.fetch_catalog(self.client, book)
            Content.save_catalog_cache(self.client, self.settings, book, chapters)
            self.library_db:putChapters(id, chapters)
            return chapters
        end,
        get_file_context = function(book, path) return self:getChapterInfoFromFile(book, path) end,
        run_online = function(_, fn, options) return self:runOnlineTask("同步进度", fn, nil, options) end,
        upload_position = function(id, position, seconds) return self.read_report:upload_position(id, position, seconds) end,
        goto_fraction = function(fraction) return self:gotoReaderPercent(fraction * 100) end,
        open_chapter = function(book, chapter) return self:openProgressTargetChapter(book, chapter) end,
        is_online = function() return self:isNetworkConnected() end,
        on_choice = require("weread.ui.progress_sync_dialog").show_choice,
        notify = require("weread.ui.progress_sync_dialog").notify,
    }
    self._reader_session_gen = 0
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
    local report = self.settings:get("read_report")
    if report.enabled and report.mode == "manual" and report.book_id ~= "" and report.report_on_open == false then
        self.read_report:maybe_start("plugin_start")
    end
end

function M.attach(Plugin)
    for _, name in ipairs({
        "weread.ui.annotations_controller", "weread.ui.xpointer_overlay_controller",
        "weread.ui.annotation_sync_controller", "weread.ui.reader_navigation", "weread.lib.reader_lifecycle",
    }) do
        for key, fn in pairs(require(name)) do Plugin[key] = fn end
    end
    local prepare_annotations = Plugin._prepareAnnotationContext
    function Plugin:_prepareAnnotationContext(...)
        local context = prepare_annotations(self, ...)
        if context and not context.store:get(context.book_id, "meta", "catalog") then
            -- Automatic EPUB descriptors can supply a catalog without a cloud
            -- request. Persist the full cached catalog so a later local-file
            -- binding can reuse the same sources while offline.
            local book = context.book
            if book and not book.chapters then Content.load_catalog_cache(self.client, self.settings, book) end
            local catalog = book and book.chapters
            if type(catalog) == "table" and #catalog > 0 then
                context.store:put(context.book_id, "meta", "catalog", catalog)
            end
        end
        return context
    end
    for _, name in ipairs({
        "applyShelfSnapshot", "loadChapters", "openChapter", "openProgressTargetChapter",
        "openBookForReading", "downloadChapterAndRead",
    }) do Plugin[name] = Library[name] end
    Plugin.isNetworkConnected = require("weread.ui.common").isNetworkConnected
    for _, name in ipairs({ "getReadReportMenuItems", "getReportIntervalMenuItems", "onShowWeReadReportStatus" }) do
        Plugin[name] = require("weread.ui.read_report")[name]
    end
    local old_register = Plugin.onDispatcherRegisterActions
    function Plugin:onDispatcherRegisterActions()
        old_register(self); UpstreamMenu.onDispatcherRegisterActions(self)
    end
    for _, name in ipairs({
        "getMockMenuItems", "showThoughtPopupHeightPicker", "showThoughtPopupFontSizePicker",
        "showThoughtPopupContrastPicker", "showThoughtPopupPositionPicker",
        "showThoughtPopupWidthPicker", "showEdgeTapRatioPicker",
    }) do Plugin[name] = UpstreamMenu[name] end
    function Plugin:getSettingsMenuItems()
        local items = UpstreamMenu.getSettingsMenuItems(self)
        -- Retain WeUI's additional reporting controls and its own updater.
        items[#items] = { text = "阅读时长上报", sub_item_table_func = function() return self:getReadReportMenuItems() end }
        items[#items + 1] = { text = "划线和想法管理", sub_item_table_func = function() return self:getUnifiedAnnotationMenuItems() end }
        return items
    end
    local old_menu = Plugin.getMenuItems
    function Plugin:getMenuItems()
        local items = old_menu(self)
        local tr = require("weread.lib.plugin_util").tr
        for _, item in ipairs(items) do
            if item.text == tr("Show underlines and thoughts") then
                item.callback = function(handle)
                    self:toggleAnnotationVisibility()
                    if handle then handle:updateItems() end
                end
            end
        end
        if self.ui.document then
            table.insert(items, 2, { text = tr("Underlines and thoughts management"),
                sub_item_table_func = function() return self:getUnifiedAnnotationMenuItems() end })
        end
        return items
    end
    function Plugin:syncProgressNow() return self:onWeReadSyncProgress() end
    local old_online = Plugin.isNetworkOnline
    function Plugin:isNetworkOnline()
        if self.settings.mock_endpoint then return true end
        return old_online(self)
    end
    function Plugin:onWeReadAccountChanged()
        self.downloader:cancelPrefetch("account_changed")
        self:cancelAnnotationPrefetch()
        self.shelf_regular, self.shelf_mp, self.shelf_books = nil, nil, nil
        self.shelf_groups, self.shelf_group_key = nil, nil
        self._annotation_context = nil
        self.settings:set("shelf_cache", {})
        self.settings:flush()
    end
    function Plugin:onShowWeRead() return self:showMainMenu() end
    function Plugin:onShowWeReadQuickMenu() return self:showEndOfBookDialog(self:detectWeReadBook()) end
    function Plugin:onShowWeReadBookshelf() self:showShelfGrid(1, "books"); return true end
    function Plugin:onShowWeReadLocalBookshelf() self:showWereadCollection(); return true end
    function Plugin:onShowWeReadReadingStatistics() self:showReadStats(); return true end
    function Plugin:onShowWeReadSearch() self:showSearch(); return true end
    function Plugin:showWereadCollection()
        local items = {}
        for _, book in pairs(self.settings:get("books", {})) do
            local path = self:getFullBookCachePath(book)
            if path and require("weread.lib.plugin_util").file_exists(path) then
                items[#items + 1] = { text = book.title or book.book_id, post_text = book.author,
                    callback = function() self:openFile(path) end }
            end
        end
        table.sort(items, function(a, b) return a.text < b.text end)
        return self:showList("微信读书 · 本地书架", items, "尚未下载整本书籍")
    end
    function Plugin:showShelfGroups()
        self:ensurePaperShelf()
        local items = { { text = "全部书籍", checked_func = function() return not self.shelf_group_key end,
            callback = function() self.shelf_group_key = nil; self:returnToPaperShelf() end } }
        for _, group in ipairs(self.shelf_groups or {}) do
            items[#items + 1] = { text = group.label, mandatory = tostring(#group.books),
                checked_func = function() return self.shelf_group_key == group.key end,
                callback = function() self.shelf_group_key = group.key; self:returnToPaperShelf() end }
        end
        return self:showList("书架分组", items)
    end
    function Plugin:ensurePaperShelf()
        if self.shelf_books then return end
        local cached = self.settings:get("shelf_cache", {})
        local books = self.library_db:getShelf()
        local archives = self.library_db:getShelfArchives()
        if not books or #books == 0 then
            if not cached.account_key or cached.account_key == self.library_db:accountKey() then
                books, archives = cached.books, cached.archives
            end
        end
        if type(books) ~= "table" then
            books = {}
            for _, book in pairs(self.settings:get("books", {})) do books[#books + 1] = book end
        end
        self:applyShelfSnapshot(books, archives)
    end
    function Plugin:returnToPaperShelf()
        local origin = require("weui_paper").weReadOrigin(self)
        if origin and origin._weui_weread_sheet then
            local parent = origin.origin_page
            origin:dismiss()
            if parent then parent.state.page = 1; parent.state.scroll_index = 1; parent:rebuild() end
        elseif origin then origin.state.page = 1; origin.state.scroll_index = 1; origin:rebuild() end
    end
    function Plugin:showShelfOptions()
        local items = {
            { text = "书架分组", callback = function() self:showShelfGroups() end },
            { text = "阅读与下载筛选", callback = function()
                self:showShelfFilterOptions(function() self:returnToPaperShelf() end)
            end },
        }
        for _, mode in ipairs({ "cover", "list" }) do
            items[#items + 1] = { text = mode == "cover" and "封面视图" or "列表视图",
                checked_func = function() return self.settings:get("shelf").view_mode == mode end,
                callback = function()
                    local shelf = self.settings:get("shelf"); shelf.view_mode = mode
                    self.settings:set("shelf", shelf); self.settings:flush(); self:returnToPaperShelf()
                end }
        end
        items[#items + 1] = { text = "本地微信读书书架", callback = function() self:showWereadCollection() end }
        return self:showList("书架选项", items)
    end
    local old_filters = Plugin.showShelfFilterOptions
    function Plugin:showShelfFilterOptions(on_changed)
        if not require("weui_paper").weReadOrigin(self) then return old_filters(self, on_changed) end
        local filters = self.shelf_filters or {}
        self.shelf_filters = filters
        local items = { { text = "显示全部", checked_func = function()
            return not filters.reading and not filters.download end,
            callback = function()
                filters.reading, filters.download = nil, nil
                self:saveShelfFilters(); on_changed()
            end } }
        for _, option in ipairs({
            { "reading", "finished", "已读完" }, { "reading", "unfinished", "未读完" },
            { "download", "downloaded", "已下载" }, { "download", "not_downloaded", "未下载" },
        }) do
            items[#items + 1] = { text = option[3],
                checked_func = function() return filters[option[1]] == option[2] end,
                callback = function()
                    if filters[option[1]] == option[2] then filters[option[1]] = nil
                    else filters[option[1]] = option[2] end
                    self:saveShelfFilters(); on_changed()
                end }
        end
        return self:showList("阅读与下载筛选", items)
    end
    local old_books = Plugin.getPaperShelfBooks
    function Plugin:getPaperShelfBooks(tab)
        self:ensurePaperShelf()
        local books = old_books(self, tab)
        local group = tab ~= "mp" and require("weread.lib.shelf_groups").find(self.shelf_groups, self.shelf_group_key)
        local members
        if group then
            members = {}
            for _, book in ipairs(group.books) do members[tostring(book.book_id or book.bookId)] = true end
        end
        local filtered, saved, downloads = {}, self.settings:get("books", {}), {}
        local shelf = self.settings:get("shelf")
        self.shelf_filters = { reading = shelf.filter_reading, download = shelf.filter_download }
        for _, book in ipairs(books) do
            if (not members or members[tostring(book.book_id or book.bookId)])
                and self:bookMatchesFilters(book, saved, downloads) then filtered[#filtered + 1] = book end
        end
        return filtered
    end
    -- The selection action stays visible on each paper page independently of
    -- display density, with selections retained across page changes.
    function Plugin:showChapterDownloadSelection(book, chapters, on_downloaded)
        local selected, handle = {}, nil
        local function targets()
            local result = {}
            for i, chapter in ipairs(chapters) do if selected[i] then result[#result + 1] = chapter end end
            return result
        end
        local action = { text_func = function() return "下载已选章节（" .. #targets() .. "）" end,
            select_enabled_func = function() return #targets() > 0 end,
            callback = function()
                self:confirmAndDownloadChapters(book, targets(), "chapters", {
                    separate_chapters = true, foreground = true,
                    on_complete = function(ok) if ok and on_downloaded then on_downloaded() end end,
                })
            end }
        local items = { { text = "全选 / 取消全选", callback = function()
            local all = #targets() == #chapters
            for i = 1, #chapters do selected[i] = not all or nil end
            handle:updateItems()
        end } }
        for i, chapter in ipairs(chapters) do
            items[#items + 1] = { text = chapter.title or tostring(chapter.chapterUid),
                checked_func = function() return selected[i] == true end,
                callback = function() selected[i] = not selected[i] or nil; handle:updateItems() end }
        end
        handle = self:showList("选择下载章节", items, "暂无章节", { pinned_action = action })
        return handle
    end
    for _, name in ipairs({ "clearBookAnnotationData", "clearBookCache", "clearAllMPCache", "clearAllCache" }) do
        Plugin[name] = require("weread.ui.cache")[name]
    end
end

return M

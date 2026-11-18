return function(reader, plugin, book, chapters, path, pump, pump_for, shot, control, dismiss_info)
    local UIManager = require("ui/uimanager")
    local Screen = require("device").screen
    local Event = require("ui/event")
    local json = require("json")
    local function dialogWithButtons()
        for i = #UIManager._window_stack, 1, -1 do
            local widget = UIManager._window_stack[i].widget
            if widget.buttons and widget.title == require("weread.lib.plugin_util").tr("WeRead · Quick menu") then
                return widget
            end
        end
        for _, window in ipairs(UIManager._window_stack) do
            print("Quick view:", tostring(window.widget.name), tostring(window.widget.title),
                tostring(window.widget.buttons ~= nil))
        end
        error("quick menu missing from native stack")
    end
    assert(plugin:onShowWeReadQuickMenu())
    local quick = dialogWithButtons()
    assert(quick.buttons[1][1].enabled and quick.buttons[1][2].enabled == false,
        "full-book quick navigation state invalid")
    shot("feature-10-quick-menu")
    UIManager:close(quick)
    local function requests()
        local count = 0
        for _, row in ipairs(control().requests) do
            if row.api == "/book/underlines" or row.api == "/book/readreviews" then count = count + 1 end
        end
        return count
    end
    -- Native font rerender invalidates geometry while reusing downloaded sources.
    dismiss_info()
    local before = requests()
    reader:handleEvent(Event:new("SetFontSize", 24))
    pump_for(0.4)
    plugin:onDocumentRerendered()
    assert(requests() == before and plugin._xpointer_overlay, "rerender fetched annotations or removed overlay")
    shot("feature-10-rerender-overlay")
    -- Actual long-thought popup, physical page keys, both layouts and bounded pool.
    local Popup = require("weread.ui.thought_popup")
    local Config = require("weread.ui.thought_popup.popup_config")
    local thought = { content = ("这是一条较长的原创想法。🌿\n"):rep(100),
        abstract = "合成文字用于界面验证", author = "测试读者", likes_count = 7 }
    for _, position in ipairs({ "center", "bottom" }) do
        local settings = plugin.settings:get("thought_popup")
        settings.position, settings.tap_to_page = position, true
        plugin.settings:set("thought_popup", settings)
        local popup = Popup.show(Config.build(plugin, { thought }))
        assert(Popup.isShowing())
        shot("feature-11-popup-" .. position)
        if position == "center" then
            assert(#popup._page_starts > 1, "long thought did not paginate")
            popup:handleEvent(Event:new("PageFwd"))
            assert(popup.page_index == 2, "physical forward key failed")
            popup:handleEvent(Event:new("PageBack"))
            assert(popup.page_index == 1, "physical backward key failed")
        end
        assert(Popup.getPoolStats().pool_size == 1)
        UIManager:close(popup)
    end
    Popup.cleanup()
    assert(not Popup.isShowing() and Popup.getPoolStats().pool_size == 0)
    -- A manual sync against the mock service verifies the actual mapped payload.
    local sync = plugin.progress_sync
    sync.on_choice = function(choice) choice.keep_local() end
    plugin:onWeReadSyncProgress()
    pump(function() return sync.verified end, 20)
    pump(function() return not sync.uploading end, 20)
    local position = assert(sync:position_for_report("900001"))
    assert(position.chapter_uid and position.chapter_offset ~= nil and position.percent ~= nil)
    local ok, outcome = plugin.read_report:upload_position("900001", position, 2)
    assert(ok, json.encode(outcome))
    local progress = control().progress["900001"]
    assert(progress and tostring(progress.chapterUid) == tostring(position.chapter_uid)
        and tonumber(progress.chapterOffset) == position.chapter_offset
        and math.abs(tonumber(progress.progress) - position.percent) < 0.01, "mapped payload changed at HTTP boundary")
    print("PASS: native rerender, long thoughts/emoji/page keys/positions, precise sync HTTP payload")
    -- Copy the original EPUB into a local filename and bind through the actual
    -- search dialog. Matching must reuse source data without editing the EPUB.
    local file = assert(io.open(path, "rb")); local bytes = file:read("*a"); file:close()
    local local_path = assert(os.getenv("KO_HOME")) .. "/library/本地山谷来信.epub"
    file = assert(io.open(local_path, "wb")); file:write(bytes); file:close()
    reader:onClose()
    reader = require("apps/reader/readerui"):new{
        dimen = Screen:getSize(), document = require("document/documentregistry"):openDocument(local_path) }
    UIManager:show(reader)
    plugin = assert(reader.weread)
    pump_for(0.3)
    assert(not plugin:_annotationBinding())
    assert(plugin:onShowWeReadQuickMenu())
    quick = dialogWithButtons()
    assert(quick.buttons[1][1].enabled == false and quick.buttons[4][1].enabled == false,
        "local-book quick menu enabled WeRead-only actions")
    UIManager:close(quick)
    plugin:bindExternalAnnotationsBook()
    local top
    for _, window in ipairs(UIManager._window_stack) do
        if window.widget.getInputText then top = window.widget end
    end
    assert(top, "local binding search dialog missing")
    top:setInputText("山谷来信")
    assert(top:getInputText() == "山谷来信", "binding query setter failed")
    top.buttons[1][2].callback()
    local matching_items
    pump(function()
        for _, window in ipairs(UIManager._window_stack) do
            local widget = window.widget
            local title = widget.title or widget.view and widget.view.title
            if title == require("weread.lib.plugin_util").tr("Select matching WeRead book") then
                matching_items = widget.item_table or widget.view and widget.view.items
                return matching_items ~= nil
            end
        end
    end)
    assert(#matching_items > 0)
    matching_items[1].callback()
    pump(function() return plugin:_annotationBinding() ~= nil end)
    assert(plugin:_annotationBinding().book_id == "900001")
    while UIManager._window_stack[#UIManager._window_stack].widget ~= reader do
        UIManager:close(UIManager._window_stack[#UIManager._window_stack].widget)
    end
    local initial = requests()
    local native_before = require("util").tableDeepCopy(reader.annotation.annotations)
    plugin:startUnifiedAnnotationSync{ offline = true, chapters = { chapters[1], chapters[2] } }
    pump(function() return plugin._external_annotation_sync ~= nil end)
    pump(function() return not plugin._external_annotation_sync end)
    assert(requests() == initial, "local file failed to reuse cached source")
    assert(require("util").tableEquals(reader.annotation.annotations, native_before))
    file = assert(io.open(local_path, "rb")); assert(file:read("*a") == bytes); file:close()
    local context = assert(plugin:_prepareAnnotationContext(false))
    assert(context.store:get("900001", "status", context.store:projectionKey(context.document_key, "1")))
    dismiss_info()
    shot("feature-12-local-book-match")
    assert(plugin:clearUnifiedAnnotationProjections())
    assert(plugin:_annotationBinding().book_id == "900001")
    assert(not context.store:get("900001", "source", "1")
        and not context.store:get("900001", "projection", context.store:projectionKey(context.document_key, "1")))
    assert(require("util").tableEquals(reader.annotation.annotations, native_before))
    file = assert(io.open(local_path, "rb")); assert(file:read("*a") == bytes); file:close()
    assert(plugin:clearBookAnnotationData("900001", book))
    print("PASS: local EPUB dialog binding, offline source reuse, independent XPointer projection; EPUB/native annotations unchanged")
    reader:onClose()
    assert(UIManager._prevent_standby_count == 0)
end

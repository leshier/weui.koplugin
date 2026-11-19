-- Custom book groups share KOReader's collections and Paper's sheet UI.
local UIManager = require("ui/uimanager")
local Collections = require("readcollection")
local Library = require("weui_library")
local Privacy = require("weui_privacy")
local Config = require("weui_config")
local util = require("util")
local M = {}

local function notice(text)
    UIManager:show(require("ui/widget/infomessage"):new{ text = text, timeout = 3 })
end

local function custom(name)
    return name ~= Collections.default_collection_name and name ~= "To Be Read"
end

function M.extend(Sheet)
    local Groups = Sheet:extend{ name = "weui_paper_groups" }

    function Groups:guard(name, callback)
        if self._closed then return end
        local function run()
            if not self._closed and Collections.coll[name] then callback() end
        end
        if Privacy.isCollectionRevealed(name) then run() else Privacy.requirePassword(run) end
    end

    function Groups:changed()
        Library.invalidate()
        self:rebuild(true)
    end

    function Groups:openGroup(group)
        self:guard(group.name, function()
            self.group, self.state.page = group, 1
            self:rebuild(true)
        end)
    end

    function Groups:editName(old_name)
        if self._closed then return end
        local dialog
        dialog = require("ui/widget/inputdialog"):new{
            title = old_name and "重命名分组" or "新建分组", input = old_name or "",
            buttons = { {
                { text = "取消", id = "close", callback = function() UIManager:close(dialog) end },
                { text = old_name and "保存" or "创建", callback = function()
                    if self._closed then UIManager:close(dialog); return end
                    local name = util.trim(dialog:getInputText() or "")
                    if name == "" or name:find("%c") or #name > 180 then
                        notice("请输入有效的分组名称。"); return
                    end
                    if name == old_name then UIManager:close(dialog); return end
                    if Collections.coll[name] then notice("这个分组名称已经存在。"); return end
                    if not custom(name) then notice("这个名称用于系统分组，请换一个名称。"); return end
                    local function save()
                        if old_name then
                            local private = Privacy.isPrivateCollection(old_name)
                            Collections:renameCollection(old_name, name)
                            if private then
                                Privacy.setPrivateCollection(name, true)
                                Privacy.setPrivateCollection(old_name, false)
                            end
                        else
                            Collections:addCollection(name)
                        end
                        if self.target_book and not old_name then
                            Collections:addItem(self.target_book.filepath, name)
                        end
                        Collections:write()
                        UIManager:close(dialog)
                        if not self.target_book then self.group = { name = name } end
                        self:changed()
                        if not old_name and not self.target_book then self:chooseBooks() end
                    end
                    if old_name then self:guard(old_name, save) else save() end
                end },
            } },
        }
        UIManager:show(dialog); dialog:onShowKeyboard()
    end

    function Groups:groupOptions()
        local name = self.group and self.group.name
        if not name then return end
        self:guard(name, function()
            local dialog
            dialog = require("ui/widget/buttondialog"):new{
                title = Privacy.isCollectionRevealed(name) and name or "私密分组",
                buttons = {
                    { { text = "添加或移除书籍", callback = function()
                        UIManager:close(dialog); self:chooseBooks()
                    end } },
                    { { text = "重命名分组", callback = function()
                        UIManager:close(dialog); self:editName(name)
                    end } },
                    { { text = "删除分组", callback = function()
                        UIManager:close(dialog)
                        UIManager:show(require("ui/widget/confirmbox"):new{
                            text = "删除这个分组？\n只删除分组，书籍文件会保留。",
                            ok_text = "删除分组", cancel_text = "取消",
                            ok_callback = function()
                                self:guard(name, function()
                                    Collections:removeCollection(name)
                                    Collections:write()
                                    Privacy.setPrivateCollection(name, false)
                                    self.group, self.state.page = nil, 1
                                    self:changed()
                                end)
                            end,
                        })
                    end } },
                    { { text = "关闭", callback = function() UIManager:close(dialog) end } },
                },
            }
            UIManager:show(dialog)
        end)
    end

    function Groups:chooseBooks()
        local name = self.group and self.group.name
        if not name then return end
        self:guard(name, function()
            self.editing, self.selected_files, self.editing_books = true, {}, self.books
            for path in pairs(Collections.coll[name]) do self.selected_files[path] = true end
            self.state.page = 1
            self:rebuild()
        end)
    end

    function Groups:saveBooks()
        local name = self.group and self.group.name
        if not (name and self.editing) then return end
        self:guard(name, function()
            -- Change only the books shown by this editor, in this one group.
            -- Other groups, favorites and unavailable member files stay intact.
            for _, book in ipairs(self.editing_books) do
                local path = book.filepath
                if self.selected_files[path] then
                    if not Collections:isFileInCollection(path, name) then Collections:addItem(path, name) end
                else
                    Collections:removeItem(path, name, true)
                end
            end
            Collections:write({ [name] = true })
            self.editing, self.selected_files, self.editing_books, self.state.page = nil, nil, nil, 1
            self:changed()
        end)
    end

    function Groups:toggleBook(name)
        self:guard(name, function()
            local path = self.target_book.filepath
            if Collections:isFileInCollection(path, name) then Collections:removeItem(path, name, true)
            else Collections:addItem(path, name) end
            Collections:write({ [name] = true })
            self:changed()
        end)
    end

    function Groups:list()
        self.entries = {}
        local title, intro, footer
        if self.editing then
            local count = 0
            for _, book in ipairs(self.editing_books) do
                local path = book.filepath
                local selected = self.selected_files[path]
                if selected then count = count + 1 end
                self.entries[#self.entries + 1] = {
                    label = book.title, meta = selected and "✓" or "",
                    callback = function()
                        self.selected_files[path] = not self.selected_files[path]
                        self:rebuild()
                    end,
                }
            end
            title, intro = "选择分组书籍", "已选 " .. count .. " 本 · 返回可取消"
            footer = { text = "保存（" .. count .. " 本）", callback = function() self:saveBooks() end }
        elseif self.group then
            local name = self.group.name
            title = Privacy.isCollectionRevealed(name) and name or "私密分组"
            local books = self:groupBooks(self.group)
            intro = #books .. " 本书"
            self.entries[1] = { label = "添加或移除书籍", meta = "›", icon_path = Config.ICON.weui_import,
                callback = function() self:chooseBooks() end }
            for _, book in ipairs(books) do self.entries[#self.entries + 1] = self:bookEntry(book) end
            footer = { text = "分组选项", callback = function() self:groupOptions() end }
        else
            local names = {}
            for name in pairs(Collections.coll) do if custom(name) then names[#names + 1] = name end end
            table.sort(names, function(a, b)
                local an = Privacy.isCollectionRevealed(a) and a or "私密分组"
                local bn = Privacy.isCollectionRevealed(b) and b or "私密分组"
                return an < bn
            end)
            title = self.target_book and "设置书籍分组" or "书籍分组"
            intro = self.target_book and "点击分组加入或移出书籍" or #names .. " 个自定义分组"
            self.entries[1] = { label = "+ 新建分组", meta = "›", icon_path = Config.ICON.weui_import,
                callback = function() self:editName() end }
            for _, name in ipairs(names) do
                local revealed = Privacy.isCollectionRevealed(name)
                local meta = revealed and (#self:groupBooks({ name = name }) .. " 本") or "已锁定"
                if self.target_book and revealed then
                    meta = Collections:isFileInCollection(self.target_book.filepath, name) and "✓ 已加入" or "加入"
                end
                self.entries[#self.entries + 1] = {
                    label = revealed and name or "私密分组", meta = meta,
                    icon_path = revealed and Config.ICON.group or Config.ICON.weui_privacy,
                    callback = function()
                        if self.target_book then self:toggleBook(name) else self:openGroup({ name = name }) end
                    end,
                }
            end
            if #names == 0 then
                self.entries[#self.entries + 1] = { label = "还没有自定义分组", meta = "点击新建" }
            end
        end
        if #self.entries == 0 then self.entries[1] = { label = "书架还没有书籍" } end
        self.pinned_action = footer
        self:drawList(title, intro, self.group ~= nil)
        self.pinned_action = nil
        if footer then self:button(footer.text, 38, self.panel_y + self.panel_h - 62, 460, footer.callback, true) end
    end

    function Groups:back()
        if self.editing then
            self.editing, self.selected_files, self.editing_books, self.state.page = nil, nil, nil, 1
            self:rebuild()
            return true
        end
        return Sheet.back(self)
    end

    return Groups
end

return M

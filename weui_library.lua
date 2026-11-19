-- Book-centred data for the paper interface. Never writes statistics/sidecars.
local lfs = require("libs/libkoreader-lfs")
local ffiUtil = require("ffi/util")
local DocSettings = require("docsettings")
local Registry = require("document/documentregistry")
local History = require("readhistory")
local Collections = require("readcollection")
local Store = require("weui_store")
local Config = require("weui_config")
local SH = require("desktop_modules/module_books_shared")
local Privacy = require("weui_privacy")
local logger = require("logger")
local M = {}
local cached, cached_at, cached_roots

local function canonical(path)
    return type(path) == "string" and (ffiUtil.realpath(path) or path) or nil
end

function M.roots(plugin)
    local roots, seen = {}, {}
    local function add(path)
        path = canonical(path)
        if path and not seen[path] and lfs.attributes(path, "mode") == "directory" then
            seen[path] = true
            roots[#roots + 1] = path
        end
    end
    add(G_reader_settings:readSetting("home_dir") or require("device").home_dir)
    for _, path in ipairs(Store:get("weui_library_folders") or {}) do add(path) end
    local wr = plugin and plugin._weread_plugin
    if wr and wr.settings then add(wr.settings:get_download_dir()) end
    local ok, ZConfig = pcall(require, "zlibrary.config")
    if ok then add(ZConfig.getDownloadDir()) end
    return roots
end

function M.invalidate()
    cached, cached_at, cached_roots = nil, nil, nil
end

function M.collectionDisplayName(name)
    if name == "To Be Read" then return require("weui_i18n").translate("To Be Read") end
    if name == Collections.default_collection_name then return "收藏" end
    return name
end

function M.refresh(path)
    M.invalidate()
    SH.invalidateSidecarCache(path)
    if path then Config.invalidateCover(path) end
    local Paper = package.loaded["weui_paper"]
    local page = Paper and Paper._instance
    if page and not page._closed then page:rebuild() end
end

function M.books(plugin, force)
    local roots = M.roots(plugin)
    local key = table.concat(roots, "\n")
    if not force and cached and cached_roots == key and os.time() - cached_at < 60 then
        return cached
    end
    local files, visited, readtimes, result = {}, {}, {}, {}
    local function add(path, attr)
        path = canonical(path)
        if path and not files[path] and Registry:hasProvider(path) then
            attr = attr or lfs.attributes(path)
            if attr and attr.mode == "file" then files[path] = attr end
        end
    end
    local function scan(dir)
        dir = canonical(dir)
        if not dir or visited[dir] then return end
        visited[dir] = true
        local ok, iter, obj = pcall(lfs.dir, dir)
        if not ok then return end
        for name in iter, obj do
            if name:sub(1, 1) ~= "." and not name:match("%.sdr$") then
                local path = dir .. "/" .. name
                local attr = lfs.attributes(path)
                if attr and attr.mode == "directory" then scan(path)
                elseif attr and attr.mode == "file" then add(path, attr) end
            end
        end
    end
    for _, dir in ipairs(roots) do scan(dir) end
    for _, path in ipairs(Store:get("weui_library_files") or {}) do add(path) end
    for _, item in ipairs(History.hist or {}) do
        local path = canonical(item.file)
        if path then
            add(path)
            readtimes[path] = tonumber(item.time) or 0
        end
    end
    if not Collections.coll then Collections:_read() end
    for _, coll in pairs(Collections.coll or {}) do
        for path in pairs(coll) do add(path) end
    end
    local favorites = (Collections.coll or {})[Collections.default_collection_name] or {}
    for path, attr in pairs(files) do
        local data = SH.getBookData(path)
        local ds = DocSettings:open(path)
        local summary = ds:readSetting("summary") or {}
        local props = ds:readSetting("doc_props") or {}
        local tags = props.keywords or props.tags or ""
        if type(tags) == "table" then tags = table.concat(tags, " ") end
        -- DocSettings:close() flushes; these are read-only snapshots.
        data.filepath = path
        data.modified = attr.modification or 0
        data.last_read = readtimes[path] or 0
        data.status = summary.status == "complete" and "done"
            or (data.percent > 0 or data.last_read > 0) and "reading" or "unread"
        data.favorite = favorites[path] ~= nil
        data.chapter = ds:readSetting("last_toc_title") or ""
        data.last_page = ds:readSetting("last_page") or ds:readSetting("last_page_number")
        data.md5 = ds:readSetting("partial_md5_checksum")
        data.tags = tostring(tags)
        data.summary = summary
        data.private = Privacy.isPrivateBook(path, props.title) and not Privacy.isUnlocked()
        if data.private then data.tags, data.chapter = "", "" end
        result[#result + 1] = data
    end
    table.sort(result, function(a, b)
        if a.last_read ~= b.last_read then return a.last_read > b.last_read end
        if a.modified ~= b.modified then return a.modified > b.modified end
        return a.filepath < b.filepath
    end)
    cached, cached_at, cached_roots = result, os.time(), key
    return result
end

function M.filter(books, query, status, sort)
    query = (query or ""):lower()
    local out = {}
    for _, book in ipairs(books) do
        local hay = (book.title .. " " .. book.authors .. " " .. book.tags):lower()
        if (query == "" or hay:find(query, 1, true))
            and (not status or status == "all" or status == book.status
                or status == "favorites" and book.favorite) then
            out[#out + 1] = book
        end
    end
    if sort == "title" then
        table.sort(out, function(a, b)
            if a.title ~= b.title then return a.title < b.title end
            return a.filepath < b.filepath
        end)
    elseif sort == "progress" then
        table.sort(out, function(a, b)
            if a.percent ~= b.percent then return a.percent > b.percent end
            return a.filepath < b.filepath
        end)
    end
    return out
end

function M.yearlyBooks(books, year)
    year = tostring(year or os.date("%Y"))
    local count = 0
    for _, book in ipairs(books or {}) do
        if book.status == "done" and tostring((book.summary or {}).modified or ""):sub(1, 4) == year then
            count = count + 1
        end
    end
    return count + (tonumber(Store:get("weui_reading_goal_physical")) or 0)
end

function M.favorite(book)
    if not Collections.coll then Collections:_read() end
    local name = Collections.default_collection_name
    if book.favorite then Collections:removeItem(book.filepath, name)
    else
        Collections:addItem(book.filepath, name)
        Collections:write({ [name] = true })
    end
    M.invalidate()
end

function M.import(path)
    path = canonical(path)
    if not path or lfs.attributes(path, "mode") ~= "file" or not Registry:hasProvider(path) then
        return nil, "请选择 KOReader 支持的书籍文件。"
    end
    local files = Store:get("weui_library_files") or {}
    for _, old in ipairs(files) do
        if canonical(old) == path then M.refresh(path); return path end
    end
    files[#files + 1] = path
    Store:set("weui_library_files", files)
    M.refresh(path)
    return path
end

-- Called only after KOReader has deleted the file and its native metadata.
function M.forgetFile(path)
    path = canonical(path)
    local files, kept = Store:get("weui_library_files") or {}, {}
    for _, file in ipairs(files) do
        if canonical(file) ~= path then kept[#kept + 1] = file end
    end
    if #kept ~= #files then Store:set("weui_library_files", kept) end
    SH.invalidateSidecarCache(path)
    M.invalidate()
end

function M.notes(books, query, kind)
    local out = {}
    query = (query or ""):lower()
    for _, book in ipairs(books) do
        if not book.private then
            local ds = DocSettings:open(book.filepath)
            local annotations = ds:readSetting("annotations")
            local legacy = annotations == nil
            annotations = annotations or ds:readSetting("bookmarks") or {}
            for _, a in ipairs(annotations) do
                if a.drawer or a.highlighted or a.note and a.note ~= "" then
                    local note = legacy and a.text or a.note
                    local quote = legacy and a.notes or a.text
                    note = type(note) == "string" and note ~= "" and note or nil
                    quote = type(quote) == "string" and quote or ""
                    local typ = note and "note" or "highlight"
                    local text = note or quote
                    if text ~= "" and (not kind or kind == "all" or kind == typ)
                        and (query == "" or (book.title .. " " .. quote .. " " .. (note or "")):lower():find(query, 1, true)) then
                        out[#out + 1] = {
                            book = book, kind = typ, text = text, quote = quote, note = note,
                            page = a.pageref or a.pageno or (type(a.page) == "number" and a.page),
                            chapter = a.chapter or "", date = a.datetime_updated or a.datetime or "",
                        }
                    end
                end
            end
        end
    end
    table.sort(out, function(a, b)
        if a.date ~= b.date then return a.date > b.date end
        return a.book.filepath < b.book.filepath
    end)
    return out
end

function M.exportNotes(records, path)
    if not Privacy.isUnlocked() then
        for _, record in ipairs(records) do
            if Privacy.isPrivateBook(record.book.filepath) then
                return nil, "请先解锁隐私书，再导出这些笔记。"
            end
        end
    end
    if lfs.attributes(path) then return nil, "文件已存在。" end
    local mode_ok, file, err = pcall(io.open, path, "wx")
    if not mode_ok then file, err = nil, file end
    -- LuaJIT's libc may not support "x"; callers supply a new unique filename.
    if not file and not lfs.attributes(path) then file, err = io.open(path, "w") end
    if not file then return nil, err end
    local chunks = { "阅读笔记与划线\n" }
    for _, n in ipairs(records) do
        chunks[#chunks + 1] = string.format("\n《%s》 · %s\n%s · %s\n%s\n%s\n",
            n.book.title, n.book.authors, n.page and ("第 " .. n.page .. " 页") or n.chapter,
            n.date, n.quote, n.note and ("笔记：" .. n.note) or "")
    end
    local ok, write_err = file:write(table.concat(chunks))
    local closed, close_err = file:close()
    if not ok or not closed then return nil, write_err or close_err end
    return true
end

-- Calendar arithmetic at local noon avoids repeated/missing days across DST.
function M.day(date, offset)
    local y, m, d = date:match("^(%d+)%-(%d+)%-(%d+)")
    return os.date("%Y-%m-%d", os.time{
        year = tonumber(y), month = tonumber(m), day = tonumber(d) + (offset or 0), hour = 12,
    })
end

function M.period(period, now)
    local t = os.date("*t", now or os.time())
    local today = string.format("%04d-%02d-%02d", t.year, t.month, t.day)
    local tomorrow = M.day(today, 1)
    if period == "month" then
        local start = string.format("%04d-%02d-01", t.year, t.month)
        local prev = os.date("%Y-%m-%d", os.time{ year = t.year, month = t.month - 1, day = 1, hour = 12 })
        return start, tomorrow, prev, start
    elseif period == "year" then
        return t.year .. "-01-01", tomorrow, (t.year - 1) .. "-01-01", t.year .. "-01-01"
    elseif period == "all" then return "0000-01-01", tomorrow end
    return M.day(today, -6), tomorrow, M.day(today, -13), M.day(today, -6)
end

function M.stats(period, now, books)
    local start, finish, prev, prev_end = M.period(period, now)
    local today = M.day(finish, -1)
    local data = {
        start = start, finish = today, seconds = 0, previous = 0, days = 0,
        daily = {}, ranking = {}, bars = {}, streak = 0, best = 0, available = false,
    }
    local path = Config.getStatsDbPath()
    if lfs.attributes(path, "mode") ~= "file" then return data end
    local SQ = require("lua-ljsqlite3/init")
    local ok, conn = pcall(SQ.open, path, "ro")
    if not ok then logger.warn("weui paper statistics:", conn); return data end
    local bookmap = {}
    for _, book in ipairs(books or {}) do if book.md5 then bookmap[book.md5] = book end end
    local success, err = pcall(function()
        conn:set_busy_timeout(100)
        local rows = conn:exec([[
            SELECT strftime('%Y-%m-%d',start_time,'unixepoch','localtime'),
                   sum(duration)
            FROM page_stat_data WHERE duration > 0
            GROUP BY 1 ORDER BY 1
        ]])
        local dates = {}
        for i, date in ipairs(rows and rows[1] or {}) do
            local secs = tonumber(rows[2][i]) or 0
            if date <= today then
                data.daily[date] = secs
                dates[#dates + 1] = date
                if date >= start then data.seconds = data.seconds + secs; data.days = data.days + 1 end
                if prev and date >= prev and date < prev_end then data.previous = data.previous + secs end
            end
        end
        data.streak = require("weui_streak").computeCurrentDayStreak(dates, { today = today })
        local run, last = 0
        for _, date in ipairs(dates) do
            run = last and M.day(last, 1) == date and (run + 1) or 1
            data.best, last = math.max(data.best, run), date
        end
        if period == "all" then start = dates[1] or today; data.start = start end
        local function timestamp(date)
            local y, m, d = date:match("(%d+)%-(%d+)%-(%d+)")
            return os.time{ year = tonumber(y), month = tonumber(m), day = tonumber(d), hour = 0 }
        end
        rows = conn:exec(string.format([[
            SELECT b.title,b.authors,b.md5,sum(p.duration)
            FROM page_stat_data p JOIN book b ON b.id=p.id_book
            WHERE p.duration>0 AND p.start_time>=%d AND p.start_time<%d
            GROUP BY b.id ORDER BY 4 DESC
        ]], timestamp(start), timestamp(finish)))
        for i, title in ipairs(rows and rows[1] or {}) do
            local book = bookmap[rows[3][i]]
            local hidden = book and book.private or Privacy.isPrivateBook(nil, title) and not Privacy.isUnlocked()
            data.ranking[#data.ranking + 1] = {
                title = hidden and Privacy.privateTitle() or title,
                authors = hidden and Privacy.privateAuthor() or rows[2][i],
                seconds = tonumber(rows[4][i]) or 0, book = book,
            }
        end
        data.available = true
    end)
    conn:close()
    if not success then logger.warn("weui paper statistics:", err); data.error = tostring(err) end
    local buckets = {}
    if period == "week" then
        for i = 0, 6 do
            local date = M.day(start, i)
            data.bars[#data.bars + 1] = { label = os.date("%m/%d", os.time{
                year = tonumber(date:sub(1, 4)), month = tonumber(date:sub(6, 7)), day = tonumber(date:sub(9, 10)), hour = 12,
            }), seconds = data.daily[date] or 0 }
        end
    elseif period == "month" then
        for i = 1, 5 do data.bars[i] = { label = (i - 1) * 7 + 1 .. "日", seconds = 0 } end
        for date, secs in pairs(data.daily) do
            if date >= start and date < finish then
                local i = math.floor((tonumber(date:sub(9, 10)) - 1) / 7) + 1
                data.bars[i].seconds = data.bars[i].seconds + secs
            end
        end
    else
        for date, secs in pairs(data.daily) do
            if date >= start and date < finish then
                local key = period == "year" and date:sub(6, 7) or date:sub(1, 4)
                buckets[key] = (buckets[key] or 0) + secs
            end
        end
        if period == "year" then
            for i = 1, 12 do data.bars[i] = { label = tostring(i), seconds = buckets[string.format("%02d", i)] or 0 } end
        else
            local first, last = tonumber(start:sub(1, 4)), tonumber(today:sub(1, 4))
            for y = first, last do data.bars[#data.bars + 1] = { label = tostring(y), seconds = buckets[tostring(y)] or 0 } end
        end
    end
    local count = 0
    local date = start
    while date < finish do count = count + 1; date = M.day(date, 1) end
    data.average = count > 0 and data.seconds / count or 0
    return data
end

return M

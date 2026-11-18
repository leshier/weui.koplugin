-- Seed once, then leave all operations to the person testing the app.
local DataStorage = require("datastorage")
local lfs = require("libs/libkoreader-lfs")
local root = DataStorage:getDataDir()
assert(lfs.attributes(root .. "/.weui-manual-profile", "mode") == "file", "manual profile marker missing")
local ffi = require("ffi")
ffi.cdef[[int getpid(void);]]
local pid_file = assert(io.open(root .. "/.weui-manual-pid", "w"))
pid_file:write(tostring(ffi.C.getpid())); pid_file:close()
local library = root .. "/library"
local marker = root .. "/data/.paper-manual-seeded"
-- Match the native statistics schema. An early seed with user_version=0
-- otherwise looks like the pre-2020 schema and triggers a migration of a
-- page_stat table that never existed in this test profile.
local Stats = dofile(root .. "/plugins/weui.koplugin/scripts/qa/fixtures/paper_stats.lua")
if lfs.attributes(marker, "mode") == "file" then
    local database = DataStorage:getSettingsDir() .. "/statistics.sqlite3"
    local conn = require("lua-ljsqlite3/init").open(database)
    Stats.repair(conn, database, library)
    if tonumber(conn:rowexec("PRAGMA user_version;")) == 0
        and conn:rowexec("SELECT name FROM sqlite_master WHERE name='page_stat_data';")
        and not conn:rowexec("SELECT name FROM sqlite_master WHERE name='page_stat';") then
        Stats.finish(conn)
        require("logger").info("weui: repaired manual profile statistics schema")
    end
    conn:close()
    return
end
G_reader_settings:saveSetting("home_dir", library)
G_reader_settings:saveSetting("lastdir", library)
G_reader_settings:saveSetting("autoremove_deleted_items_from_history", true)

local titles = {
    "山海小记", "日常的秩序", "四季书", "城与乡", "时间的形状",
    "云的来信", "行走之间", "远方的灯", "可删除的测试书",
}
local files = {}
local DocSettings = require("docsettings")
for i, title in ipairs(titles) do
    local path = library .. "/" .. title .. ".txt"
    files[i] = path
    local fh = assert(io.open(path, "w"))
    fh:write((title .. "\n\n这是一篇原创测试文章，用来验证阅读、收藏、笔记与删除。\n"
        .. "每一次返回，也都从上次停下的地方继续。\n\n"):rep(180))
    fh:close()
    local ds = DocSettings:open(path)
    ds:saveSetting("doc_props", { title = title, authors = "纸页测试", keywords = i % 2 == 0 and "生活" or "随笔" })
    ds:saveSetting("percent_finished", i < 4 and i * 0.15 or i == 8 and 1 or 0)
    ds:saveSetting("summary", {
        status = i == 8 and "complete" or i < 4 and "reading" or "new",
        modified = os.date("%Y-%m-%d"),
    })
    ds:saveSetting("partial_md5_checksum", string.format("%032d", i))
    ds:saveSetting("doc_pages", 200)
    ds:saveSetting("last_page", i < 4 and i * 30 or 1)
    if i < 4 then
        ds:saveSetting("annotations", {
            { drawer = "lighten", text = "阅读让我们尝试另一种观察世界的方式。",
                note = i == 1 and "每一页都是一次停留。" or nil, pageno = 15 * i,
                datetime = os.date("%Y-%m-%d") .. " 12:00:00" },
            { drawer = "underline", text = "每一次返回，也都从上次停下的地方继续。",
                pageno = 25 * i, datetime = os.date("%Y-%m-%d") .. " 10:00:00" },
        })
    end
    ds:flush()
end
local History = require("readhistory")
History.hist = {}
for order, i in ipairs({ 1, 2, 3, 6, 8 }) do
    History.hist[order] = { file = files[i], time = os.time() - (order - 1) * 24 * 3600 }
end
History:_flush()
local Collections = require("readcollection")
Collections:_read()
for _, i in ipairs({ 1, 3, 5 }) do Collections:addItem(files[i], Collections.default_collection_name) end
Collections:addCollection("散文")
Collections:addItem(files[4], "散文")
Collections:write()
local settings = require("luasettings"):open(root .. "/settings/weui/weui_settings.lua")
settings:saveSetting("weui_reading_goal", 24)
settings:saveSetting("weui_monthly_reading_goal_secs", 12 * 3600)
settings:saveSetting("weui_daily_reading_goal_secs", 40 * 60)
settings:flush()

local conn = require("lua-ljsqlite3/init").open(DataStorage:getSettingsDir() .. "/statistics.sqlite3")
Stats.create(conn)
for i = 1, 2 do
    conn:exec(string.format("INSERT INTO book(id,title,authors,md5) VALUES(%d,'%s','纸页测试','%032d')", i, titles[i], i))
end
local today = os.date("*t")
for i = 0, 13 do
    local ts = os.time{ year = today.year, month = today.month, day = today.day - i, hour = 12 }
    conn:exec(string.format("INSERT INTO page_stat_data VALUES(%d,%d,%d,%d,200)", i % 2 + 1, i + 1, ts, (i < 7 and 40 or 20) * 60))
end
conn:close()
local seeded = assert(io.open(marker, "w"))
seeded:write("Original sample books, notes, collections and statistics.\n")
seeded:close()
require("logger").info("weui: manual test profile ready:", root, "books=", #files)

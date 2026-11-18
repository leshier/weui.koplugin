-- Statistics fixtures must match KOReader's positional INSERT contract.
-- This helper is confined to marked/disposable QA homes, never user databases.
local M = {}
local schema = [[
    CREATE TABLE IF NOT EXISTS book(
      id INTEGER PRIMARY KEY AUTOINCREMENT,title TEXT,authors TEXT,notes INTEGER DEFAULT 0,
      last_open INTEGER DEFAULT 0,highlights INTEGER DEFAULT 0,pages INTEGER DEFAULT 200,
      series TEXT,language TEXT,md5 TEXT,total_read_time INTEGER DEFAULT 0,total_read_pages INTEGER DEFAULT 0);
    CREATE TABLE IF NOT EXISTS page_stat_data(
      id_book INTEGER,page INTEGER,start_time INTEGER,duration INTEGER,total_pages INTEGER);
]]

function M.finish(conn)
    conn:exec([[
        CREATE INDEX IF NOT EXISTS page_stat_data_start_time ON page_stat_data(start_time);
        CREATE UNIQUE INDEX IF NOT EXISTS book_title_authors_md5 ON book(title, authors, md5);
        CREATE TABLE IF NOT EXISTS numbers(number INTEGER PRIMARY KEY);
        WITH RECURSIVE counter AS (SELECT 1 AS N UNION ALL SELECT N + 1 FROM counter WHERE N < 1000)
          INSERT OR IGNORE INTO numbers SELECT N FROM counter;
        CREATE VIEW IF NOT EXISTS page_stat AS
          SELECT id_book, first_page + idx - 1 AS page, start_time,
            duration / (last_page - first_page + 1) AS duration
          FROM (
            SELECT id_book, page, total_pages, pages, start_time, duration,
              ((page - 1) * pages) / total_pages + 1 AS first_page,
              max(((page - 1) * pages) / total_pages + 1, (page * pages) / total_pages) AS last_page, idx
            FROM page_stat_data JOIN book ON book.id = id_book
            JOIN (SELECT number AS idx FROM numbers) AS N ON idx <= (last_page - first_page + 1)
          );
        PRAGMA user_version=20221111;
    ]])
end

function M.create(conn)
    conn:exec(schema)
    M.finish(conn)
end

local function quote(value) return "'" .. tostring(value):gsub("'", "''") .. "'" end

function M.repair(conn, database, library)
    local columns = conn:rowexec("SELECT group_concat(name, ',') FROM pragma_table_info('book');")
    local old = "id,title,authors,notes,highlights,pages,series,language,md5,last_open,total_read_time,total_read_pages"
    if columns ~= old then return false end
    -- Flush WAL before copying; keep a complete pre-migration backup.
    conn:exec("PRAGMA wal_checkpoint(TRUNCATE);")
    local backup = database .. ".paper-columns-" .. os.date("%Y%m%d-%H%M%S") .. ".bak"
    assert(require("ffi/util").copyFile(database, backup) == nil, "statistics backup failed")
    conn:exec("BEGIN IMMEDIATE;")
    local ok, err = xpcall(function()
        conn:exec([[
            DROP VIEW IF EXISTS page_stat;
            DROP INDEX IF EXISTS book_title_authors_md5;
            ALTER TABLE book RENAME TO paper_old_book;
        ]])
        conn:exec(schema)
        conn:exec([[
            INSERT INTO book(id,title,authors,notes,last_open,highlights,pages,series,language,md5,total_read_time,total_read_pages)
            SELECT id,title,authors,notes,last_open,highlights,pages,series,language,md5,total_read_time,total_read_pages
            FROM paper_old_book;
        ]])
        -- Native saves may already have corrected named fields such as
        -- last_open/pages. Recover only the still-displaced metadata fields
        -- of native-inserted rows, using the fixture's own book sidecar.
        local stmt = conn:prepare("SELECT id,title FROM book WHERE authors='N/A' AND md5='N/A' AND CAST(series AS INTEGER)=pages;")
        local repairs = {}
        for row in stmt:rows() do
            local path = library .. "/" .. row[2] .. ".txt"
            if require("libs/libkoreader-lfs").attributes(path, "mode") == "file" then
                local ds = require("docsettings"):open(path)
                local md5 = ds:readSetting("partial_md5_checksum")
                local props = ds:readSetting("doc_props") or {}
                if md5 and tostring(md5):match("^%x+$") and #tostring(md5) == 32 then
                    repairs[#repairs + 1] = { tonumber(row[1]), md5, props.series or "N/A", props.language or "N/A" }
                end
            end
        end
        stmt:close()
        for _, row in ipairs(repairs) do
            conn:exec(string.format("UPDATE book SET md5=%s,series=%s,language=%s WHERE id=%d;",
                quote(row[2]), quote(row[3]), quote(row[4]), row[1]))
        end
        assert(conn:rowexec("SELECT count(*) FROM book;") == conn:rowexec("SELECT count(*) FROM paper_old_book;"), "statistics rows lost")
        conn:exec("DROP TABLE paper_old_book;")
        M.finish(conn)
        assert(conn:rowexec("PRAGMA integrity_check;") == "ok", "statistics integrity failed")
        conn:exec("COMMIT;")
    end, debug.traceback)
    if not ok then conn:exec("ROLLBACK;"); error(err) end
    require("logger").info("weui: repaired QA statistics column order; backup:", backup)
    return true, backup
end

return M

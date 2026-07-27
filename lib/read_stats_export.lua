-- read_stats_export.lua - 导出微信读书阅读统计为 CSV / JSON
-- 纯数据转换，无 UI 依赖，可单元测试。输入是 ReadStats.normalize() 的产物。
local ReadStatsExport = {}

-- CSV 字段转义：含逗号/引号/换行的值用双引号包裹，内部引号双写。
local function csv_field(value)
    local s = tostring(value or "")
    if s:find('[",\n\r]') then
        return '"' .. s:gsub('"', '""') .. '"'
    end
    return s
end

local function csv_row(fields)
    local out = {}
    for i = 1, #fields do
        out[i] = csv_field(fields[i])
    end
    return table.concat(out, ",")
end

-- 把任意 normalized 统计表写成多段 CSV 字符串。
-- 段：概览 / 每日时长 / 最长阅读 / 偏好分类 / 偏好作者 / 偏好出版社 / 摘要
function ReadStatsExport.to_csv(data)
    data = type(data) == "table" and data or {}
    local lines = {}

    -- 概览
    lines[#lines + 1] = csv_row({ "Section", "Key", "Value" })
    local period = data.period_label or ""
    lines[#lines + 1] = csv_row({ "Overview", "Period", period })
    lines[#lines + 1] = csv_row({ "Overview", "Mode", data.mode or "" })
    lines[#lines + 1] = csv_row({ "Overview", "TotalReadSeconds", data.total_read_time or 0 })
    lines[#lines + 1] = csv_row({ "Overview", "ReadDays", data.read_days or 0 })
    lines[#lines + 1] = csv_row({ "Overview", "DayAverageSeconds", data.day_average or 0 })
    if data.read_rate ~= nil then
        lines[#lines + 1] = csv_row({ "Overview", "ReadRate", data.read_rate })
    end
    if data.compare ~= nil then
        lines[#lines + 1] = csv_row({ "Overview", "Compare", data.compare })
    end
    if data.rank_text ~= nil then
        lines[#lines + 1] = csv_row({ "Overview", "Rank", data.rank_text })
    end

    -- 每日时长 buckets
    if type(data.buckets) == "table" and #data.buckets > 0 then
        lines[#lines + 1] = ""
        lines[#lines + 1] = csv_row({ "Section", "Timestamp", "Label", "Seconds" })
        for _, b in ipairs(data.buckets) do
            lines[#lines + 1] = csv_row({ "Daily", b.ts, b.label, b.value or 0 })
        end
    end

    -- 最长阅读书籍
    if type(data.top_books) == "table" and #data.top_books > 0 then
        lines[#lines + 1] = ""
        lines[#lines + 1] = csv_row({ "Section", "Title", "Author", "Seconds" })
        for _, b in ipairs(data.top_books) do
            lines[#lines + 1] = csv_row({ "TopBook", b.title, b.author or "", b.seconds or 0 })
        end
    end

    -- 偏好分类
    if type(data.prefer_category) == "table" and #data.prefer_category > 0 then
        lines[#lines + 1] = ""
        lines[#lines + 1] = csv_row({ "Section", "Category", "Seconds", "Count" })
        for _, c in ipairs(data.prefer_category) do
            lines[#lines + 1] = csv_row({ "PreferCategory", c.title, c.seconds or 0, c.count or 0 })
        end
    end

    -- 偏好作者
    if type(data.prefer_author) == "table" and #data.prefer_author > 0 then
        lines[#lines + 1] = ""
        lines[#lines + 1] = csv_row({ "Section", "Author", "Count" })
        for _, a in ipairs(data.prefer_author) do
            lines[#lines + 1] = csv_row({ "PreferAuthor", a.name, a.count or 0 })
        end
    end

    -- 偏好出版社
    if type(data.prefer_publisher) == "table" and #data.prefer_publisher > 0 then
        lines[#lines + 1] = ""
        lines[#lines + 1] = csv_row({ "Section", "Publisher", "Count" })
        for _, p in ipairs(data.prefer_publisher) do
            lines[#lines + 1] = csv_row({ "PreferPublisher", p.name, p.count or 0 })
        end
    end

    -- 摘要
    if type(data.summary) == "table" and #data.summary > 0 then
        lines[#lines + 1] = ""
        lines[#lines + 1] = csv_row({ "Section", "Stat", "Counts" })
        for _, s in ipairs(data.summary) do
            lines[#lines + 1] = csv_row({ "Summary", s.name, s.counts })
        end
    end

    return table.concat(lines, "\n") .. "\n"
end

-- ---- 极简 JSON 编码器（仅覆盖 normalized 数据用到的类型） ----
local function json_escape(s)
    s = tostring(s or "")
    s = s:gsub('\\', '\\\\')
          :gsub('"', '\\"')
          :gsub('\n', '\\n')
          :gsub('\r', '\\r')
          :gsub('\t', '\\t')
    return '"' .. s .. '"'
end

local function json_value(v)
    local tv = type(v)
    if tv == "number" then
        return tostring(v)
    elseif tv == "boolean" then
        return v and "true" or "false"
    elseif v == nil then
        return "null"
    elseif tv == "string" then
        return json_escape(v)
    elseif tv == "table" then
        -- 区分数组（连续整数键 1..n）与对象
        local n = 0
        for _ in pairs(v) do n = n + 1 end
        local is_array = true
        for k in pairs(v) do
            if type(k) ~= "number" or k < 1 or k > n then is_array = false; break end
        end
        -- 修正：数组需键为 1..n 连续
        if is_array and n > 0 then
            for i = 1, n do
                if v[i] == nil then is_array = false; break end
            end
        end
        if is_array and n > 0 then
            local items = {}
            for i = 1, n do items[i] = json_value(v[i]) end
            return "[" .. table.concat(items, ",") .. "]"
        end
        -- 对象
        local items = {}
        for k, val in pairs(v) do
            items[#items + 1] = json_escape(tostring(k)) .. ":" .. json_value(val)
        end
        return "{" .. table.concat(items, ",") .. "}"
    end
    return "null"
end

function ReadStatsExport.to_json(data)
    data = type(data) == "table" and data or {}
    return json_value(data)
end

-- 写入文件。format: "csv" 或 "json"。返回写入路径或 nil, err。
function ReadStatsExport.write_file(data, format, path)
    local content
    if format == "json" then
        content = ReadStatsExport.to_json(data)
    else
        format = "csv"
        content = ReadStatsExport.to_csv(data)
    end
    local f, err = io.open(path, "wb")
    if not f then
        return nil, tostring(err or "open failed")
    end
    f:write(content)
    f:close()
    return path
end

return ReadStatsExport

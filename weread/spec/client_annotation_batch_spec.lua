package.path = "./?.lua;" .. package.path

package.preload["ltn12"] = function() return {} end
package.preload["socketutil"] = function() return {} end
package.preload["socket.http"] = function() return {} end
package.preload["json"] = function()
    return { encode = function() return "{}" end, decode = function() return {} end }
end
package.preload["weread.lib.cookie"] = function() return {} end
package.preload["weread.lib.protocol"] = function() return {} end

local Client = require("weread.lib.client")
local client = setmetatable({}, { __index = Client })
local ranges = {}
for index = 1, 61 do ranges[index] = tostring(index) end

local batches = client:build_chapter_review_batches(ranges)
assert(#batches == 3, "61 ranges must be split into three requests")
assert(#batches[1] == 30 and #batches[2] == 30 and #batches[3] == 1,
    "thought requests must contain at most 30 ranges")
assert(batches[1][1].range == "1" and batches[2][1].range == "31"
        and batches[3][1].range == "61",
    "thought range order changed while batching")
assert(batches[1][1].count == 30 and batches[1][1].maxIdx == 0
        and batches[1][1].synckey == 0,
    "thought pagination parameters changed")

print("client_annotation_batch_spec: 30-range thought batches passed")

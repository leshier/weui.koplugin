-- The About screen must accept KOReader's normal _meta.lua schema.

local root = (arg[0]:match("^(.*)/scripts/") or ".")
package.path = root .. "/?.lua;" .. package.path
package.loaded.weui_i18n = { translate = function(value) return value end }

local meta = assert(dofile(root .. "/_meta.lua"))
assert(type(meta.version) == "string" and meta.version:match("^%d+%.%d+%.%d+$"))
assert(type(meta.author) == "string" and meta.author ~= "")

local fh = assert(io.open(root .. "/weui_menu.lua", "rb"))
local source = fh:read("*a")
fh:close()
assert(not source:find('Meta.name ~= "weui"', 1, true),
    "About screen still rejects standard KOReader metadata")
assert(source:find("Meta.version or", 1, true), "About screen does not display the version")
assert(source:find("Meta.author or", 1, true), "About screen does not display the author")

print("ABOUT_METADATA_OK")

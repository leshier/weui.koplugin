-- Keep WeUI's additional read-only endpoints on the current upstream client.
local Client = require("weread.lib.client")
local Legacy = require("lib.client")
local Extended = setmetatable({}, { __index = Client })
Extended.__index = Extended
for name, method in pairs(Legacy) do
    if Client[name] == nil then Extended[name] = method end
end
function Extended:request(options)
    return require("weui_network").request(self, options, Client.request)
end
return Extended

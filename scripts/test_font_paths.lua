local canonical = {
    ["./fonts"] = "/mnt/us/koreader/fonts",
    ["plugins/weui.koplugin/fonts/PaperSong.ttf"] = "/mnt/us/koreader/plugins/weui.koplugin/fonts/PaperSong.ttf",
    ["/mnt/us/koreader/plugins/weui.koplugin/fonts/PaperSong.ttf"] = "/mnt/us/koreader/plugins/weui.koplugin/fonts/PaperSong.ttf",
    ["/qa/plugins/weui.koplugin/fonts/PaperSong.ttf"] = "/workspace/weui.koplugin/fonts/PaperSong.ttf",
    ["/runtime/fonts"] = "/runtime/fonts",
    ["/runtime/fonts/custom/title.ttf"] = "/runtime/fonts/custom/title.ttf",
    ["/runtime/fonts-extra/title.ttf"] = "/runtime/fonts-extra/title.ttf",
}
local calls, unsupported = {}, false
package.loaded["ffi/util"] = { realpath = function(path) return canonical[path] end }
package.loaded.fontlist = { fontdir = "./fonts" }
package.loaded.logger = { warn = function() end }
package.loaded["ui/font"] = { getFace = function(_, name, size)
    calls[#calls + 1] = { name = name, size = size }
    if unsupported and name:find("PaperSong", 1, true) then return end
    return { realname = name, size = size }
end }
local Fonts = require("weui_fonts")
local bundled = "plugins/weui.koplugin/fonts/PaperSong.ttf"
local relative = "../plugins/weui.koplugin/fonts/PaperSong.ttf"
assert(Fonts.fontName(bundled) == relative, "relative plugin source path")
assert(Fonts.fontName(canonical[bundled]) == relative, "absolute plugin source path")
package.loaded.fontlist.fontdir = "/runtime/fonts"
assert(Fonts.fontName("/qa/plugins/weui.koplugin/fonts/PaperSong.ttf")
    == "../../workspace/weui.koplugin/fonts/PaperSong.ttf", "symlink outside runtime")
assert(Fonts.fontName("/runtime/fonts/custom/title.ttf") == "custom/title.ttf", "font root descendant")
assert(Fonts.fontName("/runtime/fonts-extra/title.ttf") == "../fonts-extra/title.ttf", "partial directory match")
assert(Fonts.fontName("missing.ttf") == nil, "missing bundle")
package.loaded.fontlist.fontdir = "./fonts"
local fallback = "NotoSansCJKsc-Regular.otf"
local face = Fonts.bundledFace(bundled, fallback)
assert(face(33).realname == relative and calls[#calls].size == 33, "bundled face or logical size")
unsupported = true
calls = {}
face = Fonts.bundledFace(bundled, fallback)
assert(face(33).realname == fallback, "unsupported bundle fallback")
assert(face(20).realname == fallback and #calls == 3, "failed bundle retried after fallback")
assert(calls[3].size == 20, "fallback size lost")
calls = {}
assert(Fonts.bundledFace("missing.ttf", fallback)(33).realname == fallback and #calls == 1,
    "missing bundle triggered font enumeration")
package.loaded.fontlist.fontdir = "missing-root"
assert(Fonts.fontName(bundled) == nil, "unavailable font root")
print("FONT_PATHS_OK: relative/absolute sources, symlinks, font roots, missing/unsupported fallback")

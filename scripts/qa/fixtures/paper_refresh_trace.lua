-- Capture every native refresh, including forceRePaint inside an action.
-- Hook SDL's final render: UIManager may already have cached refresh methods.
local Screen = require("device").screen
local M = { stage = "boot", frames = 0, violations = {} }
local root = assert(os.getenv("WEUI_PAPER_QA_ROOT"))
local lfs = require("libs/libkoreader-lfs")
assert(lfs.mkdir(root .. "/artifacts/frames"))
local log = assert(io.open(root .. "/artifacts/refreshes.tsv", "w"))
log:write("frame\tstage\tmode\tvisible\twidgets\n")
local original = assert(Screen._render, "refresh trace requires the native SDL renderer")
Screen._render = function(self, bb, ...)
        local result = original(self, bb, ...)
        local manager = package.loaded["ui/uimanager"]
        if manager then
            local stack, visible = {}, "none"
            local modes = {}
            for _, refresh in ipairs(manager._refresh_stack) do modes[#modes + 1] = refresh.mode end
            for _, entry in ipairs(manager._window_stack) do
                local w = entry.widget
                local label = w._weui_paper_return_blocker and "reader-snapshot"
                    or w.screen or w.name or (w.file_chooser and "filemanager")
                    or (w.text and "dialog") or "overlay"
                stack[#stack + 1] = label
                if w.covers_fullscreen then visible = label end
            end
            if visible == "filemanager" and (M.stage:match("^19%-") or M.stage:match("^22%-")
                    or M.stage:match("^43%-") or M.stage:match("^66%-")
                    or M.stage:match("^76[bdfgik]%-") or M.stage:match("^96%-")
                    or M.stage:match("^105%-")) then
                M.violations[M.stage] = "native file manager painted during paper return"
            end
            M.frames = M.frames + 1
            local filename = string.format("%05d-%s.png", M.frames, M.stage)
            log:write(filename, "\t", M.stage, "\t", table.concat(modes, ","), "\t", visible, "\t", table.concat(stack, ">"), "\n")
            log:flush()
            assert(bb:writePNG(root .. "/artifacts/frames/" .. filename))
        end
        return result
end
return M

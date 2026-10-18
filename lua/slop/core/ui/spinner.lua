--# selene: allow(unused_variable)
--- Spinner frames + ticking timer (main-loop callbacks). OWNER: edit. STATUS: stub.
---@class slop.ui.spinner
local M = {}

---@class slop.spinner.Opts
---@field style? string                    default config ui.spinner ("dots")
---@field interval? integer                ms, default 80
---@field on_tick fun(frame: string)       called on the main loop

---@class slop.Spinner
---@field start fun(self: slop.Spinner)
---@field stop fun(self: slop.Spinner)
---@field frame fun(self: slop.Spinner): string
---@field is_running fun(self: slop.Spinner): boolean

---@param opts slop.spinner.Opts
---@return slop.Spinner
function M.new(opts)
  error("slop: core.ui.spinner.new not implemented yet", 2)
end

--- Frames of a style.
---@param style? string
---@return string[]
function M.frames(style)
  error("slop: core.ui.spinner.frames not implemented yet", 2)
end

return M

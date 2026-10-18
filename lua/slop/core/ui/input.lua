--# selene: allow(unused_variable)
--- Multi-line prompt float (anchored at a buffer position or centered). OWNER: edit. STATUS: stub.
--- Keys: <C-s> submit (insert/normal), <CR> submit (normal), <Esc>/q cancel (normal).
---@class slop.ui.input
local M = {}

---@class slop.input.Opts
---@field title? string
---@field default? string|string[]
---@field anchor? {buf: integer, row: integer, col?: integer}   float follows this position (default: centered)
---@field width? slop.float.Size
---@field height? slop.float.Size          initial; grows with content
---@field filetype? string                 default "slopprompt"
---@field history? string                  history key (persisted per project via core.project.state)
---@field complete? fun(lead: string, line: string): string[]   e.g. #preset / @file items
---@field footer? string                   key hints
---@field on_submit fun(text: string)
---@field on_cancel? fun()

---@class slop.input.Handle
---@field buf integer
---@field win integer
---@field close fun(self: slop.input.Handle)

---@param opts slop.input.Opts
---@return slop.input.Handle
function M.open(opts)
  error("slop: core.ui.input.open not implemented yet", 2)
end

return M

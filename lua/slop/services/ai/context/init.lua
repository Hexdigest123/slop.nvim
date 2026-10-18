--# selene: allow(unused_variable)
--- Context gathering for AI requests (FIM: header, scope, neighbours, recent edits, ring; budgeted).
--- OWNER: complete. STATUS: stub (interface only). Everything returned is already redacted via core.secrets.
---@class slop.ai.context
local M = {}

---@class slop.ai.Context
---@field prompt string                   assembled prefix side (header + scope + neighbours + edits + prefix)
---@field suffix string
---@field parts table<string, string>     individual parts (header, scope, neighbors, edits, prefix) for debugging
---@field blocked? boolean                true when the buffer is blocked (caller must not send)

---@class slop.ai.ContextOpts
---@field scope? boolean
---@field neighbors? boolean
---@field recent_edits? boolean
---@field ring? boolean
---@field budget? integer|"auto"          characters

--- Build FIM context for `buf` at (row, col) (0-based).
---@param buf integer
---@param row integer
---@param col integer
---@param opts? slop.ai.ContextOpts
---@return slop.ai.Context
function M.fim(buf, row, col, opts)
  error("slop: services.ai.context.fim not implemented yet", 2)
end

return M

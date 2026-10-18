--# selene: allow(unused_variable)
--- Treesitter helpers (native vim.treesitter only). OWNER: complete. STATUS: stub (interface only).
---@class slop.ts
local M = {}

---@class slop.ts.Scope
---@field node TSNode
---@field kind "function"|"method"|"class"|"block"|string
---@field name? string
---@field range slop.Range               0-based {srow, scol, erow, ecol}
---@field header string[]                signature line(s) of the scope

---@param buf integer
---@return string? lang                  parser language if a parser is available
function M.lang(buf)
  error("slop: core.ts.lang not implemented yet", 2)
end

---@param buf integer
---@return boolean
function M.has_parser(buf)
  error("slop: core.ts.has_parser not implemented yet", 2)
end

--- Smallest enclosing function/class-like scope at `pos` (0-based {row, col}; default cursor).
---@param buf integer
---@param pos? {[1]: integer, [2]: integer}
---@param opts? {kinds?: string[]}
---@return slop.ts.Scope?
function M.scope(buf, pos, opts)
  error("slop: core.ts.scope not implemented yet", 2)
end

--- All enclosing scopes, outermost first.
---@param buf integer
---@param pos? {[1]: integer, [2]: integer}
---@return slop.ts.Scope[]
function M.scopes(buf, pos)
  error("slop: core.ts.scopes not implemented yet", 2)
end

--- Is `pos` inside an empty block body (multi-line completion hint)?
---@param buf integer
---@param pos? {[1]: integer, [2]: integer}
---@return boolean
function M.in_empty_block(buf, pos)
  error("slop: core.ts.in_empty_block not implemented yet", 2)
end

return M

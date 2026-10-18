--# selene: allow(unused_variable)
--- Ghost text (virtual text suggestions) + partial accept. OWNER: complete. STATUS: stub (interface only).
--- Used by complete (insert mode) and commit (gitcommit buffer, line 1). One suggestion per buffer.
--- Rendering: first line virt_text inline, rest virt_lines; hl "SlopGhost". Accept = one undo step.
---@class slop.ui.ghost
local M = {}

---@class slop.ghost.Opts
---@field hl? string                       default "SlopGhost"
---@field on_accept? fun(text: string, kind: "all"|"word"|"line"|"lines")
---@field on_clear? fun()
---@field id? any                          caller tag (e.g. request id) returned by get()

---@class slop.ghost.State
---@field buf integer
---@field row integer                      0-based
---@field col integer                      0-based byte col
---@field lines string[]
---@field id? any

--- Show `text` at (row, col) in `buf`, replacing any current ghost text there.
---@param buf integer
---@param row integer
---@param col integer
---@param text string|string[]
---@param opts? slop.ghost.Opts
function M.show(buf, row, col, text, opts)
  error("slop: core.ui.ghost.show not implemented yet", 2)
end

---@param buf? integer                     default current
function M.clear(buf)
  error("slop: core.ui.ghost.clear not implemented yet", 2)
end

---@param buf? integer
---@return boolean
function M.is_visible(buf)
  return false
end

---@param buf? integer
---@return slop.ghost.State?
function M.get(buf)
  return nil
end

--- Insert the whole suggestion. Returns false when nothing is visible (so keymaps can fall through).
---@param buf? integer
---@return boolean
function M.accept(buf)
  return false
end

---@param buf? integer
---@return boolean
function M.accept_word(buf)
  return false
end

---@param buf? integer
---@return boolean
function M.accept_line(buf)
  return false
end

---@param n? integer                       default vim.v.count1
---@param buf? integer
---@return boolean
function M.accept_n_lines(n, buf)
  return false
end

return M

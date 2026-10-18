--# selene: allow(unused_variable)
--- Named, reusable scratch buffers ("slop://<name>") and windows to show them in.
--- OWNER: rest. STATUS: stub (interface only).
---@class slop.ui.scratch
local M = {}

---@class slop.scratch.BufOpts
---@field filetype? string
---@field modifiable? boolean             default false
---@field secret_path? string             sets vim.b.slop_secret_path (core.secrets / cloak effective path)

---@class slop.scratch.OpenOpts: slop.scratch.BufOpts
---@field layout? "vsplit"|"split"|"float"|"tab"|"current"  default "vsplit"
---@field enter? boolean                  focus the window (default false: focus stays in the source)
---@field size? integer|number            split size (cells or fraction)
---@field float? slop.float.Opts

--- Get (or create) the named scratch buffer: buftype=nofile, bufhidden=hide, noswapfile.
---@param name string
---@param opts? slop.scratch.BufOpts
---@return integer buf
function M.get(name, opts)
  error("slop: core.ui.scratch.get not implemented yet", 2)
end

--- Show the named scratch buffer, reusing a window that already shows it.
---@param name string
---@param opts? slop.scratch.OpenOpts
---@return integer buf, integer win
function M.open(name, opts)
  error("slop: core.ui.scratch.open not implemented yet", 2)
end

--- Replace the buffer's lines (handles 'modifiable').
---@param buf integer
---@param lines string[]
function M.set_lines(buf, lines)
  error("slop: core.ui.scratch.set_lines not implemented yet", 2)
end

--- Set the winbar of every window showing `buf` (statusline syntax).
---@param buf integer
---@param text string
function M.set_winbar(buf, text)
  error("slop: core.ui.scratch.set_winbar not implemented yet", 2)
end

---@param name string
function M.close(name)
  error("slop: core.ui.scratch.close not implemented yet", 2)
end

return M

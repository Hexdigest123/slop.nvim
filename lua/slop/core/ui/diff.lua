--# selene: allow(unused_variable)
--- Inline diff preview with per-hunk accept/reject. OWNER: edit. STATUS: stub (interface only).
--- Used by edit (agent replacement) and rest (AI gen/fix into a possibly non-current buffer).
--- Accept applies with nvim_buf_set_text in one undo block; hunks are tracked with extmarks.
---@class slop.ui.diff
local M = {}

---@class slop.diff.Hunk
---@field index integer
---@field old_start integer                0-based row in the original range
---@field old_count integer
---@field new_lines string[]
---@field state "pending"|"accepted"|"rejected"

---@class slop.diff.Opts
---@field keymaps? table<string, string|false>  accept, reject, accept_all, reject_all, next, prev, refine (buffer-local)
---@field on_refine? fun(handle: slop.diff.Handle)
---@field on_done? fun(result: "accepted"|"rejected"|"partial", handle: slop.diff.Handle)
---@field conflict? boolean                region changed while in flight: require explicit accept, show warning
---@field title? string                    virt-text label

---@class slop.diff.Handle
---@field buf integer
---@field hunks fun(self: slop.diff.Handle): slop.diff.Hunk[]
---@field accept fun(self: slop.diff.Handle, index?: integer)   default: hunk under cursor
---@field reject fun(self: slop.diff.Handle, index?: integer)
---@field accept_all fun(self: slop.diff.Handle)
---@field reject_all fun(self: slop.diff.Handle)
---@field next fun(self: slop.diff.Handle)
---@field prev fun(self: slop.diff.Handle)
---@field close fun(self: slop.diff.Handle)                     clears marks/keymaps (pending hunks rejected)
---@field is_active fun(self: slop.diff.Handle): boolean

--- Preview replacing rows [range[1], range[2]) (0-based, end-exclusive; equal = pure insertion) of `buf`
--- with `new_lines`. `buf` may be any loaded buffer (bufload()ed if needed).
---@param buf integer
---@param range {[1]: integer, [2]: integer}
---@param new_lines string[]
---@param opts? slop.diff.Opts
---@return slop.diff.Handle
function M.show(buf, range, new_lines, opts)
  error("slop: core.ui.diff.show not implemented yet", 2)
end

--- Pure: line hunks between two line lists (vim.text.diff indices).
---@param old string[]
---@param new string[]
---@return slop.diff.Hunk[]
function M.compute(old, new)
  error("slop: core.ui.diff.compute not implemented yet", 2)
end

--- Active diff handles in a buffer.
---@param buf integer
---@return slop.diff.Handle[]
function M.list(buf)
  return {}
end

return M

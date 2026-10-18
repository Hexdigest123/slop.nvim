--# selene: allow(unused_variable)
--- Generic picker: fzf-lua (with preview) when installed, else a built-in float picker
--- (prompt + list + preview, matchfuzzypos), vim.ui.select as last resort. Backend from config ui.picker.
--- OWNER: rest. STATUS: stub (interface only).
---@class slop.ui.picker
local M = {}

---@class slop.picker.Preview
---@field lines? string[]                 literal preview content
---@field path? string                    or preview a file ...
---@field lnum? integer                   ... at this line (1-based)
---@field filetype? string

---@class slop.picker.Opts
---@field prompt? string
---@field format? fun(item: any): string|{[1]: string, [2]: string?}[]  display text or {text, hl} chunks
---                                       default: item.text or tostring(item)
---@field preview? fun(item: any): slop.picker.Preview?
---@field on_select fun(item: any?, action: string?)  item nil when cancelled; action = key of `actions`
---@field actions? table<string, string>  extra keys -> action name passed to on_select, e.g. { ["<C-v>"] = "vsplit" }
---@field backend? "auto"|"fzf"|"builtin"|"select"  override config ui.picker

--- Pick one of `items` (list, or a function producing them asynchronously: fun(cb: fun(items: any[]))).
---@param items any[]|fun(cb: fun(items: any[]))
---@param opts slop.picker.Opts
function M.pick(items, opts)
  error("slop: core.ui.picker.pick not implemented yet", 2)
end

return M

--# selene: allow(unused_variable)
--- Floating windows. OWNER: term. STATUS: stub (interface only).
--- Every slop float goes through here and is ALWAYS bordered with config `ui.border` (default "rounded").
---@class slop.ui.float
local M = {}

---@alias slop.float.Size number|fun(columns: integer, lines: integer): integer
---  (0, 1] = fraction of the editor, > 1 = cells, function = computed

---@class slop.float.Opts
---@field buf? integer                   buffer to show (default: new scratch buffer, bufhidden=wipe)
---@field width? slop.float.Size         default 0.8
---@field height? slop.float.Size        default 0.8
---@field min_width? integer
---@field min_height? integer
---@field relative? "editor"|"cursor"|"win"  default "editor" (centered)
---@field win? integer                   for relative = "win"
---@field bufpos? integer[]              {row, col} anchor in `win` (float follows the text)
---@field row? number
---@field col? number
---@field anchor? "NW"|"NE"|"SW"|"SE"
---@field border? string|string[]        default config ui.border
---@field title? string|{[1]: string, [2]: string}[]
---@field title_pos? "left"|"center"|"right"
---@field footer? string|{[1]: string, [2]: string}[]
---@field footer_pos? "left"|"center"|"right"
---@field enter? boolean                 focus it (default true)
---@field style? "minimal"|false         default "minimal"
---@field zindex? integer
---@field focusable? boolean
---@field wo? table<string, any>         window-local options (winhighlight defaults to Slop* groups)
---@field bo? table<string, any>         buffer-local options
---@field close_keys? string[]           normal-mode keys that close it (e.g. { "q", "<Esc>" })
---@field close_on_leave? boolean        close on WinLeave
---@field responsive? boolean            recompute size on VimResized (default true)
---@field on_close? fun()

---@class slop.float.Handle
---@field buf integer
---@field win integer
---@field close fun(self: slop.float.Handle)
---@field is_valid fun(self: slop.float.Handle): boolean
---@field update fun(self: slop.float.Handle, opts: slop.float.Opts)  re-layout / retitle
---@field focus fun(self: slop.float.Handle)

--- Open a float.
---@param opts? slop.float.Opts
---@return slop.float.Handle
function M.open(opts)
  error("slop: core.ui.float.open not implemented yet", 2)
end

--- Resolve a size spec against a total.
---@param size slop.float.Size
---@param total integer
---@return integer
function M.resolve_size(size, total)
  if type(size) == "function" then
    return math.floor(size(vim.o.columns, vim.o.lines))
  end
  if size <= 1 then
    return math.floor(total * size)
  end
  return math.floor(size)
end

--- Effective border: config ui.border.
---@return string|string[]
function M.border()
  return require("slop.config").get("ui").border
end

return M

--- Small shared helpers: async/timing, tables, strings, highlights, augroups, extmarks.
---@class slop.util
local M = {}

local api = vim.api
local uv = vim.uv

-- Async / timing -------------------------------------------------------------------------------

---@class slop.util.Debounced
---@field cancel fun(self)          Drop a pending call.
---@field flush fun(self)           Run a pending call now.
---@field pending fun(self): boolean
---@field close fun(self)           Cancel and free the timer.
---@overload fun(...)

--- Trailing-edge debounce: the last call wins and runs `ms` after the last invocation, on the main loop.
--- Never drops the final call (no throttling).
---@param fn fun(...)
---@param ms integer
---@return slop.util.Debounced
function M.debounce(fn, ms)
  local timer = assert(uv.new_timer())
  local args, n = nil, 0
  local obj = {}
  local function run()
    if not args then
      return
    end
    local a, c = args, n
    args = nil
    fn(unpack(a, 1, c))
  end
  function obj:cancel()
    timer:stop()
    args = nil
  end
  function obj:flush()
    timer:stop()
    run()
  end
  function obj:pending()
    return args ~= nil
  end
  function obj:close()
    obj:cancel()
    if not timer:is_closing() then
      timer:close()
    end
  end
  return setmetatable(obj, {
    __call = function(_, ...)
      args, n = { ... }, select("#", ...)
      timer:stop()
      timer:start(ms, 0, vim.schedule_wrap(run))
    end,
  })
end

--- vim.schedule_wrap re-export (wrap luv/vim.system callbacks before touching the editor).
M.schedule_wrap = vim.schedule_wrap

--- Run `fn` now if on the main loop, else schedule it.
---@param fn fun()
function M.main(fn)
  if vim.in_fast_event() then
    vim.schedule(fn)
  else
    fn()
  end
end

-- Tables ---------------------------------------------------------------------------------------

--- Safe nested get: tbl_get(t, "a", "b") or tbl_get(t, "a.b").
---@param t table?
---@return any
function M.tbl_get(t, ...)
  local keys = { ... }
  if #keys == 1 and type(keys[1]) == "string" and keys[1]:find(".", 1, true) then
    keys = vim.split(keys[1], ".", { plain = true })
  end
  local cur = t
  for _, k in ipairs(keys) do
    if type(cur) ~= "table" then
      return nil
    end
    cur = cur[k]
  end
  return cur
end

--- Nested set creating intermediate tables. `path` is "a.b.c" or { "a", "b", "c" }.
---@param t table
---@param path string|string[]
---@param value any
function M.tbl_set(t, path, value)
  local keys = type(path) == "string" and vim.split(path, ".", { plain = true }) or path
  local cur = t
  for i = 1, #keys - 1 do
    if type(cur[keys[i]]) ~= "table" then
      cur[keys[i]] = {}
    end
    cur = cur[keys[i]]
  end
  cur[keys[#keys]] = value
end

--- Deep merge (later wins); lists are replaced, not index-merged.
---@return table
function M.merge(...)
  return vim.tbl_deep_extend("force", {}, ...)
end

--- Filter `items` to those starting with `lead` (sorted) — the usual subcommand `complete()` body.
---@param items string[]
---@param lead string
---@return string[]
function M.complete_prefix(items, lead)
  local out = {}
  for _, s in ipairs(items) do
    if vim.startswith(s, lead or "") then
      out[#out + 1] = s
    end
  end
  table.sort(out)
  return out
end

--- Remove duplicates keeping first occurrence order.
---@generic T
---@param list T[]
---@return T[]
function M.uniq(list)
  local seen, out = {}, {}
  for _, v in ipairs(list) do
    if not seen[v] then
      seen[v] = true
      out[#out + 1] = v
    end
  end
  return out
end

-- Strings --------------------------------------------------------------------------------------

---@param s string
---@return string
function M.pascal(s)
  return require("slop.core.events").pascal(s)
end

---@param text string
---@return string[]
function M.lines(text)
  return vim.split(text, "\n", { plain = true })
end

-- Augroups / namespaces / highlights -----------------------------------------------------------

--- The module's augroup "slop.<name>" (not cleared). Registry replays lazy-load trigger events into it,
--- so modules should create their autocmds in this group.
---@param name string
---@param clear? boolean
---@return integer
function M.augroup(name, clear)
  return api.nvim_create_augroup("slop." .. name, { clear = clear == true })
end

local namespaces = {}
--- Cached namespace "slop.<name>".
---@param name string
---@return integer
function M.ns(name)
  namespaces[name] = namespaces[name] or api.nvim_create_namespace("slop." .. name)
  return namespaces[name]
end

local hl_groups = {} ---@type table<string, vim.api.keyset.highlight>

--- Define highlight groups with default = true; re-applied on ColorScheme.
---@param groups table<string, vim.api.keyset.highlight>
function M.hl(groups)
  for name, val in pairs(groups or {}) do
    val = vim.deepcopy(val)
    val.default = true
    hl_groups[name] = val
    api.nvim_set_hl(0, name, val)
  end
end

--- Re-apply every group registered via util.hl() (called from the ColorScheme autocmd).
function M.reapply_hl()
  for name, val in pairs(hl_groups) do
    api.nvim_set_hl(0, name, val)
  end
end

-- Buffers / extmarks ---------------------------------------------------------------------------

---@param buf integer?
---@return boolean
function M.buf_valid(buf)
  return type(buf) == "number" and api.nvim_buf_is_valid(buf) and api.nvim_buf_is_loaded(buf)
end

--- A guard that returns true while `buf` is valid and its changedtick has not moved.
--- Re-check this in every async callback before touching the buffer.
---@param buf integer
---@return fun(): boolean
function M.tick_guard(buf)
  buf = buf == 0 and api.nvim_get_current_buf() or buf
  local tick = api.nvim_buf_get_changedtick(buf)
  return function()
    return M.buf_valid(buf) and api.nvim_buf_get_changedtick(buf) == tick
  end
end

---@class slop.Range
---@field [1] integer start row (0-based)
---@field [2] integer start col (0-based, bytes)
---@field [3] integer end row (0-based)
---@field [4] integer end col (0-based, exclusive)

--- Create a region extmark that tracks edits (left-gravity start, right-gravity end).
---@param buf integer
---@param ns integer
---@param range slop.Range
---@param opts? vim.api.keyset.set_extmark  extra extmark options
---@return integer id
function M.region_mark(buf, ns, range, opts)
  local o = vim.tbl_extend("force", {
    end_row = range[3],
    end_col = range[4],
    right_gravity = false,
    end_right_gravity = true,
    strict = false,
  }, opts or {})
  return api.nvim_buf_set_extmark(buf, ns, range[1], range[2], o)
end

--- Current range of an extmark, or nil if the buffer/extmark is gone.
---@param buf integer
---@param ns integer
---@param id integer
---@return slop.Range?
function M.mark_range(buf, ns, id)
  if not M.buf_valid(buf) then
    return nil
  end
  local m = api.nvim_buf_get_extmark_by_id(buf, ns, id, { details = true })
  if not m or #m == 0 then
    return nil
  end
  local d = m[3] or {}
  if d.invalid then
    return nil
  end
  return { m[1], m[2], d.end_row or m[1], d.end_col or m[2] }
end

--- Is the extmark still present (and not invalidated)?
---@param buf integer
---@param ns integer
---@param id integer
---@return boolean
function M.mark_valid(buf, ns, id)
  return M.mark_range(buf, ns, id) ~= nil
end

--- Text of a range as lines.
---@param buf integer
---@param range slop.Range
---@return string[]
function M.range_text(buf, range)
  return api.nvim_buf_get_text(buf, range[1], range[2], range[3], range[4], {})
end

--- Range of the last/current visual selection (charwise, end exclusive), 0-based.
---@param buf? integer
---@return slop.Range
function M.visual_range(buf)
  buf = buf or 0
  local mode = vim.fn.mode()
  local s, e
  if mode:match("^[vV\22]") then
    s, e = vim.fn.getpos("v"), vim.fn.getpos(".")
  else
    s, e = vim.fn.getpos("'<"), vim.fn.getpos("'>")
    mode = vim.fn.visualmode()
  end
  if s[2] > e[2] or (s[2] == e[2] and s[3] > e[3]) then
    s, e = e, s
  end
  local srow, erow = s[2] - 1, e[2] - 1
  if mode == "V" then
    local last = api.nvim_buf_get_lines(buf, erow, erow + 1, false)[1] or ""
    return { srow, 0, erow, #last }
  end
  local line = api.nvim_buf_get_lines(buf, erow, erow + 1, false)[1] or ""
  local ecol = math.min(e[3], #line)
  -- include the full last (multi-byte) character
  if ecol > 0 and ecol <= #line then
    local char = vim.fn.strpart(line, ecol - 1, 1, true)
    ecol = ecol - 1 + #char
  end
  return { srow, s[3] - 1, erow, ecol }
end

return M

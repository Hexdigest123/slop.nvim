--- Floating windows. OWNER: term.
--- Every slop float goes through here and is ALWAYS bordered with config `ui.border` (default "rounded").
---
---   local h = require("slop.core.ui.float").open({ title = "Prompt", width = 60, height = 5, close_keys = { "q" } })
---   h:update({ footer = "3 items" })   h:close()
---
--- Sizes are the CONTENT size (the border is extra). Editor-relative floats are centered and re-laid out on
--- VimResized (fractions / functions are re-evaluated) unless `responsive = false`.
---@class slop.ui.float
local M = {}

local api = vim.api

---@alias slop.float.Size number|fun(columns: integer, lines: integer): integer
---  (0, 1] = fraction of the editor, > 1 = cells, function = computed

---@class slop.float.Opts
---@field buf? integer                   buffer to show (default: new scratch buffer, bufhidden=wipe)
---@field width? slop.float.Size         default 0.8
---@field height? slop.float.Size        default 0.8
---@field min_width? integer
---@field min_height? integer
---@field relative? "editor"|"cursor"|"win"|"region"  default "editor" (centered)
---@field win? integer                   for relative = "win" / "region" (default: the window current at open())
---@field bufpos? integer[]              {row, col} anchor in `win` (float follows the text)
---@field region? slop.Range             for relative = "region": shown below the region (above if no room)
---@field row? number
---@field col? number
---@field anchor? "NW"|"NE"|"SW"|"SE"
---@field border? string|string[]        default config ui.border ("none" is coerced to "rounded")
---@field title? string|{[1]: string, [2]: string}[]
---@field title_pos? "left"|"center"|"right"
---@field footer? string|{[1]: string, [2]: string}[]
---@field footer_pos? "left"|"center"|"right"
---@field enter? boolean                 focus it (default true)
---@field style? "minimal"|false         default "minimal"
---@field zindex? integer
---@field focusable? boolean
---@field noautocmd? boolean
---@field wo? table<string, any>         window-local options (winhighlight defaults to Slop* groups)
---@field bo? table<string, any>         buffer-local options
---@field close_keys? string[]           normal-mode keys that close it (e.g. { "q", "<Esc>" })
---@field close_on_leave? boolean        close on WinLeave
---@field responsive? boolean            recompute size on VimResized (default true)
---@field on_close? fun()                called once, however the window gets closed

---@class slop.float.Handle
---@field buf integer
---@field win integer
---@field opts slop.float.Opts
---@field private _own boolean           buffer created by open()
---@field private _au integer[]
---@field private _closed boolean
---@field private _keys {key: string, fn: function, saved: table?}[]  close_keys mapped on a caller's buffer
local Handle = {}
Handle.__index = Handle

local DEFAULT_WINHL = "NormalFloat:SlopNormal,FloatBorder:SlopBorder,FloatTitle:SlopTitle,FloatFooter:SlopFooter"

local handles = {} ---@type table<integer, slop.float.Handle>
local group ---@type integer?

local function augroup()
  group = group or api.nvim_create_augroup("slop.float", { clear = true })
  return group
end

-- Sizing ---------------------------------------------------------------------------------------

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

--- Effective border: opts.border or config ui.border; never borderless.
---@param border? string|string[]
---@return string|string[]
function M.border(border)
  local b = border
  if b == nil then
    local ok, ui = pcall(function()
      return require("slop.config").get("ui")
    end)
    b = ok and ui and ui.border or "rounded"
  end
  if b == "none" or b == "" or b == false then
    b = "rounded"
  end
  return b
end

local function clamp(v, lo, hi)
  return math.max(lo, math.min(v, hi))
end

---@param s any
---@return any
local function pad(s)
  if type(s) == "string" and s ~= "" and not s:match("^%s") then
    return " " .. s .. " "
  end
  return s
end

--- Editor area available to floats (columns, lines without the command line).
---@return integer columns, integer lines
local function editor_size()
  return vim.o.columns, math.max(1, vim.o.lines - vim.o.cmdheight)
end

--- Build the nvim_open_win() config for `opts`.
---@param opts slop.float.Opts
---@return vim.api.keyset.win_config
function M.config(opts)
  opts = opts or {}
  local cols, lines = editor_size()
  local maxw, maxh = math.max(1, cols - 2), math.max(1, lines - 2)
  local w = M.resolve_size(opts.width or 0.8, cols)
  local h = M.resolve_size(opts.height or 0.8, lines)
  w = clamp(math.max(w, opts.min_width or 1), 1, maxw)
  h = clamp(math.max(h, opts.min_height or 1), 1, maxh)

  ---@type vim.api.keyset.win_config
  local c = {
    width = w,
    height = h,
    border = M.border(opts.border),
    zindex = opts.zindex,
    focusable = opts.focusable,
    anchor = opts.anchor,
  }
  if opts.style ~= false then
    c.style = opts.style or "minimal"
  end
  if opts.noautocmd then
    c.noautocmd = true
  end
  if opts.title and opts.title ~= "" then
    c.title = pad(opts.title)
    c.title_pos = opts.title_pos or "center"
  end
  if opts.footer and opts.footer ~= "" then
    c.footer = pad(opts.footer)
    c.footer_pos = opts.footer_pos or "center"
  end

  local rel = opts.relative or "editor"
  if rel == "editor" then
    c.relative = "editor"
    c.row = opts.row or math.max(0, math.floor((lines - h - 2) / 2))
    c.col = opts.col or math.max(0, math.floor((cols - w - 2) / 2))
  elseif rel == "cursor" then
    c.relative = "cursor"
    c.row = opts.row or 1
    c.col = opts.col or 0
  elseif rel == "win" then
    c.relative = "win"
    c.win = opts.win or api.nvim_get_current_win()
    c.bufpos = opts.bufpos
    c.row = opts.row or (opts.bufpos and 1 or 0)
    c.col = opts.col or 0
  elseif rel == "region" then
    local win = opts.win or api.nvim_get_current_win()
    local r = assert(opts.region, "slop: float: relative = 'region' needs opts.region")
    c.relative = "win"
    c.win = win
    -- below the last line of the region, unless it would not fit on screen
    local pos = vim.fn.screenpos(win, r[3] + 1, 1)
    local fits_below = pos.row == 0 or (pos.row + h + 2 <= lines)
    if fits_below then
      c.bufpos = { r[3], 0 }
      c.anchor = opts.anchor or "NW"
      c.row = opts.row or 1
    else
      c.bufpos = { r[1], 0 }
      c.anchor = opts.anchor or "SW"
      c.row = opts.row or 0
    end
    c.col = opts.col or r[2]
  else
    error("slop: float: invalid relative '" .. tostring(rel) .. "'", 2)
  end
  return c
end

-- Handles --------------------------------------------------------------------------------------

---@return boolean
function Handle:is_valid()
  return self.win ~= nil and api.nvim_win_is_valid(self.win)
end

function Handle:close()
  if self:is_valid() then
    pcall(api.nvim_win_close, self.win, true)
  end
  self:_finish()
end

function Handle:focus()
  if self:is_valid() then
    api.nvim_set_current_win(self.win)
  end
end

--- Merge `opts` into the stored options and re-apply layout, title and footer.
---@param opts? slop.float.Opts
function Handle:update(opts)
  if opts then
    self.opts = vim.tbl_extend("force", self.opts, opts)
  end
  if not self:is_valid() then
    return
  end
  local c = M.config(self.opts)
  c.noautocmd = nil
  c.style = nil
  if c.title == nil then
    c.title = ""
  end
  if c.footer == nil then
    c.footer = ""
  end
  pcall(api.nvim_win_set_config, self.win, c)
end

---@private
function Handle:_finish()
  if self._closed then
    return
  end
  self._closed = true
  handles[self.win] = nil
  for _, id in ipairs(self._au) do
    pcall(api.nvim_del_autocmd, id)
  end
  if not self._own and api.nvim_buf_is_valid(self.buf) then
    -- a caller's buffer: remove our close keys (unless mapped anew since) and give back the buffer's own mappings
    for _, k in ipairs(self._keys) do
      local cur = api.nvim_buf_call(self.buf, function()
        return vim.fn.maparg(k.key, "n", false, true)
      end)
      if type(cur) == "table" and cur.callback == k.fn then
        pcall(vim.keymap.del, "n", k.key, { buf = self.buf })
        if k.saved then
          pcall(api.nvim_buf_call, self.buf, function()
            vim.fn.mapset("n", false, k.saved)
          end)
        end
      end
    end
  end
  if self.opts.on_close then
    local ok, err = pcall(self.opts.on_close)
    if not ok then
      require("slop.core.log").error("float on_close: %s", err)
    end
  end
end

local resize_au ---@type integer?

local function ensure_resize()
  if resize_au then
    return
  end
  resize_au = api.nvim_create_autocmd("VimResized", {
    group = augroup(),
    desc = "slop: re-layout floats",
    callback = function()
      M.relayout()
    end,
  })
end

--- Re-layout every responsive editor-relative float (what VimResized runs).
function M.relayout()
  for _, h in pairs(handles) do
    local rel = h.opts.relative or "editor"
    if h.opts.responsive ~= false and rel == "editor" then
      h:update()
    end
  end
end

--- Open a float.
---@param opts? slop.float.Opts
---@return slop.float.Handle
function M.open(opts)
  opts = vim.tbl_extend("force", {}, opts or {})
  if (opts.relative == "win" or opts.relative == "region") and not opts.win then
    -- pin the default "current window" now: update() would re-resolve it to whatever is current then (the
    -- float itself once focused -> "floating window cannot be relative to itself")
    opts.win = api.nvim_get_current_win()
  end
  local buf, own = opts.buf, false
  if not (buf and api.nvim_buf_is_valid(buf)) then
    buf = api.nvim_create_buf(false, true)
    vim.bo[buf].bufhidden = "wipe"
    own = true
  end
  for k, v in pairs(opts.bo or {}) do
    vim.bo[buf][k] = v
  end
  local win = api.nvim_open_win(buf, opts.enter ~= false, M.config(opts))
  local wo = vim.tbl_extend("force", { winhighlight = DEFAULT_WINHL }, opts.wo or {})
  for k, v in pairs(wo) do
    api.nvim_set_option_value(k, v, { win = win, scope = "local" })
  end

  local h =
    setmetatable({ buf = buf, win = win, opts = opts, _own = own, _au = {}, _closed = false, _keys = {} }, Handle)
  handles[win] = h

  h._au[#h._au + 1] = api.nvim_create_autocmd("WinClosed", {
    group = augroup(),
    pattern = tostring(win),
    once = true,
    desc = "slop: float closed",
    callback = function()
      h:_finish()
    end,
  })
  if opts.close_on_leave then
    h._au[#h._au + 1] = api.nvim_create_autocmd("WinLeave", {
      group = augroup(),
      desc = "slop: close float on leave",
      callback = function()
        if api.nvim_get_current_win() == h.win then
          vim.schedule(function()
            h:close()
          end)
        end
      end,
    })
  end
  for _, key in ipairs(opts.close_keys or {}) do
    local saved
    if not own then
      saved = api.nvim_buf_call(buf, function()
        return vim.fn.maparg(key, "n", false, true)
      end)
      if not (type(saved) == "table" and (saved.buf or saved.buffer) == 1) then
        saved = nil -- (not buffer-local)
      end
    end
    local function close()
      h:close()
    end
    require("slop.core.keymaps").set_buf(buf, "n", key, close, { desc = "close float", nowait = true })
    h._keys[#h._keys + 1] = { key = key, fn = close, saved = saved }
  end
  ensure_resize()
  return h
end

--- Handle of a slop float window.
---@param win integer
---@return slop.float.Handle?
function M.get(win)
  local h = handles[win == 0 and api.nvim_get_current_win() or win]
  return h and h:is_valid() and h or nil
end

--- Live slop floats.
---@return slop.float.Handle[]
function M.list()
  local out = {}
  for _, h in pairs(handles) do
    if h:is_valid() then
      out[#out + 1] = h
    end
  end
  table.sort(out, function(a, b)
    return a.win < b.win
  end)
  return out
end

--- Close a float by window id or handle (any floating window, slop's or not).
---@param target integer|slop.float.Handle
function M.close(target)
  if type(target) == "table" then
    target:close()
    return
  end
  local h = M.get(target)
  if h then
    h:close()
  elseif api.nvim_win_is_valid(target) and M.is_float(target) then
    pcall(api.nvim_win_close, target, true)
  end
end

--- Close every slop float.
function M.close_all()
  for _, h in ipairs(M.list()) do
    h:close()
  end
end

--- Is `win` a floating window?
---@param win integer
---@return boolean
function M.is_float(win)
  win = win == 0 and api.nvim_get_current_win() or win
  return api.nvim_win_is_valid(win) and api.nvim_win_get_config(win).relative ~= ""
end

return M

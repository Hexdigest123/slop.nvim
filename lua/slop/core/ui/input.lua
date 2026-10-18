--- Multi-line prompt float (anchored at a buffer region or centered). OWNER: edit.
---
--- Keys (buffer-local): <C-s> submit (insert/normal), <CR> submit (normal), <Esc>/q cancel (normal),
--- <C-c> cancel (insert/normal), <Up>/<Down> history (normal). Empty text cancels.
--- Leaving or closing the window cancels. Exactly one of on_submit/on_cancel runs.
--- Completion: typing a token that starts with a trigger character ("#", "@" by default) calls
--- `opts.complete(lead, line)` and shows the items with complete(); <C-x><C-u> also works (completefunc).
---@class slop.ui.input
local M = {}

local api = vim.api
local util = require("slop.core.util")

local MAX_HISTORY = 100
local MAX_HEIGHT = 10

util.hl({ SlopInputToken = { link = "SlopMatch" } })

---@class slop.input.Anchor
---@field buf integer
---@field row integer                      0-based
---@field col? integer
---@field end_row? integer                 last row of the region (float goes below it, or above `row`)

---@class slop.input.Opts
---@field title? string
---@field default? string|string[]
---@field anchor? slop.input.Anchor        float follows this region (default: centered)
---@field win? integer                     source window (default: current, or one showing anchor.buf)
---@field width? slop.float.Size
---@field height? slop.float.Size          initial; grows with content (max 10)
---@field filetype? string                 default "slopprompt"
---@field history? string                  history key (persisted per project via core.project.state)
---@field complete? fun(lead: string, line: string): (string|table)[]   e.g. #preset / @file items
---@field triggers? string[]               default { "#", "@" }
---@field footer? string                   key hints
---@field on_submit fun(text: string)
---@field on_cancel? fun()

---@class slop.input.Handle
---@field buf integer
---@field win integer
---@field private _float slop.float.Handle
---@field private _close fun()
local Handle = {}
Handle.__index = Handle

function Handle:close()
  self._close()
end

---@return string
function Handle:text()
  if not api.nvim_buf_is_valid(self.buf) then
    return ""
  end
  return table.concat(api.nvim_buf_get_lines(self.buf, 0, -1, false), "\n")
end

---@param text string|string[]
function Handle:set_text(text)
  if not api.nvim_buf_is_valid(self.buf) then
    return
  end
  local lines = type(text) == "table" and text or util.lines(text --[[@as string]])
  api.nvim_buf_set_lines(self.buf, 0, -1, false, lines)
  if api.nvim_win_is_valid(self.win) then
    local last = #lines
    api.nvim_win_set_cursor(self.win, { last, #(lines[last] or "") })
  end
end

-- History ------------------------------------------------------------------------------------------

local cache = {} ---@type table<string, table<string, string[]>>   path -> key -> entries

local function history_paths(buf)
  local ok, project = pcall(require, "slop.core.project")
  if not ok then
    return nil
  end
  local opts = buf and { buf = buf } or nil
  local okp, read = pcall(project.dir, opts or {}, "state", "ui", "input_history.json")
  if not okp then
    return nil
  end
  return read, project
end

local function load(buf)
  local path, project = history_paths(buf)
  if not path then
    return {}, nil
  end
  if not cache[path] then
    local data = vim.uv.fs_stat(path) and project.read_json(path) or nil
    cache[path] = type(data) == "table" and data or {}
  end
  return cache[path], path
end

--- History entries for `key` (newest first).
---@param key string
---@param buf? integer  project of this buffer (default current)
---@return string[]
function M.history(key, buf)
  local all = load(buf)
  return vim.list_slice(all[key] or {})
end

local function add_history(key, text, buf)
  local all, path = load(buf)
  local list = vim.tbl_filter(function(e)
    return e ~= text
  end, all[key] or {})
  table.insert(list, 1, text)
  while #list > MAX_HISTORY do
    table.remove(list)
  end
  all[key] = list
  if not path then
    return
  end
  pcall(function()
    local project = require("slop.core.project")
    local target = project.state("ui", "input_history.json", buf and { buf = buf } or nil)
    project.write_json(target, all)
  end)
end

-- Completion -----------------------------------------------------------------------------------------

local active = {} ---@type table<integer, slop.input.Opts>  buf -> opts

local function token_before(line, col, triggers)
  local before = line:sub(1, col)
  local start, tok = before:match("()(%S+)$")
  if not tok then
    return nil
  end
  local first = tok:sub(1, 1)
  for _, t in ipairs(triggers) do
    if first == t then
      return start, tok
    end
  end
end

local function items_for(opts, lead, line)
  if not opts.complete then
    return {}
  end
  local ok, items = pcall(opts.complete, lead, line)
  if not ok or type(items) ~= "table" then
    return {}
  end
  return items
end

--- completefunc (<C-x><C-u>) for prompt buffers.
---@param findstart integer
---@param base string
---@return integer|table
function M._completefunc(findstart, base)
  local buf = api.nvim_get_current_buf()
  local opts = active[buf]
  if findstart == 1 then
    if not opts then
      return -3
    end
    local line = api.nvim_get_current_line()
    local col = api.nvim_win_get_cursor(0)[2]
    local start = token_before(line, col, opts.triggers or { "#", "@" })
    return start and start - 1 or -3
  end
  if not opts then
    return {}
  end
  return items_for(opts, base, api.nvim_get_current_line())
end

local function auto_complete(buf, opts)
  if vim.fn.pumvisible() == 1 or not opts.complete then
    return
  end
  local line = api.nvim_get_current_line()
  local col = api.nvim_win_get_cursor(0)[2]
  local start, tok = token_before(line, col, opts.triggers or { "#", "@" })
  local nextc = line:sub(col + 1, col + 1)
  if not start or (nextc ~= "" and not nextc:match("%s")) then
    return
  end
  local items = items_for(opts, tok, line)
  if #items > 0 and api.nvim_get_current_buf() == buf and api.nvim_get_mode().mode:sub(1, 1) == "i" then
    vim.fn.complete(start, items)
  end
end

local function highlight_tokens(buf, triggers)
  local ns = util.ns("input")
  api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for row, line in ipairs(api.nvim_buf_get_lines(buf, 0, -1, false)) do
    for s, tok in line:gmatch("()(%S+)") do
      local first = tok:sub(1, 1)
      if #tok > 1 and vim.tbl_contains(triggers, first) and (s == 1 or line:sub(s - 1, s - 1):match("%s")) then
        api.nvim_buf_set_extmark(buf, ns, row - 1, s - 1, { end_col = s - 1 + #tok, hl_group = "SlopInputToken" })
      end
    end
  end
end

-- open --------------------------------------------------------------------------------------------------

local function cells(n)
  return function()
    return n
  end
end

local function source_win(opts)
  if opts.win and api.nvim_win_is_valid(opts.win) then
    return opts.win
  end
  local cur = api.nvim_get_current_win()
  if opts.anchor and api.nvim_win_get_buf(cur) ~= opts.anchor.buf then
    for _, w in ipairs(api.nvim_tabpage_list_wins(0)) do
      if api.nvim_win_get_buf(w) == opts.anchor.buf then
        return w
      end
    end
  end
  return cur
end

---@param opts slop.input.Opts
---@return slop.input.Handle
function M.open(opts)
  assert(type(opts) == "table" and type(opts.on_submit) == "function", "slop: input.open needs on_submit")
  local float = require("slop.core.ui.float")
  local keymaps = require("slop.core.keymaps")
  local triggers = opts.triggers or { "#", "@" }
  local src_win = source_win(opts)
  local hist_buf = opts.anchor and opts.anchor.buf or api.nvim_win_get_buf(src_win)

  local buf = api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  local default = opts.default or ""
  local lines = type(default) == "table" and default or util.lines(default --[[@as string]])
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  active[buf] = opts

  local width = opts.width
  if not width then
    local ww = api.nvim_win_get_width(src_win)
    width = opts.anchor and math.max(30, math.min(80, ww - (opts.anchor.col or 0) - 4))
      or math.min(80, vim.o.columns - 10)
  end
  -- float sizes in (0, 1] are fractions: pass cell counts as functions
  local base_rows = opts.height and float.resolve_size(opts.height, vim.o.lines) or 1
  local float_opts = {
    buf = buf,
    width = width,
    height = cells(math.max(base_rows, math.min(#lines, MAX_HEIGHT))),
    title = opts.title or "slop",
    title_pos = "left",
    footer = opts.footer or "<C-s> submit · <Esc> cancel",
    footer_pos = "right",
    enter = true,
    close_on_leave = true,
    responsive = not opts.anchor,
    wo = { wrap = true, linebreak = true, cursorline = false },
  }
  if opts.anchor then
    float_opts.relative = "region"
    float_opts.win = src_win
    local a = opts.anchor
    float_opts.region = { a.row, a.col or 0, a.end_row or a.row, 0 }
    float_opts.col = 0
  end

  local finished = false
  local self ---@type slop.input.Handle
  local fh ---@type slop.float.Handle

  local function restore_focus()
    if api.nvim_win_is_valid(src_win) then
      pcall(api.nvim_set_current_win, src_win)
    end
  end

  local function finish(text)
    if finished then
      return
    end
    finished = true
    active[buf] = nil
    if api.nvim_get_mode().mode:sub(1, 1) == "i" then
      vim.cmd.stopinsert()
    end
    if fh and fh:is_valid() then
      fh:close()
    end
    restore_focus()
    if text then
      if opts.history then
        add_history(opts.history, text, hist_buf)
      end
      opts.on_submit(text)
    elseif opts.on_cancel then
      opts.on_cancel()
    end
  end

  float_opts.on_close = function()
    vim.schedule(function()
      finish(nil)
    end)
  end
  fh = float.open(float_opts)
  vim.bo[buf].filetype = opts.filetype or "slopprompt"
  vim.bo[buf].completefunc = "v:lua.require'slop.core.ui.input'._completefunc"

  local function submit()
    local text = vim.trim(table.concat(api.nvim_buf_get_lines(buf, 0, -1, false), "\n"))
    finish(text ~= "" and text or nil)
  end
  local function cancel()
    finish(nil)
  end

  -- history navigation
  local hist = opts.history and M.history(opts.history, hist_buf) or {}
  local hi, draft = 0, nil
  local function set_lines(l)
    api.nvim_buf_set_lines(buf, 0, -1, false, l)
    local last = #l
    pcall(api.nvim_win_set_cursor, fh.win, { last, #(l[last] or "") })
  end
  local function nav(dir)
    if #hist == 0 then
      return
    end
    if hi == 0 then
      draft = api.nvim_buf_get_lines(buf, 0, -1, false)
    end
    hi = math.max(0, math.min(#hist, hi + dir))
    set_lines(hi == 0 and (draft or { "" }) or util.lines(hist[hi]))
  end

  local set = function(mode, lhs, rhs, desc)
    keymaps.set_buf(buf, mode, lhs, rhs, { desc = "prompt " .. desc, nowait = true })
  end
  set({ "i", "n" }, "<C-s>", submit, "submit")
  set("n", "<CR>", submit, "submit")
  set("n", "<Esc>", cancel, "cancel")
  set("n", "q", cancel, "cancel")
  set({ "i", "n" }, "<C-c>", cancel, "cancel")
  set("n", "<Up>", function()
    nav(1)
  end, "older history entry")
  set("n", "<Down>", function()
    nav(-1)
  end, "newer history entry")

  local group = util.augroup("input." .. buf, true)
  local function relayout()
    if not fh:is_valid() then
      return
    end
    local ok, th = pcall(api.nvim_win_text_height, fh.win, {})
    local h = ok and th.all or api.nvim_buf_line_count(buf)
    local want = math.max(base_rows, math.min(h, MAX_HEIGHT))
    if want ~= api.nvim_win_get_height(fh.win) then
      fh:update({ height = cells(want) })
    end
  end
  api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    group = group,
    buffer = buf,
    callback = function(ev)
      highlight_tokens(buf, triggers)
      relayout()
      if ev.event == "TextChangedI" then
        auto_complete(buf, opts)
      end
    end,
  })
  api.nvim_create_autocmd("BufWipeout", {
    group = group,
    buffer = buf,
    once = true,
    callback = function()
      active[buf] = nil
      pcall(api.nvim_del_augroup_by_id, group)
    end,
  })
  highlight_tokens(buf, triggers)

  local last = #lines
  api.nvim_win_set_cursor(fh.win, { last, #(lines[last] or "") })
  vim.cmd.startinsert({ bang = true })

  self = setmetatable({ buf = buf, win = fh.win, _float = fh, _close = cancel }, Handle)
  return self
end

return M

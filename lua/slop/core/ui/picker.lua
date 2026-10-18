--- Generic picker: fzf-lua (with preview) when installed, else a built-in float picker
--- (prompt + list + preview, matchfuzzypos), vim.ui.select as last resort. Backend from config ui.picker.
--- OWNER: rest.
---
---   picker.pick(items, {
---     prompt = "Requests", format = function(it) return it.label end,
---     preview = function(it) return { path = it.file, lnum = it.line } end,
---     actions = { ["<C-v>"] = "vsplit" },
---     on_select = function(item, action) ... end,   -- item nil when cancelled; always called exactly once
---   })
---@class slop.ui.picker
local M = {}

local api = vim.api

---@class slop.picker.Preview
---@field lines? string[]                 literal preview content
---@field path? string                    or preview a file ...
---@field lnum? integer                   ... at this line (1-based)
---@field filetype? string

---@alias slop.picker.Chunks {[1]: string, [2]: string?}[]

---@class slop.picker.Opts
---@field prompt? string
---@field title? string
---@field format? fun(item: any): string|slop.picker.Chunks  display text or {text, hl} chunks
---                                       default: item.text or tostring(item)
---@field preview? fun(item: any): slop.picker.Preview?
---@field on_select fun(item: any?, action: string?)  item nil when cancelled; action = value from `actions`
---@field actions? table<string, string>  extra keys -> action name passed to on_select, e.g. { ["<C-v>"] = "vsplit" }
---@field backend? "auto"|"fzf"|"builtin"|"select"  override config ui.picker
---@field multi? boolean                  on_select receives a list of items (marked, else the current one)
---@field initial? string                 initial query

---@class slop.picker.Handle
---@field close fun()                     cancel (on_select(nil))

local PREVIEW_MAX_BYTES = 1024 * 1024

-- Helpers --------------------------------------------------------------------------------------

---@param item any
---@param opts? slop.picker.Opts
---@return string|slop.picker.Chunks
local function formatted(item, opts)
  if opts and opts.format then
    return opts.format(item)
  end
  if type(item) == "table" and item.text ~= nil then
    return tostring(item.text)
  end
  return tostring(item)
end

---@param f string|slop.picker.Chunks
---@return string text, {[1]: integer, [2]: integer, [3]: string}[] hls  (byte start, byte end, group)
local function flatten(f)
  if type(f) == "string" then
    return (f:gsub("\n", " ")), {}
  end
  local parts, hls, len = {}, {}, 0
  for _, chunk in ipairs(f) do
    local t = tostring(chunk[1] or ""):gsub("\n", " ")
    parts[#parts + 1] = t
    if chunk[2] and #t > 0 then
      hls[#hls + 1] = { len, len + #t, chunk[2] }
    end
    len = len + #t
  end
  return table.concat(parts), hls
end

--- Display text of an item (chunks joined).
---@param item any
---@param opts? slop.picker.Opts
---@return string
function M.text(item, opts)
  return (flatten(formatted(item, opts)))
end

--- Resolved backend for `opts` (pure apart from probing fzf-lua).
---@param opts? slop.picker.Opts
---@return "fzf"|"builtin"|"select"
function M.backend(opts)
  local want = opts and opts.backend
  if not want then
    local ok, ui = pcall(require("slop.config").get, "ui")
    want = ok and ui and ui.picker or "auto"
  end
  if want == "select" or want == "builtin" then
    return want
  end
  local has_fzf = pcall(require, "fzf-lua")
  if has_fzf then
    return "fzf"
  end
  if want == "fzf" then
    require("slop.core.log").debug("picker: fzf-lua not installed, using the builtin picker")
  end
  return "builtin"
end

---@class slop.picker.Match
---@field item any
---@field index integer                  index in the original list
---@field text string
---@field positions integer[]            0-based BYTE offsets of matched characters

--- Pure fuzzy filter (matchfuzzypos). Empty query keeps the original order.
---@param items any[]
---@param query string
---@param opts? slop.picker.Opts
---@return slop.picker.Match[]
function M.filter(items, query, opts)
  local entries = {}
  for i, item in ipairs(items) do
    entries[i] = { text = M.text(item, opts), index = i }
  end
  local out = {}
  if not query or vim.trim(query) == "" then
    for i, e in ipairs(entries) do
      out[i] = { item = items[e.index], index = e.index, text = e.text, positions = {} }
    end
    return out
  end
  local res = vim.fn.matchfuzzypos(entries, query, { key = "text" })
  for i, e in ipairs(res[1]) do
    local pos = {}
    for _, cidx in ipairs(res[2][i] or {}) do
      local ok, b = pcall(vim.str_byteindex, e.text, "utf-32", cidx, false)
      pos[#pos + 1] = ok and b or cidx
    end
    out[i] = { item = items[e.index], index = e.index, text = e.text, positions = pos }
  end
  return out
end

--- Fill a buffer with a preview (lines, or a file read from disk) and return the line to show.
---@param buf integer
---@param pv slop.picker.Preview?
---@return integer? lnum
local function fill_preview(buf, pv)
  local lines = { "" }
  local ft
  if pv then
    if pv.lines then
      lines = pv.lines
    elseif pv.path then
      local stat = vim.uv.fs_stat(pv.path)
      if not stat then
        lines = { "(file not found: " .. pv.path .. ")" }
      elseif stat.size > PREVIEW_MAX_BYTES then
        lines = vim.fn.readfile(pv.path, "", 2000)
      else
        lines = vim.fn.readfile(pv.path)
      end
      ft = vim.filetype.match({ filename = pv.path })
      vim.b[buf].slop_secret_path = pv.path
    end
    ft = pv.filetype or ft
  end
  vim.bo[buf].modifiable = true
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  if ft and vim.bo[buf].filetype ~= ft then
    pcall(function()
      vim.bo[buf].filetype = ft
    end)
  end
  return pv and pv.lnum
end

--- Ensure on_select is called once, on the main loop, after the UI closed.
---@param opts slop.picker.Opts
---@return fun(item: any?, action: string?)
local function once(opts)
  local done = false
  return function(item, action)
    if done then
      return
    end
    done = true
    vim.schedule(function()
      opts.on_select(item, action)
    end)
  end
end

-- vim.ui.select backend --------------------------------------------------------------------------

local function pick_select(items, opts)
  local finish = once(opts)
  local function run(list)
    vim.ui.select(list, {
      prompt = opts.prompt or opts.title,
      format_item = function(item)
        return M.text(item, opts)
      end,
    }, function(choice)
      if opts.multi then
        finish(choice and { choice } or nil)
      else
        finish(choice)
      end
    end)
  end
  if type(items) == "function" then
    items(vim.schedule_wrap(run))
  else
    run(items)
  end
end

-- fzf-lua backend --------------------------------------------------------------------------------

--- "<C-v>" -> "ctrl-v", "<M-x>" -> "alt-x", "<CR>" -> "enter".
---@param key string
---@return string
function M.fzf_key(key)
  local k = key:lower()
  local special = { ["<cr>"] = "enter", ["<esc>"] = "esc", ["<bs>"] = "bspace", ["<space>"] = "space" }
  if special[k] then
    return special[k]
  end
  local m, c = k:match("^<([cma])%-(.+)>$")
  if m then
    local name = ({ c = "ctrl", m = "alt", a = "alt" })[m]
    return name .. "-" .. (special["<" .. c .. ">"] or c)
  end
  return k
end

local function ansi(text, hls)
  if #hls == 0 then
    return text
  end
  local utils = require("fzf-lua.utils")
  local out, pos = {}, 0
  for _, h in ipairs(hls) do
    if h[1] > pos then
      out[#out + 1] = text:sub(pos + 1, h[1])
    end
    out[#out + 1] = (utils.ansi_from_hl(h[3], text:sub(h[1] + 1, h[2])))
    pos = h[2]
  end
  out[#out + 1] = text:sub(pos + 1)
  return table.concat(out)
end

local function fzf_previewer(preview, by_index)
  local base = require("fzf-lua.previewer.builtin").base
  local P = base:extend()
  function P:new(o, popts, fzf_win)
    P.super.new(self, o, popts, fzf_win)
    setmetatable(self, P)
    return self
  end
  function P:populate_preview_buf(entry_str)
    local idx = tonumber((entry_str or ""):match("^(%d+)\t"))
    local item = idx and by_index[idx]
    local buf = self:get_tmp_buffer()
    local ok, pv = pcall(preview, item)
    local lnum = fill_preview(buf, ok and pv or { lines = { tostring(pv) } })
    self:set_preview_buf(buf)
    local win = self.win and self.win.preview_winid
    if lnum and win and api.nvim_win_is_valid(win) then
      pcall(api.nvim_win_set_cursor, win, { lnum, 0 })
      pcall(api.nvim_win_call, win, function()
        vim.cmd("normal! zz")
      end)
    end
    if self.win and self.win.update_preview_scrollbar then
      pcall(self.win.update_preview_scrollbar, self.win)
    end
  end
  return P
end

local function pick_fzf(items, opts)
  local fzf = require("fzf-lua")
  local finish = once(opts)
  local by_index = {}
  local key_action = {} ---@type table<string, string>
  local noop = function() end
  local fzf_actions = { ["enter"] = noop, ["esc"] = noop, ["ctrl-c"] = noop }
  for key, name in pairs(opts.actions or {}) do
    local k = M.fzf_key(key)
    key_action[k] = name
    fzf_actions[k] = noop
  end

  local function to_lines(list)
    local lines = {}
    for i, item in ipairs(list) do
      by_index[i] = item
      local text, hls = flatten(formatted(item, opts))
      lines[i] = i .. "\t" .. ansi(text, hls)
    end
    return lines
  end

  local contents
  if type(items) == "function" then
    contents = function(cb)
      items(function(list)
        vim.schedule(function()
          coroutine.wrap(function()
            for _, l in ipairs(to_lines(list)) do
              cb(l)
            end
            cb(nil)
          end)()
        end)
      end)
    end
  else
    contents = to_lines(items)
  end

  local fzf_opts = { ["--delimiter"] = "\t", ["--with-nth"] = "2..", ["--ansi"] = true }
  if opts.multi then
    fzf_opts["--multi"] = true
  end
  if opts.initial and opts.initial ~= "" then
    fzf_opts["--query"] = opts.initial
  end

  fzf.fzf_exec(contents, {
    prompt = (opts.prompt or "") .. "> ",
    winopts = {
      title = opts.title and (" " .. opts.title .. " ") or nil,
      border = require("slop.core.ui.float").border(),
      on_close = function()
        -- fallback for closes that never reach fn_selected (e.g. the window was closed by the user)
        vim.defer_fn(function()
          finish(nil)
        end, 300)
      end,
    },
    fzf_opts = fzf_opts,
    previewer = opts.preview and fzf_previewer(opts.preview, by_index) or nil,
    actions = fzf_actions,
    fn_selected = function(selected)
      if not selected or #selected == 0 then
        return finish(nil)
      end
      local key = selected[1]
      local chosen = {}
      for i = 2, #selected do
        local idx = tonumber(selected[i]:match("^(%d+)\t"))
        if idx and by_index[idx] ~= nil then
          chosen[#chosen + 1] = by_index[idx]
        end
      end
      if key == "esc" or key == "ctrl-c" or key == "ctrl-q" or #chosen == 0 then
        return finish(nil)
      end
      local action = key_action[key]
      if opts.multi then
        finish(chosen, action)
      else
        finish(chosen[1], action)
      end
    end,
  })
end

-- Builtin float backend --------------------------------------------------------------------------

---@param has_preview boolean
local function layout(has_preview)
  local cols, lines = vim.o.columns, math.max(1, vim.o.lines - vim.o.cmdheight)
  local W = math.max(20, math.min(cols - 4, math.floor(cols * 0.85)))
  local H = math.max(5, math.min(lines - 4, math.floor(lines * 0.75)))
  local show_preview = has_preview and W >= 70
  local lw = show_preview and math.floor(W * 0.45) or W
  local row = math.max(0, math.floor((lines - H - 2) / 2))
  local col = math.max(0, math.floor((cols - W - 2) / 2))
  return {
    prompt = { row = row, col = col, width = lw, height = 1 },
    list = { row = row + 3, col = col, width = lw, height = math.max(1, H - 3) },
    preview = show_preview and { row = row, col = col + lw + 2, width = W - lw - 2, height = H + 1 } or nil,
  }
end

---@param n integer
---@return fun(): integer
local function const(n)
  return function()
    return n
  end
end

local function pick_builtin(items, opts)
  local float = require("slop.core.ui.float")
  local km = require("slop.core.keymaps")
  local ns = require("slop.core.util").ns("picker")
  local finish = once(opts)

  local state = {
    items = type(items) == "table" and items or {},
    loading = type(items) == "function",
    matches = {}, ---@type slop.picker.Match[]
    sel = 1,
    marks = {}, ---@type table<integer, boolean>
    closing = false,
    preview_tick = 0,
  }
  local L = layout(opts.preview ~= nil)
  local handles = {}
  local prefix = opts.multi and 2 or 0

  local function close_all()
    state.closing = true
    for _, h in pairs(handles) do
      if h:is_valid() then
        h:close()
      end
    end
    if api.nvim_get_mode().mode:sub(1, 1) == "i" then
      vim.cmd("stopinsert")
    end
  end
  local function cancel()
    if state.closing then
      return
    end
    close_all()
    finish(nil)
  end

  local list_buf = api.nvim_create_buf(false, true)
  local prompt_buf = api.nvim_create_buf(false, true)
  local preview_buf = L.preview and api.nvim_create_buf(false, true) or nil
  for _, b in ipairs({ list_buf, prompt_buf, preview_buf }) do
    vim.bo[b].bufhidden = "wipe"
  end

  local function on_close()
    if not state.closing then
      vim.schedule(cancel)
    end
  end

  if L.preview then
    handles.preview = float.open({
      buf = preview_buf,
      enter = false,
      focusable = false,
      row = L.preview.row,
      col = L.preview.col,
      width = const(L.preview.width),
      height = const(L.preview.height),
      title = "Preview",
      zindex = 60,
      responsive = false,
      wo = { wrap = false, number = true, cursorline = true },
      on_close = on_close,
    })
  end
  handles.list = float.open({
    buf = list_buf,
    enter = false,
    focusable = false,
    row = L.list.row,
    col = L.list.col,
    width = const(L.list.width),
    height = const(L.list.height),
    zindex = 60,
    responsive = false,
    wo = { wrap = false, cursorline = false },
    on_close = on_close,
  })
  handles.prompt = float.open({
    buf = prompt_buf,
    enter = true,
    row = L.prompt.row,
    col = L.prompt.col,
    width = const(L.prompt.width),
    height = const(1),
    title = opts.title or opts.prompt or "Pick",
    title_pos = "left",
    zindex = 61,
    responsive = false,
    on_close = on_close,
  })

  local function current()
    return state.matches[state.sel]
  end

  local function render_preview()
    if not (preview_buf and handles.preview and handles.preview:is_valid()) then
      return
    end
    local m = current()
    local pv
    if m then
      local ok, res = pcall(opts.preview, m.item)
      pv = ok and res or { lines = { "preview error: " .. tostring(res) } }
    else
      pv = { lines = {} }
    end
    local lnum = fill_preview(preview_buf, pv)
    local win = handles.preview.win
    local count = api.nvim_buf_line_count(preview_buf)
    pcall(api.nvim_win_set_cursor, win, { math.min(math.max(lnum or 1, 1), count), 0 })
    api.nvim_win_call(win, function()
      vim.cmd("normal! " .. (lnum and "zz" or "zt"))
    end)
  end

  local function render_list()
    if not api.nvim_buf_is_valid(list_buf) then
      return
    end
    local lines = {}
    if state.loading then
      lines = { "  loading…" }
    elseif #state.matches == 0 then
      lines = { "  (no matches)" }
    else
      for i, m in ipairs(state.matches) do
        local mark = opts.multi and (state.marks[m.index] and "● " or "  ") or ""
        lines[i] = mark .. m.text
      end
    end
    vim.bo[list_buf].modifiable = true
    api.nvim_buf_set_lines(list_buf, 0, -1, false, lines)
    vim.bo[list_buf].modifiable = false
    api.nvim_buf_clear_namespace(list_buf, ns, 0, -1)
    if state.loading or #state.matches == 0 then
      api.nvim_buf_set_extmark(list_buf, ns, 0, 0, { end_col = #lines[1], hl_group = "SlopDim" })
    else
      for i, m in ipairs(state.matches) do
        local _, hls = flatten(formatted(m.item, opts))
        for _, h in ipairs(hls) do
          pcall(api.nvim_buf_set_extmark, list_buf, ns, i - 1, h[1] + prefix, {
            end_col = h[2] + prefix,
            hl_group = h[3],
            priority = 100,
          })
        end
        for _, p in ipairs(m.positions) do
          local len = #(vim.fn.strcharpart(m.text:sub(p + 1), 0, 1))
          pcall(api.nvim_buf_set_extmark, list_buf, ns, i - 1, p + prefix, {
            end_col = p + prefix + math.max(len, 1),
            hl_group = "SlopMatch",
            priority = 110,
          })
        end
      end
      api.nvim_buf_set_extmark(list_buf, ns, state.sel - 1, 0, { line_hl_group = "SlopSelected", priority = 90 })
      if handles.list:is_valid() then
        pcall(api.nvim_win_set_cursor, handles.list.win, { state.sel, 0 })
      end
    end
    if handles.prompt:is_valid() then
      local footer = state.loading and "…" or ("%d/%d"):format(#state.matches, #state.items)
      handles.prompt:update({ footer = footer, footer_pos = "right" })
    end
  end

  local function refresh()
    local query = api.nvim_buf_is_valid(prompt_buf) and (api.nvim_buf_get_lines(prompt_buf, 0, 1, false)[1] or "") or ""
    state.matches = state.loading and {} or M.filter(state.items, query, opts)
    state.sel = 1
    render_list()
    render_preview()
  end

  local function move(delta)
    local n = #state.matches
    if n == 0 then
      return
    end
    state.sel = ((state.sel - 1 + delta) % n) + 1
    render_list()
    render_preview()
  end

  local function accept(action)
    if state.closing then
      return
    end
    local m = current()
    if not m then
      return
    end
    close_all()
    if opts.multi then
      local chosen = {}
      for i, item in ipairs(state.items) do
        if state.marks[i] then
          chosen[#chosen + 1] = item
        end
      end
      finish(#chosen > 0 and chosen or { m.item }, action)
    else
      finish(m.item, action)
    end
  end

  local function scroll_preview(dir)
    if handles.preview and handles.preview:is_valid() then
      api.nvim_win_call(handles.preview.win, function()
        vim.cmd(("normal! %s"):format(vim.keycode(dir > 0 and "<C-d>" or "<C-u>")))
      end)
    end
  end

  local maps = {
    {
      { "<C-n>", "<Down>" },
      function()
        move(1)
      end,
      "picker next",
    },
    {
      { "<C-p>", "<Up>" },
      function()
        move(-1)
      end,
      "picker previous",
    },
    {
      { "<CR>" },
      function()
        accept(nil)
      end,
      "picker select",
    },
    { { "<Esc>", "<C-c>" }, cancel, "picker cancel" },
    {
      { "<C-d>" },
      function()
        scroll_preview(1)
      end,
      "picker scroll preview down",
    },
    {
      { "<C-u>" },
      function()
        scroll_preview(-1)
      end,
      "picker scroll preview up",
    },
  }
  if opts.multi then
    maps[#maps + 1] = {
      { "<C-Space>" },
      function()
        local m = current()
        if m then
          state.marks[m.index] = not state.marks[m.index] or nil
          move(1)
        end
      end,
      "picker toggle mark",
    }
  end
  for key, name in pairs(opts.actions or {}) do
    maps[#maps + 1] = {
      { key },
      function()
        accept(name)
      end,
      "picker " .. name,
    }
  end
  for _, m in ipairs(maps) do
    for _, lhs in ipairs(m[1]) do
      km.set_buf(prompt_buf, { "i", "n" }, lhs, m[2], { desc = m[3], nowait = true })
    end
  end
  km.set_buf(prompt_buf, "n", "q", cancel, { desc = "picker cancel", nowait = true })

  api.nvim_create_autocmd({ "TextChangedI", "TextChanged" }, {
    buffer = prompt_buf,
    desc = "slop: picker filter",
    callback = refresh,
  })
  api.nvim_create_autocmd("WinLeave", {
    buffer = prompt_buf,
    desc = "slop: picker close on leave",
    callback = function()
      vim.schedule(function()
        if not state.closing and handles.prompt:is_valid() and api.nvim_get_current_win() ~= handles.prompt.win then
          cancel()
        end
      end)
    end,
  })

  if opts.initial and opts.initial ~= "" then
    api.nvim_buf_set_lines(prompt_buf, 0, -1, false, { opts.initial })
  end
  refresh()
  vim.cmd("startinsert!")

  if state.loading then
    items(function(list)
      vim.schedule(function()
        if state.closing then
          return
        end
        state.items = list or {}
        state.loading = false
        refresh()
      end)
    end)
  end

  ---@type slop.picker.Handle
  local handle = {
    close = cancel,
    -- test hooks
    _state = state,
    _handles = handles,
    _bufs = { prompt = prompt_buf, list = list_buf, preview = preview_buf },
    _move = move,
    _accept = accept,
  }
  return handle
end

-- Entry point ------------------------------------------------------------------------------------

--- Pick one of `items` (list, or a function producing them asynchronously: fun(cb: fun(items: any[]))).
---@param items any[]|fun(cb: fun(items: any[]))
---@param opts slop.picker.Opts
---@return slop.picker.Handle?
function M.pick(items, opts)
  assert(type(opts) == "table" and type(opts.on_select) == "function", "slop: picker.pick needs opts.on_select")
  local backend = M.backend(opts)
  if backend == "fzf" then
    local ok, err = pcall(pick_fzf, items, opts)
    if ok then
      return nil
    end
    require("slop.core.log").warn("picker: fzf-lua failed (%s), using the builtin picker", tostring(err))
    backend = "builtin"
  end
  if backend == "select" then
    pick_select(items, opts)
    return nil
  end
  return pick_builtin(items, opts)
end

return M

--- Terminal jobs: spawn hidden, show/hide in a window (job + scrollback persist), send, kill, list.
--- OWNER: term. Used by the term module and any future task runner / agent-CLI terminal.
---
---   local term = require("slop.core.term")
---   local t = term.spawn({ cmd = { "lazygit" }, layout = "float", hidden = true })
---   t:toggle()                     -- show / hide (the job keeps running while hidden)
---   t:send({ "make test" })        -- bracketed paste for multi-line, <CR> appended
---
--- Design (research/12-term.md §4.3): one window "slot" per layout per tabpage; floats via core.ui.float
--- (always bordered); exit -> exit_code + User SlopTermExit; BufWipeout unregisters the terminal.
---@class slop.term
local M = {}

local api = vim.api

---@alias slop.term.Layout "float"|"split"|"vsplit"

---@class slop.term.Spec
---@field name? string                 display name (default: basename of cmd[1])
---@field cmd? string|string[]          default: { vim.o.shell }; a string with spaces runs through 'shell'
---@field cwd? string                   default: core.project.root()
---@field env? table<string, string>
---@field owner? string                 "term" | "task" | ...  (default "term")
---@field hidden? boolean               excluded from list()/last() by default
---@field layout? slop.term.Layout      default layout for show() (default "float")
---@field float? slop.float.Opts        float overrides (size, border, ...); title = true|string|false
---@field split? {size?: slop.float.Size}   rows of a split (default 0.3)
---@field vsplit? {size?: slop.float.Size}  columns of a vsplit (default 0.4)
---@field wo? table<string, any>        window-local options for every window showing it
---@field start_insert? boolean         enter terminal mode on first show (default true)
---@field persist_mode? boolean         restore the mode it was left in (default true)
---@field hide_on_leave? boolean        hide the float when focus leaves it (default false)
---@field close_on_exit? boolean|"success"  wipe buffer when the job exits (default true)
---@field on_open? fun(term: slop.Term)     after the job started (buffer exists)
---@field on_exit? fun(term: slop.Term, code: integer)

---@class slop.term.ShowOpts
---@field layout? slop.term.Layout
---@field enter? boolean                focus the window (default true)
---@field insert? boolean               start insert (default: restore remembered mode)

---@class slop.term.SendOpts
---@field submit? boolean               append <CR> (default true)
---@field paste? boolean|"auto"         bracketed paste; "auto" (default) = only for multi-line text
---@field dedent? boolean               strip common indent (default true)
---@field show? boolean                 show the terminal (without focusing it) after sending

---@class slop.Term
---@field id integer                    1..n, gap-filling
---@field name string
---@field owner string
---@field cmd string[]
---@field cwd string
---@field buf integer?                  terminal buffer (nil once wiped)
---@field win integer?                  window currently showing it (current tab), if any
---@field job integer?                  channel id
---@field layout slop.term.Layout
---@field hidden boolean
---@field exit_code integer?
---@field spec slop.term.Spec
---@field mode "t"|"n"                  remembered mode
---@field private _sizes table<string, integer>
---@field private _origin integer?
---@field private _used integer
local Term = {}
Term.__index = Term

local terms = {} ---@type table<integer, slop.Term>
local slots = {} ---@type table<integer, table<string, integer>>  tabpage -> layout -> win
local used_tick = 0

local function log()
  return require("slop.core.log").scope("term")
end

local function float()
  return require("slop.core.ui.float")
end

local function group()
  return api.nvim_create_augroup("slop.core.term", { clear = false })
end

---@param t slop.Term|integer|string|nil
---@return slop.Term?
local function resolve(t)
  if type(t) == "table" then
    return t
  end
  if t == nil then
    return nil
  end
  return M.get(t)
end

local function next_id()
  local i = 1
  while terms[i] do
    i = i + 1
  end
  return i
end

local function emit(t, event, extra)
  local data = { id = t.id, name = t.name, owner = t.owner }
  for k, v in pairs(extra or {}) do
    data[k] = v
  end
  require("slop.core.events").emit("term", event, data)
end

-- Windows / layouts ------------------------------------------------------------------------------

---@return table<string, integer>
local function tab_slots()
  local tab = api.nvim_get_current_tabpage()
  slots[tab] = slots[tab] or {}
  return slots[tab]
end

--- Windows of the current tabpage showing this terminal.
---@return integer[]
function Term:windows()
  local out = {}
  if not (self.buf and api.nvim_buf_is_valid(self.buf)) then
    return out
  end
  for _, win in ipairs(api.nvim_tabpage_list_wins(0)) do
    if api.nvim_win_get_buf(win) == self.buf then
      out[#out + 1] = win
    end
  end
  return out
end

--- Layout of a window showing this terminal ("float", "split", "vsplit", or "window" for other windows).
---@param win? integer  default: first window showing it
---@return slop.term.Layout|"window"|nil
function Term:layout_of(win)
  win = win or self:windows()[1]
  if not (win and api.nvim_win_is_valid(win)) then
    return nil
  end
  if float().is_float(win) then
    return "float"
  end
  for layout, w in pairs(tab_slots()) do
    if w == win then
      return layout
    end
  end
  return "window"
end

---@return boolean
function Term:is_visible()
  return #self:windows() > 0
end

---@return boolean
function Term:is_running()
  return self.job ~= nil and self.exit_code == nil and vim.fn.jobwait({ self.job }, 0)[1] == -1
end

local function set_wo(win, opts)
  for k, v in pairs(opts) do
    pcall(api.nvim_set_option_value, k, v, { win = win, scope = "local" })
  end
end

local function title_of(t)
  local title = (t.spec.float or {}).title
  if title == false then
    return nil
  end
  if type(title) == "string" or type(title) == "table" then
    return title
  end
  return t.name
end

local function remember_mode(t)
  local m = api.nvim_get_mode().mode
  t.mode = m:sub(1, 1) == "t" and "t" or "n"
end

--- Only non-float window of the tab?
local function is_last_window(win)
  local n = 0
  for _, w in ipairs(api.nvim_tabpage_list_wins(0)) do
    if not float().is_float(w) then
      n = n + 1
    end
  end
  return n <= 1 and not float().is_float(win)
end

--- A buffer to put in a last window instead of closing it.
local function fallback_buf(t)
  local alt = vim.fn.bufnr("#")
  if alt > 0 and alt ~= t.buf and api.nvim_buf_is_valid(alt) and vim.bo[alt].buflisted then
    return alt
  end
  for _, b in ipairs(api.nvim_list_bufs()) do
    if b ~= t.buf and vim.bo[b].buflisted and api.nvim_buf_is_loaded(b) and vim.bo[b].buftype ~= "terminal" then
      return b
    end
  end
  return api.nvim_create_buf(true, false)
end

---@param t slop.Term
---@param win integer
local function close_window(t, win)
  if not api.nvim_win_is_valid(win) then
    return
  end
  local layout = t:layout_of(win)
  if layout == "split" then
    t._sizes.split = api.nvim_win_get_height(win)
  elseif layout == "vsplit" then
    t._sizes.vsplit = api.nvim_win_get_width(win)
  end
  if is_last_window(win) then
    vim.wo[win].winfixbuf = false
    api.nvim_win_set_buf(win, fallback_buf(t))
    return
  end
  pcall(api.nvim_win_close, win, true)
end

local function restore_origin(t, was_current)
  if was_current and t._origin and api.nvim_win_is_valid(t._origin) then
    if api.nvim_win_get_tabpage(t._origin) == api.nvim_get_current_tabpage() then
      api.nvim_set_current_win(t._origin)
    end
  end
end

local function enter_mode(t, insert)
  if insert == nil then
    if t.spec.persist_mode ~= false then
      insert = t.mode == "t"
    else
      insert = t.spec.start_insert ~= false
    end
  end
  if insert and t:is_running() then
    vim.cmd.startinsert()
  else
    vim.cmd.stopinsert()
  end
end

-- Lifecycle --------------------------------------------------------------------------------------

---@param t slop.Term
local function unregister(t)
  if terms[t.id] == t then
    terms[t.id] = nil
  end
end

---@param t slop.Term
---@param code integer
local function on_exit(t, code)
  t.exit_code = code
  emit(t, "Exit", { code = code })
  if t.spec.on_exit then
    local ok, err = pcall(t.spec.on_exit, t, code)
    if not ok then
      log().error("on_exit: %s", err)
    end
  end
  local coe = t.spec.close_on_exit
  if coe == nil then
    coe = true
  end
  if coe == true or (coe == "success" and code == 0) then
    local buf = t.buf
    local wins = t:windows()
    local was_current = vim.tbl_contains(wins, api.nvim_get_current_win())
    for _, win in ipairs(wins) do
      close_window(t, win)
    end
    restore_origin(t, was_current)
    unregister(t)
    if buf and api.nvim_buf_is_valid(buf) then
      pcall(api.nvim_buf_delete, buf, { force = true })
    end
  end
end

---@param t slop.Term
---@return boolean ok, string? err
local function start(t)
  local buf = api.nvim_create_buf(false, true)
  local job_cmd = t._job_cmd
  local ok, job = pcall(api.nvim_buf_call, buf, function()
    return vim.fn.jobstart(job_cmd, {
      term = true,
      cwd = t.cwd,
      env = t.spec.env,
      on_exit = function(_, code)
        vim.schedule(function()
          on_exit(t, code)
        end)
      end,
    })
  end)
  if not ok or type(job) ~= "number" or job <= 0 then
    pcall(api.nvim_buf_delete, buf, { force = true })
    return false, tostring(ok and ("jobstart returned " .. tostring(job)) or job)
  end
  t.buf, t.job, t.exit_code = buf, job, nil
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].buflisted = false
  vim.b[buf].slop_term = t.id
  pcall(function()
    vim.bo[buf].filetype = "slopterm"
  end)
  local grp = group()
  api.nvim_create_autocmd("BufWipeout", {
    group = grp,
    buf = buf,
    once = true,
    desc = "slop: unregister terminal",
    callback = function()
      if t.buf == buf then
        t.buf = nil
        unregister(t)
      end
    end,
  })
  api.nvim_create_autocmd("WinLeave", {
    group = grp,
    buf = buf,
    desc = "slop: terminal mode / hide on leave",
    callback = function()
      local win = api.nvim_get_current_win()
      remember_mode(t)
      if t.spec.hide_on_leave and float().is_float(win) then
        vim.schedule(function()
          if api.nvim_win_is_valid(win) and api.nvim_get_current_win() ~= win and api.nvim_win_get_buf(win) == buf then
            pcall(api.nvim_win_close, win, true)
          end
        end)
      end
    end,
  })
  return true
end

--- Spawn a terminal job in a hidden buffer (not shown).
---@param spec? slop.term.Spec
---@return slop.Term? term, string? err   nil + error message when the command cannot be started
function M.spawn(spec)
  spec = spec or {}
  local cmd = spec.cmd or { vim.o.shell }
  local job_cmd ---@type string|string[]
  if type(cmd) == "string" then
    if cmd:find("%s") then
      job_cmd = cmd
      cmd = { vim.o.shell, vim.o.shellcmdflag, cmd }
    else
      cmd = { cmd }
      job_cmd = cmd
    end
  else
    cmd = vim.list_extend({}, cmd)
    job_cmd = cmd
  end
  local cwd = spec.cwd or require("slop.core.project").root()
  if vim.fn.isdirectory(cwd) == 0 then
    cwd = vim.fn.getcwd()
  end
  local id = next_id()
  local t = setmetatable({
    id = id,
    name = spec.name or vim.fs.basename(cmd[1]),
    owner = spec.owner or "term",
    cmd = cmd,
    cwd = cwd,
    layout = spec.layout or "float",
    hidden = spec.hidden == true,
    spec = spec,
    mode = spec.start_insert == false and "n" or "t",
    _job_cmd = job_cmd,
    _sizes = {},
    _used = 0,
  }, Term)
  local ok, err = start(t)
  if not ok then
    log().error("cannot start %s: %s", table.concat(cmd, " "), err)
    return nil, err
  end
  terms[id] = t
  emit(t, "Open")
  if spec.on_open then
    local ok2, e = pcall(spec.on_open, t)
    if not ok2 then
      log().error("on_open: %s", e)
    end
  end
  return t
end

---@param t slop.Term
---@param layout slop.term.Layout
---@param enter boolean
---@return integer win
local function open_window(t, layout, enter)
  local sl = tab_slots()
  local win = sl[layout]
  local base_wo = { winfixbuf = true }
  if win and api.nvim_win_is_valid(win) and vim.b[api.nvim_win_get_buf(win)].slop_term then
    -- occupied slot: swap the buffer
    vim.wo[win].winfixbuf = false
    api.nvim_win_set_buf(win, t.buf)
    set_wo(win, base_wo)
    if layout == "float" then
      local h = float().get(win)
      if h then
        h:update({ title = title_of(t) or "" })
      end
    end
    if enter then
      api.nvim_set_current_win(win)
    end
    return win
  end
  if layout == "float" then
    local fo = vim.tbl_extend("force", {}, t.spec.float or {})
    fo.buf, fo.enter, fo.title = t.buf, enter, title_of(t)
    fo.close_keys, fo.close_on_leave, fo.on_close = nil, nil, nil
    fo.wo = vim.tbl_extend("force", base_wo, t.spec.wo or {}, fo.wo or {})
    win = float().open(fo).win
  else
    local o = t.spec[layout] or {}
    local cfg = { win = -1 }
    if layout == "split" then
      cfg.split = "below"
      cfg.height = math.max(1, t._sizes.split or float().resolve_size(o.size or 0.3, vim.o.lines))
    else
      cfg.split = "right"
      cfg.width = math.max(1, t._sizes.vsplit or float().resolve_size(o.size or 0.4, vim.o.columns))
    end
    win = api.nvim_open_win(t.buf, enter, cfg)
    set_wo(win, {
      number = false,
      relativenumber = false,
      signcolumn = "no",
      foldcolumn = "0",
      spell = false,
      winfixheight = layout == "split",
      winfixwidth = layout == "vsplit",
    })
    set_wo(win, vim.tbl_extend("force", base_wo, t.spec.wo or {}))
  end
  sl[layout] = win
  return win
end

--- Show a terminal in a float/split/vsplit. Showing it in another layout than the visible one moves it.
---@param term slop.Term|integer|string  object, id or name
---@param opts? slop.term.ShowOpts
---@return slop.Term?
function M.show(term, opts)
  local t = resolve(term)
  if not t then
    log().warn("no terminal %s", tostring(term))
    return nil
  end
  if not (t.buf and api.nvim_buf_is_valid(t.buf)) then
    local ok, err = start(t)
    if not ok then
      log().error("cannot start %s: %s", table.concat(t.cmd, " "), err)
      return nil
    end
    terms[t.id] = t
  end
  opts = opts or {}
  local layout = opts.layout or t.layout
  local enter = opts.enter ~= false
  used_tick = used_tick + 1
  t._used = used_tick
  t.layout = layout

  local cur = api.nvim_get_current_win()
  if vim.b[api.nvim_win_get_buf(cur)].slop_term == nil then
    t._origin = cur
  end
  local win
  for _, w in ipairs(t:windows()) do
    if t:layout_of(w) == layout then
      win = w
    else
      close_window(t, w) -- move to the requested layout
    end
  end
  if win then
    if enter then
      api.nvim_set_current_win(win)
    end
  else
    win = open_window(t, layout, enter)
  end
  t.win = win
  if enter then
    enter_mode(t, opts.insert)
  end
  return t
end

--- Hide every window of the current tabpage showing the terminal (job and scrollback persist).
---@param term slop.Term|integer|string
function M.hide(term)
  local t = resolve(term)
  if not t then
    return
  end
  local cur = api.nvim_get_current_win()
  local wins = t:windows()
  local was_current = vim.tbl_contains(wins, cur)
  if was_current then
    remember_mode(t)
  end
  for _, win in ipairs(wins) do
    close_window(t, win)
  end
  t.win = nil
  restore_origin(t, was_current)
  if was_current then
    vim.cmd.stopinsert()
  end
end

--- Show when hidden, hide when visible; with `opts.layout`, a terminal visible in another layout is moved.
---@param term slop.Term|integer|string
---@param opts? slop.term.ShowOpts
---@return slop.Term?
function M.toggle(term, opts)
  local t = resolve(term)
  if not t then
    return nil
  end
  local wins = t:windows()
  if #wins == 0 then
    return M.show(t, opts)
  end
  local layout = opts and opts.layout
  if layout then
    local in_layout = false
    for _, w in ipairs(wins) do
      if t:layout_of(w) == layout then
        in_layout = true
      end
    end
    if not in_layout then
      return M.show(t, opts)
    end
  end
  M.hide(t)
  return t
end

--- Focus the terminal's window (showing it first when hidden).
---@param term slop.Term|integer|string
function M.focus(term)
  local t = resolve(term)
  if not t then
    return
  end
  local win = t:windows()[1]
  if win then
    api.nvim_set_current_win(win)
    enter_mode(t)
  else
    M.show(t)
  end
end

--- Strip the common leading indent (blank lines ignored).
---@param lines string[]
---@return string[]
function M.dedent(lines)
  local min
  for _, l in ipairs(lines) do
    if l:find("%S") then
      local n = #l:match("^%s*")
      min = min and math.min(min, n) or n
    end
  end
  if not min or min == 0 then
    return lines
  end
  local out = {}
  for i, l in ipairs(lines) do
    out[i] = l:sub(min + 1)
  end
  return out
end

--- Bytes sent for `data` (pure; exposed for tests).
---@param data string|string[]
---@param opts? slop.term.SendOpts
---@return string
function M.encode(data, opts)
  opts = opts or {}
  local lines = type(data) == "string" and vim.split(data, "\n", { plain = true }) or vim.list_extend({}, data)
  while #lines > 1 and lines[#lines] == "" do
    lines[#lines] = nil
  end
  for i, l in ipairs(lines) do
    lines[i] = l:gsub("\r$", "")
  end
  if opts.dedent ~= false then
    lines = M.dedent(lines)
  end
  local paste = opts.paste
  if paste == nil then
    paste = "auto"
  end
  local text = table.concat(lines, "\r")
  if paste == true or (paste == "auto" and #lines > 1) then
    text = "\27[200~" .. text .. "\27[201~"
  end
  if opts.submit ~= false then
    text = text .. "\r"
  end
  return text
end

--- Send text to the job (bracketed paste for multi-line text by default; <CR> appended).
---@param term slop.Term|integer|string
---@param data string|string[]
---@param opts? slop.term.SendOpts
---@return boolean sent
function M.send(term, data, opts)
  local t = resolve(term)
  if not t then
    log().warn("no terminal %s", tostring(term))
    return false
  end
  opts = opts or {}
  if not (t.buf and api.nvim_buf_is_valid(t.buf)) then
    if not start(t) then
      return false
    end
    terms[t.id] = t
  end
  if not t:is_running() then
    log().warn("terminal %s has exited", t.name)
    return false
  end
  api.nvim_chan_send(t.job, M.encode(data, opts))
  if opts.show and not t:is_visible() then
    M.show(t, { enter = false })
  end
  for _, win in ipairs(t:windows()) do
    pcall(api.nvim_win_set_cursor, win, { api.nvim_buf_line_count(t.buf), 0 })
  end
  return true
end

--- Stop the job, close its windows and wipe its buffer.
---@param term slop.Term|integer|string
function M.kill(term)
  local t = resolve(term)
  if not t then
    return
  end
  local wins = t:windows()
  local was_current = vim.tbl_contains(wins, api.nvim_get_current_win())
  for _, win in ipairs(wins) do
    close_window(t, win)
  end
  restore_origin(t, was_current)
  unregister(t)
  local buf = t.buf
  t.buf = nil
  if t.job and t.exit_code == nil then
    pcall(vim.fn.jobstop, t.job)
  end
  if buf and api.nvim_buf_is_valid(buf) then
    pcall(api.nvim_buf_delete, buf, { force = true })
  end
end

---@param target integer|string  id or name
---@return slop.Term?
function M.get(target)
  if type(target) == "number" then
    return terms[target]
  end
  for _, t in ipairs(M.list({ hidden = true })) do
    if t.name == target then
      return t
    end
  end
  return nil
end

--- Registered terminals, sorted by id.
---@param opts? {hidden?: boolean, owner?: string}  include hidden terminals / filter by owner
---@return slop.Term[]
function M.list(opts)
  opts = opts or {}
  local out = {}
  for _, t in pairs(terms) do
    if (opts.hidden or not t.hidden) and (not opts.owner or t.owner == opts.owner) then
      out[#out + 1] = t
    end
  end
  table.sort(out, function(a, b)
    return a.id < b.id
  end)
  return out
end

--- Most recently shown non-hidden terminal (else the lowest id).
---@return slop.Term?
function M.last()
  local best
  for _, t in ipairs(M.list()) do
    if not best or t._used > best._used then
      best = t
    end
  end
  return best
end

--- Terminal object of a buffer (vim.b.slop_term), if any.
---@param buf? integer
---@return slop.Term?
function M.from_buf(buf)
  local id = vim.b[buf or 0].slop_term
  return id and terms[id] or nil
end

function Term:show(opts)
  return M.show(self, opts)
end
function Term:hide()
  return M.hide(self)
end
function Term:toggle(opts)
  return M.toggle(self, opts)
end
function Term:focus()
  return M.focus(self)
end
function Term:send(data, opts)
  return M.send(self, data, opts)
end
function Term:kill()
  return M.kill(self)
end

return M

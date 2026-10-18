--- cloak: on-screen masking via a decoration provider (visible rows only, no flash on open/paste/reload).
---
--- overlay (default): ephemeral `virt_text_pos = "overlay"` marks created inside the redraw that shows the
---   text; masks are sized by display width (tabs, wide chars). Windows get local 'nowrap' (overlay cannot
---   cover continuation rows), restored when the buffer is uncloaked.
--- conceal: persistent `conceal = ""` + inline virt_text marks reconciled for the visible rows (ephemeral
---   inline virt_text does not render), windows get conceallevel=2 / concealcursor=nvic (restored later).
---
--- Display state: a global flag plus a per-buffer override (vim.b.slop_cloak_enabled). It never affects
--- core.secrets redaction (computed from text by the provider registered in init.lua).
local M = {}

local api = vim.api

---@class slop.cloak.BufState
---@field path string
---@field rules slop.cloak.Rule[]
---@field display boolean        display providers of core.secrets may add spans
---@field tick integer
---@field rows table<integer, {col: integer, end_col: integer, text: string}[]>
---@field drawn table<integer, string>  conceal mode: row -> key of what is drawn

local S = {
  cfg = nil, ---@type table?
  rules = function()
    return {}
  end, ---@type fun(path: string): slop.cloak.Rule[]
  global = true,
  bufs = {}, ---@type table<integer, slop.cloak.BufState|false>
  bufs_path = {}, ---@type table<integer, string>  path a `false` entry was computed for
  reveal = {}, ---@type table<integer, {buf: integer, srow: integer, erow: integer, ids: integer[]}>
  saved = {}, ---@type table<integer, table<integer, table<string, any>>>  win -> buf -> saved options
  completion = {}, ---@type table<integer, boolean>  buffers whose completion we disabled
  fallback_path = nil, ---@type fun(win: integer, buf: integer): string?
  ns = nil, ---@type integer?
  ns_conceal = nil, ---@type integer?
  active = false,
}

M._state = S

local function ns()
  S.ns = S.ns or require("slop.core.util").ns("cloak")
  return S.ns
end

local function ns_conceal()
  S.ns_conceal = S.ns_conceal or require("slop.core.util").ns("cloak.conceal")
  return S.ns_conceal
end

local function render_mode()
  return S.cfg and S.cfg.render or "overlay"
end

--- Display width of `s` starting at screen column `vcol` (tabs expand to `ts`).
---@param s string
---@param vcol integer
---@param ts integer
---@return integer
function M.width(s, vcol, ts)
  if not s:find("[\t\128-\255%c]") then
    return #s
  end
  local w = 0
  for ch in s:gmatch("[%z\1-\127\192-\255][\128-\191]*") do
    if ch == "\t" then
      w = w + ts - ((vcol + w) % ts)
    else
      w = w + api.nvim_strwidth(ch)
    end
  end
  return w
end

--- Mask text for a span (cloak.nvim determine_replacement, by display width).
---@param prefix string
---@param width integer  display width of the masked text
---@param exact boolean  conceal mode: no padding, cloak_length exact
---@return string
function M.mask(prefix, width, exact)
  local cfg = S.cfg or {}
  local char = cfg.cloak_character or "*"
  local cw = math.max(api.nvim_strwidth(char), 1)
  local pw = api.nvim_strwidth(prefix)
  local n = cfg.cloak_length and tonumber(cfg.cloak_length) or nil
  local count = n and math.max(math.floor(n), 0) or math.max(math.floor((width - pw) / cw), 0)
  local s = prefix .. char:rep(count)
  if not exact then
    local rest = width - api.nvim_strwidth(s)
    if rest > 0 then
      s = s .. (" "):rep(rest)
    end
  end
  return s
end

-- Buffer state ---------------------------------------------------------------------------------

local function has_display_providers()
  for _, p in ipairs(require("slop.core.secrets").providers()) do
    if p.display then
      return true
    end
  end
  return false
end

---@param buf integer
---@param win? integer
---@return string
local function path_of(buf, win)
  local p = vim.b[buf].slop_secret_path
  if type(p) == "string" and p ~= "" then
    return p
  end
  local name = api.nvim_buf_get_name(buf)
  if name == "" and win and S.fallback_path then
    local ok, fp = pcall(S.fallback_path, win, buf)
    if ok and type(fp) == "string" then
      return fp
    end
  end
  return name
end

--- Cloak state of a buffer, nil when no rule applies. Recomputed when the effective path changes.
---@param buf integer
---@param win? integer
---@return slop.cloak.BufState?
function M.buf_state(buf, win)
  if not api.nvim_buf_is_valid(buf) then
    S.bufs[buf] = nil
    return nil
  end
  local path = path_of(buf, win)
  local st = S.bufs[buf]
  if st ~= nil and (st == false and S.bufs_path[buf] == path or st and st.path == path) then
    return st or nil
  end
  S.bufs_path[buf] = path
  local rules = path ~= "" and S.rules(path) or {}
  local display = path ~= "" and has_display_providers()
  if #rules == 0 and not display then
    S.bufs[buf] = false
    return nil
  end
  st = { path = path, rules = rules, display = display, tick = -1, rows = {}, drawn = {} }
  S.bufs[buf] = st
  return st
end

--- Is the buffer cloaked (a rule applies) — regardless of display state?
---@param buf integer
---@return boolean
function M.is_cloaked(buf)
  local st = M.buf_state(buf)
  return st ~= nil and #st.rules > 0
end

--- Display state of a buffer (global flag, per-buffer override).
---@param buf? integer
---@return boolean
function M.is_enabled(buf)
  buf = (buf == nil or buf == 0) and api.nvim_get_current_buf() or buf
  local o = api.nvim_buf_is_valid(buf) and vim.b[buf].slop_cloak_enabled
  if o == true or o == false then
    return o
  end
  return S.global
end

local function shown(buf, st)
  return st ~= nil and M.is_enabled(buf)
end

--- Spans (with mask text) of one row, cached per changedtick.
---@param buf integer
---@param st slop.cloak.BufState
---@param row integer
---@param line string
local function row_spans(buf, st, row, line)
  local cached = st.rows[row]
  if cached then
    return cached
  end
  local cfg = S.cfg or {}
  local spans = require("slop.modules.cloak.patterns").compute(st.rules, { line }, row, cfg)
  if st.display then
    local extra = require("slop.core.secrets").spans(st.path, { line }, row, { display = true })
    for _, e in ipairs(extra) do
      spans[#spans + 1] = { row = row, col = e.col, end_col = e.end_col, prefix = "" }
    end
    if #extra > 0 then
      table.sort(spans, function(a, b)
        return a.col < b.col
      end)
      local merged = {}
      for _, s in ipairs(spans) do
        local last = merged[#merged]
        if last and s.col < last.end_col then
          last.end_col = math.max(last.end_col, s.end_col)
        else
          merged[#merged + 1] = s
        end
      end
      spans = merged
    end
  end
  local ts = vim.bo[buf].tabstop
  local exact = render_mode() == "conceal"
  local out = {}
  for _, s in ipairs(spans) do
    local ec = math.min(s.end_col, #line)
    if ec > s.col then
      local vcol = M.width(line:sub(1, s.col), 0, ts)
      local w = M.width(line:sub(s.col + 1, ec), vcol, ts)
      out[#out + 1] = { col = s.col, end_col = ec, text = M.mask(s.prefix or "", w, exact) }
    end
  end
  st.rows[row] = out
  return out
end

local function revealed(win, buf, row)
  local r = S.reveal[win]
  return r ~= nil and r.buf == buf and row >= r.srow and row <= r.erow
end

local function revealed_any(buf, row)
  for win, r in pairs(S.reveal) do
    if r.buf == buf and row >= r.srow and row <= r.erow and api.nvim_win_is_valid(win) then
      return true
    end
  end
  return false
end

-- Decoration provider -------------------------------------------------------------------------

local schedule_win -- forward

local function on_win(_, win, buf, top, bot)
  local st = M.buf_state(buf, win)
  if not shown(buf, st) then
    return false
  end
  ---@cast st slop.cloak.BufState
  local tick = api.nvim_buf_get_changedtick(buf)
  if st.tick ~= tick then
    st.tick, st.rows, st.drawn = tick, {}, {}
  end
  schedule_win(win, buf)
  local hl = (S.cfg and S.cfg.highlight_group) or "SlopCloakMask"
  local lines = api.nvim_buf_get_lines(buf, top, bot + 1, false)
  if render_mode() == "conceal" then
    local nsc = ns_conceal()
    for i, line in ipairs(lines) do
      local row = top + i - 1
      local rev = revealed_any(buf, row)
      local key = tick .. (rev and "r" or "") .. line
      if st.drawn[row] ~= key then
        st.drawn[row] = key
        for _, m in ipairs(api.nvim_buf_get_extmarks(buf, nsc, { row, 0 }, { row, -1 }, {})) do
          api.nvim_buf_del_extmark(buf, nsc, m[1])
        end
        if not rev then
          for _, s in ipairs(row_spans(buf, st, row, line)) do
            pcall(api.nvim_buf_set_extmark, buf, nsc, row, s.col, {
              end_col = s.end_col,
              conceal = "",
              virt_text = { { s.text, hl } },
              virt_text_pos = "inline",
              invalidate = true,
              undo_restore = false,
              priority = 200,
            })
          end
        end
      end
    end
    return false
  end
  local nso = ns()
  for i, line in ipairs(lines) do
    local row = top + i - 1
    if not revealed(win, buf, row) then
      for _, s in ipairs(row_spans(buf, st, row, line)) do
        pcall(api.nvim_buf_set_extmark, buf, nso, row, s.col, {
          virt_text = { { s.text, hl } },
          virt_text_pos = "overlay",
          hl_mode = "combine",
          ephemeral = true,
          priority = 200,
        })
      end
    end
  end
  return false
end

-- Window options / completion side effects -----------------------------------------------------

local function win_opts_wanted()
  if render_mode() == "conceal" then
    return { conceallevel = 2, concealcursor = "nvic" }
  end
  if S.cfg and S.cfg.nowrap == false then
    return {}
  end
  return { wrap = false }
end

--- Apply or restore the window-local options for the buffer currently shown in `win`.
---@param win integer
function M.apply_win(win)
  if not api.nvim_win_is_valid(win) then
    S.saved[win] = nil
    return
  end
  local buf = api.nvim_win_get_buf(win)
  local st = M.buf_state(buf, win)
  local saved = S.saved[win] and S.saved[win][buf]
  if S.active and shown(buf, st) then
    for opt, val in pairs(win_opts_wanted()) do
      local cur = vim.wo[win][0][opt]
      if cur ~= val then
        S.saved[win] = S.saved[win] or {}
        S.saved[win][buf] = S.saved[win][buf] or {}
        if S.saved[win][buf][opt] == nil then
          S.saved[win][buf][opt] = cur
        end
        vim.wo[win][0][opt] = val
      end
    end
  elseif saved then
    for opt, val in pairs(saved) do
      pcall(function()
        vim.wo[win][0][opt] = val
      end)
    end
    S.saved[win][buf] = nil
  end
end

local pending_wins = {}
schedule_win = function(win, buf)
  local want = win_opts_wanted()
  local need = false
  for opt, val in pairs(want) do
    if vim.wo[win][opt] ~= val then
      need = true
    end
  end
  if need or (S.cfg and S.cfg.disable_completion and not S.completion[buf]) then
    if not pending_wins[win] then
      pending_wins[win] = true
      vim.schedule(function()
        pending_wins[win] = nil
        M.apply_win(win)
        if api.nvim_win_is_valid(win) then
          M.apply_buf(api.nvim_win_get_buf(win))
        end
      end)
    end
  end
end

--- Disable/restore completion for a buffer according to its cloak display state.
---@param buf integer
function M.apply_buf(buf)
  if not api.nvim_buf_is_valid(buf) then
    S.completion[buf] = nil
    return
  end
  local integ = require("slop.modules.cloak.integrations")
  local want = S.active and S.cfg and S.cfg.disable_completion ~= false and shown(buf, M.buf_state(buf))
  if want and not S.completion[buf] then
    S.completion[buf] = true
    integ.completion(buf, false)
  elseif not want and S.completion[buf] then
    S.completion[buf] = nil
    integ.completion(buf, true)
  end
end

-- Redraw / state changes ----------------------------------------------------------------------

--- Redraw every window showing `buf` (all windows when nil), re-applying side effects.
---@param buf? integer
function M.refresh(buf)
  for b, st in pairs(S.bufs) do
    if (buf == nil or b == buf) and st then
      st.rows, st.tick, st.drawn = {}, -1, {}
      if (render_mode() ~= "conceal" or not shown(b, st)) and api.nvim_buf_is_valid(b) then
        api.nvim_buf_clear_namespace(b, ns_conceal(), 0, -1)
      end
    end
  end
  for _, win in ipairs(api.nvim_list_wins()) do
    local b = api.nvim_win_get_buf(win)
    if buf == nil or b == buf then
      M.apply_win(win)
      M.apply_buf(b)
      pcall(api.nvim__redraw, { win = win, valid = false, flush = false })
    end
  end
end

--- Forget cached state (rules changed, buffer renamed...).
---@param buf? integer
function M.invalidate(buf)
  if buf then
    S.bufs[buf], S.bufs_path[buf] = nil, nil
    if api.nvim_buf_is_valid(buf) then
      api.nvim_buf_clear_namespace(buf, ns_conceal(), 0, -1)
    end
  else
    for b in pairs(S.bufs) do
      if api.nvim_buf_is_valid(b) then
        api.nvim_buf_clear_namespace(b, ns_conceal(), 0, -1)
      end
    end
    S.bufs, S.bufs_path = {}, {}
  end
end

---@param enabled boolean
---@param scope? "global"|"buffer"
---@param buf? integer
function M.set_enabled(enabled, scope, buf)
  buf = (buf == nil or buf == 0) and api.nvim_get_current_buf() or buf
  if scope == "buffer" then
    vim.b[buf].slop_cloak_enabled = enabled
  else
    S.global = enabled
    for _, b in ipairs(api.nvim_list_bufs()) do
      if api.nvim_buf_is_valid(b) and vim.b[b].slop_cloak_enabled ~= nil then
        vim.b[b].slop_cloak_enabled = nil
      end
    end
  end
  if not enabled then
    M.end_reveal()
  end
  M.refresh()
  require("slop.core.events").emit(
    "cloak",
    "Toggled",
    { enabled = enabled, buf = scope == "buffer" and buf or nil, scope = scope or "global" }
  )
end

-- Preview line --------------------------------------------------------------------------------

--- End reveal(s): of one window, or all.
---@param win? integer
function M.end_reveal(win)
  for w, r in pairs(S.reveal) do
    if win == nil or w == win then
      for _, id in ipairs(r.ids) do
        pcall(api.nvim_del_autocmd, id)
      end
      S.reveal[w] = nil
      if api.nvim_buf_is_valid(r.buf) then
        local st = S.bufs[r.buf]
        if st then
          st.drawn = {}
        end
        pcall(api.nvim__redraw, { buf = r.buf, valid = false, flush = false })
      end
    end
  end
end

--- Reveal `count` rows from the cursor in the current window until the cursor leaves them / the window /
--- the buffer. No-op when the buffer is not cloaked or display is off (cloak.nvim parity).
---@param count? integer
---@return boolean revealed
function M.preview_line(count)
  local win, buf = api.nvim_get_current_win(), api.nvim_get_current_buf()
  local st = M.buf_state(buf, win)
  if not shown(buf, st) then
    return false
  end
  M.end_reveal(win)
  local row = api.nvim_win_get_cursor(win)[1] - 1
  local n = math.max((count or 1), 1)
  local r = { buf = buf, srow = row, erow = row + n - 1, ids = {} }
  S.reveal[win] = r
  local group = require("slop.core.util").augroup("cloak")
  r.ids[#r.ids + 1] = api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
    group = group,
    buffer = buf,
    desc = "slop: cloak re-cloak previewed line",
    callback = function()
      local cw = api.nvim_get_current_win()
      local crow = api.nvim_win_get_cursor(cw)[1] - 1
      if cw ~= win or crow < r.srow or crow > r.erow then
        M.end_reveal(win)
      end
    end,
  })
  r.ids[#r.ids + 1] = api.nvim_create_autocmd({ "BufLeave", "WinLeave" }, {
    group = group,
    buffer = buf,
    desc = "slop: cloak re-cloak previewed line",
    callback = function()
      M.end_reveal(win)
    end,
  })
  if st then
    st.drawn = {}
  end
  pcall(api.nvim__redraw, { buf = buf, valid = false, flush = false })
  return true
end

-- Lifecycle -----------------------------------------------------------------------------------

---@param cfg table
---@param rules_for fun(path: string): slop.cloak.Rule[]
function M.start(cfg, rules_for)
  S.cfg, S.rules, S.active = cfg, rules_for, true
  api.nvim_set_decoration_provider(ns(), { on_win = on_win })
  local group = require("slop.core.util").augroup("cloak")
  api.nvim_create_autocmd("BufWinEnter", {
    group = group,
    desc = "slop: cloak window options",
    callback = function(ev)
      for _, win in ipairs(vim.fn.win_findbuf(ev.buf)) do
        M.apply_win(win)
      end
      M.apply_buf(ev.buf)
    end,
  })
  api.nvim_create_autocmd({ "BufFilePost", "BufReadPost", "BufNewFile" }, {
    group = group,
    desc = "slop: cloak path changed",
    callback = function(ev)
      M.invalidate(ev.buf)
      M.refresh(ev.buf)
    end,
  })
  api.nvim_create_autocmd("BufWipeout", {
    group = group,
    desc = "slop: cloak forget buffer",
    callback = function(ev)
      S.bufs[ev.buf], S.bufs_path[ev.buf], S.completion[ev.buf] = nil, nil, nil
    end,
  })
  api.nvim_create_autocmd("WinClosed", {
    group = group,
    desc = "slop: cloak forget window",
    callback = function(ev)
      local w = tonumber(ev.match)
      if w then
        M.end_reveal(w)
        S.saved[w] = nil
      end
    end,
  })
  if cfg.cloak_on_leave then
    api.nvim_create_autocmd("BufWinLeave", {
      group = group,
      desc = "slop: cloak_on_leave",
      callback = function(ev)
        if M.is_cloaked(ev.buf) and not M.is_enabled(ev.buf) then
          vim.b[ev.buf].slop_cloak_enabled = nil
          M.set_enabled(true)
        end
      end,
    })
  end
  M.refresh()
end

function M.stop()
  S.active = false
  M.end_reveal()
  pcall(api.nvim_set_decoration_provider, ns(), {})
  M.refresh() -- restores window options and completion (active = false)
  M.invalidate()
  S.completion, S.saved = {}, {}
end

---@param cfg table
function M.reconfigure(cfg)
  S.cfg = cfg
  M.invalidate()
  M.refresh()
end

return M

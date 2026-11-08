--- cloak: on-screen masking via a decoration provider (drawn rows only, no flash on open/paste/reload). Marks are
--- made in on_line, which runs for the rows Neovim draws: on_win's row range spans closed folds (100k rows after
--- `zM`), on_line gets a closed fold's first line only, the one its fold line shows.
---
--- overlay (default): ephemeral `virt_text_pos = "overlay"` marks created inside the redraw that shows the
---   text; masks are sized by display width (tabs, wide chars). Windows get local 'nowrap' (overlay cannot
---   cover continuation rows), restored when the buffer is uncloaked.
--- conceal: persistent `conceal = ""` + inline virt_text marks reconciled for the drawn rows (ephemeral
---   inline virt_text does not render), windows get conceallevel=2 / concealcursor=nvic (restored later).
---   Until a window has conceallevel >= 1 (it got the buffer without BufWinEnter), overlay masks are drawn.
--- Both modes give windows a local foldtext="" (fold lines are drawn with their masks) and turn 'inccommand'
--- off while a ":" command is typed over a masked buffer (the live preview shows substituted text).
---
--- Display state: a global flag plus a per-buffer override (vim.b.slop_cloak_enabled). It never affects
--- core.secrets redaction (computed from text by the provider registered in init.lua).
local M = {}

local api = vim.api

---@class slop.cloak.BufState
---@field path string
---@field rules slop.cloak.Rule[]
---@field display boolean        display providers of core.secrets may add spans
---@field has_spans? boolean     a span was drawn (display-only buffers get side effects only then)
---@field tick integer
---@field tabs? string           'tabstop'|'vartabstop' the row cache was computed with
---@field ts? integer
---@field vts? integer[]
---@field rows table<integer, {col: integer, end_col: integer, text: string, width: integer}[]>
---@field drawn table<integer, string>  conceal mode: row -> key of what is drawn

local S = {
  cfg = nil, ---@type table?
  ---@type fun(path: string): slop.cloak.Rule[]
  rules = function()
    return {}
  end,
  global = true,
  bufs = {}, ---@type table<integer, slop.cloak.BufState|false>
  bufs_path = {}, ---@type table<integer, string>  path a `false` entry was computed for
  reveal = {}, ---@type table<integer, {buf: integer, srow: integer, erow: integer, ids: integer[]}>
  saved = {}, ---@type table<integer, table<integer, table<string, any>>>  win -> buf -> saved options
  --- buf -> option -> cloak set it to `to` in place of the user's `from` (other windows may copy `to` along with the
  --- buffer, see apply_win)
  orig = {}, ---@type table<integer, table<string, {from: any, to: any}>>
  completion = {}, ---@type table<integer, boolean>  buffers whose completion we disabled
  unlisted = {}, ---@type table<integer, boolean>  nobuflisted: buffer -> it was listed before
  split_src = nil, ---@type integer?  window being split (WinNewPre)
  icm = nil, ---@type string?  'inccommand' saved while a ":" cmdline is open over a masked buffer
  leave_au = nil, ---@type integer?  cloak_on_leave autocmd
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

--- Cells of a tab at screen column `vcol` ('vartabstop' wins over 'tabstop', as in Vim's tabstop_padding()).
---@param vcol integer
---@param ts integer
---@param vts? integer[]
---@return integer
local function tab_width(vcol, ts, vts)
  if not vts or #vts == 0 then
    ts = ts > 0 and ts or 8
    return ts - (vcol % ts)
  end
  local stop = 0
  for _, w in ipairs(vts) do
    stop = stop + w
    if stop > vcol then
      return stop - vcol
    end
  end
  local last = vts[#vts]
  return last - ((vcol - stop) % last)
end

--- Display width of `s` starting at screen column `vcol`: tabs expand per 'tabstop'/'vartabstop', the rest as
--- Neovim draws it (wide chars, ^X for control chars, <xx> for invalid bytes; nvim_strwidth() says 1 for ^X).
---@param s string
---@param vcol integer
---@param ts integer
---@param vts? integer[]
---@return integer
function M.width(s, vcol, ts, vts)
  if not s:find("[\t\128-\255%c]") then
    return #s
  end
  local w = 0
  for text, tab in s:gmatch("([^\t]*)(\t?)") do
    if text ~= "" then
      w = w + vim.fn.strdisplaywidth(text)
    end
    if tab ~= "" then
      w = w + tab_width(vcol + w, ts, vts)
    end
  end
  return w
end

--- Tab settings of a buffer, plus a key that changes when they do.
---@param buf integer
---@return integer ts, integer[]? vts, string key
local function tabs_of(buf)
  local ts, vts = vim.bo[buf].tabstop, vim.bo[buf].vartabstop
  local list = vts ~= "" and vim.tbl_map(tonumber, vim.split(vts, ",", { plain = true })) or nil
  return ts, list, ts .. "|" .. vts
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
  -- An unnamed buffer's fallback path (fzf-lua preview) needs a window. A window-less lookup (apply_buf,
  -- is_cloaked) would read "" and clobber what on_win found, rebuilding the state on every redraw.
  if st ~= nil and win == nil and path == "" then
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

--- Window options, completion and listing only change where something is masked: a cloak rule applies, or a
--- display provider produced a span (one display provider must not touch every buffer).
---@param buf integer
---@param st slop.cloak.BufState?
---@return boolean
local function affected(buf, st)
  if not shown(buf, st) then
    return false
  end
  ---@cast st slop.cloak.BufState
  return #st.rules > 0 or st.has_spans == true
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
  local ts, vts = st.ts or vim.bo[buf].tabstop, st.vts
  local exact = render_mode() == "conceal"
  local out = {}
  for _, s in ipairs(spans) do
    local ec = math.min(s.end_col, #line)
    if ec > s.col then
      local vcol = M.width(line:sub(1, s.col), 0, ts, vts)
      local w = M.width(line:sub(s.col + 1, ec), vcol, ts, vts)
      out[#out + 1] = { col = s.col, end_col = ec, text = M.mask(s.prefix or "", w, exact), width = w }
    end
  end
  if #out > 0 then
    st.has_spans = true
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

---@type table<integer, {buf: integer, st: slop.cloak.BufState, tick: integer, hl: string, conceal: boolean}>
local drawing = {} -- window -> what on_line draws for it in the current redraw

local function on_win(_, win, buf)
  drawing[win] = nil
  local st = M.buf_state(buf, win)
  if not shown(buf, st) then
    return false
  end
  ---@cast st slop.cloak.BufState
  local tick = api.nvim_buf_get_changedtick(buf)
  local ts, vts, tabs = tabs_of(buf)
  if st.tick ~= tick or st.tabs ~= tabs then
    -- mask widths depend on the tab settings too (a wider tab must not reuse a narrower mask)
    st.tick, st.tabs, st.ts, st.vts, st.rows, st.drawn = tick, tabs, ts, vts, {}, {}
  end
  drawing[win] = {
    buf = buf,
    st = st,
    tick = tick,
    hl = (S.cfg and S.cfg.highlight_group) or "SlopCloakMask",
    -- conceal marks need conceallevel >= 1; a window that got the buffer without BufWinEnter (fzf-lua swaps
    -- preview buffers with eventignore, noautocmd floats) only gets it from schedule_win: draw overlays until then
    conceal = render_mode() == "conceal" and vim.wo[win].conceallevel >= 1,
  }
  if affected(buf, st) then
    schedule_win(win, buf)
  end
  -- the rows are drawn in on_line: on_win's top..bot spans closed folds (100k rows after `zM`), which are
  -- never drawn and must not be fetched or matched
  return true
end

local function on_line(_, win, buf, row)
  local d = drawing[win]
  if not d or d.buf ~= buf then
    return
  end
  local st = d.st
  local line = api.nvim_buf_get_lines(buf, row, row + 1, false)[1]
  if not line then
    return
  end
  local had = st.has_spans
  if d.conceal then
    local nsc = ns_conceal()
    local rev = revealed_any(buf, row)
    local key = d.tick .. (rev and "r" or "") .. line
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
            virt_text = { { s.text, d.hl } },
            virt_text_pos = "inline",
            invalidate = true,
            undo_restore = false,
            priority = 200,
          })
        end
      end
    end
  elseif not revealed(win, buf, row) then
    local nso = ns()
    for _, s in ipairs(row_spans(buf, st, row, line)) do
      -- conceal-mode masks are exact (cloak_length): as an overlay it must still cover the whole value
      local pad = s.width - api.nvim_strwidth(s.text)
      pcall(api.nvim_buf_set_extmark, buf, nso, row, s.col, {
        virt_text = { { pad > 0 and s.text .. (" "):rep(pad) or s.text, d.hl } },
        virt_text_pos = "overlay",
        hl_mode = "combine",
        ephemeral = true,
        priority = 200,
      })
    end
  end
  -- row_spans() may just have found the first span of a display-only buffer: it gets the side effects now
  if not had and st.has_spans and affected(buf, st) then
    schedule_win(win, buf)
  end
end

-- Window options / completion side effects -----------------------------------------------------

local function win_opts_wanted()
  -- a closed fold shows its first line: with foldtext() as raw text, with foldtext="" drawn with its masks
  -- (diff mode folds every unchanged region)
  if render_mode() == "conceal" then
    return { conceallevel = 2, concealcursor = "nvic", foldtext = "" }
  end
  if S.cfg and S.cfg.nowrap == false then
    return { foldtext = "" }
  end
  return { wrap = false, foldtext = "" }
end

local applying = false -- apply_win() sets options, which fires the OptionSet handler that calls it

---@param win integer
---@param buf integer
---@param opt string
---@param val any
local function save_opt(win, buf, opt, val)
  S.saved[win] = S.saved[win] or {}
  S.saved[win][buf] = S.saved[win][buf] or {}
  if S.saved[win][buf][opt] == nil then
    S.saved[win][buf][opt] = val
  end
end

---@param win integer
---@param entered? boolean  the window just got the buffer (BufWinEnter)
local function apply_win(win, entered)
  local buf = api.nvim_win_get_buf(win)
  local st = M.buf_state(buf, win)
  local saved = S.saved[win] and S.saved[win][buf]
  -- A window that gets a buffer copies its window-local options from another window showing it, or from the
  -- window info Neovim keeps per buffer (also of closed windows): cloak's values arrive without passing here
  -- first. `orig` tells which values are cloak's, so they are restored there too.
  local orig = S.orig[buf] or {}
  if S.active and affected(buf, st) then
    local want = win_opts_wanted()
    -- options of an earlier config (render mode or nowrap changed live) go back to the user's value
    for opt, val in pairs(vim.deepcopy(saved or {})) do
      if want[opt] == nil then
        pcall(function()
          vim.wo[win][0][opt] = val
        end)
        saved[opt] = nil
      end
    end
    for opt, val in pairs(want) do
      local cur = vim.wo[win][0][opt]
      if cur ~= val then
        save_opt(win, buf, opt, cur)
        S.orig[buf] = S.orig[buf] or {}
        S.orig[buf][opt] = { from = cur, to = val }
        vim.wo[win][0][opt] = val
      elseif not (saved and saved[opt] ~= nil) and orig[opt] and orig[opt].to == val then
        save_opt(win, buf, opt, orig[opt].from) -- copied from a cloaked window
      end
    end
  else
    for opt, val in pairs(saved or {}) do
      pcall(function()
        vim.wo[win][0][opt] = val
      end)
    end
    for opt, o in pairs(entered and orig or {}) do
      if not (saved and saved[opt] ~= nil) and vim.wo[win][0][opt] == o.to then
        pcall(function()
          vim.wo[win][0][opt] = o.from -- copied from a cloaked window, never saved here
        end)
      end
    end
    if saved then
      S.saved[win][buf] = nil
    end
  end
end

--- Apply or restore the window-local options for the buffer currently shown in `win`.
---@param win integer
---@param entered? boolean  the window just got the buffer (BufWinEnter)
function M.apply_win(win, entered)
  if not api.nvim_win_is_valid(win) then
    S.saved[win] = nil
    return
  end
  if applying then
    return
  end
  applying = true
  local ok, err = pcall(apply_win, win, entered)
  applying = false
  if not ok then
    error(err, 0)
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
  local cfg = S.cfg or {}
  if need or (cfg.disable_completion and not S.completion[buf]) or (cfg.nobuflisted and S.unlisted[buf] == nil) then
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

--- Disable/restore completion (and, with nobuflisted, the listing) of a buffer per its cloak display state.
---@param buf integer
function M.apply_buf(buf)
  if not api.nvim_buf_is_valid(buf) then
    S.completion[buf], S.unlisted[buf] = nil, nil
    return
  end
  local integ = require("slop.modules.cloak.integrations")
  local hit = S.active and S.cfg ~= nil and affected(buf, M.buf_state(buf))
  local want = hit and S.cfg.disable_completion ~= false
  if want and not S.completion[buf] then
    S.completion[buf] = true
    integ.completion(buf, false)
  elseif not want and S.completion[buf] then
    S.completion[buf] = nil
    integ.completion(buf, true)
  end
  -- opt-in: the b/u sources of 'complete' skip unlisted buffers, so other buffers' <C-n> / 'autocomplete'
  -- stop offering the cloaked values
  local unlist = hit and S.cfg.nobuflisted == true
  if unlist and S.unlisted[buf] == nil then
    S.unlisted[buf] = vim.bo[buf].buflisted -- only a buffer we unlisted is listed again
    vim.bo[buf].buflisted = false
  elseif not unlist and S.unlisted[buf] ~= nil then
    if S.unlisted[buf] then
      vim.bo[buf].buflisted = true
    end
    S.unlisted[buf] = nil
  end
end

-- Redraw / state changes ----------------------------------------------------------------------

--- Redraw every window showing `buf` (all windows when nil), re-applying side effects.
---@param buf? integer  0 = current buffer
function M.refresh(buf)
  buf = buf == 0 and api.nvim_get_current_buf() or buf
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
  -- hidden buffers get their completion / listing back too (display toggled off, teardown)
  for b in pairs(vim.tbl_extend("force", {}, S.completion, S.unlisted)) do
    if buf == nil or b == buf then
      M.apply_buf(b)
    end
  end
end

--- Forget cached state (rules changed, buffer renamed...).
---@param buf? integer  0 = current buffer
function M.invalidate(buf)
  buf = buf == 0 and api.nvim_get_current_buf() or buf
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
    buf = buf,
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
    buf = buf,
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

--- (Re)create the cloak_on_leave autocmd for the current config (none when off or stopped).
local function set_on_leave()
  if S.leave_au then
    pcall(api.nvim_del_autocmd, S.leave_au)
    S.leave_au = nil
  end
  if not (S.active and S.cfg and S.cfg.cloak_on_leave) then
    return
  end
  S.leave_au = api.nvim_create_autocmd("BufWinLeave", {
    group = require("slop.core.util").augroup("cloak"),
    desc = "slop: cloak_on_leave",
    callback = function(ev)
      if M.is_cloaked(ev.buf) and not M.is_enabled(ev.buf) then
        vim.b[ev.buf].slop_cloak_enabled = nil
        M.set_enabled(true)
      end
    end,
  })
end

local function restore_icm()
  if S.icm ~= nil then
    vim.o.inccommand, S.icm = S.icm, nil
  end
end

---@param cfg table
---@param rules_for fun(path: string): slop.cloak.Rule[]
function M.start(cfg, rules_for)
  S.cfg, S.rules, S.active = cfg, rules_for, true
  api.nvim_set_decoration_provider(ns(), { on_win = on_win, on_line = on_line })
  local group = require("slop.core.util").augroup("cloak")
  api.nvim_create_autocmd("BufWinEnter", {
    group = group,
    desc = "slop: cloak window options",
    callback = function(ev)
      local cur = api.nvim_get_current_win() -- the window the buffer entered
      for _, win in ipairs(vim.fn.win_findbuf(ev.buf)) do
        M.apply_win(win, win == cur)
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
      S.bufs[ev.buf], S.bufs_path[ev.buf], S.completion[ev.buf], S.unlisted[ev.buf] = nil, nil, nil, nil
      S.orig[ev.buf] = nil
    end,
  })
  api.nvim_create_autocmd("WinClosed", {
    group = group,
    desc = "slop: cloak forget window",
    callback = function(ev)
      local w = tonumber(ev.match)
      if w then
        M.end_reveal(w)
        S.saved[w], drawing[w] = nil, nil
      end
    end,
  })
  -- a split / float of a cloaked window inherits its local options, cloak's overrides included: give it the
  -- source's saved values too, or they would never be restored (WinNew runs with the new window current)
  api.nvim_create_autocmd("WinNewPre", {
    group = group,
    desc = "slop: cloak remember the split window",
    callback = function()
      S.split_src = api.nvim_get_current_win()
    end,
  })
  api.nvim_create_autocmd("WinNew", {
    group = group,
    desc = "slop: cloak options inherited by a new window",
    callback = function()
      local new, src = api.nvim_get_current_win(), S.split_src
      S.split_src = nil
      local buf = api.nvim_win_get_buf(new)
      local from = src and S.saved[src] and S.saved[src][buf]
      if not from then -- floats have no WinNewPre: any window showing the buffer
        for w, bufs in pairs(S.saved) do
          if w ~= new and bufs[buf] and api.nvim_win_is_valid(w) and api.nvim_win_get_buf(w) == buf then
            from = bufs[buf]
            break
          end
        end
      end
      if from then
        S.saved[new] = S.saved[new] or {}
        S.saved[new][buf] = vim.deepcopy(from)
      end
    end,
  })
  -- `:set wrap` & co. on a cloaked window are undone before the redraw that would show them (OptionSet runs
  -- with the changed window current); schedule_win() would only fix it one frame later
  api.nvim_create_autocmd("OptionSet", {
    group = group,
    pattern = { "wrap", "conceallevel", "concealcursor", "foldtext" },
    desc = "slop: cloak keep window options",
    callback = function()
      M.apply_win(api.nvim_get_current_win())
    end,
  })
  -- 'inccommand' shows the substituted text live (in the window and the "[Preview]" split), which the rules
  -- may no longer match (`:%s/=/: /` turns KEY=secret into KEY: secret): off while a ":" command is typed
  -- over a masked buffer
  api.nvim_create_autocmd("CmdlineEnter", {
    group = group,
    pattern = ":",
    desc = "slop: cloak no live :s preview of secrets",
    callback = function()
      local win, buf = api.nvim_get_current_win(), api.nvim_get_current_buf()
      if S.icm == nil and vim.o.inccommand ~= "" and affected(buf, M.buf_state(buf, win)) then
        S.icm = vim.o.inccommand
        vim.o.inccommand = ""
      end
    end,
  })
  api.nvim_create_autocmd("CmdlineLeave", {
    group = group,
    pattern = ":",
    desc = "slop: cloak restore 'inccommand'",
    callback = restore_icm,
  })
  set_on_leave()
  M.refresh()
end

function M.stop()
  S.active = false
  M.end_reveal()
  pcall(api.nvim_set_decoration_provider, ns(), {})
  restore_icm()
  set_on_leave() -- deletes it (not active)
  M.refresh() -- restores window options, completion and listing (active = false)
  M.invalidate()
  S.completion, S.saved, S.unlisted, S.orig = {}, {}, {}, {}
  drawing = {}
end

---@param cfg table
function M.reconfigure(cfg)
  S.cfg = cfg
  set_on_leave()
  M.invalidate()
  M.refresh()
end

return M

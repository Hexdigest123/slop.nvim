--- context: the floats. One state per source window: a text float pinned over the window's text area (row 0) and a
--- gutter float over its number/sign columns. Lines are the source rows; highlights are copied from the source
--- buffer (treesitter captures of its active highlighter + highlight extmarks such as semantic tokens), never
--- re-parsed. Floats are raw borderless windows on purpose: they must line up cell for cell with the window.
local M = {}

local api = vim.api
local uv = vim.uv

---@class slop.context.WinState
---@field buf? integer   text float buffer
---@field fwin? integer  text float window
---@field gbuf? integer  gutter float buffer
---@field gwin? integer  gutter float window
---@field key? string    what is on screen (skip identical redraws)
---@field groups slop.context.Group[]

local S = {
  cfg = nil, ---@type table?
  enabled = true,
  wins = {}, ---@type table<integer, slop.context.WinState>
  timer = nil, ---@type uv.uv_timer_t?
  last = 0,
  tokens = nil, ---@type slop.util.Debounced?
}
M._state = S

M.THROTTLE_MS = 30

local function ns()
  return require("slop.core.util").ns("context")
end

local function log()
  return require("slop.core.log").scope("context")
end

local function scopes()
  return require("slop.modules.context.scopes")
end

local function valid_win(w)
  return w ~= nil and api.nvim_win_is_valid(w)
end

local function valid_buf(b)
  return b ~= nil and api.nvim_buf_is_valid(b)
end

-- Windows --------------------------------------------------------------------------------------

local function close_win(w)
  if valid_win(w) then
    pcall(api.nvim_win_close, w, true)
  end
end

--- Hide the context of `win` (its buffers are kept for the next show).
---@param win integer
function M.close(win)
  local st = S.wins[win]
  if not st then
    return
  end
  close_win(st.fwin)
  close_win(st.gwin)
  st.fwin, st.gwin, st.key, st.groups = nil, nil, nil, {}
end

--- Hide and forget the context of `win` (WinClosed).
---@param win integer
function M.free(win)
  local st = S.wins[win]
  if not st then
    return
  end
  M.close(win)
  for _, b in ipairs({ st.buf, st.gbuf }) do
    if valid_buf(b) then
      pcall(api.nvim_buf_delete, b, { force = true })
    end
  end
  S.wins[win] = nil
end

function M.close_all()
  for win in pairs(S.wins) do
    M.close(win)
  end
end

local function scratch()
  local b = api.nvim_create_buf(false, true)
  vim.bo[b].bufhidden = "hide"
  vim.bo[b].undolevels = -1
  vim.b[b].slop_context_float = true
  return b
end

--- Why `win` shows no context (nil = it may).
---@param win integer
---@return string?
function M.hidden(win)
  local cfg = S.cfg
  if not cfg or not S.enabled then
    return "disabled"
  end
  if not valid_win(win) then
    return "invalid window"
  end
  if api.nvim_win_get_config(win).relative ~= "" then
    return "floating window"
  end
  local buf = api.nvim_win_get_buf(win)
  if vim.bo[buf].buftype ~= "" then
    return "buftype " .. vim.bo[buf].buftype
  end
  if vim.b[buf].slop_context == false then
    return "vim.b.slop_context = false"
  end
  if api.nvim_win_get_height(win) < math.max(cfg.min_window_height, 2) then
    return "window too small"
  end
  return nil
end

---@param cfg table
---@return string|string[]
local function border(cfg)
  local sep = cfg.separator
  if sep then
    return { "", "", "", "", sep, sep, sep, "" }
  end
  return "none"
end

--- Open or move a float.
---@param w integer?
---@param buf integer
---@param conf vim.api.keyset.win_config
---@param winhl string
---@return integer?
local function place(w, buf, conf, winhl)
  if valid_win(w) then
    ---@cast w integer
    if api.nvim_win_get_buf(w) ~= buf then
      api.nvim_win_set_buf(w, buf)
    end
    api.nvim_win_set_config(w, conf)
    return w
  end
  local open = vim.tbl_extend("force", conf, { style = "minimal", noautocmd = true })
  local ok, nw = pcall(api.nvim_open_win, buf, false, open)
  if not ok then
    log().debug("open float: %s", nw)
    return nil
  end
  local o = { win = nw }
  api.nvim_set_option_value("winhighlight", winhl, o)
  api.nvim_set_option_value("wrap", false, o)
  api.nvim_set_option_value("foldenable", false, o)
  api.nvim_set_option_value("spell", false, o)
  api.nvim_set_option_value("sidescrolloff", 0, o)
  api.nvim_set_option_value("winblend", 0, o)
  return nw
end

-- Highlights -----------------------------------------------------------------------------------

---@class slop.context.Seg
---@field [1] integer row (float buffer)
---@field [2] integer col
---@field [3] integer end col
---@field [4] integer|string hl group
---@field [5] integer priority
---@field [6] integer order

--- Highlight segments of source rows [srow, srow + #lines) mapped to float rows starting at `dst`.
---@param src integer
---@param srow integer
---@param lines string[]
---@param dst integer
---@param segs slop.context.Seg[]
local function collect(src, srow, lines, dst, segs)
  local erow = srow + #lines -- exclusive
  local function add(sr, sc, er, ec, hl, prio)
    for row = math.max(sr, srow), math.min(er, erow - 1) do
      local len = #lines[row - srow + 1]
      local s = row == sr and sc or 0
      local e = math.min(row == er and ec or len, len)
      if e > s then
        segs[#segs + 1] = { dst + row - srow, s, e, hl, prio, #segs }
      end
    end
  end

  -- treesitter: the buffer's own highlighter queries over the source rows
  local hl = vim.treesitter.highlighter.active[src]
  if hl then
    hl.tree:for_each_tree(function(tstree, ltree)
      if not tstree then
        return
      end
      local root = tstree:root()
      local rsr, _, rer = root:range()
      if rer < srow or rsr >= erow then
        return
      end
      local ok, q = pcall(hl.get_query, hl, ltree:lang())
      local query = ok and q and q:query()
      if not query then
        return
      end
      for id, node, metadata in query:iter_captures(root, src, srow, erow) do
        local name = query.captures[id]
        if name ~= "spell" and name ~= "nospell" then
          local hlid = q:get_hl_from_capture(id)
          if hlid and hlid ~= 0 then
            local r = vim.treesitter.get_range(node, src, metadata[id])
            local prio = tonumber(metadata.priority or (metadata[id] and metadata[id].priority))
              or vim.hl.priorities.treesitter
            add(r[1], r[2], r[4], r[5], hlid, prio)
          end
        end
      end
    end)
  end

  -- extmark highlights of every namespace (semantic tokens, diagnostics, other plugins)
  local own = ns()
  local ok, marks = pcall(
    api.nvim_buf_get_extmarks,
    src,
    -1,
    { srow, 0 },
    { erow - 1, -1 },
    { details = true, overlap = true, type = "highlight" }
  )
  for _, m in ipairs(ok and marks or {}) do
    local d = m[4]
    if d.hl_group and d.ns_id ~= own and not d.invalid and d.end_row then
      add(m[2], m[3], d.end_row, d.end_col or 0, d.hl_group, d.priority or 4096)
    end
  end
end

--- Set the collected segments on `buf`, re-ranked by (priority, order) so equal priorities stay deterministic.
---@param buf integer
---@param segs slop.context.Seg[]
local function apply(buf, segs)
  table.sort(segs, function(a, b)
    if a[5] ~= b[5] then
      return a[5] < b[5]
    end
    return a[6] < b[6]
  end)
  local n = ns()
  for i, s in ipairs(segs) do
    pcall(api.nvim_buf_set_extmark, buf, n, s[1], s[2], {
      end_col = s[3],
      hl_group = s[4],
      priority = math.min(i, 60000),
    })
  end
end

---@param buf integer
---@param row integer
local function bottom(buf, row)
  pcall(api.nvim_buf_set_extmark, buf, ns(), row, 0, {
    end_row = row + 1,
    end_col = 0,
    hl_group = "SlopContextBottom",
    hl_eol = true,
    priority = 65000,
  })
end

-- Gutter ---------------------------------------------------------------------------------------

--- Gutter text (+ highlights) of one source line, `width` cells wide.
---@param win integer
---@param lnum integer
---@param cursor integer cursor lnum
---@param width integer
---@return string text, {[1]: integer, [2]: integer, [3]: string}[] hls  {col, end_col, group}
local function gutter_line(win, lnum, cursor, width)
  local wo = vim.wo[win]
  local stc = wo.statuscolumn
  if stc ~= "" then
    local ok, res = pcall(api.nvim_eval_statusline, stc, {
      winid = win,
      use_statuscol_lnum = lnum,
      highlights = true,
      maxwidth = width,
    })
    if ok and res then
      local text = res.str .. (" "):rep(math.max(0, width - res.width))
      local hls = {}
      for i, h in ipairs(res.highlights or {}) do
        local e = res.highlights[i + 1] and res.highlights[i + 1].start or #res.str
        if e > h.start and h.group and h.group ~= "" then
          hls[#hls + 1] = { h.start, e, h.group }
        end
      end
      return text, hls
    end
  end
  local num = ""
  if wo.relativenumber and lnum ~= cursor then
    num = tostring(math.abs(lnum - cursor))
  elseif wo.number or wo.relativenumber then
    num = tostring(lnum)
  end
  if num == "" then
    return (" "):rep(width), {}
  end
  local pad = width - 1 - #num
  if pad < 0 then
    return num:sub(-width), {}
  end
  return (" "):rep(pad) .. num .. " ", {}
end

-- Update ---------------------------------------------------------------------------------------

---@param win integer
---@return integer
local function leftcol(win)
  return api.nvim_win_call(win, function()
    return vim.fn.winsaveview().leftcol
  end)
end

--- Draw `groups` over `win`.
---@param win integer
---@param info vim.fn.getwininfo.ret.item
---@param groups slop.context.Group[]
---@param height integer
---@param force? boolean
local function draw(win, info, groups, height, force)
  local cfg = assert(S.cfg)
  local src = info.bufnr
  local width = info.width - info.textoff
  if width <= 0 then
    M.close(win)
    return
  end
  local gutter = cfg.line_numbers and info.textoff > 0
  local cursor = api.nvim_win_get_cursor(win)[1]
  local lc = leftcol(win)
  local parts = {
    src,
    api.nvim_buf_get_changedtick(src),
    width,
    info.textoff,
    lc,
    tostring(cfg.separator),
    tostring(gutter),
    vim.bo[src].tabstop,
  }
  if gutter and (vim.wo[win].relativenumber or vim.wo[win].statuscolumn ~= "") then
    parts[#parts + 1] = cursor
  end
  for _, g in ipairs(groups) do
    parts[#parts + 1] = g.row .. "+" .. g.rows
  end
  local key = table.concat(parts, ":")
  local st = S.wins[win]
  if not st then
    st = { groups = {} }
    S.wins[win] = st
  end
  st.groups = groups
  if not force and st.key == key and valid_win(st.fwin) and (not gutter or valid_win(st.gwin)) then
    return
  end
  st.key = key

  -- text
  if not valid_buf(st.buf) then
    st.buf = scratch()
  end
  local buf = st.buf ---@cast buf integer
  local lines, segs, dst = {}, {}, 0
  for _, g in ipairs(groups) do
    local rows = api.nvim_buf_get_lines(src, g.row, g.row + g.rows, false)
    vim.list_extend(lines, rows)
    collect(src, g.row, rows, dst, segs)
    dst = dst + #rows
  end
  api.nvim_buf_clear_namespace(buf, ns(), 0, -1)
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].tabstop = vim.bo[src].tabstop
  vim.bo[buf].vartabstop = vim.bo[src].vartabstop
  -- cloak (and core.secrets) treat the float like the file it shows
  vim.b[buf].slop_secret_path = require("slop.core.secrets").effective_path(src)
  apply(buf, segs)
  if not cfg.separator then
    bottom(buf, #lines - 1)
  end
  local conf = {
    relative = "win",
    win = win,
    row = 0,
    col = info.textoff,
    width = width,
    height = height,
    focusable = false,
    zindex = cfg.zindex,
    border = border(cfg),
  }
  st.fwin = place(
    st.fwin,
    buf,
    conf,
    "Normal:SlopContext,NormalNC:SlopContext,EndOfBuffer:SlopContext,FloatBorder:SlopContextSeparator"
  )
  if not st.fwin then
    M.close(win)
    return
  end
  local fo = { win = st.fwin }
  api.nvim_set_option_value("list", vim.wo[win].list, fo)
  api.nvim_set_option_value("listchars", vim.wo[win].listchars, fo)
  local fwin = st.fwin
  api.nvim_win_call(fwin, function()
    vim.fn.winrestview({ topline = 1, lnum = 1, col = 0, leftcol = lc })
  end)

  -- gutter
  if not gutter then
    close_win(st.gwin)
    st.gwin = nil
    return
  end
  if not valid_buf(st.gbuf) then
    st.gbuf = scratch()
  end
  local gbuf = st.gbuf ---@cast gbuf integer
  local glines, ghls = {}, {}
  for _, g in ipairs(groups) do
    for lnum = g.row + 1, g.row + g.rows do
      local text, hls = gutter_line(win, lnum, cursor, info.textoff)
      glines[#glines + 1] = text
      ghls[#glines] = hls
    end
  end
  api.nvim_buf_clear_namespace(gbuf, ns(), 0, -1)
  api.nvim_buf_set_lines(gbuf, 0, -1, false, glines)
  for row, hls in pairs(ghls) do
    for _, h in ipairs(hls) do
      pcall(api.nvim_buf_set_extmark, gbuf, ns(), row - 1, h[1], { end_col = h[2], hl_group = h[3] })
    end
  end
  if not cfg.separator then
    bottom(gbuf, #glines - 1)
  end
  conf.col, conf.width = 0, info.textoff
  st.gwin = place(
    st.gwin,
    gbuf,
    conf,
    "Normal:SlopContextLineNumber,NormalNC:SlopContextLineNumber,EndOfBuffer:SlopContextLineNumber,"
      .. "FloatBorder:SlopContextSeparator"
  )
end

--- Recompute and redraw the context of `win` (default: current window).
---@param win? integer
---@param force? boolean  redraw even when nothing changed (highlights may have)
function M.update(win, force)
  win = (win == nil or win == 0) and api.nvim_get_current_win() or win
  if M.hidden(win) then
    M.close(win)
    return
  end
  local cfg = assert(S.cfg)
  local info = vim.fn.getwininfo(win)[1]
  if not info then
    return
  end
  local limit = info.height - 1 - (cfg.separator and 1 or 0)
  local ok, groups, height = pcall(scopes().compute, win, cfg, limit)
  if not ok then
    log().debug("compute: %s", groups)
    M.close(win)
    return
  end
  if not groups or height == 0 then
    M.close(win)
    if S.wins[win] then
      S.wins[win].groups = {}
    end
    return
  end
  local dok, err = pcall(draw, win, info, groups, height, force)
  if not dok then
    log().debug("draw: %s", err)
    M.close(win)
  end
end

--- Context groups currently shown over `win`.
---@param win? integer
---@return slop.context.Group[]
function M.groups(win)
  win = (win == nil or win == 0) and api.nvim_get_current_win() or win
  local st = S.wins[win]
  return st and valid_win(st.fwin) and st.groups or {}
end

--- Leading + trailing throttle of M.update(current window): runs at once unless it ran within THROTTLE_MS, else
--- once at the end of the interval. The last request always runs.
function M.request()
  local now = uv.now()
  local timer = S.timer
  if timer and timer:is_active() then
    return
  end
  local wait = S.last + M.THROTTLE_MS - now
  if wait <= 0 then
    S.last = now
    M.update()
    return
  end
  if not timer then
    timer = assert(uv.new_timer())
    S.timer = timer
  end
  timer:start(
    wait,
    0,
    vim.schedule_wrap(function()
      S.last = uv.now()
      if S.cfg then
        M.update()
      end
    end)
  )
end

-- Lifecycle ------------------------------------------------------------------------------------

---@param enabled boolean
function M.set_enabled(enabled)
  S.enabled = enabled
  if enabled then
    M.update()
  else
    M.close_all()
  end
end

---@param cfg table
function M.start(cfg)
  S.cfg = cfg
  local util = require("slop.core.util")
  local group = util.augroup("context")
  local function au(events, fn, opts)
    api.nvim_create_autocmd(
      events,
      vim.tbl_extend("force", { group = group, desc = "slop: context", callback = fn }, opts or {})
    )
  end
  au({ "CursorMoved", "CursorMovedI", "WinScrolled", "TextChanged", "TextChangedI" }, function()
    M.request()
  end)
  au({ "BufEnter", "WinEnter", "WinResized", "VimResized", "BufReadPost", "BufNewFile" }, function()
    vim.schedule(M.request)
  end)
  au("OptionSet", function()
    vim.schedule(function()
      if S.cfg then
        M.update(nil, true)
      end
    end)
  end, {
    pattern = {
      "number",
      "relativenumber",
      "numberwidth",
      "signcolumn",
      "foldcolumn",
      "statuscolumn",
      "list",
      "listchars",
      "tabstop",
      "wrap",
    },
  })
  au("WinLeave", function()
    M.close(api.nvim_get_current_win())
  end)
  au("WinClosed", function(ev)
    local w = tonumber(ev.match)
    if w then
      M.free(w)
    end
  end)
  S.tokens = S.tokens or util.debounce(function()
    if S.cfg then
      M.update(nil, true)
    end
  end, 100)
  au("LspTokenUpdate", function()
    S.tokens()
  end)
  vim.schedule(function()
    if S.cfg then
      M.update()
    end
  end)
end

---@param cfg table
function M.reconfigure(cfg)
  S.cfg = cfg
  for _, st in pairs(S.wins) do
    st.key = nil
  end
  M.update()
end

function M.stop()
  for _, win in ipairs(vim.tbl_keys(S.wins)) do
    M.free(win)
  end
  if S.timer then
    S.timer:stop()
    if not S.timer:is_closing() then
      S.timer:close()
    end
    S.timer = nil
  end
  if S.tokens then
    S.tokens:close()
    S.tokens = nil
  end
  pcall(api.nvim_del_augroup_by_name, "slop.context")
  S.cfg, S.enabled, S.last = nil, true, 0
end

return M

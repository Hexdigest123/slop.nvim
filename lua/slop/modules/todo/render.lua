--- todo: highlights and signs via a decoration provider (visible rows only, the cloak approach).
---
--- Highlights are ephemeral marks created in on_win for the rows being drawn, from per-row results cached per
--- changedtick. Signs are persistent marks (ephemeral ones do not size 'signcolumn'), reconciled for the visible
--- rows in a vim.schedule after on_win, so nothing is written to the buffer during a redraw.
---
--- A todo only counts inside a comment: the treesitter node (or injected tree) at the keyword when the buffer has
--- a parser, else a 'commentstring' heuristic.
local M = {}

local api = vim.api

local PRIORITY = 150 -- above treesitter (100), below cloak masks (200)

---@class slop.todo.Hit: slop.todo.Match
---@field stop integer   0-based exclusive end of the comment on this row (EOL when the comment goes on)

---@class slop.todo.DrawItem
---@field col integer
---@field end_col integer
---@field hl string
---@field badge boolean   stack SlopTodoKeyword on top

---@class slop.todo.BufState
---@field tick integer
---@field ok boolean                                  drawn at all (buftype / filetype / size)
---@field base table<integer, slop.todo.Hit[]|false>  comment-checked keyword hits per row
---@field cont table<integer, {hit: slop.todo.Hit, col: integer, stop: integer}|false>  multiline continuations
---@field items table<integer, slop.todo.DrawItem[]>
---@field signed table<integer, integer>              row -> changedtick its sign was reconciled at

local S = {
  cfg = nil, ---@type table?
  kw = nil, ---@type slop.todo.Keywords?
  enabled = true,
  active = false,
  bufs = {}, ---@type table<integer, slop.todo.BufState>
  parsers = {}, ---@type table<integer, string>  buffer -> filetype without a treesitter parser
  pending = {}, ---@type table<integer, table<integer, {[1]: integer, [2]: integer}>>  buf -> win -> rows to sign
  ns = nil, ---@type integer?
  ns_sign = nil, ---@type integer?
}

M._state = S

local function ns()
  S.ns = S.ns or require("slop.core.util").ns("todo")
  return S.ns
end

local function ns_sign()
  S.ns_sign = S.ns_sign or require("slop.core.util").ns("todo.signs")
  return S.ns_sign
end

local function hlcfg()
  return S.cfg and S.cfg.highlight or {}
end

-- Comment detection ---------------------------------------------------------------------------

---@param buf integer
---@return vim.treesitter.LanguageTree|false
local function parser_of(buf)
  -- only misses are cached (a failed lookup searches 'runtimepath'); get_parser() caches hits itself
  local ft = vim.bo[buf].filetype
  if S.parsers[buf] == ft then
    return false
  end
  local ok, parser = pcall(vim.treesitter.get_parser, buf, nil, { error = false })
  if ok and parser then
    return parser
  end
  S.parsers[buf] = ft
  return false
end

--- Is (row, col) inside a treesitter comment node? Returns the comment's end column on `row` when it ends there.
---@param parser vim.treesitter.LanguageTree
---@param row integer
---@param col integer
---@return boolean, integer?
local function ts_comment(parser, row, col)
  local range = { row, col, row, col + 1 }
  local ok, tree = pcall(parser.language_for_range, parser, range)
  if not ok or not tree then
    return false
  end
  -- the `comment` parser (TODO tags) is injected into host comments: ask the host tree
  if tree:lang() == "comment" and tree:parent() then
    tree = tree:parent() --[[@as vim.treesitter.LanguageTree]]
  end
  local nok, node = pcall(tree.named_node_for_range, tree, range, { ignore_injections = true })
  node = nok and node or nil
  while node do
    if node:type():find("comment", 1, true) then
      local _, _, erow, ecol = node:range()
      return true, erow == row and ecol or nil
    end
    node = node:parent()
  end
  return false
end

--- 'commentstring' heuristic for buffers without a parser: the comment leader appears before `col`, or the
--- line continues a block comment (" * ..."). Clipped at the block comment end.
---@param buf integer
---@param line string
---@param col integer
---@return boolean, integer?
function M.heuristic(buf, line, col)
  local cs = vim.bo[buf].commentstring or ""
  local l, r = cs:match("^%s*(.-)%s*%%s%s*(.-)%s*$")
  if not l or l == "" then
    return false
  end
  local before = line:sub(1, col)
  if not before:find(l, 1, true) and not (r ~= "" and before:match("^%s*%*+%s")) then
    return false
  end
  local e = r ~= "" and line:find(r, col + 1, true) or nil
  return true, e and e - 1 or nil
end

---@class slop.todo.Ctx
---@field buf integer
---@field first integer   rows parsed lazily on the first check
---@field last integer
---@field parsed? boolean

--- Is (row, col) in a comment? Second value: comment end column on that row (nil = end of line).
---@param ctx slop.todo.Ctx
---@param row integer
---@param col integer
---@param line string
---@return boolean, integer?
local function comment_at(ctx, row, col, line)
  if hlcfg().comments_only == false then
    return true
  end
  local parser = parser_of(ctx.buf)
  if parser then
    if not ctx.parsed then
      ctx.parsed = true
      pcall(parser.parse, parser, { ctx.first, ctx.last + 1 })
    end
    return ts_comment(parser, row, col)
  end
  return M.heuristic(ctx.buf, line, col)
end

-- Per-row results -----------------------------------------------------------------------------

---@param buf integer
---@return boolean
local function attachable(buf)
  if vim.bo[buf].buftype ~= "" or not S.cfg then
    return false
  end
  if vim.tbl_contains(hlcfg().exclude or {}, vim.bo[buf].filetype) then
    return false
  end
  local max = S.cfg.max_filesize
  if max and max > 0 then
    local ok, size = pcall(api.nvim_buf_get_offset, buf, api.nvim_buf_line_count(buf))
    if ok and size > max then
      return false
    end
  end
  return true
end

--- Cached state of a buffer for its current changedtick.
---@param buf integer
---@return slop.todo.BufState
function M.buf_state(buf)
  local tick = api.nvim_buf_get_changedtick(buf)
  local st = S.bufs[buf]
  if st and st.tick == tick then
    return st
  end
  st = { tick = tick, ok = attachable(buf), base = {}, cont = {}, items = {}, signed = st and st.signed or {} }
  S.bufs[buf] = st
  return st
end

--- Comment-checked keyword hits of a row (all keywords).
---@param st slop.todo.BufState
---@param ctx slop.todo.Ctx
---@param row integer
---@param line string
---@return slop.todo.Hit[]|false
local function base(st, ctx, row, line)
  local b = st.base[row]
  if b ~= nil then
    return b
  end
  b = false
  if #line <= (hlcfg().max_line_len or 400) then
    local hits = {}
    for _, m in ipairs(require("slop.modules.todo.keywords").match(line, S.kw.by_word)) do
      local ok, stop = comment_at(ctx, row, m.col, line)
      if ok then
        ---@cast m slop.todo.Hit
        m.stop = math.max(stop or #line, m.end_col)
        hits[#hits + 1] = m
      end
    end
    b = #hits > 0 and hits or false
  end
  st.base[row] = b
  return b
end

--- Start of continuation text when `line` continues a todo whose keyword is at `col`: only comment leader and
--- blanks before `col`, and text indented past it.
---@param line string
---@param col integer
---@return integer?  0-based start of the text
local function continues(line, col)
  if #line <= col or line:sub(1, col):find("%w") then
    return nil
  end
  local s = line:find("%S", col + 1)
  if not s or s == col + 1 then
    return nil
  end
  return s - 1
end

--- Multiline continuation of the nearest todo above `row` (todo-comments `multiline`).
---@param st slop.todo.BufState
---@param ctx slop.todo.Ctx
---@param row integer
---@param get fun(row: integer): string
local function continuation(st, ctx, row, get)
  local c = st.cont[row]
  if c ~= nil then
    return c
  end
  c = false
  local hc = hlcfg()
  if hc.multiline ~= false and get(row):find("%S") then
    for r = row - 1, math.max(row - (hc.multiline_context or 10), 0), -1 do
      local l = get(r)
      local b = base(st, ctx, r, l)
      if b then
        local hit = b[#b]
        if hit.stop >= #l then
          c = { hit = hit }
          for rr = r + 1, row do
            local line = get(rr)
            local s = continues(line, hit.col)
            local ok, stop = false, nil
            if s then
              ok, stop = comment_at(ctx, rr, s, line)
            end
            if not ok or (rr < row and stop and stop < #line) then
              c = false
              break
            end
            c.col, c.stop = s, stop or #line
          end
        end
        break
      elseif not l:find("%S") then
        break
      end
    end
  end
  st.cont[row] = c
  return c
end

--- Draw items of a row (keyword badges, comment text, continuation text).
---@param st slop.todo.BufState
---@param ctx slop.todo.Ctx
---@param row integer
---@param get fun(row: integer): string
---@return slop.todo.DrawItem[]
local function row_items(st, ctx, row, get)
  local items = st.items[row]
  if items then
    return items
  end
  items = {}
  local line = get(row)
  local hc = hlcfg()
  local b = base(st, ctx, row, line)
  if b then
    for i, hit in ipairs(b) do
      local g = hit.group
      local limit = b[i + 1] and math.min(b[i + 1].col, hit.stop) or hit.stop
      local kstart, kend = hit.col, hit.end_col
      if hc.keyword == "wide" then
        kstart, kend = math.max(kstart - 1, 0), math.min(kend + 1, limit)
      end
      if hc.keyword then
        local badge = hc.keyword == "wide" or hc.keyword == "bg"
        items[#items + 1] = { col = kstart, end_col = kend, hl = g.hl, badge = badge }
      end
      if hc.after == "fg" and limit > kend then
        items[#items + 1] = { col = kend, end_col = limit, hl = g.hl_text, badge = false }
      end
    end
  else
    local c = continuation(st, ctx, row, get)
    if c and hc.after == "fg" and c.stop > c.col then
      items[#items + 1] = { col = c.col, end_col = c.stop, hl = c.hit.group.hl_text, badge = false }
    end
  end
  st.items[row] = items
  return items
end

--- Line getter over rows first..last fetched once, on demand.
---@param buf integer
---@param first integer
---@param last integer
---@return fun(row: integer): string
local function lines_getter(buf, first, last)
  local lines
  return function(row)
    if row < first or row > last then
      return api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ""
    end
    lines = lines or api.nvim_buf_get_lines(buf, first, last + 1, false)
    return lines[row - first + 1] or ""
  end
end

local function first_row(top)
  local hc = hlcfg()
  return math.max(top - (hc.multiline ~= false and (hc.multiline_context or 10) or 0), 0)
end

-- Signs ---------------------------------------------------------------------------------------

---@param buf integer
local function clear_signs(buf)
  if api.nvim_buf_is_valid(buf) then
    api.nvim_buf_clear_namespace(buf, ns_sign(), 0, -1)
  end
end

--- Wanted sign of a row (first hit whose group has signs), nil for none.
---@param hits slop.todo.Hit[]|false
---@return slop.todo.Group?
local function sign_group(hits)
  for _, hit in ipairs(hits or {}) do
    if hit.group.signs and hit.group.icon ~= "" then
      return hit.group
    end
  end
  return nil
end

---@param buf integer
---@param st slop.todo.BufState
---@param top integer
---@param bot integer
local function reconcile_signs(buf, st, top, bot)
  local nss = ns_sign()
  local have = {} ---@type table<integer, {id: integer, hl: string?, invalid: boolean?}[]>
  for _, m in ipairs(api.nvim_buf_get_extmarks(buf, nss, { top, 0 }, { bot, -1 }, { details = true })) do
    have[m[2]] = have[m[2]] or {}
    table.insert(have[m[2]], { id = m[1], hl = m[4].sign_hl_group, invalid = m[4].invalid })
  end
  local first = first_row(top)
  local ctx = { buf = buf, first = first, last = bot }
  local get = lines_getter(buf, first, bot)
  for row = top, bot do
    if st.signed[row] ~= st.tick then
      st.signed[row] = st.tick
      local g = sign_group(base(st, ctx, row, get(row)))
      local marks = have[row] or {}
      local keep = g and #marks == 1 and marks[1].hl == g.hl and not marks[1].invalid
      if not keep then
        for _, m in ipairs(marks) do
          api.nvim_buf_del_extmark(buf, nss, m.id)
        end
        if g then
          local opts = {
            sign_text = g.icon,
            sign_hl_group = g.hl,
            priority = S.cfg.sign_priority,
            invalidate = true,
            undo_restore = false,
          }
          if not pcall(api.nvim_buf_set_extmark, buf, nss, row, 0, opts) then
            opts.sign_text = vim.fn.strcharpart(g.icon, 0, 1)
            pcall(api.nvim_buf_set_extmark, buf, nss, row, 0, opts)
          end
        end
      end
    end
  end
end

---@param buf integer
local function flush_signs(buf)
  local ranges = S.pending[buf]
  S.pending[buf] = nil
  if not ranges or not S.active or not S.enabled or not (S.cfg and S.cfg.signs) or not api.nvim_buf_is_valid(buf) then
    return
  end
  local st = M.buf_state(buf)
  if not st.ok then
    clear_signs(buf)
    return
  end
  local last = api.nvim_buf_line_count(buf) - 1
  for _, r in pairs(ranges) do
    if r[1] <= last then
      reconcile_signs(buf, st, r[1], math.min(r[2], last))
    end
  end
end

--- Queue a sign update of the rows `win` shows (one per window, applied on the main loop).
---@param win integer
---@param buf integer
---@param st slop.todo.BufState
---@param top integer
---@param bot integer
local function schedule_signs(win, buf, st, top, bot)
  local need = false
  for row = top, bot do
    if st.signed[row] ~= st.tick then
      need = true
      break
    end
  end
  if not need then
    return
  end
  local p = S.pending[buf]
  if p then
    p[win] = { top, bot }
    return
  end
  S.pending[buf] = { [win] = { top, bot } }
  vim.schedule(function()
    flush_signs(buf)
  end)
end

-- Decoration provider -------------------------------------------------------------------------

local function on_win(_, win, buf, top, bot)
  if not S.enabled or not S.kw then
    return false
  end
  local st = M.buf_state(buf)
  if not st.ok then
    return false
  end
  local first = first_row(top)
  local ctx = { buf = buf, first = first, last = bot }
  local get = lines_getter(buf, first, bot)
  local nsh = ns()
  for row = top, bot do
    for _, it in ipairs(row_items(st, ctx, row, get)) do
      pcall(api.nvim_buf_set_extmark, buf, nsh, row, it.col, {
        end_col = it.end_col,
        hl_group = it.hl,
        ephemeral = true,
        priority = PRIORITY,
      })
      if it.badge then
        pcall(api.nvim_buf_set_extmark, buf, nsh, row, it.col, {
          end_col = it.end_col,
          hl_group = "SlopTodoKeyword",
          ephemeral = true,
          priority = PRIORITY + 1,
        })
      end
    end
  end
  if S.cfg.signs then
    schedule_signs(win, buf, st, top, bot)
  end
  return false
end

--- Draw items of rows srow..erow (exactly what on_win draws; used by the specs).
---@param buf integer
---@param srow integer
---@param erow integer
---@return table<integer, slop.todo.DrawItem[]>
function M.items(buf, srow, erow)
  local st = M.buf_state(buf)
  local out = {}
  if not st.ok or not S.kw then
    return out
  end
  local first = first_row(srow)
  local ctx = { buf = buf, first = first, last = erow }
  local get = lines_getter(buf, first, erow)
  for row = srow, erow do
    local items = row_items(st, ctx, row, get)
    if #items > 0 then
      out[row] = items
    end
  end
  return out
end

-- Navigation ----------------------------------------------------------------------------------

--- Next/previous todo (in a comment) from a position.
---@param buf integer
---@param pos {[1]: integer, [2]: integer}   0-based row, byte col
---@param dir 1|-1
---@param words table<string, slop.todo.Group>
---@param wrap boolean
---@return {[1]: integer, [2]: integer}?  0-based row, col
function M.find(buf, pos, dir, words, wrap)
  local st = M.buf_state(buf)
  local n = api.nvim_buf_line_count(buf)
  local row, col = pos[1], pos[2]
  -- the cursor row (past the cursor), the other rows, then (wrapping) the cursor row again
  for step = 0, wrap and n or n - 1 do
    local r = row + dir * step
    if wrap then
      r = r % n
    elseif r < 0 or r >= n then
      return nil
    end
    local line = api.nvim_buf_get_lines(buf, r, r + 1, false)[1] or ""
    local hits = line:find("[:(]") and base(st, { buf = buf, first = r, last = r }, r, line) or {}
    local from, to = 1, #hits
    if dir < 0 then
      from, to = #hits, 1
    end
    for i = from, to, dir do
      local hit = hits[i]
      if words[hit.keyword] and (step > 0 or (dir > 0 and hit.col > col) or (dir < 0 and hit.col < col)) then
        return { r, hit.col }
      end
    end
  end
  return nil
end

-- Lifecycle -----------------------------------------------------------------------------------

--- Forget cached state (and signs) of a buffer, or of every buffer.
---@param buf? integer
function M.invalidate(buf)
  for b in pairs(buf and { [buf] = true } or S.bufs) do
    S.bufs[b], S.parsers[b] = nil, nil
    clear_signs(b)
  end
  if not buf then
    S.parsers = {}
  end
end

--- Redraw every window (cached state dropped).
function M.refresh()
  M.invalidate()
  for _, win in ipairs(api.nvim_list_wins()) do
    pcall(api.nvim__redraw, { win = win, valid = false, flush = false })
  end
end

---@param enabled boolean
function M.set_enabled(enabled)
  S.enabled = enabled
  M.refresh()
  require("slop.core.events").emit("todo", "Toggled", { enabled = enabled })
end

---@return boolean
function M.is_enabled()
  return S.active and S.enabled
end

---@param cfg table
---@param kw slop.todo.Keywords
function M.start(cfg, kw)
  S.cfg, S.kw, S.active = cfg, kw, true
  api.nvim_set_decoration_provider(ns(), { on_win = on_win })
  local group = require("slop.core.util").augroup("todo")
  api.nvim_create_autocmd({ "FileType", "BufFilePost" }, {
    group = group,
    desc = "slop: todo buffer changed",
    callback = function(ev)
      M.invalidate(ev.buf)
    end,
  })
  api.nvim_create_autocmd("BufWipeout", {
    group = group,
    desc = "slop: todo forget buffer",
    callback = function(ev)
      S.bufs[ev.buf], S.parsers[ev.buf], S.pending[ev.buf] = nil, nil, nil
    end,
  })
  M.refresh()
end

---@param cfg table
---@param kw slop.todo.Keywords
function M.reconfigure(cfg, kw)
  S.cfg, S.kw = cfg, kw
  M.refresh()
end

function M.stop()
  S.active = false
  pcall(api.nvim_set_decoration_provider, ns(), {})
  M.invalidate()
  S.pending = {}
  for _, win in ipairs(api.nvim_list_wins()) do
    pcall(api.nvim__redraw, { win = win, valid = false, flush = false })
  end
end

return M

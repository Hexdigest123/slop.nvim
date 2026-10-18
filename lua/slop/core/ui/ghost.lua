--- Ghost text (virtual text suggestions) + partial accept. OWNER: complete.
--- Used by complete (insert mode) and commit (gitcommit buffer, line 1). One suggestion per buffer.
---
--- Rendering: one extmark per buffer in namespace "slop.ghost": the first line is `inline` virt_text at
--- (row, col), lines 2.. are virt_lines below; hl_mode = "combine"; tabs are expanded for display. An optional
--- counter ("(i/n)") / loading marker is appended to the last displayed line in SlopGhostCounter.
---
--- Accepting inserts with nvim_buf_set_text after an undo break (one undo step) and moves the cursor to the end of
--- the inserted text when the buffer is shown in the current window. Partial accepts keep the remainder visible at
--- the new position. The accept-word pattern is ported from zbirenbaum/copilot.lua (MIT, (c) Zach Birenbaum).
---@class slop.ui.ghost
local M = {}

local api = vim.api

---@class slop.ghost.Opts
---@field hl? string                       default "SlopGhost"
---@field on_accept? fun(text: string, kind: "all"|"word"|"line"|"lines"|"chars")  after insertion
---@field on_clear? fun(reason: "clear"|"accept"|"replace")  the ghost went away
---@field id? any                          caller tag (e.g. request id) returned by get()
---@field counter? {[1]: integer, [2]: integer}|string  "(i/n)" shown when n > 1; a string is shown verbatim
---@field loading? boolean                 append " …"
---@field priority? integer

---@class slop.ghost.State
---@field buf integer
---@field row integer                      0-based (follows the extmark)
---@field col integer                      0-based byte col (follows the extmark)
---@field lines string[]
---@field text string
---@field id? any
---@field counter? {[1]: integer, [2]: integer}|string
---@field opts slop.ghost.Opts

local states = {} ---@type table<integer, {mark: integer, lines: string[], opts: slop.ghost.Opts}>
local hl_done = false

local function ns()
  return require("slop.core.util").ns("ghost")
end

local function ensure_hl()
  if hl_done then
    return
  end
  hl_done = true
  require("slop.core.util").hl({
    SlopGhost = { link = "Comment" },
    SlopGhostCounter = { link = "SlopDim" },
    SlopDim = { link = "NonText" },
  })
end

local function resolve(buf)
  if buf == nil or buf == 0 then
    return api.nvim_get_current_buf()
  end
  return buf
end

local function display(s, buf)
  if s:find("\t", 1, true) then
    local ts = vim.bo[buf].tabstop
    s = s:gsub("\t", string.rep(" ", ts > 0 and ts or 8))
  end
  if s:find("%c") then
    s = vim.fn.strtrans(s)
  end
  return s
end

local function counter_text(c, loading)
  local t = ""
  if type(c) == "string" then
    t = c ~= "" and (" " .. c) or ""
  elseif type(c) == "table" and (c[2] or 0) > 1 then
    t = (" (%d/%d)"):format(c[1], c[2])
  end
  if loading then
    t = t .. " …"
  end
  return t
end

local function to_lines(text)
  if type(text) == "table" then
    return vim.deepcopy(text)
  end
  return vim.split(text or "", "\n", { plain = true })
end

local function empty(lines)
  return #lines == 0 or (#lines == 1 and lines[1] == "")
end

local function render(buf, row, col, lines, opts, mark)
  ensure_hl()
  local hl = opts.hl or "SlopGhost"
  local extra = counter_text(opts.counter, opts.loading)
  local line = api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ""
  col = math.max(0, math.min(col, #line))
  local o = {
    id = mark,
    virt_text_pos = "inline",
    hl_mode = "combine",
    priority = opts.priority or 4096,
    right_gravity = true,
    undo_restore = false,
    invalidate = false,
  }
  local first = display(lines[1] or "", buf)
  local vt = {}
  if first ~= "" then
    vt[#vt + 1] = { first, hl }
  end
  if #lines > 1 then
    local vl = {}
    for i = 2, #lines do
      local chunks = { { display(lines[i], buf), hl } }
      if i == #lines and extra ~= "" then
        chunks[#chunks + 1] = { extra, "SlopGhostCounter" }
      end
      vl[#vl + 1] = chunks
    end
    o.virt_lines = vl
  elseif extra ~= "" then
    vt[#vt + 1] = { extra, "SlopGhostCounter" }
  end
  if #vt > 0 then
    o.virt_text = vt
  end
  return api.nvim_buf_set_extmark(buf, ns(), row, col, o)
end

--- Show `text` at (row, col) in `buf`, replacing any current ghost text there.
---@param buf integer
---@param row integer                      0-based
---@param col integer                      0-based byte col
---@param text string|string[]
---@param opts? slop.ghost.Opts
function M.show(buf, row, col, text, opts)
  buf = resolve(buf)
  if not api.nvim_buf_is_valid(buf) then
    return
  end
  opts = opts or {}
  local lines = to_lines(text)
  local prev = states[buf]
  if empty(lines) then
    M.clear(buf)
    return
  end
  local mark = prev and prev.mark or nil
  if prev and prev.opts ~= opts and prev.opts.id ~= opts.id and prev.opts.on_clear then
    pcall(prev.opts.on_clear, "replace")
  end
  local ok, id = pcall(render, buf, row, col, lines, opts, mark)
  if not ok then
    require("slop.core.log").debug("ghost: render failed: %s", id)
    M.clear(buf)
    return
  end
  states[buf] = { mark = id, lines = lines, opts = opts }
end

--- Update the counter / loading marker of the visible ghost.
---@param buf integer
---@param counter? {[1]: integer, [2]: integer}|string
---@param loading? boolean
function M.set_counter(buf, counter, loading)
  buf = resolve(buf)
  local st = M.get(buf)
  if not st then
    return
  end
  st.opts.counter = counter
  st.opts.loading = loading
  M.show(buf, st.row, st.col, st.lines, st.opts)
end

local function drop(buf, reason)
  local st = states[buf]
  if not st then
    return
  end
  states[buf] = nil
  if api.nvim_buf_is_valid(buf) then
    pcall(api.nvim_buf_del_extmark, buf, ns(), st.mark)
  end
  if st.opts.on_clear then
    pcall(st.opts.on_clear, reason)
  end
end

---@param buf? integer                     default current
function M.clear(buf)
  drop(resolve(buf), "clear")
end

---@param buf? integer
---@return slop.ghost.State?
function M.get(buf)
  buf = resolve(buf)
  local st = states[buf]
  if not st then
    return nil
  end
  if not api.nvim_buf_is_valid(buf) then
    states[buf] = nil
    return nil
  end
  local pos = api.nvim_buf_get_extmark_by_id(buf, ns(), st.mark, {})
  if not pos or #pos == 0 then
    states[buf] = nil
    return nil
  end
  return {
    buf = buf,
    row = pos[1],
    col = pos[2],
    lines = vim.deepcopy(st.lines),
    text = table.concat(st.lines, "\n"),
    id = st.opts.id,
    counter = st.opts.counter,
    opts = st.opts,
  }
end

---@param buf? integer
---@return boolean
function M.is_visible(buf)
  return M.get(buf) ~= nil
end

-- Partial-accept splitting (pure) ----------------------------------------------------------------

--- Byte length of the part of `text` that each accept kind takes.
---@param text string
---@param kind "all"|"word"|"line"|"lines"
---@param n? integer                       for "lines"
---@return integer
function M.split_len(text, kind, n)
  if kind == "all" or text == "" then
    return #text
  end
  if kind == "word" then
    -- copilot.lua (MIT): "%s*%p*[^%s%p]*%s*", but trailing whitespace stops at a newline
    local _, e = text:find("^%s*%p*[^%s%p]*[ \t]*")
    if not e or e == 0 then
      e = 1
    end
    return e
  end
  n = math.max(1, n or 1)
  local lines = vim.split(text, "\n", { plain = true })
  local k = n
  if lines[1] == "" and #lines > 1 then
    k = n + 1
  end
  k = math.min(k, #lines)
  local len = 0
  for i = 1, k do
    len = len + #lines[i] + (i > 1 and 1 or 0)
  end
  return len
end

-- Accepting --------------------------------------------------------------------------------------

local function break_undo()
  -- setting 'undolevels' closes the current undo block (also mid-insert): the accept becomes its own step
  vim.o.undolevels = vim.o.undolevels
end

local function insert(buf, row, col, part)
  local lines = vim.split(part, "\n", { plain = true })
  local line = api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ""
  col = math.min(col, #line)
  break_undo()
  api.nvim_buf_set_text(buf, row, col, row, col, lines)
  local erow = row + #lines - 1
  local ecol = #lines == 1 and (col + #lines[1]) or #lines[#lines]
  local win = api.nvim_get_current_win()
  if api.nvim_win_get_buf(win) == buf then
    local mode = api.nvim_get_mode().mode
    local c = ecol
    if not mode:match("^[iR]") then
      c = math.max(0, ecol - 1)
    end
    pcall(api.nvim_win_set_cursor, win, { erow + 1, c })
  end
  return erow, ecol
end

---@param buf integer
---@param len integer
---@param kind string
---@return boolean
local function accept_len(buf, len, kind)
  local st = M.get(buf)
  if not st then
    return false
  end
  local text = st.text
  len = math.max(0, math.min(len, #text))
  if len == 0 then
    return false
  end
  local part, rest = text:sub(1, len), text:sub(len + 1)
  local opts = st.opts
  local raw = states[buf]
  -- remove the mark first so it does not get in the way of the insertion
  states[buf] = nil
  pcall(api.nvim_buf_del_extmark, buf, ns(), raw.mark)
  if api.nvim_get_mode().mode:match("^[iR]") and vim.fn.pumvisible() == 1 then
    pcall(vim.fn.complete, vim.fn.col("."), {})
  end
  local ok, erow, ecol = pcall(insert, buf, st.row, st.col, part)
  if not ok then
    require("slop.core.log").error("ghost: accept failed: %s", erow)
    if opts.on_clear then
      pcall(opts.on_clear, "clear")
    end
    return true
  end
  if rest ~= "" then
    local id = render(buf, erow, ecol, vim.split(rest, "\n", { plain = true }), opts, nil)
    states[buf] = { mark = id, lines = vim.split(rest, "\n", { plain = true }), opts = opts }
  elseif opts.on_clear then
    pcall(opts.on_clear, "accept")
  end
  if opts.on_accept then
    local cok, cerr = pcall(opts.on_accept, part, kind)
    if not cok then
      require("slop.core.log").error("ghost: on_accept failed: %s", cerr)
    end
  end
  return true
end

--- Insert the whole suggestion. Returns false when nothing is visible (so keymaps can fall through).
---@param buf? integer
---@return boolean
function M.accept(buf)
  buf = resolve(buf)
  local st = M.get(buf)
  return st ~= nil and accept_len(buf, #st.text, "all")
end

---@param buf? integer
---@return boolean
function M.accept_word(buf)
  buf = resolve(buf)
  local st = M.get(buf)
  return st ~= nil and accept_len(buf, M.split_len(st.text, "word"), "word")
end

--- Accept the current line (or, when the suggestion starts with a line break, the next line).
---@param buf? integer
---@return boolean
function M.accept_line(buf)
  buf = resolve(buf)
  local st = M.get(buf)
  return st ~= nil and accept_len(buf, M.split_len(st.text, "lines", 1), "line")
end

---@param n? integer                       default vim.v.count1 (never prompts)
---@param buf? integer
---@return boolean
function M.accept_n_lines(n, buf)
  buf = resolve(buf)
  local st = M.get(buf)
  return st ~= nil and accept_len(buf, M.split_len(st.text, "lines", n or vim.v.count1), "lines")
end

--- Accept the first `n` bytes of the suggestion.
---@param buf? integer
---@param n integer
---@return boolean
function M.accept_text(buf, n)
  buf = resolve(buf)
  return accept_len(buf, n, "chars")
end

return M

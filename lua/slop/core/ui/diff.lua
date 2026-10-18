--- Inline diff review with per-hunk accept/reject. OWNER: edit.
--- Used by edit (agent replacement) and rest (AI gen/fix into a possibly non-current buffer).
---
--- APPLIED PREVIEW: `show()` writes the new lines into the buffer right away (per hunk, bottom-to-top with
--- nvim_buf_set_text). Added/changed lines are real buffer text highlighted `SlopDiffAdd` (syntax stays);
--- the removed lines are drawn as virt_lines (`SlopDiffDelete`) above their hunk.
---   accept(i)  keeps the hunk (only its decoration goes away)
---   reject(i)  restores the hunk's old lines
--- The whole review (apply + every reject) is ONE undo block (undojoin while our change is the newest undo state).
--- `reject_all()` with nothing accepted and nothing else changed undoes the block (buffer not left 'modified').
--- If the user undoes the preview with `u`, the handle closes as "rejected" without touching the buffer again.
---
--- Buffer-local keymaps (normal mode) exist while at least one handle is active in the buffer; they act on the
--- hunk under the cursor and fall through to the key's previous/native meaning when there is nothing to act on.
---@class slop.ui.diff
local M = {}

local api = vim.api
local util = require("slop.core.util")

---@class slop.diff.Hunk
---@field index integer
---@field old_start integer                0-based row in the original range
---@field old_count integer
---@field old_lines string[]
---@field new_start integer                0-based row in the new lines
---@field new_count integer
---@field new_lines string[]
---@field state "pending"|"accepted"|"rejected"
---@field mark? integer                    tracking extmark (internal)
---@field eof? boolean                     pure deletion at the end of the buffer (internal)

---@class slop.diff.Opts
---@field keymaps? table<string, string|false>  accept, reject, accept_all, reject_all, next, prev, refine (buffer-local)
---@field on_refine? fun(handle: slop.diff.Handle)
---@field on_done? fun(result: "accepted"|"rejected"|"partial"|"unchanged", handle: slop.diff.Handle)
---@field conflict? boolean                region changed while in flight: show a warning line
---@field title? string                    label shown above the first hunk
---@field hints? boolean                   key hints as eol text on each hunk (default true)
---@field jump? boolean                    move the cursor to the first hunk when the buffer is current (default false)

M.default_keymaps = {
  accept = "ga",
  reject = "gr",
  accept_all = "gA",
  reject_all = "gR",
  next = "]h",
  prev = "[h",
  refine = "<C-r>",
}

util.hl({
  SlopDiffAdd = { link = "DiffAdd" },
  SlopDiffDelete = { link = "DiffDelete" },
  SlopDiffHint = { link = "Comment" },
  SlopDiffTitle = { link = "Title" },
  SlopDiffWarn = { link = "DiagnosticWarn" },
})

local function ns_decor()
  return util.ns("diff")
end
local function ns_track()
  return util.ns("diff.track")
end

local by_buf = {} ---@type table<integer, slop.diff.Handle[]>
local buf_state = {} ---@type table<integer, {maps: table<string, {action: string, saved: table?}>, group: integer}>
local next_id = 0

-- Pure diff ---------------------------------------------------------------------------------------

local function join(lines)
  if #lines == 0 then
    return ""
  end
  return table.concat(lines, "\n") .. "\n"
end

--- Pure: line hunks between two line lists (vim.text.diff indices, histogram).
---@param old string[]
---@param new string[]
---@return slop.diff.Hunk[]
function M.compute(old, new)
  local idx = vim.text.diff(join(old), join(new), { result_type = "indices", algorithm = "histogram" }) --[[@as integer[][] ]]
  local hunks = {}
  for i, h in ipairs(idx) do
    local sa, ca, sb, cb = h[1], h[2], h[3], h[4]
    local old_start = ca == 0 and sa or sa - 1
    local new_start = cb == 0 and sb or sb - 1
    hunks[i] = {
      index = i,
      old_start = old_start,
      old_count = ca,
      old_lines = vim.list_slice(old, old_start + 1, old_start + ca),
      new_start = new_start,
      new_count = cb,
      new_lines = vim.list_slice(new, new_start + 1, new_start + cb),
      state = "pending",
    }
  end
  return hunks
end

-- Buffer helpers -----------------------------------------------------------------------------------

local function get_line(buf, row)
  return api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ""
end

--- Replace rows [s, e) of `buf` with `lines` using nvim_buf_set_text (extmarks on other lines survive).
---@param buf integer
---@param s integer
---@param e integer
---@param lines string[]
local function replace_rows(buf, s, e, lines)
  local lc = api.nvim_buf_line_count(buf)
  if #lines > 0 then
    if e > s then
      api.nvim_buf_set_text(buf, s, 0, e - 1, #get_line(buf, e - 1), lines)
    elseif s < lc then
      local t = vim.list_extend(vim.list_slice(lines), { "" })
      api.nvim_buf_set_text(buf, s, 0, s, 0, t)
    else
      local last = #get_line(buf, lc - 1)
      api.nvim_buf_set_text(buf, lc - 1, last, lc - 1, last, vim.list_extend({ "" }, lines))
    end
  elseif e > s then
    if e < lc then
      api.nvim_buf_set_text(buf, s, 0, e, 0, { "" })
    elseif s > 0 then
      api.nvim_buf_set_text(buf, s - 1, #get_line(buf, s - 1), e - 1, #get_line(buf, e - 1), { "" })
    else
      api.nvim_buf_set_lines(buf, 0, -1, false, {})
    end
  end
end

local function undotree(buf)
  return api.nvim_buf_call(buf, function()
    return vim.fn.undotree()
  end)
end

--- Rows [s, e) currently covered by a tracking mark.
---@return integer? s, integer? e
local function mark_rows(buf, id, eof)
  local m = api.nvim_buf_get_extmark_by_id(buf, ns_track(), id, { details = true })
  if not m or not m[1] then
    return nil
  end
  local sr, sc, d = m[1], m[2], m[3] or {}
  local er, ec = d.end_row or sr, d.end_col or sc
  if er == sr and ec == sc then
    if eof then
      return sr + 1, sr + 1
    end
    return sr, sr
  end
  return sr, (ec > 0 and er + 1 or er)
end

local function expand_tabs(s, ts)
  if not s:find("\t", 1, true) then
    return s
  end
  local out, col = {}, 0
  for ch in s:gmatch("[^\t]*\t?") do
    local text = ch:gsub("\t$", "")
    out[#out + 1] = text
    col = col + api.nvim_strwidth(text)
    if ch:sub(-1) == "\t" then
      local n = ts - (col % ts)
      out[#out + 1] = (" "):rep(n)
      col = col + n
    end
  end
  return table.concat(out)
end

local function width_for(buf)
  for _, win in ipairs(api.nvim_list_wins()) do
    if api.nvim_win_get_buf(win) == buf then
      return api.nvim_win_get_width(win)
    end
  end
  return vim.o.columns
end

-- Handle --------------------------------------------------------------------------------------------

---@class slop.diff.Handle
---@field id integer
---@field buf integer
---@field opts slop.diff.Opts
---@field private _hunks slop.diff.Hunk[]
---@field private _active boolean
---@field private _seq integer?          undo seq of our latest change
---@field private _seq_base integer?     undo seq right after the initial apply
---@field private _region integer?       tracking mark of the whole preview
---@field private _decor table<integer, integer[]>
---@field private _done boolean
local Handle = {}
Handle.__index = Handle

---@return slop.diff.Hunk[]
function Handle:hunks()
  return self._hunks
end

---@return boolean
function Handle:is_active()
  return self._active
end

--- Current rows of the whole preview (end-exclusive), nil when closed.
---@return {[1]: integer, [2]: integer}?
function Handle:range()
  if not self._region or not util.buf_valid(self.buf) then
    return nil
  end
  local s, e = mark_rows(self.buf, self._region)
  if not s then
    return nil
  end
  return { s, e }
end

---@param h slop.diff.Hunk
---@return integer? s, integer? e
function Handle:_rows(h)
  if not h.mark then
    return nil
  end
  return mark_rows(self.buf, h.mark, h.eof)
end

--- The pending hunk at buffer row `row` (0-based), if any.
---@param row integer
---@return slop.diff.Hunk?
function Handle:hunk_at(row)
  for _, h in ipairs(self._hunks) do
    if h.state == "pending" then
      local s, e = self:_rows(h)
      if s then
        if (e > s and row >= s and row < e) or (e == s and (row == s or (h.eof and row == s - 1))) then
          return h
        end
      end
    end
  end
end

--- Nearest pending hunk to `row`.
---@param row integer
---@return slop.diff.Hunk?
function Handle:_nearest(row)
  local best, dist
  for _, h in ipairs(self._hunks) do
    if h.state == "pending" then
      local s, e = self:_rows(h)
      if s then
        local d = row < s and s - row or (row >= math.max(e, s + 1) and row - math.max(e, s + 1) + 1 or 0)
        if not dist or d < dist then
          best, dist = h, d
        end
      end
    end
  end
  return best
end

---@return boolean
function Handle:_contains(row)
  local r = self:range()
  if not r then
    return false
  end
  return row >= r[1] - 1 and row <= math.max(r[2], r[1] + 1)
end

--- Run a buffer edit, joining it with our previous change when that is still the newest undo state.
function Handle:_edit(fn)
  local buf = self.buf
  api.nvim_buf_call(buf, function()
    local joined = false
    if self._seq then
      local ut = vim.fn.undotree()
      if ut.seq_last == self._seq and ut.seq_cur == self._seq then
        joined = pcall(vim.cmd.undojoin)
      end
    end
    if not joined then
      -- start a fresh undo block: changes to non-current buffers are not synced by the main loop
      vim.cmd("let &g:undolevels = &g:undolevels")
    end
    fn()
    vim.cmd("let &g:undolevels = &g:undolevels")
  end)
  self._seq = undotree(buf).seq_last
end

function Handle:_cursor_row()
  if api.nvim_get_current_buf() ~= self.buf then
    return nil
  end
  return api.nvim_win_get_cursor(0)[1] - 1
end

---@param index? integer
---@return slop.diff.Hunk?
function Handle:_target(index)
  if index then
    local h = self._hunks[index]
    return h and h.state == "pending" and h or nil
  end
  local row = self:_cursor_row()
  if not row then
    return nil
  end
  return self:hunk_at(row) or self:_nearest(row)
end

function Handle:_clear_decor(h)
  for _, id in ipairs(self._decor[h.index] or {}) do
    pcall(api.nvim_buf_del_extmark, self.buf, ns_decor(), id)
  end
  self._decor[h.index] = nil
end

function Handle:_pending_count()
  local n = 0
  for _, h in ipairs(self._hunks) do
    if h.state == "pending" then
      n = n + 1
    end
  end
  return n
end

local function keys_of(opts)
  local km = vim.tbl_extend("force", M.default_keymaps, opts.keymaps or {})
  if not opts.on_refine then
    km.refine = false
  end
  return km
end

function Handle:_render()
  if not self._active or not util.buf_valid(self.buf) then
    return
  end
  local buf = self.buf
  local ts = vim.bo[buf].tabstop
  local width = width_for(buf)
  local km = keys_of(self.opts)
  local total = #self._hunks
  local first = true
  for _, h in ipairs(self._hunks) do
    self:_clear_decor(h)
    if h.state == "pending" then
      local ids = {}
      local s, e = self:_rows(h)
      if s then
        local lc = api.nvim_buf_line_count(buf)
        local vl = {}
        if first then
          if self.opts.title and self.opts.title ~= "" then
            vl[#vl + 1] = { { self.opts.title, "SlopDiffTitle" } }
          end
          if self.opts.conflict then
            vl[#vl + 1] = {
              { "⚠ the region changed while the request was running: review carefully", "SlopDiffWarn" },
            }
          end
        end
        for _, l in ipairs(h.old_lines) do
          local text = expand_tabs(l, ts)
          local pad = math.max(0, width - api.nvim_strwidth(text))
          vl[#vl + 1] = { { text .. (" "):rep(pad), "SlopDiffDelete" } }
        end
        local hint
        if self.opts.hints ~= false then
          local parts = { ("hunk %d/%d"):format(h.index, total) }
          if km.accept then
            parts[#parts + 1] = km.accept .. " accept"
          end
          if km.reject then
            parts[#parts + 1] = km.reject .. " reject"
          end
          if km.accept_all and km.reject_all then
            parts[#parts + 1] = km.accept_all .. "/" .. km.reject_all .. " all"
          end
          if km.refine then
            parts[#parts + 1] = km.refine .. " refine"
          end
          hint = "  " .. table.concat(parts, " · ")
        end
        if e > s then
          ids[#ids + 1] = api.nvim_buf_set_extmark(buf, ns_decor(), s, 0, {
            end_row = e - 1,
            line_hl_group = "SlopDiffAdd",
            priority = 200,
          })
          if hint then
            ids[#ids + 1] = api.nvim_buf_set_extmark(buf, ns_decor(), s, 0, {
              virt_text = { { hint, "SlopDiffHint" } },
              virt_text_pos = "eol",
              priority = 200,
            })
          end
          if #vl > 0 then
            ids[#ids + 1] = api.nvim_buf_set_extmark(buf, ns_decor(), s, 0, {
              virt_lines = vl,
              virt_lines_above = true,
            })
          end
        else
          if hint then
            vl[#vl + 1] = { { hint, "SlopDiffHint" } }
          end
          if #vl > 0 then
            local row, above = s, true
            if h.eof or s >= lc then
              row, above = lc - 1, false
            end
            ids[#ids + 1] = api.nvim_buf_set_extmark(buf, ns_decor(), row, 0, {
              virt_lines = vl,
              virt_lines_above = above,
            })
          end
        end
        if first and s == 0 then
          -- virt_lines above row 0 are only visible with topfill
          for _, win in ipairs(api.nvim_list_wins()) do
            if api.nvim_win_get_buf(win) == buf then
              api.nvim_win_call(win, function()
                if vim.fn.line("w0") == 1 then
                  vim.fn.winrestview({ topfill = #vl })
                end
              end)
            end
          end
        end
      end
      self._decor[h.index] = ids
      first = false
    end
  end
end

function Handle:_result()
  local acc, rej = 0, 0
  for _, h in ipairs(self._hunks) do
    if h.state == "accepted" then
      acc = acc + 1
    elseif h.state == "rejected" then
      rej = rej + 1
    end
  end
  if rej == 0 then
    return "accepted"
  elseif acc == 0 then
    return "rejected"
  end
  return "partial"
end

--- Tear down marks/maps and fire on_done once.
---@param result? string
function Handle:_finish(result)
  if self._done then
    return
  end
  self._done = true
  self._active = false
  if util.buf_valid(self.buf) then
    for _, h in ipairs(self._hunks) do
      self:_clear_decor(h)
      if h.mark then
        pcall(api.nvim_buf_del_extmark, self.buf, ns_track(), h.mark)
      end
    end
    if self._region then
      pcall(api.nvim_buf_del_extmark, self.buf, ns_track(), self._region)
    end
  end
  M._unregister(self)
  if self.opts.on_done then
    local ok, err = pcall(self.opts.on_done, result or self:_result(), self)
    if not ok then
      require("slop.core.log").error("diff on_done: %s", err)
    end
  end
end

function Handle:_maybe_finish()
  if self:_pending_count() == 0 then
    self:_finish()
  else
    self:_render()
  end
end

--- Accept a hunk (default: the hunk under / nearest to the cursor). Returns false when there is none.
---@param index? integer
---@return boolean
function Handle:accept(index)
  if not self._active then
    return false
  end
  local h = self:_target(index)
  if not h then
    return false
  end
  h.state = "accepted"
  self:_clear_decor(h)
  self:_maybe_finish()
  return true
end

---@param h slop.diff.Hunk
function Handle:_revert(h)
  local s, e = self:_rows(h)
  if s then
    replace_rows(self.buf, s, e, h.old_lines)
  end
  h.state = "rejected"
  self:_clear_decor(h)
end

--- Reject a hunk (restore its old lines). Returns false when there is none.
---@param index? integer
---@return boolean
function Handle:reject(index)
  if not self._active then
    return false
  end
  local h = self:_target(index)
  if not h then
    return false
  end
  if util.buf_valid(self.buf) then
    self:_edit(function()
      self:_revert(h)
    end)
  else
    h.state = "rejected"
  end
  self:_maybe_finish()
  return true
end

function Handle:accept_all()
  if not self._active then
    return
  end
  for _, h in ipairs(self._hunks) do
    if h.state == "pending" then
      h.state = "accepted"
    end
  end
  self:_finish()
end

function Handle:reject_all()
  if not self._active then
    return
  end
  local buf = self.buf
  if util.buf_valid(buf) then
    local any_accepted = false
    for _, h in ipairs(self._hunks) do
      any_accepted = any_accepted or h.state == "accepted"
    end
    local ut = undotree(buf)
    if not any_accepted and self._seq and ut.seq_last == self._seq and ut.seq_cur == self._seq then
      self._active = false -- the TextChanged watcher must not treat our own undo as the user's
      local views = {}
      for _, win in ipairs(api.nvim_list_wins()) do
        if api.nvim_win_get_buf(win) == buf then
          views[win] = api.nvim_win_call(win, vim.fn.winsaveview)
        end
      end
      api.nvim_buf_call(buf, function()
        vim.cmd("silent undo")
      end)
      for win, view in pairs(views) do
        pcall(api.nvim_win_call, win, function()
          vim.fn.winrestview(view)
        end)
      end
      for _, h in ipairs(self._hunks) do
        if h.state == "pending" then
          h.state = "rejected"
        end
      end
    else
      -- bottom-to-top so earlier rows stay valid
      self:_edit(function()
        for i = #self._hunks, 1, -1 do
          local h = self._hunks[i]
          if h.state == "pending" then
            self:_revert(h)
          end
        end
      end)
    end
  else
    for _, h in ipairs(self._hunks) do
      if h.state == "pending" then
        h.state = "rejected"
      end
    end
  end
  self:_finish()
end

--- Close the review; pending hunks are rejected.
function Handle:close()
  if self._active then
    self:reject_all()
  end
end

---@param dir 1|-1
function Handle:_jump(dir)
  local row = self:_cursor_row()
  if not row then
    return false
  end
  local rows = {}
  for _, h in ipairs(self._hunks) do
    if h.state == "pending" then
      local s = self:_rows(h)
      if s then
        rows[#rows + 1] = s
      end
    end
  end
  return M._jump_rows(rows, row, dir)
end

function Handle:next()
  return self:_jump(1)
end

function Handle:prev()
  return self:_jump(-1)
end

-- Registry / keymaps ------------------------------------------------------------------------------

function M._jump_rows(rows, row, dir)
  if #rows == 0 then
    return false
  end
  table.sort(rows)
  local target
  if dir > 0 then
    for _, r in ipairs(rows) do
      if r > row then
        target = r
        break
      end
    end
    target = target or rows[1]
  else
    for i = #rows, 1, -1 do
      if rows[i] < row then
        target = rows[i]
        break
      end
    end
    target = target or rows[#rows]
  end
  local lc = api.nvim_buf_line_count(0)
  api.nvim_win_set_cursor(0, { math.min(target, lc - 1) + 1, 0 })
  return true
end

--- Active diff handles in a buffer.
---@param buf integer
---@return slop.diff.Handle[]
function M.list(buf)
  buf = buf == 0 and api.nvim_get_current_buf() or buf
  return vim.list_slice(by_buf[buf] or {})
end

--- Close (reject pending) every handle of `buf`, or of all buffers.
---@param buf? integer
function M.close_all(buf)
  local bufs = buf and { buf == 0 and api.nvim_get_current_buf() or buf } or vim.tbl_keys(by_buf)
  for _, b in ipairs(bufs) do
    for _, hd in ipairs(M.list(b)) do
      hd:close()
    end
  end
end

--- Handle the cursor is in (or the only one in the buffer).
local function handle_at(buf, row)
  local list = by_buf[buf] or {}
  for _, hd in ipairs(list) do
    if hd:hunk_at(row) then
      return hd
    end
  end
  for _, hd in ipairs(list) do
    if hd:_contains(row) then
      return hd
    end
  end
  if #list == 1 then
    return list[1]
  end
end

local function dispatch(buf, action)
  local row = api.nvim_win_get_cursor(0)[1] - 1
  if action == "next" or action == "prev" then
    local rows = {}
    for _, hd in ipairs(by_buf[buf] or {}) do
      for _, h in ipairs(hd._hunks) do
        if h.state == "pending" then
          local s = hd:_rows(h)
          if s then
            rows[#rows + 1] = s
          end
        end
      end
    end
    return M._jump_rows(rows, row, action == "next" and 1 or -1)
  end
  local hd = handle_at(buf, row)
  if not hd then
    return false
  end
  if action == "accept" or action == "reject" then
    local h = hd:hunk_at(row) or (hd:_contains(row) and hd:_nearest(row)) or nil
    if not h then
      return false
    end
    return hd[action](hd, h.index)
  elseif action == "accept_all" then
    hd:accept_all()
  elseif action == "reject_all" then
    hd:reject_all()
  elseif action == "refine" then
    if not hd.opts.on_refine then
      return false
    end
    hd.opts.on_refine(hd)
  end
  return true
end

local function setup_buf(buf, handle)
  local st = buf_state[buf]
  if not st then
    st = { maps = {}, group = util.augroup("diff.buf" .. buf, true) }
    buf_state[buf] = st
    api.nvim_create_autocmd({ "BufWipeout", "BufUnload" }, {
      group = st.group,
      buffer = buf,
      callback = function()
        for _, hd in ipairs(M.list(buf)) do
          hd._active = false
          hd:_finish("rejected")
        end
      end,
    })
    api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
      group = st.group,
      buffer = buf,
      callback = function()
        local list = by_buf[buf]
        if not list or #list == 0 then
          return
        end
        local ut = undotree(buf)
        for _, hd in ipairs(vim.list_slice(list)) do
          if hd._active and hd._seq_base and ut.seq_cur < hd._seq_base then
            hd._active = false -- user undid the preview: no further edits
            for _, h in ipairs(hd._hunks) do
              if h.state == "pending" then
                h.state = "rejected"
              end
            end
            hd:_finish("rejected")
          end
        end
      end,
    })
  end
  local keymaps = require("slop.core.keymaps")
  for action, lhs in pairs(keys_of(handle.opts)) do
    if type(lhs) == "string" and lhs ~= "" and not st.maps[lhs] then
      local saved = vim.fn.maparg(lhs, "n", false, true)
      if not (type(saved) == "table" and saved.buffer == 1) then
        saved = nil
      end
      st.maps[lhs] = { action = action, saved = saved }
      keymaps.fallthrough("n", lhs, function()
        return dispatch(buf, action)
      end, { desc = "diff " .. action:gsub("_", " "), buf = buf })
    end
  end
end

local function teardown_buf(buf)
  local st = buf_state[buf]
  if not st then
    return
  end
  buf_state[buf] = nil
  pcall(api.nvim_del_augroup_by_id, st.group)
  if not api.nvim_buf_is_valid(buf) then
    return
  end
  for lhs, m in pairs(st.maps) do
    pcall(vim.keymap.del, "n", lhs, { buf = buf })
    if m.saved then
      pcall(api.nvim_buf_call, buf, function()
        vim.fn.mapset("n", false, m.saved)
      end)
    end
  end
end

function M._unregister(handle)
  local list = by_buf[handle.buf]
  if not list then
    return
  end
  for i, hd in ipairs(list) do
    if hd == handle then
      table.remove(list, i)
      break
    end
  end
  if #list == 0 then
    by_buf[handle.buf] = nil
    teardown_buf(handle.buf)
  end
end

-- show ------------------------------------------------------------------------------------------------

--- Preview replacing rows [range[1], range[2]) (0-based, end-exclusive; equal = pure insertion) of `buf`
--- with `new_lines`. `buf` may be any buffer (bufload()ed if needed). See the module doc (applied preview).
---@param buf integer
---@param range {[1]: integer, [2]: integer}
---@param new_lines string[]
---@param opts? slop.diff.Opts
---@return slop.diff.Handle
function M.show(buf, range, new_lines, opts)
  opts = opts or {}
  buf = buf == 0 and api.nvim_get_current_buf() or buf
  if not api.nvim_buf_is_loaded(buf) then
    vim.fn.bufload(buf)
  end
  local lc = api.nvim_buf_line_count(buf)
  local s = math.max(0, math.min(range[1], lc))
  local e = math.max(s, math.min(range[2], lc))
  if lc == 1 and get_line(buf, 0) == "" then
    s, e = 0, 1 -- empty buffer: replace its only line instead of appending below it
  end
  local old = api.nvim_buf_get_lines(buf, s, e, false)
  next_id = next_id + 1
  local self = setmetatable({
    id = next_id,
    buf = buf,
    opts = opts,
    _hunks = M.compute(old, new_lines),
    _active = true,
    _decor = {},
    _done = false,
  }, Handle)

  if #self._hunks == 0 then
    self._active = false
    self._done = true
    if opts.on_done then
      vim.schedule(function()
        opts.on_done("unchanged", self)
      end)
    end
    return self
  end

  -- apply bottom-to-top (one tick -> one undo block)
  self:_edit(function()
    for i = #self._hunks, 1, -1 do
      local h = self._hunks[i]
      replace_rows(buf, s + h.old_start, s + h.old_start + h.old_count, h.new_lines)
    end
  end)
  self._seq_base = self._seq

  -- tracking marks at the hunks' rows in the new text
  lc = api.nvim_buf_line_count(buf)
  local track = ns_track()
  for _, h in ipairs(self._hunks) do
    local row = s + h.new_start
    if h.new_count > 0 then
      h.mark = api.nvim_buf_set_extmark(buf, track, row, 0, {
        end_row = row + h.new_count,
        end_col = 0,
        right_gravity = false,
        end_right_gravity = false,
        strict = false,
      })
    elseif row >= lc then
      h.eof = true
      h.mark = api.nvim_buf_set_extmark(buf, track, lc - 1, #get_line(buf, lc - 1), { right_gravity = false })
    else
      h.mark = api.nvim_buf_set_extmark(buf, track, row, 0, { right_gravity = false })
    end
  end
  self._region = api.nvim_buf_set_extmark(buf, track, math.min(s, lc - 1), 0, {
    end_row = math.min(s + #new_lines, lc),
    end_col = 0,
    right_gravity = false,
    end_right_gravity = true,
    strict = false,
  })

  by_buf[buf] = by_buf[buf] or {}
  table.insert(by_buf[buf], self)
  setup_buf(buf, self)
  self:_render()
  if opts.jump and api.nvim_get_current_buf() == buf then
    local r = self:_rows(self._hunks[1])
    if r then
      api.nvim_win_set_cursor(0, { math.min(r, lc - 1) + 1, 0 })
    end
  end
  return self
end

return M

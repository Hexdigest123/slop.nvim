--- Recent-edits log + context ring. OWNER: complete.
---
--- Recent edits: per-buffer baseline snapshot; after an idle period (or on BufLeave / InsertLeave) the diff
--- baseline -> current (vim.text.diff, unified, 3 lines context) is recorded as an event and the baseline moves on.
--- Defaults follow copilot's recentEditsProvider (MIT, (c) Microsoft): max 8 edits, 2000 chars per edit.
---
--- Ring: chunks of recently yanked / visited / saved text (llama.vim-style "ring buffer" idea), deduplicated by
--- Jaccard similarity, used as extra volatile context.
---
--- Only buffers that are not blocked by core.secrets are tracked; texts are stored RAW and redacted when rendered.
---@class slop.ai.context.edits
local M = {}

local api = vim.api

M.opts = {
  max_events = 8,
  max_event_chars = 2000,
  max_buffer_bytes = 1024 * 1024,
  debounce = 500,
  ring_size = 16,
  ring_chunk_lines = 64,
  ring_min_lines = 3,
}

local snapshots = {} ---@type table<integer, {tick: integer, lines: string[]}>
local events = {} ---@type {buf: integer, path: string, diff: string, time: number}[]
local ring = {} ---@type {path: string, buf: integer, srow: integer, lines: string[], set: table, n: integer, time: number}[]
local timers = {} ---@type table<integer, uv.uv_timer_t>
local attached = false

local function trackable(buf)
  if not api.nvim_buf_is_valid(buf) or not api.nvim_buf_is_loaded(buf) then
    return false
  end
  if vim.bo[buf].buftype ~= "" or api.nvim_buf_get_name(buf) == "" then
    return false
  end
  local bytes = api.nvim_buf_get_offset(buf, api.nvim_buf_line_count(buf))
  if bytes > M.opts.max_buffer_bytes then
    return false
  end
  return not require("slop.core.secrets").is_blocked(buf)
end

--- Take a baseline snapshot of `buf` (if it has none).
---@param buf integer
---@param force? boolean
function M.snapshot(buf, force)
  if (snapshots[buf] and not force) or not trackable(buf) then
    return
  end
  snapshots[buf] = { tick = api.nvim_buf_get_changedtick(buf), lines = api.nvim_buf_get_lines(buf, 0, -1, false) }
end

local function truncate_hunks(diff, max)
  if #diff <= max then
    return diff
  end
  local hunks = {}
  for line in vim.gsplit(diff, "\n", { plain = true }) do
    if line:match("^@@") or #hunks == 0 then
      hunks[#hunks + 1] = {}
    end
    table.insert(hunks[#hunks], line)
  end
  local out, n = {}, 0
  for _, hk in ipairs(hunks) do
    local text = table.concat(hk, "\n")
    if n + #text + 1 > max then
      break
    end
    out[#out + 1] = text
    n = n + #text + 1
  end
  if #out == 0 then
    return diff:sub(1, max)
  end
  return table.concat(out, "\n")
end

--- Record the pending edit of `buf` now (baseline -> current).
---@param buf integer
function M.flush(buf)
  local snap = snapshots[buf]
  if not snap or not api.nvim_buf_is_valid(buf) then
    return
  end
  local tick = api.nvim_buf_get_changedtick(buf)
  if tick == snap.tick then
    return
  end
  local cur = api.nvim_buf_get_lines(buf, 0, -1, false)
  local a = table.concat(snap.lines, "\n") .. "\n"
  local b = table.concat(cur, "\n") .. "\n"
  snapshots[buf] = { tick = tick, lines = cur }
  if a == b then
    return
  end
  local ok, diff = pcall(vim.text.diff, a, b, { ctxlen = 3, result_type = "unified" })
  if not ok or type(diff) ~= "string" or diff == "" then
    return
  end
  diff = truncate_hunks(diff, M.opts.max_event_chars)
  events[#events + 1] = { buf = buf, path = api.nvim_buf_get_name(buf), diff = diff, time = vim.uv.now() }
  while #events > M.opts.max_events do
    table.remove(events, 1)
  end
end

local function schedule_flush(buf)
  local t = timers[buf]
  if not t then
    t = assert(vim.uv.new_timer())
    timers[buf] = t
  end
  t:stop()
  t:start(
    M.opts.debounce,
    0,
    vim.schedule_wrap(function()
      M.flush(buf)
    end)
  )
end

---@return {buf: integer, path: string, diff: string, time: number}[]
function M.events()
  return events
end

-- Ring -------------------------------------------------------------------------------------------

--- Add a chunk of text to the ring (deduplicated: a chunk >= 90% similar to an existing one replaces it).
---@param buf integer
---@param srow integer                 0-based first row
---@param lines string[]
function M.ring_add(buf, srow, lines)
  if #lines < M.opts.ring_min_lines or not trackable(buf) then
    return
  end
  local nb = require("slop.services.ai.context.neighbors")
  local set, n = nb.tokens(table.concat(lines, "\n"))
  if n < 3 then
    return
  end
  for i = #ring, 1, -1 do
    if nb.jaccard(set, n, ring[i].set, ring[i].n) > 0.9 then
      table.remove(ring, i)
    end
  end
  ring[#ring + 1] = {
    buf = buf,
    path = api.nvim_buf_get_name(buf),
    srow = srow,
    lines = lines,
    set = set,
    n = n,
    time = vim.uv.now(),
  }
  while #ring > M.opts.ring_size do
    table.remove(ring, 1)
  end
end

--- Chunk around the cursor of the current window.
---@param buf integer
function M.ring_cursor(buf)
  local win = api.nvim_get_current_win()
  if api.nvim_win_get_buf(win) ~= buf then
    return
  end
  local row = api.nvim_win_get_cursor(win)[1] - 1
  local half = math.floor(M.opts.ring_chunk_lines / 2)
  local s = math.max(0, row - half)
  M.ring_add(buf, s, api.nvim_buf_get_lines(buf, s, s + M.opts.ring_chunk_lines, false))
end

---@return table[]
function M.ring()
  return ring
end

-- Wiring -----------------------------------------------------------------------------------------

--- Start tracking (idempotent). Takes baselines of loaded buffers lazily (BufEnter / InsertEnter / first change).
function M.attach()
  if attached then
    return
  end
  attached = true
  local group = api.nvim_create_augroup("slop.ai.context", { clear = true })
  api.nvim_create_autocmd({ "BufEnter", "InsertEnter", "BufReadPost" }, {
    group = group,
    desc = "slop: ai context baseline",
    callback = function(ev)
      M.snapshot(ev.buf)
    end,
  })
  api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    group = group,
    desc = "slop: ai context recent edits",
    callback = function(ev)
      if not snapshots[ev.buf] then
        M.snapshot(ev.buf)
        return
      end
      schedule_flush(ev.buf)
    end,
  })
  api.nvim_create_autocmd({ "InsertLeave", "BufLeave" }, {
    group = group,
    desc = "slop: ai context flush edits",
    callback = function(ev)
      M.flush(ev.buf)
      if ev.event == "BufLeave" then
        M.ring_cursor(ev.buf)
      end
    end,
  })
  api.nvim_create_autocmd("BufWritePost", {
    group = group,
    desc = "slop: ai context ring (save)",
    callback = function(ev)
      M.ring_cursor(ev.buf)
    end,
  })
  api.nvim_create_autocmd("TextYankPost", {
    group = group,
    desc = "slop: ai context ring (yank)",
    callback = function(ev)
      local reg = vim.v.event.regcontents
      if type(reg) == "table" and #reg > 0 then
        local row = api.nvim_buf_get_mark(ev.buf, "[")[1] - 1
        M.ring_add(ev.buf, math.max(0, row), vim.list_slice(reg, 1, M.opts.ring_chunk_lines))
      end
    end,
  })
  api.nvim_create_autocmd({ "BufWipeout", "BufDelete" }, {
    group = group,
    desc = "slop: ai context cleanup",
    callback = function(ev)
      M.flush(ev.buf)
      snapshots[ev.buf] = nil
      local t = timers[ev.buf]
      if t then
        timers[ev.buf] = nil
        t:stop()
        t:close()
      end
      require("slop.services.ai.context.neighbors").forget(ev.buf)
    end,
  })
  M.snapshot(api.nvim_get_current_buf())
end

--- Forget everything (tests).
function M.reset()
  snapshots, events, ring = {}, {}, {}
  for _, t in pairs(timers) do
    t:stop()
    t:close()
  end
  timers = {}
  attached = false
  pcall(api.nvim_del_augroup_by_name, "slop.ai.context")
end

return M

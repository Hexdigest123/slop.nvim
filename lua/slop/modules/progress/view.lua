--- progress: the bottom-right window. One reused nofile buffer in a non-focusable float (its own
--- nvim_open_win: core.ui.float never goes borderless, this HUD defaults to border = "none").
--- A core.ui.spinner ticker runs while there are items: it advances the frames, prunes lingering items
--- and retries a render that failed (textlock, cmdwin).
---@class slop.progress.view
local M = {}

local api = vim.api
local store = require("slop.modules.progress.store")
local fn = vim.fn

local cfg ---@type table
local state = {
  win = nil, ---@type integer?
  buf = nil, ---@type integer?
  visible = true,
  ticker = nil, ---@type slop.Spinner?
  queued = false,
  drawn = nil, ---@type string?  last buffer content (skip identical redraws)
  sweep = nil, ---@type fun(): boolean?
}

local NS = api.nvim_create_namespace("slop.progress")
local WINHL = "Normal:SlopProgressNormal,NormalFloat:SlopProgressNormal,FloatBorder:SlopProgressBorder"

local ICON_HL = {
  success = "SlopProgressDone",
  failed = "SlopProgressError",
  cancel = "SlopProgressCancel",
}

---@param c table  module config
---@param sweep? fun(): boolean  called on every tick before pruning
function M.configure(c, sweep)
  cfg = c
  state.sweep = sweep or state.sweep
  if state.ticker then
    state.ticker:stop()
    state.ticker = nil
  end
end

---@return slop.Spinner
local function ticker()
  if not state.ticker then
    state.ticker = require("slop.core.ui.spinner").new({
      style = cfg.spinner or nil,
      interval = cfg.interval,
      on_tick = function()
        if state.sweep then
          state.sweep()
        end
        M.render()
      end,
    })
  end
  return state.ticker
end

-- Lines -------------------------------------------------------------------------------------------

---@param s string
---@param width integer
---@return string
local function truncate(s, width)
  if fn.strdisplaywidth(s) <= width then
    return s
  end
  if width <= 1 then
    return width == 1 and "…" or ""
  end
  local n = fn.strchars(s)
  while n > 0 and fn.strdisplaywidth(fn.strcharpart(s, 0, n)) > width - 1 do
    n = n - 1
  end
  return fn.strcharpart(s, 0, n) .. "…"
end

---@param item slop.progress.Item
---@param frame string
---@return string icon, string hl
function M.icon(item, frame)
  if item.status == "running" then
    return frame, "SlopProgressSpinner"
  end
  return cfg.icons[item.status] or cfg.icons.success, ICON_HL[item.status] or ICON_HL.success
end

---@alias slop.progress.Chunk {[1]: string, [2]: string?}

--- The chunks of one item line: "<message> (<p>%)  <title> <icon>", the message truncated to fit `width`.
---@param item slop.progress.Item
---@param frame string
---@param width integer
---@return slop.progress.Chunk[]
function M.item_chunks(item, frame, width)
  local icon, icon_hl = M.icon(item, frame)
  local tail = {} ---@type slop.progress.Chunk[]
  local msg = item.message or ""
  local title = item.title or ""
  if title == msg then
    title = ""
  end
  if title ~= "" then
    tail[#tail + 1] = { (msg ~= "" and "  " or "") .. title, "SlopProgressTitle" }
  end
  tail[#tail + 1] = { " " .. icon, icon_hl }
  local pct = ""
  if item.status == "running" and item.percent then
    pct = ("%s(%d%%)"):format(msg ~= "" and " " or "", item.percent)
  end
  local used = fn.strdisplaywidth(pct)
  for _, c in ipairs(tail) do
    used = used + fn.strdisplaywidth(c[1])
  end
  local out = {} ---@type slop.progress.Chunk[]
  if msg ~= "" then
    out[1] = { truncate(msg, math.max(1, width - used)), "SlopProgressMessage" }
  elseif title == "" and #tail == 1 then
    tail[1][1] = icon -- icon only: drop the separator
  end
  if pct ~= "" then
    out[#out + 1] = { pct, "SlopProgressPercent" }
  end
  vim.list_extend(out, tail)
  return out
end

---@param width integer
---@return integer
local function max_width(width)
  local mw = cfg.window.max_width
  local cols = vim.o.columns - cfg.window.x_padding - (cfg.window.border == "none" and 0 or 2)
  local limit = mw <= 1 and math.floor(vim.o.columns * mw) or math.floor(mw)
  return math.max(1, math.min(width, limit, cols))
end

--- Lines to show for `items` (grouped; at most `max_items` per group, newest kept).
---@param items slop.progress.Item[]
---@param frame string
---@return slop.progress.Chunk[][] lines
function M.lines(items, frame)
  local groups, order = {}, {}
  for _, item in ipairs(items) do
    if not groups[item.group] then
      groups[item.group] = {}
      order[#order + 1] = item.group
    end
    local g = groups[item.group]
    g[#g + 1] = item
  end
  local width = max_width(math.huge)
  local lines = {}
  for _, name in ipairs(order) do
    lines[#lines + 1] = { { truncate(name, width), "SlopProgressGroup" } }
    local list = groups[name]
    for i = math.max(1, #list - cfg.max_items + 1), #list do
      lines[#lines + 1] = M.item_chunks(list[i], frame, width)
    end
  end
  return lines
end

-- Window ------------------------------------------------------------------------------------------

---@return integer
local function statusline_height()
  local ls = vim.o.laststatus
  if ls == 0 then
    return 0
  elseif ls == 1 then
    local n = 0
    for _, w in ipairs(api.nvim_tabpage_list_wins(0)) do
      if api.nvim_win_get_config(w).relative == "" then
        n = n + 1
      end
    end
    return n > 1 and 1 or 0
  end
  return 1
end

--- Window config for content of `width` x `height` (anchored at the bottom-right corner).
---@param width integer
---@param height integer
---@return vim.api.keyset.win_config
function M.win_config(width, height)
  local w = cfg.window
  local bordered = w.border ~= "none"
  local bottom = vim.o.lines - vim.o.cmdheight - statusline_height() - w.y_padding
  local room = math.max(1, bottom - (bordered and 2 or 0) - (vim.o.showtabline > 0 and 1 or 0))
  return {
    relative = "editor",
    anchor = "SE",
    row = math.max(1, bottom),
    col = math.max(1, vim.o.columns - w.x_padding),
    width = math.max(1, width),
    height = math.max(1, math.min(height, room)),
    style = "minimal",
    focusable = false,
    mouse = false,
    border = w.border,
    zindex = w.zindex,
  }
end

---@return integer
local function buffer()
  if state.buf and api.nvim_buf_is_valid(state.buf) then
    return state.buf
  end
  local buf = api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].undolevels = -1
  vim.bo[buf].filetype = "slopprogress"
  state.buf, state.drawn = buf, nil
  return buf
end

--- Close the window. False when it could not be closed right now (textlock).
---@return boolean
function M.close()
  local win = state.win
  if win and api.nvim_win_is_valid(win) and not pcall(api.nvim_win_close, win, true) then
    return false
  end
  state.win = nil
  return true
end

---@param lines slop.progress.Chunk[][]
local function draw(lines)
  local width = 0
  for _, chunks in ipairs(lines) do
    local w = 0
    for _, c in ipairs(chunks) do
      w = w + fn.strdisplaywidth(c[1])
    end
    width = math.max(width, w)
  end
  width = max_width(width)
  local conf = M.win_config(width, #lines)
  -- keep the newest lines when the window cannot show them all
  local first = math.max(1, #lines - conf.height + 1)
  local text, marks = {}, {}
  for i = first, #lines do
    local chunks = lines[i]
    local w = 0
    for _, c in ipairs(chunks) do
      w = w + fn.strdisplaywidth(c[1])
    end
    local line = string.rep(" ", math.max(0, width - w)) -- right-aligned
    for _, c in ipairs(chunks) do
      if c[2] then
        marks[#marks + 1] = { #text, #line, #line + #c[1], c[2] }
      end
      line = line .. c[1]
    end
    text[#text + 1] = line
  end
  local buf = buffer()
  local drawn = table.concat(text, "\n") .. "\0" .. vim.inspect(marks)
  if drawn ~= state.drawn then
    state.drawn = nil
    api.nvim_buf_set_lines(buf, 0, -1, false, text)
    api.nvim_buf_clear_namespace(buf, NS, 0, -1)
    for _, m in ipairs(marks) do
      api.nvim_buf_set_extmark(buf, NS, m[1], m[2], { end_col = m[3], hl_group = m[4] })
    end
    state.drawn = drawn
  end
  local win = state.win
  if win and api.nvim_win_is_valid(win) and api.nvim_win_get_tabpage(win) ~= api.nvim_get_current_tabpage() then
    assert(M.close(), "progress window busy")
    win = nil
  end
  if win and api.nvim_win_is_valid(win) then
    local cur = api.nvim_win_get_config(win)
    if cur.width ~= conf.width or cur.height ~= conf.height or cur.row ~= conf.row or cur.col ~= conf.col then
      conf.style = nil
      api.nvim_win_set_config(win, conf)
    end
  else
    conf.noautocmd = true
    win = api.nvim_open_win(buf, false, conf)
    state.win = win
    vim.wo[win].winhighlight = WINHL
    vim.wo[win].winblend = cfg.window.winblend
    vim.wo[win].wrap = false
  end
end

local function retry()
  if not state.queued then
    state.queued = true
    vim.defer_fn(function()
      state.queued = false
      M.render()
    end, 50)
  end
end

--- Render the store now: prune lingering items, open/update/close the window, start/stop the ticker.
function M.render()
  if not cfg then
    return
  end
  store.prune()
  local items = store.items()
  if #items == 0 then
    if state.ticker then
      state.ticker:stop()
    end
    if not M.close() then
      retry()
    end
    return
  end
  local t = ticker()
  if not t:is_running() then
    t:start()
  end
  if not state.visible then
    if not M.close() then
      retry()
    end
    return
  end
  if fn.getcmdwintype() ~= "" then
    return -- floats cannot be opened from the cmdwin; the ticker retries
  end
  local ok = pcall(draw, M.lines(items, t:frame()))
  if not ok then
    retry()
  end
end

--- The store changed: render now when an item appeared/finished (`now`) or nothing is shown yet, else
--- leave it to the next tick (bursts of LSP reports are drawn at most once per `interval`).
---@param now? boolean
function M.request(now)
  if not now and state.ticker and state.ticker:is_running() and M.win() then
    return
  end
  M.render()
end

--- Show/hide the window (items are still tracked while hidden).
---@return boolean visible
function M.toggle()
  state.visible = not state.visible
  M.render()
  return state.visible
end

---@return integer? win
function M.win()
  return state.win and api.nvim_win_is_valid(state.win) and state.win or nil
end

---@return integer? buf
function M.buf()
  return state.buf and api.nvim_buf_is_valid(state.buf) and state.buf or nil
end

---@return boolean
function M.visible()
  return state.visible
end

-- History -----------------------------------------------------------------------------------------

--- Open the history (newest first) in a slop float; q / <Esc> close it.
---@return slop.float.Handle
function M.show_history()
  local hist = store.history()
  local lines, marks = {}, {}
  for i = #hist, 1, -1 do
    local it = hist[i]
    local icon, hl = M.icon(it, "")
    local parts = { os.date("%H:%M:%S", it.time or os.time()), icon, it.group }
    for _, s in ipairs({ it.title, it.message, it.detail }) do
      if type(s) == "string" and s ~= "" and not vim.tbl_contains(parts, s) then
        parts[#parts + 1] = s
      end
    end
    local line = table.concat(parts, "  ")
    if it.ms then
      line = ("%s  (%.1fs)"):format(line, it.ms / 1000)
    end
    local col = #parts[1] + 2
    marks[#marks + 1] = { #lines, col, col + #icon, hl }
    lines[#lines + 1] = line
  end
  if #lines == 0 then
    lines = { "no finished tasks yet" }
  end
  local h = require("slop.core.ui.float").open({
    title = "slop progress history",
    width = 0.7,
    height = math.max(1, math.min(#lines, math.floor(vim.o.lines * 0.6))),
    close_keys = { "q", "<Esc>" },
    bo = { filetype = "slopprogresshistory" },
    wo = { wrap = false, cursorline = true },
  })
  api.nvim_buf_set_lines(h.buf, 0, -1, false, lines)
  for _, m in ipairs(marks) do
    api.nvim_buf_set_extmark(h.buf, NS, m[1], m[2], { end_col = m[3], hl_group = m[4] })
  end
  vim.bo[h.buf].modifiable = false
  return h
end

--- Teardown: stop the ticker, close the window, wipe the buffer.
function M.stop()
  if state.ticker then
    state.ticker:stop()
    state.ticker = nil
  end
  M.close()
  if state.buf and api.nvim_buf_is_valid(state.buf) then
    pcall(api.nvim_buf_delete, state.buf, { force = true })
  end
  state.buf, state.visible, state.drawn, cfg = nil, true, nil, nil
end

return M

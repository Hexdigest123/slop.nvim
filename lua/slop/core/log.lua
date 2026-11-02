--- Ring-buffer logger + user notifications. All user-facing messages go through here so they get the
--- "slop: " prefix, are recorded for :Slop log, and are safe to call from fast (luv) callbacks.
---
---   local log = require("slop.core.log").scope("term")
---   log.debug("spawned %s", cmd)        -- recorded (if level allows), never shown
---   log.warn("shell %s not found", sh)  -- recorded + vim.notify("slop: term: shell ... not found")
---@class slop.log
local M = {}

local levels = vim.log.levels
local names = { [0] = "TRACE", "DEBUG", "INFO", "WARN", "ERROR", "OFF" }

---@class slop.log.Entry
---@field time number      os.time()
---@field level integer    vim.log.levels.*
---@field scope? string    module/core file name
---@field msg string

local entries = {} ---@type slop.log.Entry[]
local head = 0 -- index of newest entry
local count = 0
local cap = nil ---@type integer?  capacity the ring is laid out for

local function threshold()
  local config = package.loaded["slop.config"] or require("slop.config")
  local ok, lvl = pcall(config.log_level)
  return ok and lvl or levels.WARN
end

--- Ring capacity from log.max_entries. Clamped: the value is read while an invalid config is being
--- reported (through this logger), and `head % 0` would make every later record() throw.
---@return integer
local function max_entries()
  local ok, n = pcall(function()
    return require("slop.config").get("log").max_entries
  end)
  n = ok and type(n) == "number" and math.floor(n) or 2000
  return n >= 1 and n or 2000
end

--- Recorded entries, oldest first (for the current layout).
---@return slop.log.Entry[]
local function ordered()
  local out = {}
  if count == 0 or not cap then
    return out
  end
  local start = count < cap and 1 or (head % cap + 1)
  for i = 0, count - 1 do
    local e = entries[(start - 1 + i) % cap + 1]
    if e then
      out[#out + 1] = e
    end
  end
  return out
end

local function fmt(msg, ...)
  if select("#", ...) == 0 then
    return tostring(msg)
  end
  local args = { ... }
  for i = 1, select("#", ...) do
    if type(args[i]) == "table" then
      args[i] = vim.inspect(args[i])
    elseif args[i] == nil then
      args[i] = "nil"
    end
  end
  local ok, out = pcall(string.format, tostring(msg), unpack(args, 1, select("#", ...)))
  return ok and out or (tostring(msg) .. " " .. table.concat(vim.tbl_map(tostring, args), " "))
end

local function record(level, scope, msg)
  local max = max_entries()
  if max ~= cap then
    -- log.max_entries changed (setup()): keep the newest entries, in order
    local keep = ordered()
    keep = vim.list_slice(keep, math.max(1, #keep - max + 1))
    entries, cap, count, head = keep, max, #keep, #keep
  end
  head = head % cap + 1
  entries[head] = { time = os.time(), level = level, scope = scope, msg = msg }
  count = math.min(count + 1, cap)
end

local function prefix(scope)
  return scope and ("slop: " .. scope .. ": ") or "slop: "
end

local deferring = 0 -- > 0 while M.deferred() runs

local function show(text, level, opts)
  if vim.in_fast_event() or deferring > 0 then
    vim.schedule(function()
      vim.notify(text, level, opts)
    end)
  else
    vim.notify(text, level, opts)
  end
end

--- Run `fn` with notifications shown right after it instead of during it (they are recorded at once). For
--- code that runs inside another command, e.g. a lazy load in BufReadPre: an error message there becomes an
--- exception of that command, and an `:edit` run from Lua (pickers, vim.cmd) then skips reading the file.
---@param fn fun()
---@return boolean ok, string? err
function M.deferred(fn)
  deferring = deferring + 1
  local ok, err = xpcall(fn, debug.traceback)
  deferring = deferring - 1
  return ok, err
end

---@param level integer
---@param scope string?
---@param msg any
local function log(level, scope, msg, ...)
  local text = fmt(msg, ...)
  local thr = threshold()
  if level >= levels.INFO or level >= thr then
    record(level, scope, text)
  end
  if level >= thr and thr < levels.OFF then
    -- Avoid double prefixes when callers already wrote "slop: ...".
    if not vim.startswith(text, "slop: ") then
      text = prefix(scope) .. text
    end
    show(text, level, { title = "slop" })
  end
end

--- Always show a message (regardless of log.level) and record it. Use for explicit user feedback.
---@param msg string
---@param level? integer  default INFO
---@param opts? {scope?: string, title?: string}
function M.notify(msg, level, opts)
  opts = opts or {}
  level = level or levels.INFO
  local text = tostring(msg)
  record(level, opts.scope, text)
  if not vim.startswith(text, "slop: ") then
    text = prefix(opts.scope) .. text
  end
  show(text, level, { title = opts.title or "slop" })
end

function M.trace(msg, ...)
  log(levels.TRACE, nil, msg, ...)
end
function M.debug(msg, ...)
  log(levels.DEBUG, nil, msg, ...)
end
function M.info(msg, ...)
  log(levels.INFO, nil, msg, ...)
end
function M.warn(msg, ...)
  log(levels.WARN, nil, msg, ...)
end
function M.error(msg, ...)
  log(levels.ERROR, nil, msg, ...)
end

---@class slop.log.Scoped
---@field trace fun(msg: any, ...)
---@field debug fun(msg: any, ...)
---@field info fun(msg: any, ...)
---@field warn fun(msg: any, ...)
---@field error fun(msg: any, ...)
---@field notify fun(msg: string, level?: integer)

--- Logger whose messages are tagged with `scope` (shown as "slop: <scope>: msg").
---@param scope string
---@return slop.log.Scoped
function M.scope(scope)
  return {
    trace = function(msg, ...)
      log(levels.TRACE, scope, msg, ...)
    end,
    debug = function(msg, ...)
      log(levels.DEBUG, scope, msg, ...)
    end,
    info = function(msg, ...)
      log(levels.INFO, scope, msg, ...)
    end,
    warn = function(msg, ...)
      log(levels.WARN, scope, msg, ...)
    end,
    error = function(msg, ...)
      log(levels.ERROR, scope, msg, ...)
    end,
    notify = function(msg, level)
      M.notify(msg, level, { scope = scope })
    end,
  }
end

--- Recorded entries, oldest first.
---@param opts? {level?: integer, scope?: string}
---@return slop.log.Entry[]
function M.entries(opts)
  opts = opts or {}
  local out = {}
  for _, e in ipairs(ordered()) do
    if (not opts.level or e.level >= opts.level) and (not opts.scope or e.scope == opts.scope) then
      out[#out + 1] = e
    end
  end
  return out
end

function M.clear()
  entries, head, count = {}, 0, 0
end

---@param e slop.log.Entry
---@return string
function M.format_entry(e)
  return ("%s %-5s %s%s"):format(
    os.date("%H:%M:%S", e.time),
    names[e.level] or "?",
    e.scope and ("[" .. e.scope .. "] ") or "",
    e.msg
  )
end

local LOG_NAME = "slop://log"

--- The log buffer made by open(), if it is still that scratch buffer. ":bdelete" keeps a buffer valid but
--- clears its options and mappings: reused, it would be a normal modified file buffer that blocks :qa.
---@return integer?
local function log_buf()
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_get_name(b) == LOG_NAME then
      if vim.bo[b].buftype == "nofile" then
        return b
      end
      pcall(vim.api.nvim_buf_delete, b, { force = true })
      return nil
    end
  end
end

--- Open the log in a scratch split (buffer "slop://log", filetype "sloplog"; `q` closes).
---@param opts? {level?: integer}
---@return integer buf
function M.open(opts)
  local lines = {}
  for _, e in ipairs(M.entries(opts)) do
    vim.list_extend(lines, vim.split(M.format_entry(e), "\n", { plain = true }))
  end
  if #lines == 0 then
    lines = { "(slop log is empty)" }
  end
  local buf = log_buf()
  if not buf then
    buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(buf, LOG_NAME)
    vim.bo[buf].bufhidden = "hide"
    vim.bo[buf].filetype = "sloplog"
    vim.keymap.set("n", "q", "<Cmd>close<CR>", { buf = buf, desc = "slop: close log", nowait = true })
  end
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  local win = vim.fn.bufwinid(buf)
  if win == -1 then
    vim.cmd("botright split")
    win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, buf)
  else
    vim.api.nvim_set_current_win(win)
  end
  vim.api.nvim_win_set_cursor(win, { #lines, 0 })
  return buf
end

M.levels = levels

return M

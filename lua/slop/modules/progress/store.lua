--- progress: the task model (no UI). Items are keyed per source ("lsp:<client>:<token>", "native:<id>",
--- "ai:<id>"); finished items linger `linger` ms, then drop out. Every finished item goes to the history ring.
---@class slop.progress.store
local M = {}

---@alias slop.progress.Status "running"|"success"|"failed"|"cancel"

---@class slop.progress.Item
---@field key string
---@field origin "lsp"|"native"|"ai"
---@field group string                 display group: LSP client name, Progress source, "slop"
---@field title string
---@field message string
---@field percent? integer
---@field status slop.progress.Status
---@field started number               ms (monotonic)
---@field finished? number             ms (monotonic)
---@field ms? integer                  duration, once finished
---@field time? integer                os.time() at finish
---@field client_id? integer           origin "lsp"
---@field ai_id? integer               origin "ai", or a native item merged with an AI request
---@field detail? string               extra info kept for the history ("provider · model")

local items = {} ---@type table<string, slop.progress.Item>
local seq = {} ---@type table<string, integer>  key -> insertion number (display order)
local group_seq = {} ---@type table<string, integer>
local counter = 0
local history = {} ---@type slop.progress.Item[]
local cfg = { linger = 2000, history_size = 100 }

--- Monotonic milliseconds (overridable in tests).
---@return number
function M.now()
  return vim.uv.hrtime() / 1e6
end

---@param c {linger: integer, history_size: integer}
function M.configure(c)
  cfg = c
  while #history > cfg.history_size do
    table.remove(history, 1)
  end
end

local FIELDS = { "group", "title", "message", "percent", "client_id", "ai_id", "detail", "origin" }

---@param item slop.progress.Item
---@param fields table
local function apply(item, fields)
  for _, f in ipairs(FIELDS) do
    if fields[f] ~= nil then
      item[f] = fields[f]
    end
  end
end

---@param key string
---@param fields table
---@return slop.progress.Item
local function create(key, fields)
  counter = counter + 1
  local item = {
    key = key,
    origin = fields.origin or "native",
    group = fields.group or "slop",
    title = "",
    message = "",
    status = "running",
    started = M.now(),
  }
  apply(item, fields)
  items[key] = item
  seq[key] = counter
  if not group_seq[item.group] then
    group_seq[item.group] = counter
  end
  return item
end

--- Create or update a running item. A finished item with the same key is revived.
---@param key string
---@param fields table  any slop.progress.Item field (origin/group needed on creation)
---@return slop.progress.Item item, boolean created
function M.update(key, fields)
  local item = items[key]
  if not item then
    return create(key, fields), true
  end
  if item.status ~= "running" then
    item.status, item.finished, item.ms, item.time = "running", nil, nil, nil
    item.started = M.now()
  end
  apply(item, fields)
  return item, false
end

--- Finish an item (created first when unknown and `fields` has an origin). Pushes a copy to the history.
---@param key string
---@param status slop.progress.Status
---@param fields? table
---@return slop.progress.Item?
function M.finish(key, status, fields)
  local item = items[key]
  if not item then
    if not (fields and fields.origin) then
      return nil
    end
    item = create(key, fields)
  elseif item.status ~= "running" then
    return item
  else
    apply(item, fields or {})
  end
  local t = M.now()
  item.status = status
  item.finished = t
  item.ms = math.floor(t - item.started)
  item.time = os.time()
  if status == "success" and item.percent then
    item.percent = 100
  end
  history[#history + 1] = vim.deepcopy(item)
  while #history > cfg.history_size do
    table.remove(history, 1)
  end
  return item
end

---@param key string
---@return slop.progress.Item?
function M.get(key)
  return items[key]
end

---@param key string
function M.remove(key)
  items[key], seq[key] = nil, nil
end

--- First item matching `pred` (live object, not a copy).
---@param pred fun(item: slop.progress.Item): boolean
---@return slop.progress.Item?
function M.find(pred)
  local best
  for key, item in pairs(items) do
    if pred(item) and (not best or seq[key] < seq[best.key]) then
      best = item
    end
  end
  return best
end

--- Drop finished items older than `linger`. Returns true when something was removed.
---@param t? number
---@return boolean
function M.prune(t)
  t = t or M.now()
  local changed = false
  for key, item in pairs(items) do
    if item.finished and t - item.finished >= cfg.linger then
      M.remove(key)
      changed = true
    end
  end
  if not next(items) then
    group_seq = {}
  end
  return changed
end

---@return integer running, integer total
function M.count()
  local running, total = 0, 0
  for _, item in pairs(items) do
    total = total + 1
    if item.status == "running" then
      running = running + 1
    end
  end
  return running, total
end

--- Current items (copies) in display order: by group (first seen), then by start.
---@return slop.progress.Item[]
function M.items()
  local out = {}
  for _, item in pairs(items) do
    out[#out + 1] = item
  end
  table.sort(out, function(a, b)
    local ga, gb = group_seq[a.group] or 0, group_seq[b.group] or 0
    if ga ~= gb then
      return ga < gb
    end
    return seq[a.key] < seq[b.key]
  end)
  return vim.deepcopy(out)
end

--- Finished items, oldest first (copies).
---@return slop.progress.Item[]
function M.history()
  return vim.deepcopy(history)
end

--- Clear the current items ("items", default), the history ("history") or both ("all").
---@param what? "items"|"history"|"all"
function M.clear(what)
  what = what or "items"
  if what == "items" or what == "all" then
    items, seq, group_seq = {}, {}, {}
  end
  if what == "history" or what == "all" then
    history = {}
  end
end

--- Forget everything (teardown / tests).
function M.reset()
  items, seq, group_seq, history, counter = {}, {}, {}, {}, 0
end

return M

--- progress: event sources -> store. LspProgress, Progress (nvim_echo kind="progress") and the AI service's
--- User SlopAiRequestStarted / SlopAiRequestFinished. Also owns the 'messagesopt' echo suppression.
---@class slop.progress.sources
local M = {}

local api = vim.api
local store = require("slop.modules.progress.store")

local cfg ---@type table
local on_change = function() end
local ids = {} ---@type integer[]
local linked = {} ---@type table<integer, string>  AI request id -> native item key it was merged into
local mopt = nil ---@type {saved: string, set: string}?

local STATUS = { running = "running", success = "success", failed = "failed", cancel = "cancel" }

---@param group string
---@return boolean
local function ignored(group)
  return vim.tbl_contains(cfg.ignore, group)
end

---@param item slop.progress.Item
---@param t number
---@return boolean
local function recent(item, t)
  return item.status == "running" and math.abs(t - item.started) <= cfg.dedupe_ms
end

-- LSP -----------------------------------------------------------------------------------------------

---@param ev {data?: {client_id: integer, params: lsp.ProgressParams}}
function M.lsp(ev)
  local data = ev.data
  if not (cfg.sources.lsp and type(data) == "table" and type(data.params) == "table") then
    return
  end
  local value = data.params.value
  if type(value) ~= "table" or not value.kind then
    return
  end
  local client = vim.lsp.get_client_by_id(data.client_id)
  local group = client and client.name or ("lsp " .. tostring(data.client_id))
  if ignored(group) then
    return
  end
  local key = ("lsp:%s:%s"):format(tostring(data.client_id), tostring(data.params.token))
  if value.kind == "end" then
    -- `end` of a task we never saw: nothing to show
    if store.get(key) and store.finish(key, "success", { message = value.message }) then
      on_change()
    end
    return
  end
  local fields = { origin = "lsp", group = group, client_id = data.client_id, title = value.title }
  if value.kind == "begin" then
    fields.message = value.message or ""
    fields.percent = value.percentage
  else
    fields.message = value.message
    fields.percent = value.percentage
  end
  store.update(key, fields)
  on_change()
end

--- Finish LSP items whose client stopped (no `end` will ever arrive).
---@return boolean changed
function M.sweep()
  local changed = false
  for _, item in ipairs(store.items()) do
    if item.origin == "lsp" and item.status == "running" then
      local client = vim.lsp.get_client_by_id(item.client_id)
      if not client or client:is_stopped() then
        store.finish(item.key, "cancel")
        changed = true
      end
    end
  end
  return changed
end

-- Native progress messages ----------------------------------------------------------------------------

---@param ai_key string
---@param native slop.progress.Item
local function merge(ai_key, native)
  local ai = store.get(ai_key)
  if not ai then
    return
  end
  linked[ai.ai_id] = native.key
  native.ai_id, native.detail = ai.ai_id, ai.detail
  store.remove(ai_key)
end

---@param ev {match?: string, data?: vim.event.progress.data}
function M.native(ev)
  local d = ev.data
  if not (cfg.sources.native and type(d) == "table" and d.id ~= nil) then
    return
  end
  local source = (type(d.source) == "string" and d.source ~= "") and d.source or ev.match or "?"
  if ignored(source) or (cfg.sources.lsp and vim.tbl_contains(cfg.lsp_mirror_sources, source)) then
    return
  end
  local text = type(d.text) == "table" and table.concat(d.text) or tostring(d.text or "")
  local fields = {
    origin = "native",
    group = source,
    title = type(d.title) == "string" and d.title or "",
    message = text,
  }
  local key = "native:" .. tostring(d.id)
  local status = STATUS[d.status] or "running"
  if status == "running" then
    fields.percent = (type(d.percent) == "number" and d.percent > 0) and d.percent or nil
    local item, created = store.update(key, fields)
    if created and source == "slop" then
      local t = item.started
      local ai = store.find(function(i)
        return i.origin == "ai" and recent(i, t)
      end)
      if ai then
        merge(ai.key, item)
      end
    end
  else
    if text == "" then
      fields.message = nil
    end
    store.finish(key, status, fields)
  end
  on_change()
end

-- AI requests -------------------------------------------------------------------------------------

---@param d {id: integer, kind: string, provider?: string, model?: string, source?: string}
function M.ai_started(d)
  if type(d) ~= "table" or type(d.id) ~= "number" or not cfg.sources.ai[d.kind] or ignored("slop") then
    return
  end
  local parts = {}
  for _, s in ipairs({ d.provider or "", d.model or "" }) do
    if type(s) == "string" and s ~= "" and s ~= parts[1] then
      parts[#parts + 1] = s
    end
  end
  local detail = table.concat(parts, " · ")
  local t = store.now()
  local native = store.find(function(i)
    return i.origin == "native" and i.group == "slop" and not i.ai_id and recent(i, t)
  end)
  if native then
    linked[d.id] = native.key
    native.ai_id, native.detail = d.id, detail
    return
  end
  store.update("ai:" .. d.id, {
    origin = "ai",
    group = "slop",
    title = d.source or "ai",
    message = detail,
    ai_id = d.id,
    detail = detail,
  })
  on_change()
end

---@param d {id: integer, error?: string}
function M.ai_finished(d)
  if type(d) ~= "table" or type(d.id) ~= "number" then
    return
  end
  if linked[d.id] then
    linked[d.id] = nil
    return
  end
  local key = "ai:" .. d.id
  if not store.get(key) then
    return
  end
  local status = d.error == nil and "success" or (d.error == "cancelled" and "cancel" or "failed")
  store.finish(key, status, d.error and status == "failed" and { message = d.error } or nil)
  on_change()
end

-- 'messagesopt' -----------------------------------------------------------------------------------

--- The 'messagesopt' value with its "progress:" item set to `value`.
---@param opt string
---@param value string
---@return string
function M.with_progress(opt, value)
  local parts, found = {}, false
  for _, p in ipairs(vim.split(opt, ",", { trimempty = true })) do
    if p:match("^progress:") then
      found = true
      p = "progress:" .. value
    end
    parts[#parts + 1] = p
  end
  if not found then
    parts[#parts + 1] = "progress:" .. value
  end
  return table.concat(parts, ",")
end

--- Hide (true) or restore (false) Neovim's own cmdline echo of progress messages.
---@param on boolean
function M.suppress_echo(on)
  if on and not mopt then
    local saved = vim.o.messagesopt
    local new = M.with_progress(saved, "")
    if new ~= saved and pcall(function()
      vim.o.messagesopt = new
    end) then
      mopt = { saved = saved, set = new }
    end
  elseif not on and mopt then
    if vim.o.messagesopt == mopt.set then
      pcall(function()
        vim.o.messagesopt = mopt.saved
      end)
    end
    mopt = nil
  end
end

---@return boolean
function M.suppressing()
  return mopt ~= nil
end

-- Lifecycle ---------------------------------------------------------------------------------------

---@param c table             merged module config
function M.configure(c)
  cfg = c
  M.suppress_echo(c.suppress_echo)
end

--- Create the autocmds (in augroup "slop.progress", where the registry replays the lazy-load trigger).
---@param c table
---@param changed fun()        called after the store changed
---@param ui fun()             re-layout (VimResized / TabEnter / 'laststatus' / 'cmdheight')
function M.start(c, changed, ui)
  M.configure(c)
  on_change = changed
  local util = require("slop.core.util")
  local group = util.augroup("progress")
  local function au(event, opts)
    opts.group = group
    ids[#ids + 1] = api.nvim_create_autocmd(event, opts)
  end
  au("LspProgress", { desc = "slop: progress lsp", callback = M.lsp })
  au("Progress", { desc = "slop: progress messages", callback = M.native })
  local events = require("slop.core.events")
  au("User", {
    pattern = events.pattern("ai", "RequestStarted"),
    desc = "slop: progress ai",
    callback = function(ev)
      M.ai_started(ev.data)
    end,
  })
  au("User", {
    pattern = events.pattern("ai", "RequestFinished"),
    desc = "slop: progress ai",
    callback = function(ev)
      M.ai_finished(ev.data)
    end,
  })
  au({ "VimResized", "TabEnter" }, { desc = "slop: progress layout", callback = ui })
  au("OptionSet", { pattern = { "laststatus", "cmdheight" }, desc = "slop: progress layout", callback = ui })
end

--- Delete the autocmds (only ours: core.ui.spinner shares the augroup) and restore 'messagesopt'.
function M.stop()
  for _, id in ipairs(ids) do
    pcall(api.nvim_del_autocmd, id)
  end
  ids, linked = {}, {}
  on_change = function() end
  M.suppress_echo(false)
end

return M

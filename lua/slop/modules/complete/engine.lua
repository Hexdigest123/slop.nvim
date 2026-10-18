--- complete engine: per-buffer requests, streaming into ghost text, typed-through sync, cycling, cache.
--- OWNER: complete.
---
--- Flow: InsertEnter / TextChangedI / CursorMovedI -> sync() -> debounce (cfg.debounce, trailing, per buffer)
--- -> trigger(): gate (allowed) -> mid-line gate -> prefix cache -> context.fim -> ai.complete_fim (streamed)
--- -> render() as ghost text. A request ("req") is anchored at the cursor; everything typed or accepted after the
--- anchor is matched against the candidates, so typing through a suggestion and partial accepts never re-request.
---@class slop.complete.engine
local M = {}

local api = vim.api

---@class slop.complete.Request
---@field id integer
---@field ghost_id string
---@field buf integer
---@field anchor {[1]: integer, [2]: integer}
---@field anchor_prefix string
---@field after string
---@field items string[]
---@field index integer
---@field text string                      streamed (partially processed) text of the first candidate
---@field loading boolean
---@field fetching boolean
---@field exhausted boolean
---@field stopped? boolean
---@field multiline boolean
---@field pctx slop.complete.PPContext
---@field keys {prefix: string, suffix: string}
---@field ctx? slop.ai.Context
---@field handles slop.http.Handle[]
---@field on_items? fun(items: string[])
---@field no_render? boolean
---@field manual boolean
---@field pending_next? boolean

M.auto = true -- global auto-trigger switch (toggle)
M.cfg = nil ---@type table?

local states = {} ---@type table<integer, {debounce: slop.util.Debounced, req?: slop.complete.Request, suppress_tick?: integer}>
local seq = 0
local cache ---@type slop.complete.Cache?
local notified = {} ---@type table<string, number>

local function util()
  return require("slop.core.util")
end

local function ghost()
  return require("slop.core.ui.ghost")
end

local function pp()
  return require("slop.modules.complete.postprocess")
end

local function log()
  return require("slop.core.log").scope("complete")
end

local function events()
  return require("slop.core.events")
end

---@return table
local function cfg()
  if not M.cfg then
    M.cfg = require("slop.config").get("complete")
  end
  return M.cfg
end

local function get_cache()
  if not cache then
    cache = require("slop.modules.complete.cache").new(64)
  end
  return cache
end

local function in_insert()
  local m = api.nvim_get_mode().mode
  return m:sub(1, 1) == "i" or m:sub(1, 1) == "R"
end

local function cursor()
  local c = api.nvim_win_get_cursor(0)
  return c[1] - 1, c[2]
end

local function line_of(buf, row)
  return api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ""
end

local function state(buf)
  local st = states[buf]
  if not st then
    st = {}
    st.debounce = util().debounce(function()
      M.auto_trigger(buf)
    end, cfg().debounce)
    states[buf] = st
  end
  return st
end

--- Apply a new config (called on setup and User SlopConfigChanged).
---@param c table
function M.configure(c)
  M.cfg = c
  for buf, st in pairs(states) do
    st.debounce:close()
    st.debounce = util().debounce(function()
      M.auto_trigger(buf)
    end, c.debounce)
  end
end

--- Is the visible ghost in `buf` ours?
---@param buf? integer
---@return boolean
function M.visible(buf)
  buf = (buf == nil or buf == 0) and api.nvim_get_current_buf() or buf
  local g = ghost().get(buf)
  return g ~= nil and type(g.id) == "string" and g.id:match("^slop%.complete:") ~= nil
end

local function foreign_ghost(buf)
  local g = ghost().get(buf)
  return g ~= nil and not (type(g.id) == "string" and g.id:match("^slop%.complete:"))
end

local function menu_visible()
  if vim.fn.pumvisible() == 1 then
    return true
  end
  local cmp = package.loaded["cmp"]
  if cmp and type(cmp.visible) == "function" then
    local ok, v = pcall(cmp.visible)
    return ok and v == true
  end
  return false
end

local function close_menu()
  local cmp = package.loaded["cmp"]
  if cmp and type(cmp.visible) == "function" then
    local ok, v = pcall(cmp.visible)
    if ok and v then
      pcall(cmp.close)
    end
  end
end

--- Would a completion be allowed in `buf` (filetype, buftype, size, secrets, toggles)?
---@param buf integer
---@param manual? boolean                  manual requests bypass the auto toggles and `condition`
---@return boolean ok, string? reason
function M.allowed(buf, manual)
  local c = cfg()
  if not util().buf_valid(buf) then
    return false, "invalid buffer"
  end
  if vim.b[buf].completion == false then
    return false, "vim.b.completion = false"
  end
  if not manual then
    if not M.auto then
      return false, "auto-trigger is off"
    end
    if vim.b[buf].slop_complete == false then
      return false, "disabled for this buffer"
    end
  end
  if vim.tbl_contains(c.exclude.buftypes, vim.bo[buf].buftype) then
    return false, "buftype " .. vim.bo[buf].buftype
  end
  if not vim.bo[buf].modifiable then
    return false, "not modifiable"
  end
  local ft = vim.bo[buf].filetype
  if not (vim.tbl_contains(c.filetypes, "*") or vim.tbl_contains(c.filetypes, ft)) then
    return false, "filetype not enabled"
  end
  if vim.tbl_contains(c.exclude.filetypes, ft) then
    return false, "filetype excluded"
  end
  if api.nvim_buf_line_count(buf) > c.exclude.max_lines then
    return false, "too many lines"
  end
  local name = api.nvim_buf_get_name(buf)
  if name ~= "" and vim.fn.getfsize(name) > c.exclude.max_filesize then
    return false, "file too large"
  end
  if require("slop.core.secrets").is_blocked(buf) then
    return false, "blocked by secrets rules"
  end
  if not manual and type(c.condition) == "function" then
    local ok, res = pcall(c.condition, buf)
    if ok and res == false then
      return false, "condition() returned false"
    end
  end
  if foreign_ghost(buf) then
    return false, "another ghost text is visible"
  end
  return true
end

-- Requests ---------------------------------------------------------------------------------------

local function cancel_req(req)
  if not req then
    return
  end
  for _, h in ipairs(req.handles) do
    pcall(h.cancel, h)
  end
  req.handles = {}
  if req.on_items then
    local cb = req.on_items
    req.on_items = nil
    pcall(cb, {})
  end
end

--- Cancel the request and clear the ghost of `buf`.
---@param buf integer
function M.reset(buf)
  local st = states[buf]
  if st then
    st.debounce:cancel()
    cancel_req(st.req)
    st.req = nil
  end
  if M.visible(buf) then
    ghost().clear(buf)
  end
end

--- Forget a buffer completely.
---@param buf integer
function M.drop(buf)
  M.reset(buf)
  local st = states[buf]
  if st then
    st.debounce:close()
    states[buf] = nil
  end
end

---@param buf integer
---@param req slop.complete.Request
---@return boolean
local function current(buf, req)
  local st = states[buf]
  return st ~= nil and st.req == req
end

--- Text typed (or accepted) since the request anchor; nil when the buffer diverged from the request.
---@param buf integer
---@param req slop.complete.Request
---@return string?
function M.typed(buf, req)
  if api.nvim_get_current_buf() ~= buf then
    return nil
  end
  local row, col = cursor()
  local ar, ac = req.anchor[1], req.anchor[2]
  if row < ar or (row == ar and col < ac) then
    return nil
  end
  if line_of(buf, ar):sub(1, ac) ~= req.anchor_prefix then
    return nil
  end
  if line_of(buf, row):sub(col + 1) ~= req.after then
    return nil
  end
  local ok, parts = pcall(api.nvim_buf_get_text, buf, ar, ac, row, col, {})
  if not ok then
    return nil
  end
  return table.concat(parts, "\n")
end

--- Candidates still matching what was typed, as remainders after the typed text.
---@param req slop.complete.Request
---@param typed string
---@return string[]
local function remaining(req, typed)
  local out = {}
  for _, it in ipairs(req.items) do
    if #it > #typed and it:sub(1, #typed) == typed then
      out[#out + 1] = it:sub(#typed + 1)
    end
  end
  return out
end

local function throttled_notify(key, msg, level)
  local now = vim.uv.now()
  if notified[key] and now - notified[key] < 60000 then
    log().debug("%s", msg)
    return
  end
  notified[key] = now
  log().notify(msg, level)
end

local function report_error(err)
  local c = cfg()
  local msg = ("%s: %s"):format(c.provider, err.message or tostring(err))
  if err.kind == "config" then
    throttled_notify("config:" .. msg, msg, vim.log.levels.WARN)
  elseif err.kind == "http" or err.kind == "curl" or err.kind == "spawn" then
    throttled_notify(err.kind .. ":" .. tostring(err.code), msg, vim.log.levels.WARN)
  else
    log().debug("%s", msg) -- timeouts, decode errors: not worth a notification while typing
  end
end

--- Send one request for `req` (first = the streamed main candidate; else an extra alternative).
---@param buf integer
---@param req slop.complete.Request
---@param first boolean
---@param on_more? fun(added: integer)
function M.request(buf, req, first, on_more)
  local c = cfg()
  local ai = require("slop.core.registry").service("ai")
  local stop = vim.deepcopy(c.stop)
  if not req.multiline then
    stop[#stop + 1] = "\n"
  end
  local temperature
  if first then
    temperature = c.temperature ~= false and c.temperature or nil
  else
    temperature = math.min(1, 0.4 + 0.2 * math.max(0, #req.items - 1))
  end
  local stream = first and c.stream and not req.no_render
  events().emit("complete", "RequestStarted", { buf = buf, provider = c.provider, id = req.id, n = #req.items + 1 })
  local t0 = vim.uv.hrtime()
  local handle
  handle = ai.complete_fim({
    provider = c.provider,
    prompt = req.ctx.prompt,
    suffix = req.ctx.suffix,
    max_tokens = c.max_tokens,
    stop = stop,
    temperature = temperature,
    timeout = c.timeout,
    stream = stream,
    filetype = req.ctx.meta.filetype,
    indent = req.ctx.meta.indent,
    on_chunk = stream and function(_, text)
      if not current(buf, req) or req.stopped then
        return
      end
      local display, done = pp().partial(text, req.pctx)
      req.text = display
      if done then
        req.stopped = true
        handle:cancel()
      end
      M.render(buf)
    end or nil,
    on_done = function(items, err)
      if not current(buf, req) then
        return
      end
      if req.stopped then
        items, err = { req.text }, nil
      end
      if err and err.kind == "cancelled" then
        return
      end
      local ms = (vim.uv.hrtime() - t0) / 1e6
      if first then
        req.loading = false
      else
        req.fetching = false
      end
      if err then
        report_error(err)
      end
      local added = 0
      for _, it in ipairs(pp().process_all(items or {}, req.pctx)) do
        if not vim.tbl_contains(req.items, it) then
          req.items[#req.items + 1] = it
          added = added + 1
        end
      end
      if not first and added == 0 then
        req.exhausted = true
      end
      events().emit("complete", "RequestFinished", {
        buf = buf,
        provider = c.provider,
        id = req.id,
        items = #req.items,
        ok = err == nil,
        error = err and err.message or nil,
        ms = math.floor(ms),
      })
      if c.cache and #req.items > 0 then
        get_cache():put(req.keys.prefix, req.keys.suffix, req.items)
      end
      if on_more then
        on_more(added)
      end
      if req.on_items and first then
        local cb = req.on_items
        req.on_items = nil
        cb(vim.deepcopy(req.items))
      end
      if first and req.pending_next then
        req.pending_next = nil
        M.fetch_more(buf, function(n)
          if n > 0 then
            req.index = #req.items
          end
        end)
      elseif first and #req.items > 0 and #req.items < c.candidates and not req.no_render then
        M.fetch_more(buf)
      end
      M.render(buf)
    end,
  })
  req.handles[#req.handles + 1] = handle
end

--- Fetch one more alternative for the current request.
---@param buf integer
---@param on_more? fun(added: integer)
---@return boolean started
function M.fetch_more(buf, on_more)
  local st = states[buf]
  local req = st and st.req
  if not req or req.fetching or req.exhausted or not req.ctx or #req.items >= cfg().max_candidates then
    return false
  end
  req.fetching = true
  M.request(buf, req, false, on_more)
  return true
end

local function cache_keys(buf, row, col)
  local s = math.max(0, row - 40)
  local before = api.nvim_buf_get_text(buf, s, 0, row, col, {})
  local last = math.min(api.nvim_buf_line_count(buf) - 1, row + 20)
  local after = api.nvim_buf_get_text(buf, row, col, last, #line_of(buf, last), {})
  return { prefix = table.concat(before, "\n"), suffix = table.concat(after, "\n") }
end

---@class slop.complete.TriggerOpts
---@field manual? boolean
---@field on_items? fun(items: string[])   called once with the candidates (cmp source)
---@field no_render? boolean

--- Request a completion at the cursor of the current window.
---@param buf? integer
---@param opts? slop.complete.TriggerOpts
---@return boolean started
function M.trigger(buf, opts)
  opts = opts or {}
  buf = (buf == nil or buf == 0) and api.nvim_get_current_buf() or buf
  local function nothing()
    if opts.on_items then
      opts.on_items({})
    end
    return false
  end
  if api.nvim_get_current_buf() ~= buf or not in_insert() then
    return nothing()
  end
  local ok, why = M.allowed(buf, opts.manual)
  if not ok then
    log().trace("not triggering: %s", why)
    return nothing()
  end
  local c = cfg()
  M.reset(buf)
  local st = state(buf)
  local row, col = cursor()
  local line = line_of(buf, row)
  local before, after = line:sub(1, col), line:sub(col + 1)
  if require("slop.core.secrets").is_cloaked(buf, { row, 0, row, #line }) then
    return nothing()
  end
  if after:match("%S") then
    if c.mid_line == "never" or (c.mid_line == "closers" and not pp().valid_mid_line(after)) then
      return nothing()
    end
  end
  local multiline = c.multiline
  if multiline == "auto" then
    multiline = not after:match("%S")
  end
  local p = require("slop.core.registry").service("ai").provider(c.provider)
  seq = seq + 1
  ---@type slop.complete.Request
  local req = {
    id = seq,
    ghost_id = "slop.complete:" .. seq,
    buf = buf,
    anchor = { row, col },
    anchor_prefix = before,
    after = after,
    items = {},
    index = 1,
    text = "",
    loading = true,
    fetching = false,
    exhausted = false,
    multiline = multiline,
    handles = {},
    manual = opts.manual == true,
    on_items = opts.on_items,
    no_render = opts.no_render,
    keys = cache_keys(buf, row, col),
    pctx = {
      before = before,
      after = after,
      next_lines = api.nvim_buf_get_lines(buf, row + 1, row + 21, false),
      multiline = multiline,
      max_lines = c.max_lines,
      expandtab = vim.bo[buf].expandtab,
      tabstop = vim.bo[buf].tabstop,
      chat = p ~= nil and p.kind == "chat",
    },
  }
  st.req = req
  st.suppress_tick = nil
  if c.cache then
    local hit = get_cache():get(req.keys.prefix, req.keys.suffix)
    if hit then
      req.items = hit
      req.loading = false
      if req.on_items then
        local cb = req.on_items
        req.on_items = nil
        cb(vim.deepcopy(hit))
      end
      M.render(buf)
      return true
    end
  end
  local cctx = c.context
  local ctx = require("slop.services.ai.context").fim(buf, row, col, {
    scope = cctx.scope,
    neighbors = cctx.neighbors,
    recent_edits = cctx.recent_edits,
    ring = cctx.ring,
    diagnostics = cctx.diagnostics,
    budget = cctx.budget,
  })
  if ctx.blocked then
    st.req = nil
    return nothing()
  end
  req.ctx = ctx
  M.request(buf, req, true)
  return true
end

--- Debounced auto trigger target.
---@param buf integer
function M.auto_trigger(buf)
  if api.nvim_get_current_buf() ~= buf or not in_insert() then
    return
  end
  local st = states[buf]
  if st and st.suppress_tick == api.nvim_buf_get_changedtick(buf) then
    return
  end
  if cfg().frontend == "cmp" then
    return -- cmp drives requests
  end
  M.trigger(buf, { manual = false })
end

--- Schedule a debounced auto request for `buf`.
---@param buf integer
function M.schedule(buf)
  if not M.auto or cfg().frontend == "cmp" then
    return
  end
  state(buf).debounce()
end

-- Rendering --------------------------------------------------------------------------------------

--- Re-render the current request of `buf` (typed-through aware).
---@param buf integer
function M.render(buf)
  local st = states[buf]
  local req = st and st.req
  if not req then
    return
  end
  local c = cfg()
  if req.no_render or c.frontend == "cmp" then
    return
  end
  if api.nvim_get_current_buf() ~= buf or not in_insert() then
    if M.visible(buf) then
      ghost().clear(buf)
    end
    return
  end
  if not c.show_with_cmp_menu and menu_visible() then
    if M.visible(buf) then
      ghost().clear(buf)
    end
    return
  end
  local typed = M.typed(buf, req)
  if typed == nil then
    M.reset(buf)
    M.schedule(buf)
    return
  end
  local text, counter
  if #req.items > 0 then
    local cands = remaining(req, typed)
    if #cands == 0 then
      -- everything typed / accepted (or diverged): start over from here
      M.reset(buf)
      M.schedule(buf)
      return
    end
    req.index = math.max(1, math.min(req.index, #cands))
    text = cands[req.index]
    counter = { req.index, #cands }
  elseif req.text ~= "" then
    local partial = req.text
    if #partial > #typed and partial:sub(1, #typed) == typed then
      text = partial:sub(#typed + 1)
    elseif partial:sub(1, #typed) ~= typed and typed:sub(1, #partial) ~= partial then
      M.reset(buf)
      M.schedule(buf)
      return
    end
  elseif typed ~= "" and req.loading then
    -- typed away from the anchor before anything arrived: the request is stale
    M.reset(buf)
    M.schedule(buf)
    return
  end
  if not text or text == "" then
    if M.visible(buf) then
      ghost().clear(buf)
    end
    return
  end
  local row, col = cursor()
  ghost().show(buf, row, col, text, {
    id = req.ghost_id,
    hl = "SlopCompleteGhost",
    counter = counter,
    loading = req.fetching,
    on_accept = function(t, kind)
      events().emit("complete", "Accepted", { buf = buf, kind = kind, chars = #t, id = req.id })
    end,
  })
end

-- Synchronisation with typing -------------------------------------------------------------------

--- Called on TextChangedI / TextChangedP / CursorMovedI.
---@param buf integer
function M.sync(buf)
  local st = states[buf]
  if st and st.req then
    local typed = M.typed(buf, st.req)
    if typed ~= nil then
      if typed ~= "" then
        st.debounce:cancel()
      end
      M.render(buf)
      return
    end
    M.reset(buf)
  end
  if st and st.suppress_tick == api.nvim_buf_get_changedtick(buf) then
    return
  end
  M.schedule(buf)
end

-- Actions ----------------------------------------------------------------------------------------

local function with_ghost(fn)
  return function(...)
    local buf = api.nvim_get_current_buf()
    if not M.visible(buf) then
      return false
    end
    close_menu()
    local ok = fn(buf, ...)
    M.sync(buf)
    return ok
  end
end

M.accept = with_ghost(function(buf)
  return ghost().accept(buf)
end)

M.accept_word = with_ghost(function(buf)
  return ghost().accept_word(buf)
end)

M.accept_line = with_ghost(function(buf)
  return ghost().accept_line(buf)
end)

--- Read a count digit typed right after the key (`<M-n>3`); any other key is fed back and 1 is used.
---@return integer
local function read_count()
  api.nvim_echo({ { "slop: accept lines [1-9]: ", "Question" } }, false, {})
  local ok, ch = pcall(vim.fn.getcharstr)
  api.nvim_echo({ { "" } }, false, {})
  if ok and ch:match("^%d$") and ch ~= "0" then
    return tonumber(ch) --[[@as integer]]
  end
  if ok and ch ~= "" and ch ~= "\27" then
    api.nvim_feedkeys(ch, "m", false)
  end
  return 1
end

---@param n? integer                       default: read one digit typed right after the key
---@return boolean
function M.accept_n_lines(n)
  local buf = api.nvim_get_current_buf()
  if not M.visible(buf) then
    return false
  end
  n = n or read_count()
  close_menu()
  local ok = ghost().accept_n_lines(n, buf)
  M.sync(buf)
  return ok
end

--- Cycle candidates (fetching one more alternative lazily). false when nothing is visible.
---@param dir 1|-1
---@return boolean
function M.cycle(dir)
  local buf = api.nvim_get_current_buf()
  if not M.visible(buf) then
    return false
  end
  local st = states[buf]
  local req = st and st.req
  if not req then
    return false
  end
  if req.loading then
    -- the main candidate is still streaming: fetch the alternative once it is done
    req.pending_next = dir > 0 or nil
    return true
  end
  local typed = M.typed(buf, req) or ""
  local n = #remaining(req, typed)
  if dir > 0 then
    if req.index < n then
      req.index = req.index + 1
    elseif
      M.fetch_more(buf, function(added)
        if added > 0 then
          req.index = #remaining(req, M.typed(buf, req) or "")
        else
          req.index = 1
        end
      end)
    then
      -- shows the loading marker until the alternative arrives
      req.index = n
    else
      req.index = 1
    end
  else
    req.index = req.index > 1 and req.index - 1 or math.max(1, n)
  end
  M.render(buf)
  return true
end

function M.next()
  return M.cycle(1)
end

function M.prev()
  return M.cycle(-1)
end

--- Dismiss the suggestion (no new automatic request until the text changes).
---@return boolean
function M.dismiss()
  local buf = api.nvim_get_current_buf()
  if not M.visible(buf) then
    return false
  end
  M.reset(buf)
  state(buf).suppress_tick = api.nvim_buf_get_changedtick(buf)
  return true
end

--- Candidates at the cursor (remainders), for menu frontends.
---@param buf? integer
---@return string[]
function M.items(buf)
  buf = (buf == nil or buf == 0) and api.nvim_get_current_buf() or buf
  local st = states[buf]
  if not st or not st.req then
    return {}
  end
  local req = st.req
  local typed = M.typed(buf, req)
  if not typed then
    return {}
  end
  local out = remaining(req, typed)
  if #out == 0 and req.text ~= "" and #req.text > #typed and req.text:sub(1, #typed) == typed then
    out = { req.text:sub(#typed + 1) } -- still streaming
  end
  return out
end

---@param buf? integer
---@return {state: "idle"|"loading"|"shown", index?: integer, total?: integer, provider: string}
function M.status(buf)
  buf = (buf == nil or buf == 0) and api.nvim_get_current_buf() or buf
  local st = states[buf]
  local req = st and st.req
  local provider = cfg().provider
  if not req then
    return { state = "idle", provider = provider }
  end
  if req.loading or req.fetching then
    return { state = "loading", provider = provider, index = req.index, total = #req.items }
  end
  return { state = M.visible(buf) and "shown" or "idle", index = req.index, total = #req.items, provider = provider }
end

--- Clear the prefix cache.
function M.clear_cache()
  if cache then
    cache:clear()
  end
end

--- Reset everything (tests / teardown).
function M.teardown()
  for buf in pairs(states) do
    M.drop(buf)
  end
  states = {}
  M.cfg = nil
  cache = nil
  notified = {}
end

-- Autocmds ---------------------------------------------------------------------------------------

--- Create the engine autocmds in augroup "slop.complete".
function M.attach()
  local group = util().augroup("complete")
  api.nvim_create_autocmd("InsertEnter", {
    group = group,
    desc = "slop: complete schedule",
    callback = function(ev)
      local st = states[ev.buf]
      if st then
        st.suppress_tick = nil
      end
      M.schedule(ev.buf)
    end,
  })
  api.nvim_create_autocmd({ "TextChangedI", "TextChangedP", "CursorMovedI" }, {
    group = group,
    desc = "slop: complete sync",
    callback = function(ev)
      M.sync(ev.buf)
    end,
  })
  api.nvim_create_autocmd({ "InsertLeave", "BufLeave" }, {
    group = group,
    desc = "slop: complete clear",
    callback = function(ev)
      M.reset(ev.buf)
    end,
  })
  api.nvim_create_autocmd({ "BufUnload", "BufWipeout" }, {
    group = group,
    desc = "slop: complete forget buffer",
    callback = function(ev)
      M.drop(ev.buf)
    end,
  })
  api.nvim_create_autocmd("User", {
    group = group,
    pattern = "SlopConfigChanged",
    desc = "slop: complete reconfigure",
    callback = function()
      local ok, c = pcall(require("slop.config").get, "complete")
      if ok and c then
        M.configure(c)
      end
    end,
  })
end

return M

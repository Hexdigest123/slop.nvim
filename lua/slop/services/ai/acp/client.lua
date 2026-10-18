--- ACP client: agent lifecycle (spawn, initialize, authenticate), sessions and prompt turns. OWNER: edit.
--- Created through require("slop.services.ai.acp").client(); see that module for the public contract.
---@class slop.acp.client_mod
local M = {}

local rpc_mod = require("slop.services.ai.acp.rpc")

local PROTOCOL_VERSION = 1
local INIT_TIMEOUT = 60000
local CANCEL_GRACE = 5000

local function log()
  return require("slop.core.log").scope("acp")
end

---@class slop.acp.PromptHandlers
---@field on_update? fun(update: table)
---@field on_permission? fun(req: table, respond: fun(option_id: string|nil))
---@field on_done fun(stop_reason: string?, err: table?)

---@class slop.acp.Turn
---@field handlers slop.acp.PromptHandlers
---@field done boolean
---@field cancelled boolean
---@field timer? uv.uv_timer_t

---@class slop.acp.Session
---@field id string
---@field client slop.acp.Client
---@field cwd string
---@field read_text_file? fun(params: table): string?, (table|string)?
---@field private _turn slop.acp.Turn?
---@field private _perms table<any, fun(option_id: string|nil)>
---@field private _closed boolean
local Session = {}
Session.__index = Session

---@return boolean
function Session:is_busy()
  return self._turn ~= nil
end

---@param turn slop.acp.Turn
---@param stop_reason string?
---@param err table?
function Session:_end_turn(turn, stop_reason, err)
  if turn.done then
    return
  end
  turn.done = true
  if turn.timer and not turn.timer:is_closing() then
    turn.timer:stop()
    turn.timer:close()
  end
  if self._turn == turn then
    self._turn = nil
  end
  self:_cancel_perms()
  if turn.cancelled and not err then
    stop_reason = "cancelled"
  end
  local ok, e = pcall(turn.handlers.on_done, stop_reason, err)
  if not ok then
    log().error("on_done: %s", e)
  end
end

function Session:_cancel_perms()
  local perms = self._perms
  self._perms = {}
  for _, respond in pairs(perms) do
    respond(nil)
  end
end

--- Run one prompt turn. Only one turn at a time per session.
---@param blocks table[]
---@param handlers slop.acp.PromptHandlers
function Session:prompt(blocks, handlers)
  assert(type(handlers) == "table" and type(handlers.on_done) == "function", "slop: acp prompt needs on_done")
  if self._closed then
    vim.schedule(function()
      handlers.on_done(nil, { code = -32600, message = "session is closed" })
    end)
    return
  end
  if self._turn then
    vim.schedule(function()
      handlers.on_done(nil, { code = -32600, message = "a prompt is already running in this session" })
    end)
    return
  end
  local turn = { handlers = handlers, done = false, cancelled = false }
  self._turn = turn
  self.client:request("session/prompt", { sessionId = self.id, prompt = blocks }, function(result, err)
    local stop = type(result) == "table" and result.stopReason or nil
    self:_end_turn(turn, stop, err)
  end, { timeout = false })
end

--- Cancel the running turn: session/cancel + pending permissions answered "cancelled".
function Session:cancel()
  local turn = self._turn
  if not turn or turn.cancelled then
    return
  end
  turn.cancelled = true
  self.client:notify("session/cancel", { sessionId = self.id })
  self:_cancel_perms()
  local timer = assert(vim.uv.new_timer())
  turn.timer = timer
  timer:start(
    CANCEL_GRACE,
    0,
    vim.schedule_wrap(function()
      self:_end_turn(turn, "cancelled")
    end)
  )
end

--- Close the session (cancels a running turn; session/close only when the agent supports it).
function Session:close()
  if self._closed then
    return
  end
  if self._turn then
    self:cancel()
  end
  self._closed = true
  local client = self.client
  client.sessions[self.id] = nil
  local caps = client.capabilities or {}
  if type(caps.sessionCapabilities) == "table" and caps.sessionCapabilities.close ~= nil and client:is_running() then
    client:request("session/close", { sessionId = self.id }, function() end)
  end
end

---@class slop.acp.Client
---@field agent string
---@field state "idle"|"starting"|"ready"|"error"|"stopped"
---@field capabilities table?
---@field info table?
---@field auth_methods table?
---@field sessions table<string, slop.acp.Session>
---@field config table                    agent config {cmd, env?, auth_method?}
---@field signature string
---@field private _opts slop.acp.ClientOpts
---@field private _rpc slop.acp.Rpc?
---@field private _waiters fun(err: string?)[]
---@field private _stopping boolean
---@field private _last_tail string
local Client = {}
Client.__index = Client

---@return boolean
function Client:is_running()
  return self._rpc ~= nil and self._rpc:is_running()
end

---@param n? integer
---@return string
function Client:stderr_tail(n)
  if self._rpc then
    return self._rpc:stderr_tail(n)
  end
  return self._last_tail or ""
end

local function fmt_err(prefix, err, tail)
  local msg = type(err) == "table" and (err.message or vim.inspect(err)) or tostring(err)
  local s = prefix .. msg
  tail = tail or (type(err) == "table" and err.stderr) or ""
  if tail ~= "" then
    s = s .. "\n" .. tail
  end
  return s
end

---@param err string?
function Client:_flush(err)
  local waiters = self._waiters
  self._waiters = {}
  for _, cb in ipairs(waiters) do
    local ok, e = pcall(cb, err)
    if not ok then
      log().error("start callback: %s", e)
    end
  end
end

function Client:_methods()
  local acp = require("slop.services.ai.acp")
  return {
    ["session/request_permission"] = function(params, respond)
      local session = self.sessions[params.sessionId]
      local function answer(option_id)
        if option_id then
          respond({ outcome = { outcome = "selected", optionId = option_id } })
        else
          respond({ outcome = { outcome = "cancelled" } })
        end
      end
      local turn = session and session._turn
      if not turn or turn.cancelled then
        answer(nil)
        return
      end
      local key = {}
      local answered = false
      local function once(option_id)
        if answered then
          return
        end
        answered = true
        session._perms[key] = nil
        answer(option_id)
      end
      session._perms[key] = once
      local h = turn.handlers.on_permission
      if h then
        local ok, err = pcall(h, params, once)
        if not ok then
          log().error("on_permission: %s", err)
          once((acp.decide(params)))
        end
      else
        once((acp.decide(params)))
      end
    end,
    ["fs/read_text_file"] = function(params, respond)
      if type(params.path) ~= "string" or params.path == "" then
        respond(nil, { code = rpc_mod.INVALID_PARAMS, message = "path is required" })
        return
      end
      local session = self.sessions[params.sessionId]
      local reader = (session and session.read_text_file) or self._opts.read_text_file or acp.read_text_file
      local text, err = reader(params)
      if text == nil then
        if type(err) ~= "table" then
          err = { code = rpc_mod.INTERNAL_ERROR, message = tostring(err or "cannot read file") }
        end
        respond(nil, err)
      else
        respond({ content = text })
      end
    end,
  }
end

---@param method string
---@param params table
function Client:_on_notification(method, params)
  if method == "session/update" then
    local session = self.sessions[params.sessionId]
    local turn = session and session._turn
    if turn and turn.handlers.on_update and type(params.update) == "table" then
      local ok, err = pcall(turn.handlers.on_update, params.update)
      if not ok then
        log().error("on_update: %s", err)
      end
    end
  else
    log().debug("%s: ignored notification %s", self.agent, method)
  end
end

function Client:_on_exit(code, sig, tail)
  local was_stopping = self._stopping
  self._rpc = nil
  self._last_tail = tail
  local sessions = self.sessions
  self.sessions = {}
  for _, s in pairs(sessions) do
    s._closed = true
    if s._turn then
      s:_end_turn(s._turn, nil, {
        code = rpc_mod.INTERNAL_ERROR,
        message = ("agent %s exited (code %d)"):format(self.agent, code),
        stderr = tail,
      })
    end
  end
  if self.state == "starting" then
    self.state = "error"
    self:_flush(fmt_err(("agent %s exited during startup: "):format(self.agent), "code " .. code, tail))
  elseif self.state ~= "stopped" then
    self.state = "idle"
  end
  if not was_stopping and code ~= 0 then
    log().warn("agent %s exited (code %d, signal %d)%s", self.agent, code, sig, tail ~= "" and ("\n" .. tail) or "")
  end
  if self._opts.on_exit then
    pcall(self._opts.on_exit, code, tail)
  end
end

--- Spawn + initialize (idempotent; concurrent callers are queued).
---@param cb fun(err: string?)
function Client:start(cb)
  cb = cb or function() end
  if self.state == "ready" and self:is_running() then
    cb(nil)
    return
  end
  table.insert(self._waiters, cb)
  if self.state == "starting" then
    return
  end
  if not self.config or type(self.config.cmd) ~= "table" or #self.config.cmd == 0 then
    self.state = "error"
    self:_flush(("unknown ACP agent '%s' (configure ai.agents.%s = { cmd = { ... } })"):format(self.agent, self.agent))
    return
  end
  self.state = "starting"
  self._stopping = false
  local rpc, err = rpc_mod.spawn({
    cmd = self.config.cmd,
    env = self.config.env,
    cwd = self._opts.cwd,
    name = self.agent,
    timeout = self.config.timeout,
    methods = self:_methods(),
    on_notification = function(method, params)
      self:_on_notification(method, params)
    end,
    on_exit = function(code, sig, tail)
      self:_on_exit(code, sig, tail)
    end,
  })
  if not rpc then
    self.state = "error"
    self:_flush(err)
    return
  end
  self._rpc = rpc
  local version = require("slop").version
  rpc:request("initialize", {
    protocolVersion = PROTOCOL_VERSION,
    clientCapabilities = { fs = { readTextFile = true, writeTextFile = false }, terminal = false },
    clientInfo = { name = "slop.nvim", title = "slop.nvim", version = type(version) == "string" and version or "0" },
  }, function(result, ierr)
    if self._rpc ~= rpc then
      return
    end
    if ierr or type(result) ~= "table" then
      self.state = "error"
      local tail = rpc:stderr_tail()
      self:_kill()
      self:_flush(fmt_err(("agent %s: initialize failed: "):format(self.agent), ierr or "no result", tail))
      return
    end
    if result.protocolVersion ~= PROTOCOL_VERSION then
      self.state = "error"
      self:_kill()
      self:_flush(
        ("agent %s speaks ACP protocol version %s; slop.nvim supports %d"):format(
          self.agent,
          tostring(result.protocolVersion),
          PROTOCOL_VERSION
        )
      )
      return
    end
    self.capabilities = type(result.agentCapabilities) == "table" and result.agentCapabilities or {}
    self.info = result.agentInfo
    self.auth_methods = result.authMethods or {}
    local function ready()
      self.state = "ready"
      self:_flush(nil)
    end
    local method = self.config.auth_method
    if method then
      rpc:request("authenticate", { methodId = method }, function(_, aerr)
        if aerr then
          self.state = "error"
          local tail = rpc:stderr_tail()
          self:_kill()
          self:_flush(fmt_err(("agent %s: authenticate (%s) failed: "):format(self.agent, method), aerr, tail))
          return
        end
        ready()
      end)
    else
      ready()
    end
  end, { timeout = self.config.init_timeout or INIT_TIMEOUT })
end

function Client:_kill()
  if self._rpc then
    self._stopping = true
    self._rpc:kill()
  end
end

--- Create a session (starts the agent if needed).
---@param opts? {cwd?: string, read_text_file?: fun(params: table): string?, (table|string)?}
---@param cb fun(session: slop.acp.Session?, err: string?)
function Client:new_session(opts, cb)
  opts = opts or {}
  self:start(function(err)
    if err then
      cb(nil, err)
      return
    end
    local cwd = vim.fs.normalize(vim.fn.fnamemodify(opts.cwd or self._opts.cwd or vim.fn.getcwd(), ":p"))
    if #cwd > 1 then
      cwd = cwd:gsub("/$", "")
    end
    self:request("session/new", { cwd = cwd, mcpServers = {} }, function(result, serr)
      if serr or type(result) ~= "table" or type(result.sessionId) ~= "string" then
        cb(nil, fmt_err(("agent %s: session/new failed: "):format(self.agent), serr or "no sessionId"))
        return
      end
      local session = setmetatable({
        id = result.sessionId,
        client = self,
        cwd = cwd,
        read_text_file = opts.read_text_file,
        _perms = {},
        _closed = false,
      }, Session)
      self.sessions[session.id] = session
      cb(session, nil)
    end)
  end)
end

--- Raw request (agent must be running; use start() first).
---@param method string
---@param params? table
---@param cb fun(result: any, err: table?)
---@param opts? {timeout?: integer|false}
---@return integer
function Client:request(method, params, cb, opts)
  if not self._rpc then
    vim.schedule(function()
      cb(nil, { code = rpc_mod.INTERNAL_ERROR, message = "agent " .. self.agent .. " is not running" })
    end)
    return -1
  end
  return self._rpc:request(method, params, cb, opts)
end

---@param method string
---@param params? table
function Client:notify(method, params)
  if self._rpc then
    self._rpc:notify(method, params)
  end
end

--- Stop the agent (process group), failing every running turn.
function Client:stop()
  self.state = "stopped"
  self:_kill()
end

function Client:_kill_now()
  if self._rpc then
    self._stopping = true
    self._rpc:kill_now()
  end
end

--- New (not started) client.
---@param agent string
---@param config table?
---@param opts slop.acp.ClientOpts
---@return slop.acp.Client
function M.new(agent, config, opts)
  return setmetatable({
    agent = agent,
    state = "idle",
    config = config,
    signature = vim.inspect({ config and config.cmd, config and config.env, config and config.auth_method }),
    sessions = {},
    _opts = opts or {},
    _waiters = {},
    _stopping = false,
    _last_tail = "",
  }, Client)
end

M.Client = Client
M.Session = Session

return M

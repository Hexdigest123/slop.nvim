--- NDJSON JSON-RPC 2.0 transport over a child process's stdio (vim.system). OWNER: edit.
---
--- * One message per line; offset-based "\n" framing; vim.json.decode with luanil (no vim.NIL); empty objects are
---   encoded as vim.empty_dict().
--- * Everything is dispatched on the main loop. Agent -> client requests ALWAYS get exactly one reply:
---   unknown method -32601, handler error -32603.
--- * Requests time out (default 30 s; `timeout = false` disables). On exit every pending request fails.
--- * stderr (and non-JSON stdout lines) are kept in a ring buffer for error messages.
--- * The child is its own process group (detach = true); kill() signals the whole group (SIGTERM, then SIGKILL).
---@class slop.acp.rpc
local M = {}

local uv = vim.uv

M.METHOD_NOT_FOUND = -32601
M.INVALID_PARAMS = -32602
M.INTERNAL_ERROR = -32603
M.REQUEST_TIMEOUT = -32800

local RING = 200
local KILL_GRACE = 2000

local function log()
  return require("slop.core.log").scope("acp")
end

---@class slop.acp.RpcError
---@field code integer
---@field message string
---@field data? any
---@field stderr? string

---@class slop.acp.RpcOpts
---@field cmd string[]
---@field env? table<string, string>
---@field cwd? string
---@field name? string                    for logs
---@field timeout? integer                default request timeout (ms), default 30000
---@field methods? table<string, fun(params: table, respond: fun(result: any, err: slop.acp.RpcError?))>
---@field on_notification? fun(method: string, params: table)
---@field on_exit? fun(code: integer, signal: integer, stderr_tail: string)

---@class slop.acp.Rpc
---@field pid integer?
---@field name string
---@field private _opts slop.acp.RpcOpts
---@field private _proc vim.SystemObj?
---@field private _buf string
---@field private _next integer
---@field private _pending table<integer, {cb: fun(result: any, err: slop.acp.RpcError?), timer: uv.uv_timer_t?, method: string}>
---@field private _ring string[]
---@field private _partial string
---@field private _exited boolean
local Rpc = {}
Rpc.__index = Rpc

---@param line string
function Rpc:_ring_push(line)
  self._ring[#self._ring + 1] = line
  if #self._ring > RING then
    table.remove(self._ring, 1)
  end
end

--- Last `n` stderr lines (default 20).
---@param n? integer
---@return string
function Rpc:stderr_tail(n)
  n = n or 20
  local lines = vim.list_slice(self._ring, math.max(1, #self._ring - n + 1))
  if self._partial ~= "" then
    lines[#lines + 1] = self._partial
  end
  return table.concat(lines, "\n")
end

---@param data string
function Rpc:_on_stderr(data)
  local s = self._partial .. data
  local start = 1
  while true do
    local nl = s:find("\n", start, true)
    if not nl then
      break
    end
    self:_ring_push((s:sub(start, nl - 1):gsub("\r$", "")))
    start = nl + 1
  end
  self._partial = s:sub(start)
end

---@param msg table
function Rpc:_send(msg)
  if self._exited or not self._proc then
    return false, "agent is not running"
  end
  msg.jsonrpc = "2.0"
  local ok, json = pcall(vim.json.encode, msg)
  if not ok then
    return false, "encode failed: " .. tostring(json)
  end
  local wok, werr = pcall(self._proc.write, self._proc, json .. "\n")
  if not wok then
    return false, tostring(werr)
  end
  log().trace("%s <- %s", self.name, json:sub(1, 2000))
  return true
end

---@param id integer|string
---@param result any
---@param err? slop.acp.RpcError
function Rpc:respond(id, result, err)
  if err then
    self:_send({
      id = id,
      error = { code = err.code or M.INTERNAL_ERROR, message = err.message or "error", data = err.data },
    })
  else
    if result == nil or (type(result) == "table" and next(result) == nil and not vim.islist(result)) then
      result = vim.empty_dict()
    end
    self:_send({ id = id, result = result })
  end
end

---@param msg table
function Rpc:_dispatch(msg)
  if type(msg) ~= "table" then
    return
  end
  local methods = self._opts.methods or {}
  if msg.method ~= nil and msg.id ~= nil then
    local id = msg.id
    local answered = false
    local function respond(result, err)
      if answered then
        return
      end
      answered = true
      self:respond(id, result, err)
    end
    local h = methods[msg.method]
    if not h then
      respond(nil, { code = M.METHOD_NOT_FOUND, message = "Method not found: " .. tostring(msg.method) })
      return
    end
    local ok, err = pcall(h, msg.params or {}, respond)
    if not ok then
      log().debug("%s: handler %s failed: %s", self.name, msg.method, err)
      respond(nil, { code = M.INTERNAL_ERROR, message = tostring(err) })
    end
  elseif msg.method ~= nil then
    if self._opts.on_notification then
      local ok, err = pcall(self._opts.on_notification, msg.method, msg.params or {})
      if not ok then
        log().error("%s: notification %s: %s", self.name, msg.method, err)
      end
    end
  elseif msg.id ~= nil then
    local p = self._pending[msg.id]
    if not p then
      return
    end
    self._pending[msg.id] = nil
    if p.timer then
      p.timer:stop()
      p.timer:close()
    end
    local err = msg.error
    if err ~= nil and type(err) ~= "table" then
      err = { code = M.INTERNAL_ERROR, message = tostring(err) }
    end
    local ok, cerr = pcall(p.cb, msg.result, err)
    if not ok then
      log().error("%s: callback for %s: %s", self.name, p.method, cerr)
    end
  end
end

--- Feed stdout data (fast context: framing only, dispatch is scheduled).
---@param data string
function Rpc:_feed(data)
  local buf = self._buf .. data
  local start = 1
  local msgs = {}
  while true do
    local nl = buf:find("\n", start, true)
    if not nl then
      break
    end
    local line = buf:sub(start, nl - 1)
    start = nl + 1
    if line:find("%S") then
      local ok, msg = pcall(vim.json.decode, line, { luanil = { object = true, array = true } })
      if ok and type(msg) == "table" then
        msgs[#msgs + 1] = msg
      else
        self:_ring_push("stdout: " .. line:sub(1, 500))
      end
    end
  end
  self._buf = buf:sub(start)
  if #msgs > 0 then
    vim.schedule(function()
      for _, m in ipairs(msgs) do
        self:_dispatch(m)
      end
    end)
  end
end

--- Send a request. `cb(result, err)` runs exactly once on the main loop.
---@param method string
---@param params? table
---@param cb fun(result: any, err: slop.acp.RpcError?)
---@param opts? {timeout?: integer|false}
---@return integer id
function Rpc:request(method, params, cb, opts)
  self._next = self._next + 1
  local id = self._next
  local timeout = opts and opts.timeout
  if timeout == nil then
    timeout = self._opts.timeout or 30000
  end
  local entry = { cb = cb, method = method }
  self._pending[id] = entry
  local ok, err = self:_send({ id = id, method = method, params = params or vim.empty_dict() })
  if not ok then
    self._pending[id] = nil
    vim.schedule(function()
      cb(nil, { code = M.INTERNAL_ERROR, message = err or "send failed", stderr = self:stderr_tail() })
    end)
    return id
  end
  if timeout then
    local timer = assert(uv.new_timer())
    entry.timer = timer
    timer:start(
      timeout,
      0,
      vim.schedule_wrap(function()
        if self._pending[id] ~= entry then
          return
        end
        self._pending[id] = nil
        timer:close()
        cb(nil, { code = M.REQUEST_TIMEOUT, message = ("%s timed out after %d ms"):format(method, timeout) })
      end)
    )
  end
  return id
end

--- Send a notification.
---@param method string
---@param params? table
---@return boolean ok
function Rpc:notify(method, params)
  return (self:_send({ method = method, params = params or vim.empty_dict() }))
end

---@return boolean
function Rpc:is_running()
  return self._proc ~= nil and not self._exited
end

---@return integer
function Rpc:pending_count()
  local n = 0
  for _ in pairs(self._pending) do
    n = n + 1
  end
  return n
end

local function signal(pid, sig)
  if not pid then
    return false
  end
  -- negative pid = the whole process group (detach = true made the child a group leader)
  local ok = pcall(uv.kill, -pid, sig)
  if not ok then
    ok = pcall(uv.kill, pid, sig)
  end
  return ok
end

--- Terminate the process group: SIGTERM now, SIGKILL after a grace period.
---@param opts? {grace?: integer}
function Rpc:kill(opts)
  if self._exited or not self._proc then
    return
  end
  pcall(function()
    self._proc:write(nil) -- close stdin: well-behaved agents exit on EOF
  end)
  local pid = self.pid
  signal(pid, "sigterm")
  local grace = opts and opts.grace or KILL_GRACE
  local timer = assert(uv.new_timer())
  timer:start(grace, 0, function()
    timer:close()
    if not self._exited then
      signal(pid, "sigkill")
    end
  end)
end

--- Synchronous best-effort kill (VimLeavePre).
function Rpc:kill_now()
  if self._exited or not self._proc then
    return
  end
  signal(self.pid, "sigterm")
  signal(self.pid, "sigkill")
end

---@param code integer
---@param sig integer
function Rpc:_on_exit(code, sig)
  self._exited = true
  local tail = self:stderr_tail()
  local pending = self._pending
  self._pending = {}
  local ids = vim.tbl_keys(pending)
  table.sort(ids)
  for _, id in ipairs(ids) do
    local p = pending[id]
    if p.timer and not p.timer:is_closing() then
      p.timer:stop()
      p.timer:close()
    end
    pcall(p.cb, nil, {
      code = M.INTERNAL_ERROR,
      message = ("agent exited (code %d%s)"):format(code, sig ~= 0 and (", signal " .. sig) or ""),
      stderr = tail,
    })
  end
  if self._opts.on_exit then
    local ok, err = pcall(self._opts.on_exit, code, sig, tail)
    if not ok then
      log().error("%s: on_exit: %s", self.name, err)
    end
  end
end

--- Spawn the agent process.
---@param opts slop.acp.RpcOpts
---@return slop.acp.Rpc? rpc, string? err
function M.spawn(opts)
  assert(type(opts.cmd) == "table" and #opts.cmd > 0, "slop: acp.rpc.spawn needs cmd")
  local self = setmetatable({
    name = opts.name or opts.cmd[1],
    _opts = opts,
    _buf = "",
    _next = 0,
    _pending = {},
    _ring = {},
    _partial = "",
    _exited = false,
  }, Rpc)
  if vim.fn.executable(opts.cmd[1]) ~= 1 then
    return nil, ("agent command not found: %s"):format(opts.cmd[1])
  end
  local ok, proc = pcall(vim.system, opts.cmd, {
    stdin = true,
    cwd = opts.cwd,
    env = opts.env,
    detach = true,
    stdout = function(_, data)
      if data then
        self:_feed(data)
      end
    end,
    stderr = function(_, data)
      if data then
        self:_on_stderr(data)
      end
    end,
  }, function(res)
    vim.schedule(function()
      self:_on_exit(res.code or -1, res.signal or 0)
    end)
  end)
  if not ok then
    return nil, ("failed to start %s: %s"):format(opts.cmd[1], tostring(proc))
  end
  self._proc = proc
  self.pid = proc.pid
  log().debug("%s: spawned pid %s", self.name, tostring(proc.pid))
  return self
end

return M

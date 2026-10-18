--# selene: allow(global_usage, incorrect_standard_library_use)
-- Mock ACP agent for specs. Run: nvim --headless --clean -u NONE -l mock_agent.lua
-- Speaks NDJSON JSON-RPC on stdio. Behaviour is scripted by a JSON plan file ($SLOP_MOCK_PLAN):
--   {
--     "init": { ...initialize result... } | omitted (defaults below), "init_exit": code, "init_garbage": true,
--     "auth_fail": true,
--     "turns": [ [action, ...], ... ],     -- one list per session/prompt, in arrival order
--     "default_turn": [action, ...],       -- used when "turns" is exhausted
--     "by_prompt": { "<exact prompt text>": [action, ...] }   -- wins over "turns"
--   }
-- Actions:
--   {"chunk": "text"} {"thought": "text"} {"tool": {...toolCall}} {"tool_update": {...}} {"update": {...raw}}
--   {"permission": {"toolCall": {...}, "options": [...]}}   -> session/request_permission, waits for the answer
--   {"read": {"path": "...", "line": n, "limit": n}, "echo": true} -> fs/read_text_file, waits; echo = chunk back
--   {"request": {"method": "...", "params": {...}}}          -> generic agent->client request, waits
--   {"replace_region": "upper"|"same"|"lower"}               -> answers <slop:replacement> of the prompt's region
--   {"sleep": ms} {"wait_cancel": true} {"stderr": "text"} {"stdout_garbage": "text"} {"exit": code}
--   {"stop": "end_turn"|...} {"error": {"code": n, "message": "..."}}   (default: stop end_turn)
-- Every received message and every answer to our own requests is appended to $SLOP_MOCK_LOG (NDJSON).
local uv = vim.uv

local plan = {}
do
  local p = os.getenv("SLOP_MOCK_PLAN")
  if p and p ~= "" then
    local f = io.open(p, "r")
    if f then
      plan = vim.json.decode(f:read("*a"), { luanil = { object = true, array = true } }) or {}
      f:close()
    end
  end
end
local log_path = os.getenv("SLOP_MOCK_LOG")

local function log(entry)
  if not log_path then
    return
  end
  local f = io.open(log_path, "a")
  if f then
    f:write(vim.json.encode(entry) .. "\n")
    f:close()
  end
end

local function send(msg)
  msg.jsonrpc = "2.0"
  io.stdout:write(vim.json.encode(msg) .. "\n")
  io.stdout:flush()
end

local next_id = 1000
local waiting = {} -- our request id -> coroutine
local cancel_waiters = {} -- sessionId -> coroutine[]
local cancelled = {} -- sessionId -> true
local turn_index = 0
local sessions = 0
local prompts = {} -- sessionId -> prompt text of the running turn
local regions = {} -- sessionId -> first prompt text containing a <region> (for follow-up turns)

local function resume(co, ...)
  local ok, err = coroutine.resume(co, ...)
  if not ok then
    io.stderr:write("mock: " .. tostring(err) .. "\n")
  end
end

local function request(method, params)
  next_id = next_id + 1
  local id = next_id
  waiting[id] = coroutine.running()
  send({ id = id, method = method, params = params })
  local result, err = coroutine.yield()
  log({ event = "response", method = method, result = result, error = err })
  return result, err
end

local function update(sid, u)
  send({ method = "session/update", params = { sessionId = sid, update = u } })
end

local function sleep(ms)
  local co = coroutine.running()
  local t = uv.new_timer()
  t:start(ms, 0, function()
    t:close()
    resume(co)
  end)
  coroutine.yield()
end

local function region_of(text)
  return text:match("<region>\n(.-)\n?</region>") or ""
end

local function run_turn(id, sid, actions)
  for _, a in ipairs(actions or {}) do
    if cancelled[sid] then
      break
    end
    if a.chunk then
      update(sid, { sessionUpdate = "agent_message_chunk", content = { type = "text", text = a.chunk } })
    elseif a.thought then
      update(sid, { sessionUpdate = "agent_thought_chunk", content = { type = "text", text = a.thought } })
    elseif a.tool then
      local u = vim.deepcopy(a.tool)
      u.sessionUpdate = "tool_call"
      update(sid, u)
    elseif a.tool_update then
      local u = vim.deepcopy(a.tool_update)
      u.sessionUpdate = "tool_call_update"
      update(sid, u)
    elseif a.update then
      update(sid, a.update)
    elseif a.permission then
      local p = vim.deepcopy(a.permission)
      p.sessionId = sid
      request("session/request_permission", p)
    elseif a.read then
      local p = vim.deepcopy(a.read)
      p.sessionId = sid
      local res, err = request("fs/read_text_file", p)
      if a.echo then
        local text = res and res.content or ("ERROR: " .. tostring(err and err.message))
        update(sid, { sessionUpdate = "agent_message_chunk", content = { type = "text", text = text } })
      end
    elseif a.request then
      request(a.request.method, a.request.params)
    elseif a.replace_region then
      local region = region_of(prompts[sid] or "")
      if not (prompts[sid] or ""):find("<region>", 1, true) then
        region = region_of(regions[sid] or "")
      end
      if a.replace_region == "upper" then
        region = region:upper()
      elseif a.replace_region == "lower" then
        region = region:lower()
      end
      update(sid, {
        sessionUpdate = "agent_message_chunk",
        content = { type = "text", text = "Done.\n<slop:replacement>\n" .. region .. "\n</slop:replacement>\n" },
      })
    elseif a.sleep then
      sleep(a.sleep)
    elseif a.wait_cancel then
      if not cancelled[sid] then
        cancel_waiters[sid] = cancel_waiters[sid] or {}
        table.insert(cancel_waiters[sid], coroutine.running())
        coroutine.yield()
      end
    elseif a.stderr then
      io.stderr:write(a.stderr .. "\n")
      io.stderr:flush()
    elseif a.stdout_garbage then
      io.stdout:write(a.stdout_garbage .. "\n")
      io.stdout:flush()
    elseif a.exit then
      os.exit(a.exit)
    elseif a.error then
      prompts[sid] = nil
      send({ id = id, error = a.error })
      return
    elseif a.stop then
      prompts[sid] = nil
      send({ id = id, result = { stopReason = a.stop } })
      return
    end
  end
  prompts[sid] = nil
  send({ id = id, result = { stopReason = cancelled[sid] and "cancelled" or "end_turn" } })
end

local function prompt_text(params)
  local parts = {}
  for _, b in ipairs(params.prompt or {}) do
    if b.type == "text" then
      parts[#parts + 1] = b.text
    elseif b.type == "resource" and b.resource then
      parts[#parts + 1] = b.resource.text or ""
    end
  end
  return table.concat(parts, "\n")
end

local function handle(msg)
  log(msg)
  if msg.method and msg.id ~= nil then
    local m, p = msg.method, msg.params or {}
    if m == "initialize" then
      if plan.init_garbage then
        io.stdout:write("Please log in at https://example.invalid\n")
        io.stdout:flush()
      end
      if plan.init_exit then
        io.stderr:write("mock: fatal startup error\n")
        io.stderr:flush()
        os.exit(plan.init_exit)
      end
      send({
        id = msg.id,
        result = plan.init or {
          protocolVersion = 1,
          agentCapabilities = {
            loadSession = false,
            promptCapabilities = { embeddedContext = true },
            sessionCapabilities = { close = vim.empty_dict() },
          },
          agentInfo = { name = "mock", version = "1" },
          authMethods = {},
        },
      })
    elseif m == "authenticate" then
      if plan.auth_fail then
        send({ id = msg.id, error = { code = -32000, message = "auth failed" } })
      else
        send({ id = msg.id, result = vim.empty_dict() })
      end
    elseif m == "session/new" then
      sessions = sessions + 1
      send({ id = msg.id, result = { sessionId = "mock-" .. sessions } })
    elseif m == "session/close" then
      send({ id = msg.id, result = vim.empty_dict() })
    elseif m == "session/prompt" then
      turn_index = turn_index + 1
      local text = prompt_text(p)
      local actions = (plan.by_prompt or {})[text]
        or (plan.turns or {})[turn_index]
        or plan.default_turn
        or { { replace_region = "upper" } }
      local sid = p.sessionId
      cancelled[sid] = nil
      prompts[sid] = text
      if text:find("<region>", 1, true) then
        regions[sid] = text
      end
      local co = coroutine.create(run_turn)
      resume(co, msg.id, sid, actions)
    else
      send({ id = msg.id, error = { code = -32601, message = "Method not found: " .. m } })
    end
  elseif msg.method then
    if msg.method == "session/cancel" then
      local sid = (msg.params or {}).sessionId
      cancelled[sid] = true
      for _, co in ipairs(cancel_waiters[sid] or {}) do
        resume(co)
      end
      cancel_waiters[sid] = nil
    end
  elseif msg.id ~= nil then
    local co = waiting[msg.id]
    waiting[msg.id] = nil
    if co then
      resume(co, msg.result, msg.error)
    end
  end
end

local done = false
local buf = ""
local stdin = uv.new_pipe(false)
stdin:open(0)
stdin:read_start(function(err, data)
  if err or not data then
    done = true
    return
  end
  buf = buf .. data
  while true do
    local nl = buf:find("\n", 1, true)
    if not nl then
      break
    end
    local line = buf:sub(1, nl - 1)
    buf = buf:sub(nl + 1)
    if line:find("%S") then
      local ok, msg = pcall(vim.json.decode, line, { luanil = { object = true, array = true } })
      if ok then
        handle(msg)
      else
        io.stderr:write("mock: bad json: " .. line .. "\n")
      end
    end
  end
end)

vim.wait(10 * 60 * 1000, function()
  return done
end, 10)
os.exit(0)

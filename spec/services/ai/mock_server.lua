-- In-process mock HTTP server for specs (vim.uv TCP). OWNER: complete. Usable by any spec:
--   local mock = require("services.ai.mock_server")
--   local srv = mock.start(function(req, res) res.json(200, { ok = true }) end)
--   ... srv.url .. "/path" ...   srv.requests (list of received requests)   srv:stop()
-- req = { method, path, query (raw string), headers (lower-cased), body }
-- res.send(status, body, headers?) | res.json(status, tbl, headers?)
-- res.stream(status, chunks: string[], { delay = ms, headers = {...}, hang = bool })  (Connection: close)
-- res.hang()  never answers (timeouts / cancel tests)
-- Callers must pump the loop (vim.wait) while curl talks to the server.
local M = {}

local uv = vim.uv

local REASONS = {
  [200] = "OK",
  [201] = "Created",
  [204] = "No Content",
  [400] = "Bad Request",
  [401] = "Unauthorized",
  [404] = "Not Found",
  [429] = "Too Many Requests",
  [500] = "Internal Server Error",
  [302] = "Found",
}

local function parse(raw)
  local head_end = raw:find("\r\n\r\n", 1, true)
  if not head_end then
    return nil
  end
  local head = raw:sub(1, head_end - 1)
  local lines = vim.split(head, "\r\n", { plain = true })
  local method, target = lines[1]:match("^(%S+)%s+(%S+)")
  local headers = {}
  for i = 2, #lines do
    local k, v = lines[i]:match("^([^:]+):%s*(.*)$")
    if k then
      headers[k:lower()] = v
    end
  end
  local len = tonumber(headers["content-length"] or "0") or 0
  local body = raw:sub(head_end + 4)
  if headers["expect"] and #body == 0 and len > 0 then
    return nil, true
  end
  if #body < len then
    return nil
  end
  local path, query = target:match("^([^?]*)%??(.*)$")
  return { method = method, path = path, query = query, target = target, headers = headers, body = body:sub(1, len) }
end

---@param handler fun(req: table, res: table)
function M.start(handler)
  local server = assert(uv.new_tcp())
  assert(server:bind("127.0.0.1", 0))
  local srv = { requests = {}, clients = {} }
  server:listen(64, function(err)
    assert(not err, err)
    local client = assert(uv.new_tcp())
    server:accept(client)
    srv.clients[#srv.clients + 1] = client
    local raw = ""
    local answered = false
    local timers = {}
    local function close()
      for _, t in ipairs(timers) do
        if not t:is_closing() then
          t:stop()
          t:close()
        end
      end
      if not client:is_closing() then
        client:shutdown(function()
          if not client:is_closing() then
            client:close()
          end
        end)
      end
    end
    local function write(s)
      if not client:is_closing() then
        client:write(s)
      end
    end
    local function head(status, headers, extra)
      local out = { ("HTTP/1.1 %d %s"):format(status, REASONS[status] or "Status") }
      for k, v in pairs(headers or {}) do
        out[#out + 1] = k .. ": " .. v
      end
      for _, l in ipairs(extra or {}) do
        out[#out + 1] = l
      end
      out[#out + 1] = "Connection: close"
      return table.concat(out, "\r\n") .. "\r\n\r\n"
    end
    local res = {}
    function res.send(status, body, headers)
      body = body or ""
      write(head(status, headers, { "Content-Length: " .. #body }) .. body)
      close()
    end
    function res.json(status, tbl, headers)
      headers = vim.tbl_extend("keep", headers or {}, { ["Content-Type"] = "application/json" })
      res.send(status, vim.json.encode(tbl), headers)
    end
    function res.stream(status, chunks, opts)
      opts = opts or {}
      write(head(status, opts.headers or { ["Content-Type"] = "text/event-stream" }))
      local i = 0
      local timer = assert(uv.new_timer())
      timers[#timers + 1] = timer
      timer:start(0, opts.delay or 5, function()
        i = i + 1
        if chunks[i] then
          write(chunks[i])
        elseif not opts.hang then
          timer:stop()
          close()
        end
      end)
    end
    function res.hang() end
    client:read_start(function(rerr, data)
      if rerr or not data then
        close()
        return
      end
      raw = raw .. data
      if answered then
        return
      end
      local req, expect = parse(raw)
      if expect then
        write("HTTP/1.1 100 Continue\r\n\r\n")
        return
      end
      if req then
        answered = true
        srv.requests[#srv.requests + 1] = req
        vim.schedule(function()
          handler(req, res)
        end)
      end
    end)
  end)
  srv.port = server:getsockname().port
  srv.url = ("http://127.0.0.1:%d"):format(srv.port)
  function srv.stop()
    for _, c in ipairs(srv.clients) do
      if not c:is_closing() then
        c:close()
      end
    end
    if not server:is_closing() then
      server:close()
    end
  end
  return srv
end

--- SSE chunk helpers.
function M.sse(obj)
  return "data: " .. (type(obj) == "string" and obj or vim.json.encode(obj)) .. "\n\n"
end

--- Wait until `cond()` (pumps the loop).
function M.wait(cond, ms)
  return vim.wait(ms or 5000, cond, 5)
end

return M

--- HTTP over curl (vim.system), shared by services.ai and the rest module.
--- OWNER: complete.
---
--- Rules: never blocks (vim.system; callbacks run on the main loop); body goes via stdin
--- (`--data-binary @-`, never argv); `--globoff`; metadata from `-w '%{json}'` (no stderr parsing of -v output);
--- optional cookie jar (`-b/-c <path>`); every request is cancellable and has a timeout.
---
--- request() layout of a curl run:
---   stdout  = response body (streamed through a decoder when `stream` is set)
---   stderr  = curl's own -S error text, then "\n@@SLOP_META@@" .. %{json}   (`-w '%{stderr}...'`)
---   -D tmp  = response headers of every hop (the last hop is parsed)
---@class slop.http
local M = {}

local uv = vim.uv

local META_MARK = "@@SLOP_META@@"
local DEFAULT_TIMEOUT = 30000

---@alias slop.http.StreamMode "sse"|"ndjson"|"raw"

---@class slop.http.SseEvent
---@field event? string
---@field data string          joined `data:` lines ("[DONE]" is passed through)
---@field id? string

---@class slop.http.Request
---@field url string
---@field method? string                         default "GET" ("POST" when body is set)
---@field headers? table<string, string>|{[1]: string, [2]: string}[]  list form keeps order + duplicates
---@field query? table<string, string|number|boolean>  appended url-encoded (sorted keys)
---@field body? string|table                     table => JSON-encoded (+ Content-Type: application/json)
---@field timeout? integer                       ms, whole request (--max-time); default 30000
---@field connect_timeout? integer               ms
---@field stream? slop.http.StreamMode           decode stdout incrementally and call on_chunk
---@field on_chunk? fun(chunk: slop.http.SseEvent|table|string, handle: slop.http.Handle)  sse | ndjson | raw
---@field on_done fun(res: slop.http.Response?, err: slop.http.Error?)  exactly once, on the main loop
---@field follow_redirects? boolean              -L (default false)
---@field max_redirs? integer
---@field cookie_jar? string                     path; enables -b/-c
---@field insecure? boolean                      -k
---@field http_version? "1.1"|"2"|"3"
---@field output? string                         write body to this file instead of memory (-o)
---@field proxy? string                          --proxy
---@field env? table<string, string>             extra environment for curl
---@field extra_args? string[]                   appended verbatim to curl argv (before the url)
---@field name? string                           label for core.log entries

---@class slop.http.Response
---@field status integer                         0 when no response (see err)
---@field headers table<string, string>          lower-cased names, last value wins
---@field header_list {[1]: string, [2]: string}[]  all headers of the final hop, in order
---@field body string                            "" when streamed (kept for HTTP errors) or `output` set
---@field meta table                             curl -w '%{json}' (response_code, time_total, size_download, ...)
---@field duration_ms number
---@field json fun(self: slop.http.Response): any, string?  decode body

---@class slop.http.Error
---@field kind "timeout"|"cancelled"|"curl"|"http"|"spawn"|"decode"
---@field message string
---@field code? integer                          curl exit code or HTTP status
---@field response? slop.http.Response           for kind = "http" (status >= 400)

---@class slop.http.Handle
---@field id integer
---@field cancel fun(self: slop.http.Handle)      kills curl; on_done gets {kind="cancelled"}
---@field is_active fun(self: slop.http.Handle): boolean

local next_id = 0

local function log()
  return require("slop.core.log").scope("http")
end

-- Encoding -------------------------------------------------------------------------------------

--- Percent-encode a string (RFC 3986 unreserved characters are kept).
---@param s string|number|boolean
---@return string
function M.urlencode(s)
  return (tostring(s):gsub("[^%w%-%._~]", function(c)
    return ("%%%02X"):format(c:byte())
  end))
end

--- Encode a query table as "a=1&b=x%20y" (keys sorted; list values repeat the key).
---@param query table<string, any>
---@return string
function M.encode_query(query)
  local keys = vim.tbl_keys(query or {})
  table.sort(keys, function(a, b)
    return tostring(a) < tostring(b)
  end)
  local parts = {}
  for _, k in ipairs(keys) do
    local v = query[k]
    local vals = type(v) == "table" and v or { v }
    for _, x in ipairs(vals) do
      parts[#parts + 1] = M.urlencode(k) .. "=" .. M.urlencode(x)
    end
  end
  return table.concat(parts, "&")
end

--- Normalize headers to an ordered {name, value} list (dict form sorted by name).
---@param headers table?
---@return {[1]: string, [2]: string}[]
local function header_pairs(headers)
  local out = {}
  if type(headers) ~= "table" then
    return out
  end
  if vim.islist(headers) then
    for _, h in ipairs(headers) do
      out[#out + 1] = { tostring(h[1]), tostring(h[2] == nil and "" or h[2]) }
    end
  else
    local names = vim.tbl_keys(headers)
    table.sort(names)
    for _, n in ipairs(names) do
      out[#out + 1] = { tostring(n), tostring(headers[n]) }
    end
  end
  return out
end

local function has_header(pairs_, name)
  name = name:lower()
  for _, h in ipairs(pairs_) do
    if h[1]:lower() == name then
      return true
    end
  end
  return false
end

local function seconds(ms)
  local s = ms / 1000
  if s == math.floor(s) then
    return tostring(math.floor(s))
  end
  return ("%.3f"):format(s)
end

--- Pure: curl argv + stdin for a request (tests, "copy as curl"). Does not include the -D / -w / -N flags that
--- request() adds.
---@param opts slop.http.Request
---@return string[] args, string? stdin
function M.build_args(opts)
  assert(type(opts) == "table" and type(opts.url) == "string", "slop: http request needs opts.url")
  local args = { "-sS", "--globoff" }
  local body = opts.body
  local hdrs = header_pairs(opts.headers)
  if type(body) == "table" then
    body = vim.json.encode(body)
    if not has_header(hdrs, "content-type") then
      table.insert(hdrs, { "Content-Type", "application/json" })
    end
  end
  local method = (opts.method or (body and "POST" or "GET")):upper()
  if method == "HEAD" then
    args[#args + 1] = "--head"
  else
    vim.list_extend(args, { "-X", method })
  end
  for _, h in ipairs(hdrs) do
    -- "Name;" sends an empty header, "Name:" would remove it
    args[#args + 1] = "-H"
    args[#args + 1] = h[2] == "" and (h[1] .. ";") or (h[1] .. ": " .. h[2])
  end
  if body then
    vim.list_extend(args, { "--data-binary", "@-" })
  end
  if opts.follow_redirects then
    args[#args + 1] = "-L"
    if opts.max_redirs then
      vim.list_extend(args, { "--max-redirs", tostring(opts.max_redirs) })
    end
  end
  vim.list_extend(args, { "--max-time", seconds(opts.timeout or DEFAULT_TIMEOUT) })
  if opts.connect_timeout then
    vim.list_extend(args, { "--connect-timeout", seconds(opts.connect_timeout) })
  end
  if opts.cookie_jar then
    vim.list_extend(args, { "-b", opts.cookie_jar, "-c", opts.cookie_jar })
  end
  if opts.insecure then
    args[#args + 1] = "-k"
  end
  if opts.http_version then
    local flag = ({ ["1.0"] = "--http1.0", ["1.1"] = "--http1.1", ["2"] = "--http2", ["3"] = "--http3" })[tostring(
      opts.http_version
    )]
    if flag then
      args[#args + 1] = flag
    end
  end
  if opts.proxy then
    vim.list_extend(args, { "--proxy", opts.proxy })
  end
  if opts.output then
    vim.list_extend(args, { "-o", opts.output })
  end
  vim.list_extend(args, opts.extra_args or {})
  local url = opts.url
  if opts.query and next(opts.query) then
    local q = M.encode_query(opts.query)
    if q ~= "" then
      url = url .. (url:find("?", 1, true) and "&" or "?") .. q
    end
  end
  args[#args + 1] = url
  return args, body
end

-- Header parsing -------------------------------------------------------------------------------

--- Parse a `curl -D` dump; returns the headers of the LAST hop.
---@param text string
---@return {[1]: string, [2]: string}[] header_list, table<string, string> headers, integer? status
function M.parse_headers(text)
  local list, map, status = {}, {}, nil
  for line in ((text or "") .. "\n"):gmatch("([^\n]*)\n") do
    line = line:gsub("\r$", "")
    local code = line:match("^HTTP/[%d%.]+%s+(%d+)")
    if code then
      list, map, status = {}, {}, tonumber(code)
    else
      local name, value = line:match("^([^:%s][^:]*):%s*(.-)%s*$")
      if name then
        list[#list + 1] = { name, value }
        map[name:lower()] = value
      end
    end
  end
  return list, map, status
end

-- Decoders -------------------------------------------------------------------------------------

--- Incremental SSE decoder. feed(data) for each stdout piece, feed(nil) at end of stream (flushes a final event
--- that was not terminated by a blank line).
---@param on_event fun(ev: slop.http.SseEvent)
---@return fun(data: string?)
function M.sse_decoder(on_event)
  local buf = ""
  local ev = { data = {} }
  local function dispatch()
    if #ev.data > 0 or ev.event then
      if #ev.data > 0 then
        on_event({ event = ev.event, data = table.concat(ev.data, "\n"), id = ev.id })
      end
    end
    ev = { data = {} }
  end
  local function line(l)
    if l == "" then
      dispatch()
      return
    end
    if l:sub(1, 1) == ":" then
      return
    end
    local field, value = l:match("^([^:]*):?%s?(.*)$")
    if field == "data" then
      ev.data[#ev.data + 1] = value
    elseif field == "event" then
      ev.event = value
    elseif field == "id" then
      ev.id = value
    end
  end
  return function(data)
    if data == nil then
      if buf ~= "" then
        line((buf:gsub("\r$", "")))
        buf = ""
      end
      dispatch()
      return
    end
    buf = buf .. data
    while true do
      local nl = buf:find("\n", 1, true)
      if not nl then
        break
      end
      local l = buf:sub(1, nl - 1):gsub("\r$", "")
      buf = buf:sub(nl + 1)
      line(l)
    end
  end
end

--- Incremental NDJSON decoder (one JSON value per line; blank lines ignored).
---@param on_obj fun(obj: any)
---@param on_error? fun(line: string, err: string)
---@return fun(data: string?)
function M.ndjson_decoder(on_obj, on_error)
  local buf = ""
  local function line(l)
    l = l:gsub("\r$", "")
    if l:match("^%s*$") then
      return
    end
    local ok, obj = pcall(vim.json.decode, l, { luanil = { object = true, array = true } })
    if ok then
      on_obj(obj)
    elseif on_error then
      on_error(l, tostring(obj))
    end
  end
  return function(data)
    if data == nil then
      if buf ~= "" then
        line(buf)
        buf = ""
      end
      return
    end
    buf = buf .. data
    while true do
      local nl = buf:find("\n", 1, true)
      if not nl then
        break
      end
      local l = buf:sub(1, nl - 1)
      buf = buf:sub(nl + 1)
      line(l)
    end
  end
end

-- Low-level runner -----------------------------------------------------------------------------

---@class slop.http.CurlOpts
---@field stdin? string
---@field timeout? integer                      ms; process is killed after it (backstop)
---@field env? table<string, string>
---@field cwd? string
---@field on_stdout? fun(data: string)          main loop, in order; stdout is then not accumulated
---@field on_exit fun(code: integer, stdout: string, stderr: string, signal: integer)  main loop; not called after cancel()
---@field on_cancel? fun()                      main loop, right after cancel()

--- Low-level: run curl with raw args (used by request() and by rest's runner).
---@param args string[]                          curl arguments (without "curl")
---@param opts slop.http.CurlOpts
---@return slop.http.Handle
function M.curl(args, opts)
  next_id = next_id + 1
  local handle = { id = next_id } ---@type slop.http.Handle
  local active = true
  local proc ---@type vim.SystemObj?
  local out, err = {}, {}

  function handle:is_active()
    return active
  end

  function handle:cancel()
    if not active then
      return
    end
    active = false
    if proc then
      pcall(proc.kill, proc, 15)
    end
    if opts.on_cancel then
      vim.schedule(opts.on_cancel)
    end
  end

  local sys_opts = {
    stdin = opts.stdin,
    text = false,
    env = opts.env,
    cwd = opts.cwd,
    timeout = opts.timeout,
    stdout = function(_, data)
      if not data then
        return
      end
      if opts.on_stdout then
        vim.schedule(function()
          if active then
            opts.on_stdout(data)
          end
        end)
      else
        out[#out + 1] = data
      end
    end,
    stderr = function(_, data)
      if data then
        err[#err + 1] = data
      end
    end,
  }
  local ok, res = pcall(vim.system, vim.list_extend({ "curl" }, args), sys_opts, function(r)
    vim.schedule(function()
      if not active then
        return
      end
      active = false
      opts.on_exit(r.code, table.concat(out), table.concat(err), r.signal or 0)
    end)
  end)
  if not ok then
    active = false
    vim.schedule(function()
      opts.on_exit(-1, "", "spawn failed: " .. tostring(res), 0)
    end)
  else
    proc = res
  end
  return handle
end

-- High-level request ---------------------------------------------------------------------------

local CURL_ERRORS = {
  [6] = "could not resolve host",
  [7] = "failed to connect",
  [28] = "timed out",
  [35] = "TLS handshake failed",
  [52] = "empty reply from server",
  [56] = "failure receiving data",
}

local function make_response(status, header_list, headers, body, meta, t0)
  return {
    status = status,
    headers = headers,
    header_list = header_list,
    body = body,
    meta = meta,
    duration_ms = (uv.hrtime() - t0) / 1e6,
    json = function(self)
      local ok, v = pcall(vim.json.decode, self.body, { luanil = { object = true, array = true } })
      if ok then
        return v
      end
      return nil, tostring(v)
    end,
  }
end

local function read_file(path)
  local f = io.open(path, "rb")
  if not f then
    return ""
  end
  local s = f:read("*a") or ""
  f:close()
  return s
end

--- Start a request. Status >= 400 is reported as err.kind = "http" with err.response set.
---@param opts slop.http.Request
---@return slop.http.Handle
function M.request(opts)
  assert(type(opts) == "table" and type(opts.on_done) == "function", "slop: http.request needs opts.on_done")
  local args, stdin = M.build_args(opts)
  local url = table.remove(args)
  local hdr_file = vim.fn.tempname()
  vim.list_extend(args, { "-D", hdr_file, "-w", "%{stderr}\n" .. META_MARK .. "%{json}" })
  if opts.stream then
    args[#args + 1] = "-N"
  end
  args[#args + 1] = url
  local timeout = opts.timeout or DEFAULT_TIMEOUT
  local t0 = uv.hrtime()
  local done = false
  local handle ---@type slop.http.Handle

  local function finish(res, e)
    if done then
      return
    end
    done = true
    os.remove(hdr_file)
    local ok, cb_err = pcall(opts.on_done, res, e)
    if not ok then
      log().error("%s: on_done failed: %s", opts.name or url, cb_err)
    end
  end

  local decode ---@type fun(data: string?)?
  local raw_body = {}
  local raw_size = 0
  if opts.stream then
    local function emit(chunk)
      if done or not handle:is_active() or not opts.on_chunk then
        return
      end
      local ok, cb_err = pcall(opts.on_chunk, chunk, handle)
      if not ok then
        log().error("%s: on_chunk failed: %s", opts.name or url, cb_err)
      end
    end
    if opts.stream == "sse" then
      decode = M.sse_decoder(emit)
    elseif opts.stream == "ndjson" then
      decode = M.ndjson_decoder(emit)
    else
      decode = function(data)
        if data then
          emit(data)
        end
      end
    end
  end

  handle = M.curl(args, {
    stdin = stdin,
    env = opts.env,
    -- backstop in case curl itself hangs past --max-time
    timeout = timeout + 2000,
    on_stdout = decode and function(data)
      if raw_size < 1024 * 1024 then
        raw_body[#raw_body + 1] = data
        raw_size = raw_size + #data
      end
      decode(data)
    end or nil,
    on_cancel = function()
      finish(nil, { kind = "cancelled", message = "request cancelled" })
    end,
    on_exit = function(code, stdout, stderr, signal)
      if decode and code == 0 then
        decode(nil)
      end
      local errtext, metatext = stderr, nil
      local at = stderr:find("\n" .. META_MARK, 1, true)
      if at then
        errtext = stderr:sub(1, at - 1)
        metatext = stderr:sub(at + 1 + #META_MARK)
      end
      errtext = vim.trim(errtext or "")
      local meta = {}
      if metatext and metatext ~= "" then
        local ok, m = pcall(vim.json.decode, metatext, { luanil = { object = true, array = true } })
        if ok and type(m) == "table" then
          meta = m
        end
      end
      local header_list, headers, hdr_status = M.parse_headers(read_file(hdr_file))
      local status = tonumber(meta.response_code or meta.http_code) or hdr_status or 0
      local body = decode and "" or stdout
      if decode and status >= 400 then
        body = table.concat(raw_body)
      end
      local res = make_response(status, header_list, headers, body, meta, t0)
      if code == -1 then
        return finish(nil, { kind = "spawn", message = "could not run curl: " .. errtext })
      end
      if code == 28 or (code ~= 0 and signal ~= 0) or code == 124 then
        return finish(nil, {
          kind = "timeout",
          message = ("timed out after %s ms"):format(timeout),
          code = code,
          response = status > 0 and res or nil,
        })
      end
      if code ~= 0 then
        return finish(nil, {
          kind = "curl",
          message = errtext ~= "" and errtext or ("curl exited %d (%s)"):format(code, CURL_ERRORS[code] or "error"),
          code = code,
        })
      end
      if status >= 400 then
        return finish(nil, { kind = "http", message = ("HTTP %d"):format(status), code = status, response = res })
      end
      finish(res, nil)
    end,
  })
  return handle
end

return M

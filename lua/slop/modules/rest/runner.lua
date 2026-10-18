--- Request resolution (variables, includes, Basic auth), curl argv building (pure) and execution through
--- core.http.curl: one curl process per request, body on stdin, --globoff, -D/-o temp files, -w '%{json}'.
---@class slop.rest.runner
local M = {}

local vars = require("slop.modules.rest.vars")

---@class slop.rest.Resolved
---@field method string
---@field url string
---@field version? string
---@field headers {[1]: string, [2]: string}[]
---@field body? string
---@field timeout integer                ms
---@field follow boolean
---@field cookie_jar? string             path (nil = no jar)
---@field insecure? boolean

---@class slop.rest.ResolveOpts
---@field ctx slop.rest.VarCtx
---@field timeout integer                default timeout (ms)
---@field follow_redirects boolean
---@field cookie_jar? string|false
---@field insecure? boolean
---@field headers? table<string, string>  default headers (added when absent)
---@field read_file? fun(path: string): string?

local function encode_url(url)
  return (url:gsub(" ", "%%20"))
end

--- "Basic user:pass" / "Basic user pass" -> "Basic base64(user:pass)"; anything else unchanged.
---@param value string
---@return string
function M.basic_auth(value)
  local cred = value:match("^[Bb]asic%s+(.-)%s*$")
  if not cred or cred == "" then
    return value
  end
  local user, pass = cred:match("^([^:%s]*):(.*)$")
  if not user then
    user, pass = cred:match("^(%S+)%s+(.+)$")
  end
  if not user then
    return value
  end
  return "Basic " .. vim.base64.encode(user .. ":" .. pass)
end

--- Resolve a parsed request into concrete values. Unresolved variables => nil + error naming them.
---@param req slop.rest.Request
---@param opts slop.rest.ResolveOpts
---@return slop.rest.Resolved? resolved, string? err, string[]? unresolved
function M.resolve(req, opts)
  local missing, seen = {}, {}
  local function exp(text)
    local out, miss = vars.expand(text, opts.ctx)
    for _, m in ipairs(miss) do
      if not seen[m] then
        seen[m] = true
        missing[#missing + 1] = m
      end
    end
    return out
  end

  local url = exp(req.url)
  local headers = {}
  local has = {}
  for _, h in ipairs(req.headers or {}) do
    local name, value = exp(h[1]), exp(h[2])
    if name:lower() == "authorization" then
      value = M.basic_auth(value)
    end
    headers[#headers + 1] = { name, value }
    has[name:lower()] = true
  end
  for name, value in pairs(opts.headers or {}) do
    if not has[name:lower()] then
      headers[#headers + 1] = { name, exp(value) }
    end
  end

  local body
  if req.body then
    local base = req.file and vim.fs.dirname(req.file) or vim.fn.getcwd()
    local parts = {}
    for _, line in ipairs(vim.split(req.body, "\n", { plain = true })) do
      local inc = line:match("^<%s+(%S.-)%s*$")
      if inc then
        local path = inc:sub(1, 1) == "/" and inc or vim.fs.normalize(vim.fs.joinpath(base, inc))
        local read = opts.read_file or require("slop.core.project").read_file
        local text = read(path)
        if not text then
          return nil, "body include not found: " .. inc
        end
        parts[#parts + 1] = (text:gsub("\n$", ""))
      else
        parts[#parts + 1] = exp(line)
      end
    end
    body = table.concat(parts, "\n")
  end

  if #missing > 0 then
    return nil, vars.unresolved_message(missing), missing
  end
  local meta = req.meta or {}
  local jar = opts.cookie_jar
  if meta.no_cookie_jar then
    jar = nil
  end
  return {
    method = req.method,
    url = encode_url(url),
    version = req.version,
    headers = headers,
    body = body,
    timeout = meta.timeout or opts.timeout,
    follow = opts.follow_redirects and not meta.no_redirect,
    cookie_jar = jar or nil,
    insecure = opts.insecure,
  }
end

--- Pure: curl argv (without "curl") and stdin for a resolved request.
---@param r slop.rest.Resolved
---@param files {headers: string, body: string}  temp files for -D / -o
---@return string[] args, string? stdin
function M.build_args(r, files)
  local args = { "-sS", "--globoff" }
  if r.method == "HEAD" then
    args[#args + 1] = "--head"
  else
    vim.list_extend(args, { "-X", r.method })
  end
  local has_cookie = false
  for _, h in ipairs(r.headers) do
    if h[1]:lower() == "cookie" then
      has_cookie = true
    end
    vim.list_extend(args, { "-H", h[2] == "" and (h[1] .. ";") or (h[1] .. ": " .. h[2]) })
  end
  local stdin
  if r.body ~= nil and r.method ~= "HEAD" then
    vim.list_extend(args, { "--data-binary", "@-" })
    stdin = r.body
  end
  if r.follow then
    vim.list_extend(args, { "-L", "--max-redirs", "10" })
  end
  if r.timeout and r.timeout > 0 then
    vim.list_extend(args, { "--max-time", ("%g"):format(r.timeout / 1000) })
  end
  if r.cookie_jar then
    if not has_cookie then
      vim.list_extend(args, { "-b", r.cookie_jar })
    end
    vim.list_extend(args, { "-c", r.cookie_jar })
  end
  if r.insecure then
    args[#args + 1] = "-k"
  end
  local v = r.version and r.version:match("^HTTP/(.+)$")
  if v == "1.1" or v == "1.0" then
    args[#args + 1] = "--http" .. v
  elseif v == "2" or v == "2.0" then
    args[#args + 1] = "--http2"
  elseif v == "3" then
    args[#args + 1] = "--http3"
  end
  vim.list_extend(args, { "-D", files.headers, "-o", files.body, "-w", "%{json}" })
  args[#args + 1] = "--url"
  args[#args + 1] = r.url
  return args, stdin
end

--- Pure: the final hop of a `curl -D` dump -> status, reason, version, headers.
---@param text string
---@return integer status, string? reason, string? version, {[1]: string, [2]: string}[] headers
function M.parse_headers(text)
  local blocks, cur = {}, nil
  for line in ((text or ""):gsub("\r", "") .. "\n"):gmatch("(.-)\n") do
    if line:match("^HTTP/") then
      cur = { status = line, headers = {} }
      blocks[#blocks + 1] = cur
    elseif cur and line ~= "" then
      local n, v = line:match("^([^:]+):%s*(.-)%s*$")
      if n then
        cur.headers[#cur.headers + 1] = { n, v }
      end
    end
  end
  local last = blocks[#blocks]
  if not last then
    return 0, nil, nil, {}
  end
  local version, code, reason = last.status:match("^HTTP/(%S+)%s+(%d+)%s*(.-)%s*$")
  return tonumber(code) or 0, reason ~= "" and reason or nil, version, last.headers
end

M.REASONS = {
  [200] = "OK",
  [201] = "Created",
  [202] = "Accepted",
  [204] = "No Content",
  [301] = "Moved Permanently",
  [302] = "Found",
  [304] = "Not Modified",
  [400] = "Bad Request",
  [401] = "Unauthorized",
  [403] = "Forbidden",
  [404] = "Not Found",
  [405] = "Method Not Allowed",
  [409] = "Conflict",
  [422] = "Unprocessable Entity",
  [429] = "Too Many Requests",
  [500] = "Internal Server Error",
  [502] = "Bad Gateway",
  [503] = "Service Unavailable",
  [504] = "Gateway Timeout",
}

---@class slop.rest.RunError
---@field message string
---@field code? integer                  curl exit code
---@field kind "curl"|"cancelled"|"spawn"

---@class slop.rest.RunHandle
---@field cancel fun(self: slop.rest.RunHandle)
---@field is_active fun(self: slop.rest.RunHandle): boolean

--- Execute a resolved request. on_done(res, err) exactly once on the main loop (not called after cancel()).
---@param r slop.rest.Resolved
---@param on_done fun(res: slop.rest.Response?, err: slop.rest.RunError?)
---@return slop.rest.RunHandle
function M.execute(r, on_done)
  local base = vim.fn.tempname()
  local files = { headers = base .. ".h", body = base .. ".b" }
  local args, stdin = M.build_args(r, files)
  local project = require("slop.core.project")
  local done = false
  local function cleanup()
    os.remove(files.headers)
    os.remove(files.body)
  end
  local started = vim.uv.hrtime()
  local handle = require("slop.core.http").curl(args, {
    stdin = stdin,
    timeout = (r.timeout or 30000) + 5000,
    on_exit = function(code, stdout, stderr)
      if done then
        return
      end
      done = true
      local ok_meta, meta = pcall(vim.json.decode, stdout or "", { luanil = { object = true, array = true } })
      meta = ok_meta and type(meta) == "table" and meta or {}
      local hdr = project.read_file(files.headers) or ""
      local body = project.read_file(files.body) or ""
      cleanup()
      local status, reason, version, headers = M.parse_headers(hdr)
      if code ~= 0 and status == 0 then
        local msg = meta.errormsg or vim.trim(stderr or "")
        if msg == "" then
          msg = "curl exited with code " .. tostring(code)
        end
        return on_done(nil, { kind = code == -1 and "spawn" or "curl", message = msg, code = code })
      end
      status = tonumber(meta.response_code) or status
      local ctype = meta.content_type
      if not ctype or ctype == vim.NIL then
        for _, h in ipairs(headers) do
          if h[1]:lower() == "content-type" then
            ctype = h[2]
          end
        end
      end
      on_done({
        status = status,
        reason = reason or M.REASONS[status],
        version = version,
        headers = headers,
        body = body,
        meta = meta,
        time_ms = tonumber(meta.time_total) and tonumber(meta.time_total) * 1000 or (vim.uv.hrtime() - started) / 1e6,
        size = tonumber(meta.size_download) or #body,
        content_type = type(ctype) == "string" and ctype or nil,
        url = type(meta.url_effective) == "string" and meta.url_effective or r.url,
        curl_error = code ~= 0 and (meta.errormsg or stderr) or nil,
      }, nil)
    end,
  })
  return {
    cancel = function()
      if not done then
        done = true
        handle:cancel()
        cleanup()
      end
    end,
    is_active = function()
      return not done
    end,
  }
end

return M

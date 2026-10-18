--- {{variable}} expansion for rest requests.
---
--- Precedence (highest first): @prompt answers > file vars > selected http-client env > nearest .env > process env.
--- Special forms: {{$dynamic ...}} and {{name.response.body.<path>}} / {{name.response.headers.<Name>}} (chaining).
--- Unresolved variables are reported (never replaced by ""), so callers can refuse to send.
---@class slop.rest.vars
local M = {}

---@class slop.rest.Response
---@field status integer
---@field reason? string
---@field headers {[1]: string, [2]: string}[]
---@field body string
---@field meta? table
---@field time_ms? number
---@field size? integer
---@field content_type? string

---@class slop.rest.VarCtx
---@field prompt? table<string, string>
---@field file? table<string, string>
---@field env? table<string, string>
---@field dotenv? table<string, string>
---@field process? boolean|fun(name: string): string?   default true (os.getenv)
---@field dynamic? table<string, fun(args: string): string?>
---@field response? fun(name: string): slop.rest.Response?

local MAX_DEPTH = 10

--- Names referenced as {{name}} in `text` (trimmed, in order, duplicates kept).
---@param text string?
---@return string[]
function M.refs(text)
  local out = {}
  for inner in (text or ""):gmatch("{{(.-)}}") do
    out[#out + 1] = vim.trim(inner)
  end
  return out
end

--- Split a chaining reference "login.response.body.$.token" -> "login", "body", "$.token".
---@param ref string
---@return string? name, string? kind, string? path
function M.chain_ref(ref)
  local name, kind, path = ref:match("^(.-)%.response%.(%a+)%.?(.*)$")
  if name and name ~= "" and (kind == "body" or kind == "headers") then
    return name, kind, path
  end
  return nil
end

--- Pure JSONPath-lite: "$", ".key", "['key']", '["key"]', "[n]" (0-based) on decoded JSON.
---@param data any
---@param path string
---@return any value, boolean found
function M.jsonpath(data, path)
  local p = vim.trim(path or "")
  if p:sub(1, 1) == "$" then
    p = p:sub(2)
  end
  local cur = data
  while p ~= "" do
    local key, idx, rest
    key, rest = p:match("^%.([^%.%[]+)(.*)$")
    if not key then
      key, rest = p:match("^%[['\"](.-)['\"]%](.*)$")
    end
    if not key then
      idx, rest = p:match("^%[(%d+)%](.*)$")
    end
    if (not key and not idx) or type(cur) ~= "table" then
      return nil, false
    end
    if idx then
      cur = cur[tonumber(idx) + 1]
    else
      cur = cur[key]
    end
    if cur == nil or cur == vim.NIL then
      return nil, false
    end
    p = rest
  end
  return cur, true
end

---@param v any
---@return string
local function stringify(v)
  if type(v) == "string" then
    return v
  elseif type(v) == "table" then
    return vim.json.encode(v)
  end
  return tostring(v)
end

--- Value of a chaining reference from a stored response.
---@param res slop.rest.Response
---@param kind "body"|"headers"
---@param path string
---@return string?
function M.from_response(res, kind, path)
  if kind == "headers" then
    local want = path:lower()
    for _, h in ipairs(res.headers or {}) do
      if h[1]:lower() == want then
        return h[2]
      end
    end
    return nil
  end
  if path == "" or path == "*" then
    return res.body or ""
  end
  local ok, data = pcall(vim.json.decode, res.body or "", { luanil = { object = true, array = true } })
  if not ok then
    return nil
  end
  local v, found = M.jsonpath(data, path)
  if not found then
    return nil
  end
  return stringify(v)
end

--- RFC 4122 v4 uuid.
---@return string
function M.uuid()
  local t = {}
  for i = 1, 16 do
    t[i] = math.random(0, 255)
  end
  t[7] = (t[7] % 16) + 64 -- version 4
  t[9] = (t[9] % 64) + 128 -- variant 10xx
  local hex = {}
  for i = 1, 16 do
    hex[i] = ("%02x"):format(t[i])
  end
  local s = table.concat(hex)
  return ("%s-%s-%s-%s-%s"):format(s:sub(1, 8), s:sub(9, 12), s:sub(13, 16), s:sub(17, 20), s:sub(21, 32))
end

local seeded = false

--- Dynamic variable value ("$uuid", "$randomInt 1 10", "$processEnv HOME", ...); nil if unknown/missing.
---@param expr string  without the leading "$"
---@param ctx slop.rest.VarCtx
---@return string?
function M.dynamic(expr, ctx)
  if not seeded then
    math.randomseed(vim.uv.hrtime() % 2147483647)
    seeded = true
  end
  local name, args = expr:match("^(%S+)%s*(.*)$")
  if not name then
    return nil
  end
  if ctx.dynamic and ctx.dynamic[name] then
    local ok, v = pcall(ctx.dynamic[name], args)
    return ok and v ~= nil and tostring(v) or nil
  end
  if name == "uuid" or name == "random.uuid" or name == "guid" then
    return M.uuid()
  elseif name == "timestamp" then
    return tostring(os.time())
  elseif name == "isoTimestamp" then
    return os.date("!%Y-%m-%dT%H:%M:%SZ") --[[@as string]]
  elseif name == "randomInt" or name == "random.integer" then
    local a, b = args:match("^(%-?%d+)%s+(%-?%d+)$")
    a, b = tonumber(a) or 0, tonumber(b) or 1000
    if a > b then
      a, b = b, a
    end
    return tostring(math.random(a, b))
  elseif name == "processEnv" then
    local var = vim.trim(args)
    return var ~= "" and os.getenv(var) or nil
  elseif name == "dotenv" then
    local var = vim.trim(args)
    return ctx.dotenv and ctx.dotenv[var] or nil
  end
  return nil
end

---@param name string
---@param ctx slop.rest.VarCtx
---@return string? raw, boolean expand  (expand: value may itself contain {{...}})
local function lookup(name, ctx)
  if ctx.prompt and ctx.prompt[name] ~= nil then
    return ctx.prompt[name], false
  end
  if ctx.file and ctx.file[name] ~= nil then
    return ctx.file[name], true
  end
  if ctx.env and ctx.env[name] ~= nil then
    return stringify(ctx.env[name]), true
  end
  if ctx.dotenv and ctx.dotenv[name] ~= nil then
    return ctx.dotenv[name], false
  end
  if ctx.process ~= false and name:match("^[%w_]+$") then
    local v
    if type(ctx.process) == "function" then
      v = ctx.process(name)
    else
      v = os.getenv(name)
    end
    if v ~= nil then
      return v, false
    end
  end
  return nil, false
end

---@param text string
---@param ctx slop.rest.VarCtx
---@param stack table<string, boolean>
---@param depth integer
---@param missing string[]
---@param seen_missing table<string, boolean>
---@return string
local function expand(text, ctx, stack, depth, missing, seen_missing)
  return (
    text:gsub("{{(.-)}}", function(inner)
      local ref = vim.trim(inner)
      local function miss()
        if not seen_missing[ref] then
          seen_missing[ref] = true
          missing[#missing + 1] = ref
        end
        return nil -- keep the original text
      end
      if ref:sub(1, 1) == "$" then
        local v = M.dynamic(ref:sub(2), ctx)
        if v == nil then
          return miss()
        end
        return v
      end
      local cname, kind, path = M.chain_ref(ref)
      if cname then
        local res = ctx.response and ctx.response(cname)
        local v = res and M.from_response(res, kind --[[@as "body"|"headers"]], path or "")
        if v == nil then
          return miss()
        end
        return v
      end
      if stack[ref] or depth >= MAX_DEPTH then
        return miss()
      end
      local raw, nested = lookup(ref, ctx)
      if raw == nil then
        return miss()
      end
      if nested and raw:find("{{", 1, true) then
        stack[ref] = true
        local v = expand(raw, ctx, stack, depth + 1, missing, seen_missing)
        stack[ref] = nil
        return v
      end
      return raw
    end)
  )
end

--- Expand every {{...}} in `text`.
---@param text string?
---@param ctx slop.rest.VarCtx
---@return string? text, string[] unresolved
function M.expand(text, ctx)
  if text == nil then
    return nil, {}
  end
  local missing = {}
  local out = expand(text, ctx, {}, 0, missing, {})
  return out, missing
end

--- "unresolved variable(s): {{a}}, {{b}}"
---@param names string[]
---@return string
function M.unresolved_message(names)
  local parts = {}
  for i, n in ipairs(names) do
    parts[i] = "{{" .. n .. "}}"
  end
  return ("unresolved variable%s: %s"):format(#names == 1 and "" or "s", table.concat(parts, ", "))
end

--- Parse a .env file (KEY=VALUE, `export`, quotes, comments). Pure.
---@param text string
---@return table<string, string>
function M.parse_dotenv(text)
  local out = {}
  for line in (text or ""):gmatch("[^\r\n]+") do
    local l = vim.trim(line)
    if l ~= "" and l:sub(1, 1) ~= "#" then
      l = l:gsub("^export%s+", "")
      local k, v = l:match("^([%w_%.%-]+)%s*=%s*(.*)$")
      if k then
        local q = v:sub(1, 1)
        if (q == '"' or q == "'") and v:find(q, 2, true) then
          v = v:sub(2, v:find(q, 2, true) - 1)
          if q == '"' then
            v = v:gsub("\\n", "\n")
          end
        else
          v = vim.trim((v:gsub("%s+#.*$", "")))
        end
        out[k] = v
      end
    end
  end
  return out
end

return M

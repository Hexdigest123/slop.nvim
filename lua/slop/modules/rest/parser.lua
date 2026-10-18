--- Pure, line-based parser for the slop .http subset (plan §6). No vim.api: input is a list of lines.
---
---   parser.parse(lines, file?) -> { vars = {{name, value, line}}, requests = Request[], warnings = {{lnum, msg}} }
---
--- Syntax: "###" separators (rest of the line = title), "# @name x" / "# @depends a, b" / "# @prompt var [desc]" /
--- "# @no-cookie-jar" / "# @no-redirect" / "# @timeout 10s" directives ("#" or "//" comments), "@var = value"
--- file variables, "METHOD url [HTTP/x]" request lines (or a bare http(s):// / {{...}} url -> GET), indented
--- continuation lines starting with / ? & #, "Name: value" headers, a body after a blank line, "< ./file" body
--- includes. "> {% %}" / "< {% %}" scripts and ">> file" redirects are ignored with a warning.
---@class slop.rest.parser
local M = {}

M.METHODS = {
  GET = true,
  POST = true,
  PUT = true,
  PATCH = true,
  DELETE = true,
  HEAD = true,
  OPTIONS = true,
  TRACE = true,
  CONNECT = true,
}

---@class slop.rest.Meta
---@field depends string[]
---@field prompt {name: string, desc: string?}[]
---@field no_cookie_jar? boolean
---@field no_redirect? boolean
---@field timeout? integer                ms

---@class slop.rest.Request
---@field file? string
---@field line integer                    1-based line of the request line
---@field start integer                   1-based first line of the block (the "###" line, or 1)
---@field stop integer                    1-based last line of the block
---@field name? string                    @name, else the title
---@field title? string
---@field method string
---@field url string
---@field version? string                 "HTTP/1.1", "HTTP/2", ...
---@field headers {[1]: string, [2]: string}[]
---@field body? string                    raw body text (lines joined by "\n"); "< path" lines kept verbatim
---@field meta slop.rest.Meta
---@field warnings {lnum: integer, msg: string}[]

---@class slop.rest.File
---@field file? string
---@field vars {name: string, value: string, line: integer}[]
---@field requests slop.rest.Request[]
---@field warnings {lnum: integer, msg: string}[]

local function trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

--- "10s" / "500ms" / "2m" / "1.5" (seconds) -> ms
---@param s string
---@return integer?
function M.parse_duration(s)
  s = trim(s or ""):lower()
  local n, unit = s:match("^(%d+%.?%d*)%s*(%a*)$")
  n = tonumber(n)
  if not n then
    return nil
  end
  local mult = ({ [""] = 1000, s = 1000, sec = 1000, ms = 1, m = 60000, min = 60000 })[unit]
  if not mult then
    return nil
  end
  return math.floor(n * mult)
end

--- Comment text of a line ("# x" / "// x"), nil when the line is not a comment (or is a separator).
---@param line string
---@return string?
local function comment(line)
  if line:match("^%s*###") then
    return nil
  end
  local c = line:match("^%s*#(.*)$") or line:match("^%s*//(.*)$")
  return c
end

---@param text string comment text
---@return string? name, string? value
local function directive(text)
  local name, rest = text:match("^%s*@([%w_%-%.]+)%s*(.*)$")
  if not name then
    return nil
  end
  rest = rest:gsub("^=%s*", "")
  return name, trim(rest)
end

---@param line string
---@return string? method, string? url, string? version
function M.request_line(line)
  local word, rest = line:match("^(%u+)%s+(.-)%s*$")
  local target
  local method
  if word and M.METHODS[word] then
    method, target = word, rest
  elseif line:match("^https?://") or line:match("^{{") then
    method, target = "GET", trim(line)
  else
    return nil
  end
  local url, version = target:match("^(.-)%s+(HTTP/[%d%.]+)$")
  if url then
    return method, url, version
  end
  return method, target, nil
end

local function header(line)
  local name, value = line:match("^([%w!#$%%&'*+%.^_`|~%-]+)%s*:%s*(.-)%s*$")
  if name and not name:match("^https?$") then
    return name, value
  end
  return nil
end

local function new_request(start, title)
  return {
    start = start,
    stop = start,
    title = title ~= "" and title or nil,
    headers = {},
    meta = { depends = {}, prompt = {} },
    warnings = {},
    _body = nil, ---@type string[]?
    _directives = {},
  }
end

--- Parse a whole file.
---@param lines string[]
---@param file? string
---@return slop.rest.File
function M.parse(lines, file)
  ---@type slop.rest.File
  local out = { file = file, vars = {}, requests = {}, warnings = {} }
  local block ---@type table
  local state ---@type "pre"|"url"|"headers"|"body"
  local in_script = false ---@type false|integer

  local function warn(lnum, msg)
    local w = { lnum = lnum, msg = msg }
    out.warnings[#out.warnings + 1] = w
    if block and block.method then
      block.warnings[#block.warnings + 1] = w
    end
  end

  local function finish(last)
    if not block then
      return
    end
    if block.method then
      local body = block._body
      if body then
        while #body > 0 and body[#body]:match("^%s*$") do
          body[#body] = nil
        end
        block.body = #body > 0 and table.concat(body, "\n") or nil
      end
      -- block end = last non-blank line
      local stop = last
      while stop > block.line and (lines[stop] or ""):gsub("\r$", ""):match("^%s*$") do
        stop = stop - 1
      end
      block.stop = stop
      block.name = block._directives.name or block.title
      block.file = file
      block._body, block._directives = nil, nil
      out.requests[#out.requests + 1] = block
    end
    block = nil
  end

  local function apply_directive(lnum, name, value)
    local b = block
    if name == "name" then
      if value ~= "" then
        b._directives.name = value
      end
    elseif name == "depends" then
      for dep in value:gmatch("[^,%s]+") do
        b.meta.depends[#b.meta.depends + 1] = dep
      end
    elseif name == "prompt" then
      local var, desc = value:match("^(%S+)%s*(.*)$")
      if var then
        b.meta.prompt[#b.meta.prompt + 1] = { name = var, desc = desc ~= "" and desc or nil }
      end
    elseif name == "no-cookie-jar" then
      b.meta.no_cookie_jar = true
    elseif name == "no-redirect" then
      b.meta.no_redirect = true
    elseif name == "timeout" then
      local ms = M.parse_duration(value)
      if ms then
        b.meta.timeout = ms
      else
        warn(lnum, "invalid @timeout value: " .. value)
      end
    end
    -- unknown directives (e.g. @lang) are ignored
  end

  block = new_request(1, "")
  state = "pre"

  for lnum, raw in ipairs(lines) do
    local line = raw:gsub("\r$", "")
    local title = line:match("^###(.*)$")
    if in_script then
      if line:find("%%}") then
        in_script = false
      end
    elseif title then
      finish(lnum - 1)
      block = new_request(lnum, trim(title))
      state = "pre"
    elseif line:match("^%s*[<>]%s*{%%") then
      warn(lnum, "script blocks ({% %}) are not supported and were ignored")
      if not line:find("%%}", (line:find("{%%") or 0) + 2) then
        in_script = lnum
      end
    elseif state == "body" then
      if line:match("^%s*>>!?%s+%S") or line:match("^%s*>%s+%S") then
        warn(lnum, "response handlers / redirects (> / >>) are not supported and were ignored")
      else
        block._body[#block._body + 1] = line
      end
    elseif state == "pre" then
      local c = comment(line)
      if c then
        local dname, dval = directive(c)
        if dname then
          apply_directive(lnum, dname, dval)
        end
      elseif line:match("^@[%w_%-%.]+%s*=") then
        local name, value = line:match("^@([%w_%-%.]+)%s*=%s*(.-)%s*$")
        out.vars[#out.vars + 1] = { name = name, value = value, line = lnum }
      elseif not line:match("^%s*$") then
        local method, url, version = M.request_line(line)
        if method then
          block.method, block.url, block.version, block.line = method, url, version, lnum
          state = "url"
        else
          warn(lnum, "unexpected line before the request line: " .. line)
        end
      end
    else -- url / headers
      if state == "url" and line:match("^%s+[/?&#]") then
        block.url = block.url .. trim(line)
      else
        state = "headers"
        if line:match("^%s*$") then
          state = "body"
          block._body = {}
        elseif comment(line) then
          local c = comment(line) --[[@as string]]
          local dname, dval = directive(c)
          if dname then
            apply_directive(lnum, dname, dval)
          end
        else
          local name, value = header(line)
          if name then
            block.headers[#block.headers + 1] = { name, value }
          else
            state = "body"
            block._body = { line }
            if not line:match("^%s*[{%[<]") then
              warn(lnum, "missing blank line before the body")
            end
          end
        end
      end
    end
  end
  if in_script then
    warn(in_script, "unterminated script block")
  end
  finish(#lines)
  return out
end

--- The request whose block contains `lnum` (1-based). Falls back to the closest request above.
---@param parsed slop.rest.File
---@param lnum integer
---@return slop.rest.Request?
function M.at(parsed, lnum)
  local best
  for _, r in ipairs(parsed.requests) do
    if lnum >= r.start and lnum <= r.stop then
      return r
    end
    if r.start <= lnum then
      best = r
    end
  end
  return best
end

--- File variables visible to `req`: the last declaration above its request line wins, else the first below.
---@param parsed slop.rest.File
---@param req? slop.rest.Request
---@return table<string, string>
function M.file_vars(parsed, req)
  local before, after = {}, {}
  local line = req and req.line or math.huge
  for _, v in ipairs(parsed.vars) do
    if v.line < line then
      before[v.name] = v.value
    elseif after[v.name] == nil then
      after[v.name] = v.value
    end
  end
  return vim.tbl_extend("force", after, before)
end

return M

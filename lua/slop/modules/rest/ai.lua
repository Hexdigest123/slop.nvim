--- AI for rest: `gen` (requests from a description, the route handler under the cursor or an OpenAPI file) and
--- `fix` (repair a failed request from its block, status, headers and body). Backend: services.ai.chat
--- (cfg.ai.provider, default mistral_chat) or an ACP agent (cfg.ai.backend = "acp"). Every text passes
--- core.secrets plus header/JSON masking; env and .env VALUES are never sent (names only).
--- Output is previewed with core.ui.diff in the target .http buffer.
---@class slop.rest.ai
local M = {}

local api = vim.api

local function log()
  return require("slop.core.log").scope("rest")
end
local function cfg()
  return require("slop.config").get("rest")
end

M.MAX_CONTEXT = 60000
M.MAX_BODY = 4096

M.SYNTAX = [[
slop .http syntax (JetBrains/VS Code compatible subset):
- Requests are separated by lines starting with "###"; the text after "###" is the request title.
- "# @name camelCaseName" names a request (used for chaining). "# @depends a, b" lists requests to run first.
- "# @prompt var description" asks the user for {{var}}. "# @no-redirect", "# @no-cookie-jar", "# @timeout 10s".
- File variables: "@baseUrl = http://localhost:3000" (at the top of the file), used as {{baseUrl}}.
- Request line: "METHOD url [HTTP/1.1]"; then "Header: value" lines; then a blank line; then the body.
- Dynamic values: {{$uuid}}, {{$timestamp}}, {{$isoTimestamp}}, {{$randomInt 1 100}}, {{$processEnv NAME}}.
- Chaining: {{login.response.body.$.token}} (JSONPath on the JSON body of request "login"),
  {{login.response.headers.Set-Cookie}}. Cookies are kept automatically in a cookie jar.
- NOT supported: script blocks ("> {% %}"), ">> file" redirects, GraphQL helpers.]]

M.RULES = [[
Rules:
- Output exactly one fenced ```http code block and nothing else.
- One request per endpoint and method. Each starts with "### <sentence-style title>" then "# @name <camelCase>".
- Use existing variables like {{baseUrl}} instead of literal hosts; never invent secrets, use {{variables}} for them.
- Include Content-Type for bodies and realistic example JSON.
- Use chaining ({{name.response.body.$.field}}) or the cookie jar for auth tokens.]]

-- Masking -------------------------------------------------------------------------------------------

local SENSITIVE = {
  "authorization",
  "cookie",
  "token",
  "secret",
  "password",
  "passwd",
  "api[-_]?key",
  "apikey",
  "session",
  "credential",
  "jwt",
  "bearer",
  "private[-_]?key",
  "signature",
}
-- short words that are sensitive only as a whole part of a name ("X-Auth", "db_pass", "userPin"), not inside
-- longer words ("author", "passenger", "keyboard", "spinner")
local SENSITIVE_PARTS = { auth = true, pass = true, pwd = true, pw = true, pin = true, otp = true, key = true }

---@param name string
---@return boolean
function M.sensitive(name)
  local n = name:lower()
  for _, p in ipairs(SENSITIVE) do
    if n:find(p) then
      return true
    end
  end
  for part in name:gsub("(%l)(%u)", "%1_%2"):lower():gmatch("[^%-_%.%s]+") do
    if SENSITIVE_PARTS[part] then
      return true
    end
  end
  return false
end

local PLACEHOLDER = "<redacted>"

--- Mask values of sensitive headers (template {{var}}-only values are kept: they reveal no secret).
---@param list {[1]: string, [2]: string}[]
---@return string[]
function M.mask_headers(list)
  local out = {}
  for _, h in ipairs(list or {}) do
    local v = h[2]
    if M.sensitive(h[1]) and not v:match("^[%s%w]*{{[^}]+}}%s*$") then
      v = PLACEHOLDER
    end
    out[#out + 1] = h[1] .. ": " .. v
  end
  return out
end

--- Mask JSON string values of sensitive keys. Escape-aware: a `\"` inside the value does not end it.
---@param text string
---@return string
local function mask_json(text)
  local out, pos = {}, 1
  while true do
    local s, e, key = text:find('"([^"\\]*)"%s*:%s*"', pos)
    if not s then
      break
    end
    local i = e + 1
    while i <= #text do
      local c = text:byte(i)
      if c == 92 then -- backslash: skip the escaped character
        i = i + 2
      elseif c == 34 then -- closing quote
        break
      else
        i = i + 1
      end
    end
    local value = text:sub(e + 1, i - 1)
    out[#out + 1] = text:sub(pos, e)
    out[#out + 1] = (M.sensitive(key) and not value:match("^{{.-}}$")) and PLACEHOLDER or value
    if i <= #text then
      out[#out + 1] = '"'
    end
    pos = i + 1
  end
  out[#out + 1] = text:sub(pos)
  return table.concat(out)
end

--- Mask `name=value` pairs of sensitive names (query strings, form bodies, form-encoded responses).
---@param line string
---@return string
local function mask_pairs(line)
  return (
    line:gsub("([%w%-_%.%[%]]+)=([^&%s;#\"',]*)", function(name, value)
      if value ~= "" and M.sensitive(name) and not value:match("^{{.-}}$") then
        return name .. "=" .. PLACEHOLDER
      end
    end)
  )
end

--- Mask values of sensitive JSON fields, header lines, file variables and name=value pairs in free text.
---@param text string
---@return string
function M.mask_text(text)
  text = mask_json(text)
  local lines = {}
  for _, line in ipairs(vim.split(text, "\n", { plain = true })) do
    local hname, hval = line:match("^([%w%-_]+)%s*:%s*(.+)$")
    local vname, vval = line:match("^@([%w_%-%.]+)%s*=%s*(.+)$")
    if hname and M.sensitive(hname) and not hval:match("^[%s%w]*{{[^}]+}}%s*$") then
      line = hname .. ": " .. PLACEHOLDER
    elseif vname and M.sensitive(vname) and not vval:match("^{{.-}}$") then
      line = "@" .. vname .. " = " .. PLACEHOLDER
    else
      line = mask_pairs(line)
    end
    lines[#lines + 1] = line
  end
  return table.concat(lines, "\n")
end

--- core.secrets redaction + masking.
---@param text string
---@param src? string|integer path or buffer
---@return string
function M.redact(text, src)
  local secrets = require("slop.core.secrets")
  local out = secrets.redact_text(text, src)
  return M.mask_text(out)
end

--- Values that never reach the AI, even when a response echoes them (an echo endpoint, a validation error quoting
--- the raw body, a debug page dumping the environment): every value of the http-client.private.env.json files and
--- of the nearest .env that `file` sees. Longest first. Skipped: values under 3 characters, and .env values under 6
--- characters of names that are not sensitive (`DEBUG=true`, `PORT=3000`: no secrets, and replacing every `true`
--- would garble the context).
---@param file string
---@param root string
---@return string[]
function M.secret_values(file, root)
  local env = require("slop.modules.rest.env")
  local seen, out = {}, {}
  local function add(v, min)
    if type(v) == "number" and v == math.floor(v) then
      v = ("%d"):format(v)
    end
    if type(v) == "string" and #v >= min and not seen[v] then
      seen[v] = true
      out[#out + 1] = v
    end
  end
  for k, v in pairs((env.dotenv(file, root, cfg().env_file))) do
    add(v, M.sensitive(k) and 3 or 6)
  end
  local _, files = env.load(file, root, nil)
  for _, path in ipairs(files) do
    if vim.fs.basename(path) == env.PRIVATE then
      for _, vars in pairs(require("slop.core.project").read_json(path) or {}) do
        for _, v in pairs(type(vars) == "table" and vars or {}) do
          add(v, 3)
        end
      end
    end
  end
  table.sort(out, function(a, b)
    return #a > #b
  end)
  return out
end

-- Context -------------------------------------------------------------------------------------------

--- Framework route hint from a file path (SvelteKit, Next.js).
---@param path string
---@return string?
function M.route_hint(path)
  local function clean(p)
    p = p:gsub("%([^)]*%)/?", ""):gsub("%[%.%.%.([^%]]+)%]", "{%1}"):gsub("%[([^%]]+)%]", "{%1}")
    p = p:gsub("/+$", "")
    return "/" .. p:gsub("^/+", "")
  end
  local sk = path:match("src/routes/(.-)/?%+server%.[jt]s$")
  if sk then
    return ("SvelteKit endpoint: route path %s (exported GET/POST/... functions are the methods)"):format(clean(sk))
  end
  local nx = path:match("app/(.-)/?route%.[jt]sx?$")
  if nx then
    return ("Next.js app router handler: route path %s"):format(clean(nx))
  end
  local np = path:match("pages/(api/.-)%.[jt]sx?$")
  if np then
    return ("Next.js API route: path %s"):format(clean((np:gsub("/index$", ""))))
  end
  return nil
end

---@param buf integer
---@return boolean
function M.is_openapi(buf)
  local lines = api.nvim_buf_get_lines(buf, 0, math.min(60, api.nvim_buf_line_count(buf)), false)
  for _, l in ipairs(lines) do
    if l:match('^%s*"?openapi"?%s*:') or l:match('^%s*"?swagger"?%s*:') then
      return true
    end
  end
  -- minified JSON (the whole spec on one line): `{"openapi":"3.1.0",...`
  local head = table.concat(lines, "\n"):sub(1, 4096)
  return head:match("^%s*{") ~= nil
    and (head:find('"openapi"%s*:%s*"%d') ~= nil or head:find('"swagger"%s*:%s*"%d') ~= nil)
end

--- `text` cut to `max` bytes (never inside a UTF-8 sequence) plus a marker; 2nd result: whether it was cut.
---@param text string
---@param max integer
---@return string, boolean
local function truncate(text, max)
  if #text <= max then
    return text, false
  end
  local cut = max
  while cut > 0 and text:byte(cut + 1) >= 0x80 and text:byte(cut + 1) < 0xC0 do
    cut = cut - 1
  end
  return text:sub(1, cut) .. "\n… (truncated)", true
end

--- Description of the target .http file: titles, file vars (sensitive values masked), env names.
---@param buf integer
---@param root string
---@return string
function M.target_summary(buf, root)
  local parser = require("slop.modules.rest.parser")
  local parsed = parser.parse(api.nvim_buf_get_lines(buf, 0, -1, false))
  local out = {}
  if #parsed.vars > 0 then
    out[#out + 1] = "Existing file variables:"
    for _, v in ipairs(parsed.vars) do
      out[#out + 1] = ("@%s = %s"):format(v.name, v.value)
    end
  end
  if #parsed.requests > 0 then
    out[#out + 1] = "Existing requests (do not duplicate):"
    for _, r in ipairs(parsed.requests) do
      out[#out + 1] = ("- %s%s %s"):format(r.name and ("[" .. r.name .. "] ") or "", r.method, r.url)
    end
  end
  local env = require("slop.modules.rest.env")
  local d = require("slop.modules.rest.discover").get(root, true)
  local names = env.names(d.env_files)
  if #names > 0 then
    local keys, seen = {}, {}
    for _, f in ipairs(d.env_files) do
      for envname, tbl in pairs(require("slop.core.project").read_json(f) or {}) do
        if type(tbl) == "table" and envname then
          for k in pairs(tbl) do
            if not seen[k] then
              seen[k] = true
              keys[#keys + 1] = k
            end
          end
        end
      end
    end
    table.sort(keys)
    out[#out + 1] = ("Environments: %s; env variable NAMES available: %s"):format(
      table.concat(names, ", "),
      table.concat(keys, ", ")
    )
  end
  return M.redact(table.concat(out, "\n"), buf)
end

-- Output --------------------------------------------------------------------------------------------

--- Extract the http block from a model answer (first ```http / ```rest / ``` fence, else the whole text).
---@param text string
---@return string[]
function M.extract(text)
  text = (text or ""):gsub("\r", "")
  local block = text:match("```%s*http%s*\n(.-)\n```")
    or text:match("```%s*rest%s*\n(.-)\n```")
    or text:match("<slop:http>\n?(.-)\n?</slop:http>")
    or text:match("```[%w_-]*%s*\n(.-)\n```")
    or text
  local lines = vim.split(block, "\n", { plain = true })
  while #lines > 0 and lines[#lines]:match("^%s*$") do
    lines[#lines] = nil
  end
  while #lines > 0 and lines[1]:match("^%s*$") do
    table.remove(lines, 1)
  end
  return lines
end

-- Backend -------------------------------------------------------------------------------------------

---@param system string
---@param user string
---@param root string
---@param cb fun(text: string?, err: string?)
function M.ask(system, user, root, cb)
  local c = cfg().ai
  local progress
  pcall(function()
    progress = require("slop.core.ui.spinner").progress({ title = "slop rest", message = "asking AI…" })
  end)
  local function done(text, err)
    if progress then
      pcall(progress.finish, progress, err and "failed" or "success", err and "failed" or "done")
    end
    cb(text, err)
  end
  if c.backend == "acp" then
    local ok, err = pcall(M.ask_acp, system .. "\n\n" .. user, root, c.agent, done)
    if not ok then
      done(nil, tostring(err))
    end
    return
  end
  local ok, err = pcall(function()
    local ai = require("slop.core.registry").service("ai")
    ai.chat({
      provider = c.provider,
      system = system,
      messages = { { role = "user", content = user } },
      temperature = 0.2,
      stream = false,
      on_done = function(text, e)
        if e then
          return done(nil, type(e) == "table" and (e.message or vim.inspect(e)) or tostring(e))
        end
        done(text)
      end,
    })
  end)
  if not ok then
    done(nil, tostring(err))
  end
end

---@param prompt string
---@param root string
---@param agent string
---@param cb fun(text: string?, err: string?)
function M.ask_acp(prompt, root, agent, cb)
  local acp = require("slop.services.ai.acp")
  local client = acp.client({ agent = agent, cwd = root })
  local chunks = {}
  local function fail(e)
    cb(nil, type(e) == "table" and (e.message or vim.inspect(e)) or tostring(e))
  end
  -- new_session() starts the agent when needed; the default permission policy is read-only
  client:new_session({ cwd = root }, function(session, nerr)
    if not session then
      return fail(nerr or "no session")
    end
    session:prompt({ acp.text(prompt) }, {
      on_update = function(u)
        local up = type(u) == "table" and (u.update or u) or {}
        if up.sessionUpdate == "agent_message_chunk" then
          local text = acp.block_text and acp.block_text(up.content)
            or (type(up.content) == "table" and up.content.text)
          chunks[#chunks + 1] = text or ""
        end
      end,
      on_done = function(_, perr)
        pcall(session.close, session)
        if perr then
          return fail(perr)
        end
        cb(table.concat(chunks))
      end,
    })
  end)
end

-- Preview -------------------------------------------------------------------------------------------

--- Target buffer for generated requests: the current http buffer, else <root>/<cfg.ai.target>.
---@param root string
---@return integer buf, boolean created  created: a new buffer for a file that does not exist (yet)
function M.target_buf(root)
  local cur = api.nvim_get_current_buf()
  if vim.bo[cur].filetype == "http" then
    return cur, false
  end
  local path = vim.fs.joinpath(root, cfg().ai.target)
  local created = vim.fn.bufexists(path) == 0 and not vim.uv.fs_stat(path)
  local buf = vim.fn.bufadd(path)
  vim.fn.bufload(buf)
  vim.bo[buf].buflisted = true
  if vim.bo[buf].filetype ~= "http" then
    vim.bo[buf].filetype = "http"
  end
  return buf, created
end

---@param buf integer
local function show_buf(buf)
  if api.nvim_get_current_buf() ~= buf then
    local win = vim.fn.bufwinid(buf)
    if win ~= -1 then
      api.nvim_set_current_win(win)
    else
      api.nvim_win_set_buf(0, buf)
    end
  end
end

---@param lines string[]
---@param title string
---@param why? string  default: the answer contained no valid request
local function raw_output(lines, title, why)
  local scratch = require("slop.core.ui.scratch")
  local buf = scratch.open("rest/ai-output", { layout = "split", filetype = "markdown" })
  scratch.set_lines(buf, lines)
  log().notify(
    ("%s: %s (raw output shown)"):format(title, why or "the AI answer contained no valid request"),
    vim.log.levels.WARN
  )
end

---@param buf integer
---@param range {[1]: integer, [2]: integer}
---@param lines string[]
---@param title string
local function preview(buf, range, lines, title)
  show_buf(buf)
  local ok, handle = pcall(require("slop.core.ui.diff").show, buf, range, lines, { title = title })
  if not ok then
    log().notify("diff preview failed: " .. tostring(handle), vim.log.levels.ERROR)
    return
  end
  pcall(api.nvim_win_set_cursor, 0, { math.min(range[1] + 1, api.nvim_buf_line_count(buf)), 0 })
  return handle
end

-- gen -----------------------------------------------------------------------------------------------

---@class slop.rest.GenOpts
---@field mode? "desc"|"code"|"openapi"
---@field text? string                   description (desc) / extra instruction
---@field path? string                   OpenAPI file (openapi)
---@field range? {[1]: integer, [2]: integer}  1-based lines for code mode (visual / :range)

--- Build the user message for gen. Returns nil + err when the source is blocked.
---@param opts slop.rest.GenOpts
---@param src_buf integer
---@param target integer
---@param root string
---@return string? user, string? err
function M.gen_message(opts, src_buf, target, root)
  local secrets = require("slop.core.secrets")
  local project = require("slop.core.project")
  local parts = { "Project: " .. vim.fs.basename(root) }
  local summary = M.target_summary(target, root)
  if summary ~= "" then
    parts[#parts + 1] = summary
  end
  if opts.mode == "code" then
    if secrets.is_blocked(src_buf) then
      return nil, "this file is blocked by core.secrets; refusing to send it"
    end
    local path = api.nvim_buf_get_name(src_buf)
    local s, e
    if opts.range then
      s, e = opts.range[1] - 1, opts.range[2]
    else
      local row = api.nvim_win_get_cursor(0)[1] - 1
      local okts, scope = pcall(function()
        return require("slop.core.ts").scope(src_buf, { row, 0 }, { kinds = { "function", "method", "class" } })
      end)
      if okts and scope and scope.range then
        s, e = scope.range[1], scope.range[3] + 1
      else
        s, e = math.max(0, row - 50), math.min(api.nvim_buf_line_count(src_buf), row + 50)
      end
    end
    local lines = api.nvim_buf_get_lines(src_buf, s, e, false)
    lines = secrets.redact_lines(src_buf, lines, s)
    parts[#parts + 1] = ("Route handler code from %s (%s):"):format(
      project.relpath(path, root),
      vim.bo[src_buf].filetype
    )
    local hint = M.route_hint(path)
    if hint then
      parts[#parts + 1] = hint
    end
    -- a minified file is one huge line: the ±50 lines window alone is no size limit
    local code, cut = truncate(M.mask_text(table.concat(lines, "\n")), M.MAX_CONTEXT)
    if cut then
      log().warn("code context truncated to %d bytes", M.MAX_CONTEXT)
    end
    parts[#parts + 1] = "```" .. vim.bo[src_buf].filetype .. "\n" .. code .. "\n```"
    parts[#parts + 1] = "Generate requests for every endpoint/method this code handles."
      .. (opts.text and opts.text ~= "" and ("\nExtra instructions: " .. opts.text) or "")
  elseif opts.mode == "openapi" then
    local path = opts.path or api.nvim_buf_get_name(src_buf)
    if secrets.is_blocked(path) then
      return nil, "this file is blocked by core.secrets; refusing to send it"
    end
    local text
    local b = require("slop.modules.rest.discover").loaded_buf(vim.fs.normalize(path))
    if b then
      text = table.concat(api.nvim_buf_get_lines(b, 0, -1, false), "\n")
    else
      text = project.read_file(path)
    end
    if not text then
      return nil, "cannot read " .. path
    end
    local cut
    text, cut = truncate(text, M.MAX_CONTEXT)
    if cut then
      log().warn("OpenAPI file truncated to %d bytes", M.MAX_CONTEXT)
    end
    parts[#parts + 1] = ("OpenAPI specification (%s):"):format(project.relpath(path, root))
    parts[#parts + 1] = "```\n" .. M.redact(text, path) .. "\n```"
    parts[#parts + 1] = "Generate one request per operation."
      .. (opts.text and opts.text ~= "" and ("\nExtra instructions: " .. opts.text) or "")
  else
    parts[#parts + 1] = "Generate requests for: " .. M.redact(opts.text or "", nil)
  end
  return table.concat(parts, "\n\n")
end

--- Generate requests (see GenOpts). Without a mode: http buffer -> description prompt, OpenAPI file -> openapi,
--- other code -> the route handler under the cursor.
---@param opts? slop.rest.GenOpts
function M.gen(opts)
  opts = vim.deepcopy(opts or {})
  local src = api.nvim_get_current_buf()
  local root = require("slop.core.project").root(src)
  if not opts.mode then
    if vim.bo[src].filetype == "http" then
      opts.mode = "desc"
    elseif M.is_openapi(src) then
      opts.mode = "openapi"
    else
      opts.mode = "code"
    end
  end
  if opts.mode == "desc" and (not opts.text or opts.text == "") then
    return M.describe(function(text)
      opts.text = text
      M.gen(opts)
    end)
  end
  local target, created = M.target_buf(root)
  -- nothing generated: the buffer made for a missing target file goes again (unless the user started using it)
  local function discard()
    if
      created
      and api.nvim_buf_is_valid(target)
      and not vim.bo[target].modified
      and vim.fn.bufwinid(target) == -1
      and api.nvim_buf_line_count(target) == 1
      and api.nvim_buf_get_lines(target, 0, 1, false)[1] == ""
    then
      pcall(api.nvim_buf_delete, target, { force = true })
    end
  end
  local user, err = M.gen_message(opts, src, target, root)
  if not user then
    discard()
    log().notify(err --[[@as string]], vim.log.levels.ERROR)
    return
  end
  local system = "You write .http request files.\n" .. M.SYNTAX .. "\n" .. M.RULES
  M.ask(system, user, root, function(text, aerr)
    if aerr then
      discard()
      log().notify("AI request failed: " .. aerr, vim.log.levels.ERROR)
      return
    end
    local lines = M.extract(text or "")
    local parsed = require("slop.modules.rest.parser").parse(lines)
    if #parsed.requests == 0 then
      discard()
      return raw_output(vim.split(text or "", "\n", { plain = true }), "gen")
    end
    if not api.nvim_buf_is_valid(target) then
      return
    end
    local n = api.nvim_buf_line_count(target)
    local existing = api.nvim_buf_get_lines(target, 0, -1, false)
    local empty = #existing == 1 and existing[1] == ""
    if empty then
      return preview(target, { 0, 1 }, lines, "slop rest gen")
    end
    local new = {}
    if existing[#existing] ~= "" then
      new[1] = ""
    end
    vim.list_extend(new, lines)
    preview(target, { n, n }, new, "slop rest gen")
  end)
end

--- Ask for a description (core.ui.input, vim.ui.input fallback).
---@param cb fun(text: string)
function M.describe(cb)
  local ok = pcall(function()
    require("slop.core.ui.input").open({
      title = "Describe the requests to generate",
      history = "rest.gen",
      on_submit = function(text)
        if text and vim.trim(text) ~= "" then
          cb(text)
        end
      end,
    })
  end)
  if not ok then
    vim.ui.input({ prompt = "Describe the requests: " }, function(text)
      if text and vim.trim(text) ~= "" then
        cb(text)
      end
    end)
  end
end

-- fix -----------------------------------------------------------------------------------------------

--- Build the user message for fix from a result entry. Pure apart from reading the block / secrets.
---@param entry table {req, res?, err?}
---@param block string[]
---@param values? string[]  replaced by the placeholder wherever they appear (see secret_values())
---@return string
function M.fix_message(entry, block, values)
  local req = entry.req
  local parts = {}
  parts[#parts + 1] = "This request failed. Return the corrected request block (same title and @name)."
  parts[#parts + 1] = "Request block:\n```http\n" .. M.redact(table.concat(block, "\n"), req.file) .. "\n```"
  local warns = {}
  for _, w in ipairs(req.warnings or {}) do
    warns[#warns + 1] = ("line %d: %s"):format(w.lnum, w.msg)
  end
  if #warns > 0 then
    parts[#parts + 1] = "Parser warnings:\n" .. table.concat(warns, "\n")
  end
  if entry.err then
    parts[#parts + 1] = "Error: " .. M.redact(entry.err, req.file)
  end
  local res = entry.res
  if res then
    parts[#parts + 1] = ("Response status: %d %s"):format(res.status or 0, res.reason or "")
    parts[#parts + 1] = "Response headers:\n" .. M.redact(table.concat(M.mask_headers(res.headers), "\n"), nil)
    local body = truncate(res.body or "", M.MAX_BODY)
    if body ~= "" then
      parts[#parts + 1] = "Response body:\n" .. M.redact(body, nil)
    end
  end
  local text = table.concat(parts, "\n\n")
  for _, v in ipairs(values or {}) do
    text = text:gsub(vim.pesc(v), PLACEHOLDER)
  end
  return text
end

--- Fix the last failed request (or the request under the cursor using its last result).
function M.fix()
  local rest = require("slop.modules.rest.api")
  local last, failed = rest.results()
  local entry = failed
  if vim.bo.filetype == "http" then
    local cur = rest.request_at_cursor(0)
    if cur then
      local function same(e)
        if not (e and e.req and e.req.file == cur.file) then
          return false
        end
        -- untitled requests have no name: nil == nil must not make all of them "the same request"
        if e.req.name and cur.name then
          return e.req.name == cur.name
        end
        return e.req.line == cur.line
      end
      entry = (same(failed) and failed) or (same(last) and last) or { req = cur, err = "(not run yet)" }
    end
  end
  if not entry or not entry.req then
    log().notify("no failed request to fix", vim.log.levels.WARN)
    return
  end
  local req = entry.req
  if not req.file then
    log().notify("fix needs a request saved in a file", vim.log.levels.WARN)
    return
  end
  if require("slop.core.secrets").is_blocked(req.file) then
    -- the block would be sent as one <redacted> line and replaced with whatever the AI makes up
    log().notify("this file is blocked by core.secrets; refusing to send it", vim.log.levels.ERROR)
    return
  end
  -- re-locate the block in its (possibly edited) file
  local parsed = require("slop.modules.rest.discover").parse(req.file)
  for _, r in ipairs(parsed.requests) do
    if (req.name and r.name == req.name) or (not req.name and r.line == req.line) then
      req = r
      break
    end
  end
  local buf = vim.fn.bufadd(req.file)
  vim.fn.bufload(buf)
  local block = api.nvim_buf_get_lines(buf, req.start - 1, req.stop, false)
  local root = require("slop.core.project").root(buf)
  local user = M.fix_message(vim.tbl_extend("force", entry, { req = req }), block, M.secret_values(req.file, root))
  local system = "You fix .http requests.\n" .. M.SYNTAX .. "\n" .. M.RULES
  -- the buffer may be edited while the AI answers: track the block instead of trusting its line numbers
  local ns = require("slop.core.util").ns("rest.fix")
  local okm, mark = pcall(api.nvim_buf_set_extmark, buf, ns, req.start - 1, 0, {
    end_row = req.stop - 1,
    end_col = #(block[#block] or ""),
    invalidate = true,
  })
  M.ask(system, user, root, function(text, aerr)
    local range = { req.start - 1, req.stop }
    local gone = false
    if okm and api.nvim_buf_is_valid(buf) then
      local pos = api.nvim_buf_get_extmark_by_id(buf, ns, mark, { details = true })
      api.nvim_buf_del_extmark(buf, ns, mark)
      gone = not pos[1] or pos[3].invalid == true
      if not gone then
        range = { pos[1], pos[3].end_row + 1 }
      end
    end
    if aerr then
      log().notify("AI request failed: " .. aerr, vim.log.levels.ERROR)
      return
    end
    local lines = M.extract(text or "")
    if #require("slop.modules.rest.parser").parse(lines).requests == 0 then
      return raw_output(vim.split(text or "", "\n", { plain = true }), "fix")
    end
    if not api.nvim_buf_is_valid(buf) then
      return
    end
    if gone then
      return raw_output(vim.split(text or "", "\n", { plain = true }), "fix", "the request block was deleted meanwhile")
    end
    preview(buf, range, lines, "slop rest fix")
  end)
end

return M

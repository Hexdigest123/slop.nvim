--- Minimal ACP (Agent Client Protocol v1) client: JSON-RPC over stdio to agents in config `ai.agents`.
--- OWNER: edit. See research/01-avante-acp.md §8.
---
--- * One long-lived client per agent name, spawned lazily on the first start()/new_session() and respawned on
---   demand after it exits (acp/client.lua, transport in acp/rpc.lua).
--- * Client capabilities advertised: fs.readTextFile ONLY. The default handler (`acp.read_text_file`) serves live
---   buffers first, redacts with core.secrets and refuses blocked paths. No write/terminal capabilities
---   (agent requests for them get -32601).
--- * Permission requests without a turn handler go through `acp.decide()`: read/search/fetch/think allowed,
---   everything else rejected, always answering with the agent's own optionId.
---@class slop.acp
local M = {}

local api = vim.api

---@class slop.acp.ClientOpts
---@field agent string                    name in config ai.agents
---@field cwd? string                     default core.project.root()
---@field read_text_file? fun(params: {path: string, line?: integer, limit?: integer}): string?, (table|string)?
---@field on_exit? fun(code: integer, stderr_tail: string)

local clients = {} ---@type table<string, slop.acp.Client>
local leave_au ---@type integer?

local function agent_config(name)
  local ok, cfg = pcall(function()
    return require("slop.config").get("ai").agents[name]
  end)
  return ok and type(cfg) == "table" and cfg or nil
end

local function ensure_leave()
  if leave_au then
    return
  end
  leave_au = api.nvim_create_autocmd("VimLeavePre", {
    group = require("slop.core.util").augroup("acp"),
    desc = "slop: stop ACP agents",
    callback = function()
      for _, c in pairs(clients) do
        c.state = "stopped"
        c:_kill_now()
      end
    end,
  })
end

--- Shared long-lived client per agent name (spawned lazily on first start()). A client whose agent config
--- (cmd/env/auth_method) changed is stopped and replaced.
---@param opts slop.acp.ClientOpts|string
---@return slop.acp.Client
function M.client(opts)
  if type(opts) == "string" then
    opts = { agent = opts }
  end
  assert(type(opts.agent) == "string", "slop: acp.client needs opts.agent")
  local mod = require("slop.services.ai.acp.client")
  local cfg = agent_config(opts.agent)
  local fresh = mod.new(opts.agent, cfg, opts)
  local cur = clients[opts.agent]
  if cur and cur.signature == fresh.signature and cur.state ~= "stopped" then
    return cur
  end
  if cur then
    cur:stop()
  end
  if not fresh._opts.cwd then
    local ok, root = pcall(function()
      return require("slop.core.project").root()
    end)
    fresh._opts.cwd = ok and root or vim.fn.getcwd()
  end
  clients[opts.agent] = fresh
  ensure_leave()
  return fresh
end

--- Existing client for an agent (no spawn).
---@param agent string
---@return slop.acp.Client?
function M.get(agent)
  return clients[agent]
end

---@return slop.acp.Client[]
function M.clients()
  local out = {}
  for _, c in pairs(clients) do
    out[#out + 1] = c
  end
  table.sort(out, function(a, b)
    return a.agent < b.agent
  end)
  return out
end

--- Stop every agent process.
function M.stop_all()
  for name, c in pairs(clients) do
    c:stop()
    clients[name] = nil
  end
end

-- fs/read_text_file ----------------------------------------------------------------------------------

local MAX_READ = 4 * 1024 * 1024

local function buffer_for(path)
  for _, b in ipairs(api.nvim_list_bufs()) do
    if api.nvim_buf_is_loaded(b) then
      local name = api.nvim_buf_get_name(b)
      if name ~= "" and vim.fs.normalize(name) == path then
        return b
      end
    end
  end
end

--- Is `path` inside `root`? Symlinks are resolved for both, so a link can't escape the root.
---@param path string
---@param root string
---@return boolean
local function inside(path, root)
  local real = vim.uv.fs_realpath(path) or path
  local base = vim.uv.fs_realpath(root) or root
  base = base:gsub("/+$", "")
  return real == base or real:sub(1, #base + 1) == base .. "/"
end

--- Default `fs/read_text_file` handler: live buffer first (unsaved state), else disk; `line` is 1-based,
--- `limit` a line count. Redacted with core.secrets; blocked paths and paths outside `opts.root`
--- (default core.project.root()) are refused unless `opts.read_outside_root` is set.
---@param params {path: string, line?: integer, limit?: integer}
---@param opts? {root?: string, read_outside_root?: boolean}
---@return string? text, table? err
function M.read_text_file(params, opts)
  opts = opts or {}
  local path = params and params.path
  if type(path) ~= "string" or path == "" then
    return nil, { code = -32602, message = "path is required" }
  end
  path = vim.fs.normalize(path)
  if path:sub(1, 1) ~= "/" and not path:match("^%a:[/\\]") then
    return nil, { code = -32602, message = "path must be absolute: " .. path }
  end
  if not opts.read_outside_root then
    local root = opts.root or require("slop.core.project").root()
    if not inside(path, root) then
      return nil, { code = -32603, message = "slop: reading outside the project root is refused: " .. path }
    end
  end
  local secrets = require("slop.core.secrets")
  if secrets.is_blocked(path) then
    return nil, { code = -32603, message = "slop: reading this file is refused by the secrets policy: " .. path }
  end
  local lines
  local buf = buffer_for(path)
  if buf then
    lines = api.nvim_buf_get_lines(buf, 0, -1, false)
  else
    local stat = vim.uv.fs_stat(path)
    if not stat or stat.type ~= "file" then
      return nil, { code = -32002, message = "file not found: " .. path }
    end
    if stat.size > MAX_READ then
      return nil, { code = -32603, message = ("file too large (%d bytes): %s"):format(stat.size, path) }
    end
    local ok, read = pcall(vim.fn.readfile, path, "b")
    if not ok then
      return nil, { code = -32603, message = "cannot read " .. path }
    end
    lines = read
    for i, l in ipairs(lines) do
      lines[i] = l:gsub("\r$", "")
    end
    if lines[#lines] == "" then
      lines[#lines] = nil
    end
  end
  lines = secrets.redact_lines(path, lines, 0)
  local first = math.max(1, tonumber(params.line) or 1)
  local last = #lines
  if tonumber(params.limit) then
    last = math.min(last, first + math.max(0, math.floor(params.limit)) - 1)
  end
  return table.concat(vim.list_slice(lines, first, last), "\n")
end

-- Permissions ----------------------------------------------------------------------------------------

M.default_policy = { allow = { "read", "search", "fetch", "think" } }

local PATH_KEYS = {
  path = true,
  file_path = true,
  filePath = true,
  filepath = true,
  file = true,
  filename = true,
  abs_path = true,
  absolute_path = true,
  notebook_path = true,
}

--- File paths a tool call refers to (locations, diff content, common rawInput keys).
---@param tc table
---@return string[]
function M.tool_paths(tc)
  local out = {}
  if type(tc) ~= "table" then
    return out
  end
  for _, loc in ipairs(type(tc.locations) == "table" and tc.locations or {}) do
    if type(loc) == "table" and type(loc.path) == "string" then
      out[#out + 1] = loc.path
    end
  end
  for _, c in ipairs(type(tc.content) == "table" and tc.content or {}) do
    if type(c) == "table" and c.type == "diff" and type(c.path) == "string" then
      out[#out + 1] = c.path
    end
  end
  local raw = tc.rawInput
  if type(raw) == "table" then
    for k, v in pairs(raw) do
      if PATH_KEYS[k] and type(v) == "string" then
        out[#out + 1] = v
      elseif (k == "paths" or k == "files") and type(v) == "table" then
        for _, p in ipairs(v) do
          if type(p) == "string" then
            out[#out + 1] = p
          end
        end
      end
    end
  end
  return out
end

local function pick(options, verdict)
  local prefer = verdict == "allow" and { "allow_once", "allow_always" } or { "reject_once", "reject_always" }
  for _, kind in ipairs(prefer) do
    for _, o in ipairs(type(options) == "table" and options or {}) do
      if type(o) == "table" and o.kind == kind and o.optionId ~= nil then
        return o.optionId
      end
    end
  end
end

--- Decide a `session/request_permission` request. Returns the agent's own optionId (nil = answer "cancelled"),
--- the verdict and a human-readable reason.
---@param req {toolCall?: table, options?: table[]}
---@param policy? {allow?: string[]}
---@return string? option_id, "allow"|"reject" verdict, string reason
function M.decide(req, policy)
  policy = policy or M.default_policy
  local tc = type(req) == "table" and type(req.toolCall) == "table" and req.toolCall or {}
  local kind = type(tc.kind) == "string" and tc.kind or "other"
  local allowed = {}
  for _, k in ipairs(policy.allow or {}) do
    allowed[k] = true
  end
  local verdict, reason = "reject", ("tool kind '%s' is not allowed"):format(kind)
  if allowed[kind] then
    verdict, reason = "allow", ("tool kind '%s' is allowed"):format(kind)
    local secrets = require("slop.core.secrets")
    for _, p in ipairs(M.tool_paths(tc)) do
      if secrets.is_blocked(p) then
        verdict, reason = "reject", "blocked file: " .. p
        break
      end
    end
  end
  return pick(req and req.options, verdict), verdict, reason
end

-- Content blocks ---------------------------------------------------------------------------------------

---@param text string
---@return table
function M.text(text)
  return { type = "text", text = text }
end

---@param uri string
---@param text string
---@param mime? string
---@return table
function M.resource(uri, text, mime)
  return { type = "resource", resource = { uri = uri, text = text, mimeType = mime or "text/plain" } }
end

---@param uri string
---@param name? string
---@return table
function M.resource_link(uri, name)
  return { type = "resource_link", uri = uri, name = name or vim.fs.basename(uri) }
end

--- Concatenated text of a ContentBlock (text blocks; resource text), "" otherwise.
---@param block table?
---@return string
function M.block_text(block)
  if type(block) ~= "table" then
    return ""
  end
  if block.type == "text" and type(block.text) == "string" then
    return block.text
  end
  if block.type == "resource" and type(block.resource) == "table" and type(block.resource.text) == "string" then
    return block.resource.text
  end
  return ""
end

return M

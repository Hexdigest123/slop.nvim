--- AI service: providers (HTTP FIM/chat), context, ACP agents. OWNER: complete (acp/: edit).
--- Defaults, API-key resolution (`api_key()`) and health() come from the skeleton.
---
--- Callers MUST redact every text they put into a request with core.secrets before calling.
---
--- API-key resolution for provider <p> (see `M.api_key`):
---   1. `api_key = function() return "..." end`  -> its return value
---   2. `api_key = "SOME_ENV_VAR"`               -> os.getenv("SOME_ENV_VAR")   (strings are ALWAYS env var
---                                                  names; literal keys in config are rejected)
---   3. `api_key = false`                        -> no key (local servers: ollama, llama.cpp)
---   4. `api_key` unset                          -> os.getenv(<SERVICE>_API_KEY) with SERVICE = upper(p.service)
---                                                  e.g. service = "mistral" -> MISTRAL_API_KEY
---@class slop.ai: slop.ServiceSpec
local M = {
  name = "ai",
  description = "AI providers (FIM/chat over HTTP), context gathering and ACP agents",
  open_keys = { "providers", "agents" },
}

---@class slop.ai.ProviderConfig
---@field kind "fim"|"chat"
---@field service string                  "mistral"|"openai"|"anthropic"|"gemini"|"deepseek"|"openrouter"|"ollama"|...
---@field url string
---@field model string
---@field api_key? string|false|fun(): string?  see resolution rules above
---@field format? string                  request/response dialect (provider adapter name), default from service
---@field params? table                   extra body params merged into the request body (top_p, reasoning, ...)
---@field headers? table<string, string>  extra request headers
---@field transform? fun(req: slop.http.Request, info: {name: string?, kind: string, provider: slop.ai.ProviderConfig}): slop.http.Request?
---@field fim_template? false|"qwen"|"deepseek"|"codellama"|"starcoder"|"codestral"|fun(prompt: string, suffix: string): string
---@field chat_fim? table                 chat-model FIM prompt overrides (see services/ai/chat_fim.lua)
---@field stream? boolean                 false disables streaming for this provider
---@field timeout? integer                ms, default per request
---@field name? string                    display name

---@class slop.ai.AgentConfig
---@field cmd string[]
---@field env? table<string, string>

M.defaults = {
  providers = {
    codestral = {
      kind = "fim",
      service = "mistral",
      url = "https://api.mistral.ai/v1/fim/completions",
      model = "codestral-latest",
    },
    mistral_chat = {
      kind = "chat",
      service = "mistral",
      url = "https://api.mistral.ai/v1/chat/completions",
      model = "codestral-latest",
    },
  },
  agents = {
    vibe = { cmd = { "vibe-acp" } },
    opencode = { cmd = { "opencode", "acp" } },
    claude = { cmd = { "claude-agent-acp" } },
  },
}

function M.schema(cfg, check)
  check("providers", cfg.providers, "table")
  check("agents", cfg.agents, "table")
  for name, p in pairs(cfg.providers or {}) do
    local pre = "providers." .. name
    check(pre, p, "table")
    if type(p) == "table" then
      check(pre .. ".kind", p.kind, function(v)
        return v == "fim" or v == "chat"
      end, false, "'fim'|'chat'")
      check(pre .. ".url", p.url, "string")
      check(pre .. ".model", p.model, "string")
      check(pre .. ".service", p.service, "string", true)
      check(pre .. ".api_key", p.api_key, function(v)
        return v == nil or v == false or type(v) == "function" or (type(v) == "string" and v:match("^[%a_][%w_]*$"))
      end, false, "env var name|function|false")
      check(pre .. ".format", p.format, "string", true)
      check(pre .. ".params", p.params, "table", true)
      check(pre .. ".headers", p.headers, "table", true)
      check(pre .. ".transform", p.transform, "function", true)
      check(pre .. ".chat_fim", p.chat_fim, "table", true)
      check(pre .. ".stream", p.stream, "boolean", true)
      check(pre .. ".timeout", p.timeout, "number", true)
      check(pre .. ".name", p.name, "string", true)
      check(pre .. ".fim_template", p.fim_template, function(v)
        return v == nil
          or v == false
          or type(v) == "function"
          or (type(v) == "string" and require("slop.services.ai.providers").fim_templates[v] ~= nil)
      end, false, "false|'qwen'|'deepseek'|'codellama'|'starcoder'|'codestral'|function")
    end
  end
  for name, a in pairs(cfg.agents or {}) do
    check("agents." .. name .. ".cmd", type(a) == "table" and a.cmd or nil, "table")
  end
end

local function cfg()
  return require("slop.config").get("ai")
end

--- Resolved provider config.
---@param name string
---@return slop.ai.ProviderConfig?
function M.provider(name)
  return cfg().providers[name]
end

--- Sorted provider names (optionally of one kind).
---@param kind? "fim"|"chat"
---@return string[]
function M.providers(kind)
  local out = {}
  for name, p in pairs(cfg().providers) do
    if not kind or p.kind == kind then
      out[#out + 1] = name
    end
  end
  table.sort(out)
  return out
end

---@param name string
---@return slop.ai.AgentConfig?
function M.agent(name)
  return cfg().agents[name]
end

--- Where a provider's key comes from: "env" + var name, "function", or "none".
---@param p slop.ai.ProviderConfig
---@return "env"|"function"|"none" source, string? var
function M.api_key_source(p)
  local k = p.api_key
  if type(k) == "function" then
    return "function"
  elseif k == false then
    return "none"
  elseif type(k) == "string" then
    return "env", k
  elseif type(p.service) == "string" and p.service ~= "" then
    return "env", p.service:upper():gsub("[^%w]", "_") .. "_API_KEY"
  end
  return "none"
end

--- Resolve a provider's API key (never log the result).
---@param name_or_cfg string|slop.ai.ProviderConfig
---@return string? key, string? err
function M.api_key(name_or_cfg)
  local p = type(name_or_cfg) == "table" and name_or_cfg or M.provider(name_or_cfg --[[@as string]])
  if not p then
    return nil, "unknown provider " .. tostring(name_or_cfg)
  end
  local source, var = M.api_key_source(p)
  if source == "function" then
    local ok, key = pcall(p.api_key)
    if not ok then
      return nil, "api_key function failed: " .. tostring(key)
    end
    if type(key) ~= "string" or key == "" then
      return nil, "api_key function returned no key"
    end
    return key
  elseif source == "env" then
    local key = os.getenv(var --[[@as string]])
    if key and key ~= "" then
      return key
    end
    return nil, ("$%s is not set"):format(var)
  end
  return nil
end

---@class slop.ai.FimRequest
---@field provider? string|slop.ai.ProviderConfig  provider name (or an inline config)
---@field prompt string                   text before the cursor (already redacted)
---@field suffix string                   text after the cursor (already redacted)
---@field max_tokens? integer
---@field stop? string[]
---@field temperature? number
---@field n? integer                      candidates (openai `n`; chat-FIM alternatives)
---@field timeout? integer                ms
---@field stream? boolean                 default true
---@field filetype? string                hint for chat-FIM prompts
---@field indent? string                  hint for chat-FIM prompts ("Indentation: 2 spaces")
---@field on_chunk? fun(delta: string, text: string)  streamed text (first candidate), main loop
---@field on_done fun(items: string[]?, err: slop.ai.Error?)  exactly once; on timeout the partial text is passed too

---@class slop.ai.ChatMessage
---@field role "system"|"user"|"assistant"
---@field content string                  already redacted

---@class slop.ai.ChatRequest
---@field provider? string|slop.ai.ProviderConfig
---@field messages slop.ai.ChatMessage[]
---@field system? string                  prepended system prompt
---@field max_tokens? integer
---@field temperature? number
---@field stop? string[]
---@field timeout? integer
---@field stream? boolean                 default: true when on_chunk is given
---@field on_chunk? fun(delta: string, text: string)
---@field on_done fun(text: string?, err: slop.ai.Error?)  exactly once; on timeout the partial text is passed too

---@class slop.ai.Error : slop.http.Error
---@field kind "timeout"|"cancelled"|"curl"|"http"|"spawn"|"decode"|"config"

local function dead_handle()
  return {
    id = 0,
    cancel = function() end,
    is_active = function()
      return false
    end,
  }
end

local function fail(cb, kind, message)
  vim.schedule(function()
    cb(nil, { kind = kind, message = message })
  end)
  return dead_handle()
end

local function slog()
  return require("slop.core.log").scope("ai")
end

---@param kind "fim"|"chat"
---@param req table
---@param finish fun(text: string?, items: string[]?, err: slop.ai.Error?)
---@param on_text? fun(delta: string, text: string)
---@return slop.http.Handle
local function run(kind, req, finish, on_text)
  local providers = require("slop.services.ai.providers")
  local pname = type(req.provider) == "string" and req.provider or nil
  local p = type(req.provider) == "table" and req.provider or (pname and M.provider(pname))
  local cb = function(_, err)
    finish(nil, nil, err)
  end
  if not p then
    return fail(cb, "config", ("unknown AI provider %s"):format(vim.inspect(req.provider)))
  end
  local label = pname or p.name or p.model or "provider"
  local format = providers.format(p)
  local adapter = providers.get(format)
  if not adapter then
    return fail(cb, "config", ("provider %s: unknown format %q"):format(label, format))
  end
  local key, kerr = M.api_key(p)
  if not key and M.api_key_source(p) ~= "none" then
    return fail(cb, "config", ("provider %s: %s"):format(label, kerr or "no API key"))
  end

  -- FIM through a chat model
  local chat_fim = kind == "fim" and p.kind == "chat"
  local akind = chat_fim and "chat" or kind
  if not adapter[akind] then
    return fail(cb, "config", ("provider %s (%s) does not support %s"):format(label, format, akind))
  end
  local stream
  if kind == "fim" then
    stream = req.stream ~= false
  else
    stream = req.stream == true or (req.stream == nil and req.on_chunk ~= nil)
  end
  stream = stream and p.stream ~= false
  local areq = vim.tbl_extend("force", {}, req, { stream = stream })
  if chat_fim then
    local cf = require("slop.services.ai.chat_fim")
    areq = {
      messages = cf.messages(p, req),
      max_tokens = req.max_tokens,
      temperature = req.temperature,
      stream = stream,
    }
  end
  local hreq = adapter[akind](p, areq, key)
  if type(hreq.body) == "table" then
    providers.compact(hreq.body)
    if type(p.params) == "table" then
      hreq.body = vim.tbl_deep_extend("force", hreq.body, p.params)
    end
  end
  if type(p.headers) == "table" then
    hreq.headers = vim.tbl_extend("force", hreq.headers or {}, p.headers)
  end
  hreq.timeout = req.timeout or p.timeout or 30000
  hreq.name = "ai:" .. label
  if type(p.transform) == "function" then
    local ok, r = pcall(p.transform, hreq, { name = pname, kind = akind, provider = p })
    if not ok then
      return fail(cb, "config", ("provider %s: transform failed: %s"):format(label, r))
    end
    hreq = r or hreq
  end

  local acc = {}
  local text = ""
  local stream_err
  local shown = ""
  local t0 = vim.uv.hrtime()
  if stream then
    hreq.stream = adapter.stream_mode or "sse"
    hreq.on_chunk = function(chunk)
      local delta, _, emsg = adapter.delta(chunk, akind)
      if emsg then
        stream_err = emsg
      end
      if not delta then
        return
      end
      acc[#acc + 1] = delta
      text = text .. delta
      if on_text then
        if chat_fim then
          local first = require("slop.services.ai.chat_fim").first_partial(text)
          if #first > #shown and first:sub(1, #shown) == shown then
            local d = first:sub(#shown + 1)
            shown = first
            on_text(d, first)
          end
        else
          on_text(delta, text)
        end
      end
    end
  else
    hreq.stream = nil
  end
  hreq.on_done = function(res, err)
    local ms = (vim.uv.hrtime() - t0) / 1e6
    if err then
      if err.response then
        local body = err.response:json()
        local msg = (adapter.error_message or providers.error_message)(body)
        if msg then
          err.message = ("%s: %s"):format(err.message, msg)
        end
      end
      if err.kind ~= "cancelled" then
        slog().debug("%s %s failed after %.0f ms: %s", label, kind, ms, err.message)
      end
      local partial = (err.kind == "timeout" and text ~= "") and text or nil
      local items = partial and (chat_fim and require("slop.services.ai.chat_fim").parse(partial) or { partial }) or nil
      return finish(partial, items, err)
    end
    if stream_err then
      return finish(nil, nil, { kind = "http", message = stream_err })
    end
    local items
    if not stream then
      local body, derr = res:json()
      if body == nil then
        return finish(nil, nil, { kind = "decode", message = "invalid JSON response: " .. tostring(derr) })
      end
      if akind == "chat" then
        text = adapter.parse_chat(body) or ""
      else
        items = adapter.parse_fim(body) or {}
        text = items[1] or ""
      end
    end
    if chat_fim then
      items = require("slop.services.ai.chat_fim").parse(text)
    elseif kind == "fim" then
      items = items or { text }
    end
    slog().debug("%s %s done in %.0f ms (%d chars)", label, kind, ms, #text)
    finish(text, items, nil)
  end
  return require("slop.core.http").request(hreq)
end

--- Fill-in-the-middle completion. A provider with kind = "chat" is driven through chat-FIM prompting.
---@param req slop.ai.FimRequest
---@return slop.http.Handle
function M.complete_fim(req)
  assert(type(req) == "table" and type(req.on_done) == "function", "slop: ai.complete_fim needs on_done")
  return run("fim", req, function(_, items, err)
    req.on_done(items, err)
  end, req.on_chunk)
end

--- Chat completion (one-shot or streamed).
---@param req slop.ai.ChatRequest
---@return slop.http.Handle
function M.chat(req)
  assert(type(req) == "table" and type(req.on_done) == "function", "slop: ai.chat needs on_done")
  return run("chat", req, function(text, _, err)
    req.on_done(text, err)
  end, req.on_chunk)
end

function M.health()
  local h = vim.health
  local c = cfg()
  local names = vim.tbl_keys(c.providers)
  table.sort(names)
  for _, name in ipairs(names) do
    local p = c.providers[name]
    local source, var = M.api_key_source(p)
    local label = ("provider `%s` (%s, %s)"):format(name, tostring(p.kind), tostring(p.service))
    if source == "env" then
      local set = os.getenv(var --[[@as string]])
      if set and set ~= "" then
        h.ok(("%s: key from $%s (set)"):format(label, var))
      else
        h.warn(("%s: key from $%s (NOT set)"):format(label, var), {
          ('export %s=... or set ai.providers.%s.api_key = "OTHER_ENV_VAR" | function'):format(var, name),
        })
      end
    elseif source == "function" then
      h.ok(label .. ": key from api_key function")
    else
      h.info(label .. ": no API key configured")
    end
  end
  local agents = vim.tbl_keys(c.agents)
  table.sort(agents)
  for _, name in ipairs(agents) do
    local cmd = c.agents[name].cmd
    local exe = type(cmd) == "table" and cmd[1] or nil
    if exe and vim.fn.executable(exe) == 1 then
      h.ok(("agent `%s`: `%s` found"):format(name, exe))
    else
      h.info(("agent `%s`: `%s` not found in $PATH"):format(name, tostring(exe)))
    end
  end
end

return M

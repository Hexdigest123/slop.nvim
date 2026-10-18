--# selene: allow(unused_variable)
--- AI service: providers (HTTP FIM/chat), context, ACP agents. OWNER: complete (acp/: edit).
--- STATUS: stub. Implemented by the skeleton: defaults, API-key resolution (`api_key()`), health().
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
---@field format? string                  request/response dialect (provider adapter name), default = service
---@field params? table                   extra body params (temperature, top_p, ...)

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
---@field provider? string                default: caller's module config
---@field prompt string                   text before the cursor (already redacted)
---@field suffix string                   text after the cursor (already redacted)
---@field max_tokens? integer
---@field stop? string[]
---@field temperature? number
---@field n? integer                      candidates
---@field timeout? integer                ms
---@field stream? boolean
---@field on_chunk? fun(delta: string)    streamed text
---@field on_done fun(items: string[]?, err: slop.http.Error|string?)

---@class slop.ai.ChatMessage
---@field role "system"|"user"|"assistant"
---@field content string                  already redacted

---@class slop.ai.ChatRequest
---@field provider? string
---@field messages slop.ai.ChatMessage[]
---@field max_tokens? integer
---@field temperature? number
---@field timeout? integer
---@field stream? boolean
---@field on_chunk? fun(delta: string)
---@field on_done fun(text: string?, err: slop.http.Error|string?)

--- Fill-in-the-middle completion.
---@param req slop.ai.FimRequest
---@return slop.http.Handle
function M.complete_fim(req)
  error("slop: services.ai.complete_fim not implemented yet", 2)
end

--- Chat completion (one-shot or streamed).
---@param req slop.ai.ChatRequest
---@return slop.http.Handle
function M.chat(req)
  error("slop: services.ai.chat not implemented yet", 2)
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

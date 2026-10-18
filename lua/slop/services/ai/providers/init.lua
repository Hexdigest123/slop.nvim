--- Provider adapters: turn slop.ai requests into core.http requests and parse responses. OWNER: complete.
---
--- One file per dialect (providers/<format>.lua): mistral, openai, anthropic, gemini, llamacpp. `format` defaults to
--- a dialect derived from the provider's `service` (see `M.format`). Users can register their own adapter.
---@class slop.ai.providers
local M = {}

---@class slop.ai.Adapter
---@field fim? fun(p: slop.ai.ProviderConfig, req: slop.ai.FimRequest, key: string?): slop.http.Request
---@field chat? fun(p: slop.ai.ProviderConfig, req: slop.ai.ChatRequest, key: string?): slop.http.Request
---@field parse_fim? fun(body: table): string[]           non-streamed response -> candidates
---@field parse_chat? fun(body: table): string
---@field delta? fun(chunk: slop.http.SseEvent|table, kind: "fim"|"chat"): string?, boolean?, string?
---       streamed chunk -> text delta (nil = none), done?, error message?
---@field stream_mode? slop.http.StreamMode              default "sse"
---@field error_message? fun(body: table): string?      error text from an error response body

local custom = {} ---@type table<string, slop.ai.Adapter>

--- Built-in dialect for each known service.
M.service_format = {
  mistral = "mistral",
  codestral = "mistral",
  openai = "openai",
  openrouter = "openai",
  deepseek = "openai",
  ollama = "openai",
  groq = "openai",
  together = "openai",
  fireworks = "openai",
  opencode = "openai",
  inception = "openai",
  siliconflow = "openai",
  lmstudio = "openai",
  anthropic = "anthropic",
  claude = "anthropic",
  gemini = "gemini",
  google = "gemini",
  llamacpp = "llamacpp",
}

local builtin = { mistral = true, openai = true, anthropic = true, gemini = true, llamacpp = true }

--- Dialect name of a provider config.
---@param p slop.ai.ProviderConfig
---@return string
function M.format(p)
  if type(p.format) == "string" and p.format ~= "" then
    return p.format
  end
  return M.service_format[p.service or ""] or "openai"
end

--- Adapter for a dialect name.
---@param format string
---@return slop.ai.Adapter?
function M.get(format)
  if custom[format] then
    return custom[format]
  end
  if builtin[format] then
    return require("slop.services.ai.providers." .. format)
  end
  return nil
end

--- Register a custom adapter (user extension point).
---@param format string
---@param adapter slop.ai.Adapter
function M.register(format, adapter)
  assert(type(format) == "string" and type(adapter) == "table", "slop: providers.register(format, adapter)")
  custom[format] = adapter
end

--- Registered + built-in dialect names.
---@return string[]
function M.formats()
  local out = vim.tbl_keys(builtin)
  for k in pairs(custom) do
    if not builtin[k] then
      out[#out + 1] = k
    end
  end
  table.sort(out)
  return out
end

-- Shared helpers for adapters --------------------------------------------------------------------

--- Remove nil-ish values (vim.NIL) from a shallow table.
---@param t table
---@return table
function M.compact(t)
  for k, v in pairs(t) do
    if v == vim.NIL then
      t[k] = nil
    end
  end
  return t
end

--- Common error extraction: {error = {message}} | {error = "x"} | {message} | {detail}.
---@param body any
---@return string?
function M.error_message(body)
  if type(body) ~= "table" then
    return nil
  end
  local e = body.error
  if type(e) == "table" and type(e.message) == "string" then
    return e.message
  elseif type(e) == "string" then
    return e
  end
  if type(body.message) == "string" then
    return body.message
  end
  local d = body.detail
  if type(d) == "string" then
    return d
  elseif type(d) == "table" then
    local first = d[1]
    if type(first) == "table" and first.msg then
      return tostring(first.msg)
    end
    return vim.inspect(d)
  end
  return nil
end

--- Raw FIM prompt templates for models whose endpoint has no `suffix` field.
---@type table<string, fun(prompt: string, suffix: string): string>
M.fim_templates = {
  qwen = function(p, s)
    return "<|fim_prefix|>" .. p .. "<|fim_suffix|>" .. s .. "<|fim_middle|>"
  end,
  deepseek = function(p, s)
    return "<｜fim▁begin｜>" .. p .. "<｜fim▁hole｜>" .. s .. "<｜fim▁end｜>"
  end,
  codellama = function(p, s)
    return "<PRE> " .. p .. " <SUF>" .. s .. " <MID>"
  end,
  starcoder = function(p, s)
    return "<fim_prefix>" .. p .. "<fim_suffix>" .. s .. "<fim_middle>"
  end,
  codestral = function(p, s)
    return "[SUFFIX]" .. s .. "[PREFIX]" .. p
  end,
}

--- Resolve a provider's fim_template option to a function (nil = endpoint takes prompt + suffix).
---@param p slop.ai.ProviderConfig
---@return (fun(prompt: string, suffix: string): string)?
function M.fim_template(p)
  local t = p.fim_template
  if type(t) == "function" then
    return t
  elseif type(t) == "string" then
    return M.fim_templates[t]
  end
  return nil
end

--- Body fields shared by OpenAI-style FIM endpoints.
---@param p slop.ai.ProviderConfig
---@param req slop.ai.FimRequest
---@return table
function M.fim_body(p, req)
  local tpl = M.fim_template(p)
  local body = {
    model = p.model,
    prompt = tpl and tpl(req.prompt, req.suffix or "") or req.prompt,
    suffix = (not tpl) and req.suffix or nil,
    max_tokens = req.max_tokens,
    stop = req.stop and #req.stop > 0 and req.stop or nil,
    temperature = req.temperature,
    stream = req.stream ~= false,
  }
  return body
end

---@param messages slop.ai.ChatMessage[]
---@param system? string
---@return string? system, slop.ai.ChatMessage[] rest
function M.split_system(messages, system)
  local sys = { system }
  local rest = {}
  for _, m in ipairs(messages or {}) do
    if m.role == "system" then
      sys[#sys + 1] = m.content
    else
      rest[#rest + 1] = { role = m.role, content = m.content }
    end
  end
  local s = table.concat(
    vim.tbl_filter(function(x)
      return type(x) == "string" and x ~= ""
    end, sys),
    "\n\n"
  )
  return s ~= "" and s or nil, rest
end

---@param key string?
---@return table
function M.bearer(key)
  local hdr = { ["Content-Type"] = "application/json", Accept = "application/json" }
  if key then
    hdr.Authorization = "Bearer " .. key
  end
  return hdr
end

return M

--- OpenAI-compatible dialect: chat (/v1/chat/completions) and FIM (/v1/completions with prompt + suffix).
--- Serves openai, openrouter, deepseek (beta FIM), ollama, groq, lmstudio, ... OWNER: complete.
local P = require("slop.services.ai.providers")

---@type slop.ai.Adapter
local M = {}

function M.fim(p, req, key)
  local body = P.fim_body(p, req)
  if req.n and req.n > 1 then
    body.n = req.n
  end
  return { url = p.url, method = "POST", headers = P.bearer(key), body = body }
end

function M.chat(p, req, key)
  local system, rest = P.split_system(req.messages, req.system)
  local messages = {}
  if system then
    messages[1] = { role = "system", content = system }
  end
  vim.list_extend(messages, rest)
  local body = {
    model = p.model,
    messages = messages,
    temperature = req.temperature,
    stop = req.stop and #req.stop > 0 and req.stop or nil,
    stream = req.stream ~= false,
  }
  if p.service == "openai" then
    -- api.openai.com: reasoning models (o-series, gpt-5) reject max_tokens; every chat model takes this one
    body.max_completion_tokens = req.max_tokens
  else
    body.max_tokens = req.max_tokens
  end
  return { url = p.url, method = "POST", headers = P.bearer(key), body = body }
end

local function choice_text(c)
  if type(c) ~= "table" then
    return nil
  end
  if type(c.text) == "string" then
    return c.text
  end
  local m = c.message or c.delta
  if type(m) ~= "table" then
    return nil
  end
  if type(m.content) == "string" then
    return m.content
  end
  -- Reasoning models (e.g. Mistral's zai-glm, magistral) send content as chunks:
  -- { {type="thinking", thinking={...}}, {type="text", text="..."} }. Keep only the text.
  if type(m.content) == "table" then
    local parts = {}
    for _, chunk in ipairs(m.content) do
      if type(chunk) == "table" and chunk.type == "text" and type(chunk.text) == "string" then
        parts[#parts + 1] = chunk.text
      end
    end
    return #parts > 0 and table.concat(parts) or nil
  end
  return nil
end

function M.parse_fim(body)
  local out = {}
  for _, c in ipairs(type(body) == "table" and body.choices or {}) do
    local t = choice_text(c)
    if t then
      out[#out + 1] = t
    end
  end
  return out
end

function M.parse_chat(body)
  local c = type(body) == "table" and body.choices and body.choices[1]
  return choice_text(c) or ""
end

function M.delta(ev)
  local data = type(ev) == "table" and ev.data or ev
  if data == "[DONE]" then
    return nil, true
  end
  local ok, obj = pcall(vim.json.decode, data, { luanil = { object = true, array = true } })
  if not ok or type(obj) ~= "table" then
    return nil
  end
  if obj.error then
    return nil, true, P.error_message(obj)
  end
  -- with n > 1 the chunks of every candidate arrive interleaved, each with its index: stream the first candidate
  local c
  for _, x in ipairs(type(obj.choices) == "table" and obj.choices or {}) do
    if type(x) == "table" and (x.index == nil or x.index == 0) then
      c = x
      break
    end
  end
  local text = choice_text(c)
  local done = type(c) == "table" and c.finish_reason ~= nil and c.finish_reason ~= vim.NIL or nil
  return text ~= "" and text or nil, done
end

M.error_message = P.error_message

return M

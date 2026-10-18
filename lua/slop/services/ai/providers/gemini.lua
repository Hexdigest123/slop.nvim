--- Google Gemini dialect (generativelanguage v1beta: :generateContent / :streamGenerateContent?alt=sse,
--- x-goog-api-key, systemInstruction, contents with roles user/model). OWNER: complete.
local P = require("slop.services.ai.providers")

---@type slop.ai.Adapter
local M = {}

M.base_url = "https://generativelanguage.googleapis.com/v1beta/models"

--- Full endpoint for a provider: url may be the models base (model + method appended) or a full method url.
---@param p slop.ai.ProviderConfig
---@param stream boolean
---@return string
function M.endpoint(p, stream)
  local url = (p.url and p.url ~= "") and p.url or M.base_url
  if url:find(":generateContent", 1, true) or url:find(":streamGenerateContent", 1, true) then
    return url
  end
  url = url:gsub("/+$", "")
  if stream then
    return ("%s/%s:streamGenerateContent?alt=sse"):format(url, p.model)
  end
  return ("%s/%s:generateContent"):format(url, p.model)
end

function M.chat(p, req, key)
  local system, rest = P.split_system(req.messages, req.system)
  local contents = {}
  for _, m in ipairs(rest) do
    contents[#contents + 1] = { role = m.role == "assistant" and "model" or "user", parts = { { text = m.content } } }
  end
  local gen = {
    maxOutputTokens = req.max_tokens,
    temperature = req.temperature,
    stopSequences = req.stop and #req.stop > 0 and req.stop or nil,
  }
  local headers = { ["Content-Type"] = "application/json", Accept = "application/json" }
  if key then
    headers["x-goog-api-key"] = key
  end
  return {
    url = M.endpoint(p, req.stream ~= false),
    method = "POST",
    headers = headers,
    body = {
      systemInstruction = system and { parts = { { text = system } } } or nil,
      contents = contents,
      generationConfig = next(gen) and gen or nil,
    },
  }
end

local function text_of(obj)
  local c = type(obj) == "table" and obj.candidates and obj.candidates[1]
  local parts = type(c) == "table" and type(c.content) == "table" and c.content.parts or {}
  local out = {}
  for _, part in ipairs(parts) do
    if type(part) == "table" and type(part.text) == "string" and not part.thought then
      out[#out + 1] = part.text
    end
  end
  return table.concat(out), c
end

function M.parse_chat(body)
  return (text_of(body))
end

function M.delta(ev)
  local ok, obj = pcall(vim.json.decode, ev.data, { luanil = { object = true, array = true } })
  if not ok or type(obj) ~= "table" then
    return nil
  end
  if obj.error then
    return nil, true, P.error_message(obj)
  end
  local text, c = text_of(obj)
  local done = type(c) == "table" and c.finishReason ~= nil and c.finishReason ~= vim.NIL or nil
  return text ~= "" and text or nil, done
end

M.error_message = P.error_message

return M

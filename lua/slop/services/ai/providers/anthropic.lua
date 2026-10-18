--- Anthropic Messages API dialect (/v1/messages; x-api-key, anthropic-version, top-level system, max_tokens).
--- OWNER: complete.
local P = require("slop.services.ai.providers")

---@type slop.ai.Adapter
local M = {}

M.version = "2023-06-01"

function M.chat(p, req, key)
  local system, rest = P.split_system(req.messages, req.system)
  local headers = {
    ["Content-Type"] = "application/json",
    Accept = "application/json",
    ["anthropic-version"] = M.version,
  }
  if key then
    headers["x-api-key"] = key
  end
  return {
    url = p.url,
    method = "POST",
    headers = headers,
    body = {
      model = p.model,
      system = system,
      messages = rest,
      max_tokens = req.max_tokens or 1024,
      temperature = req.temperature,
      stop_sequences = req.stop and #req.stop > 0 and req.stop or nil,
      stream = req.stream ~= false,
    },
  }
end

function M.parse_chat(body)
  local out = {}
  for _, block in ipairs(type(body) == "table" and body.content or {}) do
    if type(block) == "table" and block.type == "text" and type(block.text) == "string" then
      out[#out + 1] = block.text
    end
  end
  return table.concat(out)
end

function M.delta(ev)
  local ok, obj = pcall(vim.json.decode, ev.data, { luanil = { object = true, array = true } })
  if not ok or type(obj) ~= "table" then
    return nil
  end
  local t = obj.type or ev.event
  if t == "content_block_delta" and type(obj.delta) == "table" then
    local text = obj.delta.text
    return type(text) == "string" and text ~= "" and text or nil
  elseif t == "message_stop" then
    return nil, true
  elseif t == "error" then
    return nil, true, P.error_message(obj) or "stream error"
  end
  return nil
end

M.error_message = P.error_message

return M

--- llama.cpp server dialect: native FIM via /infill ({input_prefix, input_suffix}); chat via its OpenAI-compatible
--- /v1/chat/completions. OWNER: complete.
local P = require("slop.services.ai.providers")
local openai = require("slop.services.ai.providers.openai")

---@type slop.ai.Adapter
local M = {}

function M.fim(p, req, key)
  return {
    url = p.url,
    method = "POST",
    headers = P.bearer(key),
    body = {
      input_prefix = req.prompt,
      input_suffix = req.suffix or "",
      n_predict = req.max_tokens,
      stop = req.stop and #req.stop > 0 and req.stop or nil,
      temperature = req.temperature,
      stream = req.stream ~= false,
      cache_prompt = true,
    },
  }
end

function M.parse_fim(body)
  if type(body) == "table" and type(body.content) == "string" then
    return { body.content }
  end
  return openai.parse_fim(body)
end

M.chat = openai.chat
M.parse_chat = openai.parse_chat

function M.delta(ev, kind)
  if kind == "chat" then
    return openai.delta(ev)
  end
  local ok, obj = pcall(vim.json.decode, ev.data, { luanil = { object = true, array = true } })
  if not ok or type(obj) ~= "table" then
    return nil
  end
  if obj.error then
    return nil, true, P.error_message(obj)
  end
  local text = obj.content
  return type(text) == "string" and text ~= "" and text or nil, obj.stop == true or nil
end

M.error_message = P.error_message

return M

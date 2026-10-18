--- Mistral dialect: Codestral FIM (/v1/fim/completions, api.mistral.ai or codestral.mistral.ai) and chat
--- (/v1/chat/completions, OpenAI-shaped). OWNER: complete.
local P = require("slop.services.ai.providers")
local openai = require("slop.services.ai.providers.openai")

---@type slop.ai.Adapter
local M = {}

function M.fim(p, req, key)
  local body = P.fim_body(p, req)
  return { url = p.url, method = "POST", headers = P.bearer(key), body = body }
end

M.chat = openai.chat
M.parse_fim = openai.parse_fim
M.parse_chat = openai.parse_chat
M.delta = openai.delta

function M.error_message(body)
  -- {"object":"error","message":"...","type":"invalid_request_error"} | {"detail":[{"msg":...}]}
  return P.error_message(body)
end

return M

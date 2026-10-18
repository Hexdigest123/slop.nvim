--# selene: allow(unused_variable)
--- Provider adapters: turn slop.ai requests into core.http requests and parse responses.
--- OWNER: complete. STATUS: stub (interface only). One file per dialect: providers/<format>.lua
--- (mistral, openai, anthropic, gemini, ollama, ...); `format` defaults to the provider's `service`.
---@class slop.ai.providers
local M = {}

---@class slop.ai.Adapter
---@field fim? fun(p: slop.ai.ProviderConfig, req: slop.ai.FimRequest, key: string?): slop.http.Request
---@field chat? fun(p: slop.ai.ProviderConfig, req: slop.ai.ChatRequest, key: string?): slop.http.Request
---@field parse_fim? fun(body: table): string[]           non-streamed response -> candidates
---@field parse_chat? fun(body: table): string
---@field delta? fun(chunk: slop.http.SseEvent|table): string?  streamed chunk -> text delta (nil = none/done)

--- Adapter for a dialect name.
---@param format string
---@return slop.ai.Adapter?
function M.get(format)
  error("slop: services.ai.providers.get not implemented yet", 2)
end

--- Register a custom adapter (user extension point).
---@param format string
---@param adapter slop.ai.Adapter
function M.register(format, adapter)
  error("slop: services.ai.providers.register not implemented yet", 2)
end

return M

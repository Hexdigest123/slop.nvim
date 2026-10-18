--# selene: allow(unused_variable)
--- Minimal ACP (Agent Client Protocol) client: JSON-RPC over stdio to agents in config `ai.agents`.
--- OWNER: edit. STATUS: stub (interface only). See research/01-avante-acp.md §8.
---
--- Client capabilities advertised: fs.readTextFile ONLY (served by `read_text_file`, which must redact and
--- refuse blocked paths via core.secrets). No write/terminal capabilities.
---@class slop.acp
local M = {}

---@class slop.acp.ClientOpts
---@field agent string                    name in config ai.agents
---@field cwd? string                     default core.project.root()
---@field read_text_file? fun(params: {path: string, line?: integer, limit?: integer}): string?, string?  text or nil, err
---@field on_exit? fun(code: integer, stderr_tail: string)

---@class slop.acp.PromptHandlers
---@field on_update? fun(update: table)   raw `session/update` params.update (agent_message_chunk, tool_call, plan, ...)
---@field on_permission? fun(req: table, respond: fun(option_id: string|nil))  nil option_id = cancelled
---@field on_done fun(stop_reason: string?, err: table?)

---@class slop.acp.Session
---@field id string
---@field client slop.acp.Client
---@field prompt fun(self: slop.acp.Session, blocks: table[], handlers: slop.acp.PromptHandlers)
---@field cancel fun(self: slop.acp.Session)   session/cancel + answer pending permissions "cancelled"

---@class slop.acp.Client
---@field agent string
---@field capabilities table?             agentCapabilities after initialize
---@field start fun(self: slop.acp.Client, cb: fun(err: string?))   spawn + initialize (idempotent)
---@field new_session fun(self: slop.acp.Client, opts: {cwd?: string}, cb: fun(session: slop.acp.Session?, err: string?))
---@field request fun(self: slop.acp.Client, method: string, params: table?, cb: fun(result: any, err: table?)): integer
---@field notify fun(self: slop.acp.Client, method: string, params: table?)
---@field stop fun(self: slop.acp.Client)
---@field is_running fun(self: slop.acp.Client): boolean

--- Shared long-lived client per agent name (spawned lazily on first start()).
---@param opts slop.acp.ClientOpts
---@return slop.acp.Client
function M.client(opts)
  error("slop: services.ai.acp.client not implemented yet", 2)
end

--- Content block helpers.
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

return M

-- Helpers to run the mock ACP agent (mock_agent.lua) from specs: `local mock = require("services.ai.acp.mock")`.
local h = require("helpers")

local M = {}

M.script = h.root .. "/spec/services/ai/acp/mock_agent.lua"

--- Agent config for the mock with a plan. Returns cfg and an object to read the mock's log.
---@param plan? table
---@return table cfg, {entries: fun(): table[], received: fun(method: string): table[], responses: fun(method: string): table[], path: string}
function M.agent(plan)
  local dir = h.tmpdir("mock")
  local plan_path = dir .. "/plan.json"
  local log_path = dir .. "/log.ndjson"
  h.write(plan_path, vim.json.encode(plan or vim.empty_dict()))
  local cfg = {
    cmd = { vim.v.progpath, "--headless", "--clean", "-u", "NONE", "-l", M.script },
    env = { SLOP_MOCK_PLAN = plan_path, SLOP_MOCK_LOG = log_path },
  }
  local log = { path = log_path }
  function log.entries()
    local text = h.read(log_path) or ""
    local out = {}
    for line in text:gmatch("[^\n]+") do
      out[#out + 1] = vim.json.decode(line, { luanil = { object = true, array = true } })
    end
    return out
  end
  function log.received(method)
    return vim.tbl_filter(function(e)
      return e.method == method and e.event == nil
    end, log.entries())
  end
  function log.responses(method)
    return vim.tbl_filter(function(e)
      return e.event == "response" and e.method == method
    end, log.entries())
  end
  return cfg, log
end

--- setup() slop with the mock registered as agent `name` (default "mock"). Extra opts are merged.
---@param plan? table
---@param opts? table
---@param name? string
function M.setup(plan, opts, name)
  local cfg, log = M.agent(plan)
  name = name or "mock"
  require("slop").setup(vim.tbl_deep_extend("force", { ai = { agents = { [name] = cfg } } }, opts or {}))
  return log, cfg
end

--- Wait until fn() is truthy (default 5 s).
function M.wait(fn, ms)
  return vim.wait(ms or 5000, fn, 10)
end

return M

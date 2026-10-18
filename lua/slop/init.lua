--- slop.nvim public entry point.
---
--- `require("slop").setup(opts)` only stores config (order-independent, idempotent).
--- `require("slop").<module>` lazily loads that module and returns its `api` table.
---@class slop
---@field config slop.ConfigModule
local M = {}

M.version = "0.0.0" -- x-release-please-version

--- Configure slop. Optional: the plugin works with defaults / `vim.g.slop`.
--- Safe to call any number of times, before or after plugin/slop.lua is sourced.
---@param opts? slop.Opts
function M.setup(opts)
  require("slop.config").setup(opts)
end

--- Load a module now (normally modules load lazily via their manifest triggers).
---@param name string
---@return table? api
function M.load(name)
  return (require("slop.core.registry").load(name))
end

local function disabled_proxy(name, err)
  return setmetatable({}, {
    __index = function(_, key)
      error(("slop: module '%s' is unavailable (%s); cannot access '%s'"):format(name, err or "?", tostring(key)), 2)
    end,
  })
end

return setmetatable(M, {
  __index = function(t, key)
    if key == "config" then
      local config = require("slop.config")
      rawset(t, key, config)
      return config
    end
    if type(key) ~= "string" then
      return nil
    end
    local registry = require("slop.core.registry")
    if registry.kind(key) ~= "module" then
      return nil
    end
    local mod_api, err = registry.load(key)
    if mod_api then
      return mod_api
    end
    return disabled_proxy(key, err)
  end,
})

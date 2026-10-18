--- Thin wrappers over `User Slop<Module><Event>` autocmds.
---
---   events.emit("term", "Open", { id = 1 })      -- fires User SlopTermOpen with data
---   events.on("term", "Open", function(data, ev) ... end)
---   events.emit(nil, "ModuleLoaded", { name = "term" })  -- core event: User SlopModuleLoaded
---
--- Event names are PascalCase. Module names are converted: "my_mod" -> "MyMod".
--- Core events: SlopConfigChanged, SlopModuleLoaded {name}, SlopModuleDisabled {name}.
---@class slop.events
local M = {}

local group = nil ---@type integer?

local function pascal(s)
  return (s:gsub("[_%-.]+(%w)", string.upper):gsub("^%l", string.upper))
end

--- The autocmd pattern for an event.
---@param module string?  nil/"" for core events
---@param event string
---@return string
function M.pattern(module, event)
  return "Slop" .. ((module and module ~= "") and pascal(module) or "") .. pascal(event)
end

--- Fire `User Slop<Module><Event>`. Safe from fast contexts (scheduled there).
---@param module string?
---@param event string
---@param data? any  passed as `ev.data` (must be serialisable: no functions/userdata)
function M.emit(module, event, data)
  local pattern = M.pattern(module, event)
  local function fire()
    vim.api.nvim_exec_autocmds("User", { pattern = pattern, modeline = false, data = data })
  end
  if vim.in_fast_event() then
    vim.schedule(fire)
  else
    fire()
  end
end

---@class slop.events.OnOpts
---@field once? boolean
---@field group? integer|string  default: augroup "slop.events"
---@field desc? string

--- Subscribe to `User Slop<Module><Event>`.
---@param module string?
---@param event string
---@param cb fun(data: any, ev: vim.api.keyset.create_autocmd.callback_args): boolean?  return true to unsubscribe
---@param opts? slop.events.OnOpts
---@return integer autocmd_id
function M.on(module, event, cb, opts)
  opts = opts or {}
  if not opts.group then
    group = group or vim.api.nvim_create_augroup("slop.events", { clear = false })
  end
  return vim.api.nvim_create_autocmd("User", {
    group = opts.group or group,
    pattern = M.pattern(module, event),
    once = opts.once,
    desc = opts.desc or ("slop: " .. M.pattern(module, event)),
    callback = function(ev)
      return cb(ev.data, ev)
    end,
  })
end

--- Unsubscribe.
---@param id integer
function M.off(id)
  pcall(vim.api.nvim_del_autocmd, id)
end

M.pascal = pascal

return M

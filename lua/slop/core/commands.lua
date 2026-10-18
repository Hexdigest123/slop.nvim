--- `:Slop <module> <sub> [args]` dispatcher + completion, and the core subcommands.
---
---   :Slop health [module]          :checkhealth slop
---   :Slop log [clear]              open the log (or clear it)
---   :Slop modules [enable|disable <name>]
---   :[range]Slop <module> [sub] [args...]   (module loads on first use)
---@class slop.commands
local M = {}

local util = require("slop.core.util")

local function registry()
  return require("slop.core.registry")
end

local function err(msg)
  require("slop.core.log").notify(msg, vim.log.levels.ERROR)
end

local function echo(lines)
  local chunks = {}
  for i, l in ipairs(lines) do
    chunks[#chunks + 1] = { l .. (i < #lines and "\n" or "") }
  end
  vim.api.nvim_echo(chunks, false, {})
end

---@type table<string, slop.Subcommand>
M.core = {
  health = {
    desc = "run :checkhealth slop",
    impl = function()
      vim.cmd("checkhealth slop")
    end,
  },
  log = {
    desc = "open the slop log (`clear` empties it)",
    impl = function(args)
      local log = require("slop.core.log")
      if args[1] == "clear" then
        log.clear()
        log.notify("log cleared")
      else
        log.open()
      end
    end,
    complete = function(lead)
      return util.complete_prefix({ "clear" }, lead)
    end,
  },
  modules = {
    desc = "list modules; `enable|disable <name>`",
    impl = function(args)
      local reg = registry()
      local action, name = args[1], args[2]
      if action == "enable" or action == "disable" then
        if not name or reg.kind(name) ~= "module" then
          return err(("slop: unknown module %s"):format(vim.inspect(name)))
        end
        reg[action](name)
        return
      elseif action then
        return err("slop: usage :Slop modules [enable|disable <name>]")
      end
      local lines = { "slop modules:" }
      for _, n in ipairs(reg.names()) do
        local status = reg.status(n)
        lines[#lines + 1] = ("  %-10s %s"):format(n, status)
      end
      echo(lines)
    end,
    complete = function(lead, args)
      if #args <= 1 then
        return util.complete_prefix({ "enable", "disable" }, lead)
      end
      local reg = registry()
      local want = args[1] == "enable"
      local names = vim.tbl_filter(function(n)
        return reg.is_enabled(n) ~= want
      end, reg.names())
      return util.complete_prefix(names, lead)
    end,
  },
}

local function usage()
  local names = vim.list_extend(vim.tbl_keys(M.core), registry().names({ enabled = true }))
  table.sort(names)
  err("slop: usage :Slop {" .. table.concat(names, "|") .. "} [subcommand] [args]")
end

--- Entry point of the :Slop user command.
---@param cmd vim.api.keyset.create_user_command.command_args
function M.run(cmd)
  local name = cmd.fargs[1]
  if not name then
    return usage()
  end
  local rest = vim.list_slice(cmd.fargs, 2)
  local core = M.core[name]
  if core then
    return core.impl(rest, cmd)
  end
  local reg = registry()
  if reg.kind(name) ~= "module" then
    return err(("slop: unknown module or command %q"):format(name))
  end
  if not reg.is_enabled(name) then
    return err(("slop: module '%s' is disabled (enable it with :Slop modules enable %s)"):format(name, name))
  end
  if not reg.load(name) then
    return
  end
  local spec = reg.spec(name)
  local cmds = spec and spec.commands or {}
  local subname = rest[1]
  local sub = subname and cmds[subname]
  local args = vim.list_slice(rest, 2)
  if not sub then
    for _, c in pairs(cmds) do
      if c.default then
        sub = c
        args = rest
        break
      end
    end
  end
  if not sub then
    local subs = vim.tbl_keys(cmds)
    table.sort(subs)
    if subname then
      return err(("slop: %s has no subcommand %q (have: %s)"):format(name, subname, table.concat(subs, ", ")))
    end
    return err(("slop: usage :Slop %s {%s}"):format(name, table.concat(subs, "|")))
  end
  local ok, e = xpcall(sub.impl, debug.traceback, args, cmd)
  if not ok then
    err(("slop: %s %s failed: %s"):format(name, subname or "", e))
  end
end

--- Completion for :Slop. Handles a range prefix ("'<,'>Slop ...") and bang.
--- Level 1: core subcommands + enabled modules; level 2: the module's subcommands (spec loaded, no setup);
--- level 3+: the subcommand's complete(arg_lead, args_after_sub, cmdline).
---@param arg_lead string
---@param cmdline string
---@return string[]
function M.complete(arg_lead, cmdline, _)
  local rest = cmdline:match("Slop!?%s+(.*)$") or ""
  local words = vim.split(rest, "%s+", { trimempty = false })
  if #words <= 1 then
    local names = vim.list_extend(vim.tbl_keys(M.core), registry().names({ enabled = true }))
    return util.complete_prefix(names, arg_lead)
  end
  local first = words[1]
  local core = M.core[first]
  if core then
    return core.complete and core.complete(arg_lead, vim.list_slice(words, 2), cmdline) or {}
  end
  local reg = registry()
  if reg.kind(first) ~= "module" or not reg.is_enabled(first) then
    return {}
  end
  local spec = reg.spec(first)
  local cmds = spec and spec.commands or {}
  if #words == 2 then
    return util.complete_prefix(vim.tbl_keys(cmds), arg_lead)
  end
  local sub = cmds[words[2]]
  if sub and sub.complete then
    local ok, res = pcall(sub.complete, arg_lead, vim.list_slice(words, 3), cmdline)
    return ok and type(res) == "table" and res or {}
  end
  return {}
end

return M

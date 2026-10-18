--- :checkhealth slop — core checks, then every module (spec.health()) and service.
--- Health functions must not require the module to be set up (they run without setup()).
---@class slop.health
local M = {}

local h = vim.health

local function check_config(ns)
  local config = require("slop.config")
  local ok, errs = pcall(config.errors, ns)
  if not ok then
    h.error(("config `%s`: %s"):format(ns, errs))
    return
  end
  for _, e in ipairs(errs) do
    h.error("config: " .. e)
  end
  for _, k in ipairs(config.unknown(ns)) do
    h.warn(("unknown option `%s` (typo?)"):format(k))
  end
  return #errs == 0
end

local function run_health(label, fn)
  local ok, err = xpcall(fn, debug.traceback)
  if not ok then
    h.error(("%s health() failed: %s"):format(label, err))
  end
end

local function core()
  h.start("slop: core")
  local v = vim.version()
  if vim.fn.has("nvim-0.12") == 1 then
    h.ok(("Neovim %d.%d.%d"):format(v.major, v.minor, v.patch))
  else
    h.error("Neovim >= 0.12 is required")
  end
  for _, exe in ipairs({ "git", "curl" }) do
    if vim.fn.executable(exe) == 1 then
      h.ok(("`%s` found"):format(exe))
    else
      h.warn(("`%s` not found in $PATH"):format(exe), { "Some modules need " .. exe })
    end
  end
  if vim.g.loaded_slop then
    h.ok("plugin/slop.lua loaded")
  else
    h.warn("plugin/slop.lua not sourced (is slop.nvim on the runtimepath?)")
  end

  local config = require("slop.config")
  local all_ok = true
  for _, ns in ipairs({ "ui", "log", "project", "secrets" }) do
    all_ok = check_config(ns) ~= false and all_ok
  end
  for _, k in ipairs(config.unknown_top()) do
    h.warn(("unknown top-level option `%s` (typo?)"):format(k))
  end
  if all_ok then
    h.ok("core configuration is valid")
  end

  local ok, root = pcall(require("slop.core.project").root)
  if ok then
    h.info("project root: " .. root)
  end
  local border = config.get("ui").border
  if border == "none" or border == "" then
    h.warn("ui.border is 'none': floats are invisible with transparent colorschemes")
  end

  local log = require("slop.core.log")
  local errors = log.entries({ level = vim.log.levels.ERROR })
  if #errors > 0 then
    h.warn(("%d error(s) logged this session, see :Slop log"):format(#errors), { log.format_entry(errors[#errors]) })
  end
end

local function modules()
  local registry = require("slop.core.registry")
  h.start("slop: modules")
  local names = registry.names()
  for _, name in ipairs(names) do
    local status, err = registry.status(name)
    local spec, serr = registry.spec(name)
    if not spec then
      h.error(("%s: %s"):format(name, serr or "spec not found"))
    elseif status == "failed" then
      h.error(("%s: failed to load: %s"):format(name, err))
    else
      h.ok(("%s: %s — %s"):format(name, status, spec.description))
    end
  end
  for _, name in ipairs(names) do
    local spec = registry.spec(name)
    if spec and registry.is_enabled(name) then
      h.start("slop: " .. name)
      if check_config(name) ~= false then
        h.ok("configuration is valid")
      end
      if spec.health then
        run_health(name, spec.health)
      end
    end
  end
end

local function services()
  local registry = require("slop.core.registry")
  for _, name in ipairs(registry.service_names()) do
    local spec, err = registry.service_spec(name)
    h.start("slop: service " .. name)
    if not spec then
      h.error(err or "failed to load")
    else
      if check_config(name) ~= false then
        h.ok("configuration is valid")
      end
      if spec.health then
        run_health("service " .. name, spec.health)
      end
    end
  end
end

function M.check()
  core()
  modules()
  services()
end

return M

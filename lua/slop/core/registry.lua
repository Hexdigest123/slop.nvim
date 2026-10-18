--- Module + service registry: discovery, enable/disable, contract validation, load-once.
---
--- Modules: `lua/slop/modules/<name>/init.lua` (built-in, discovered on the runtimepath) or
--- `opts.modules = { <name> = spec }` (user modules). Services: `lua/slop/services/<name>/init.lua`.
---@class slop.registry
local M = {}

local api = vim.api

---@class slop.Subcommand
---@field impl fun(args: string[], cmd: vim.api.keyset.create_user_command.command_args)
---@field complete? fun(arg_lead: string, args: string[], cmdline: string): string[]  args = words after the sub
---@field desc? string
---@field default? boolean  run when `:Slop <module>` is given without a subcommand

---@class slop.ModuleSpec
---@field name string                     must equal the directory / opts.modules key
---@field description string
---@field defaults table                  merged under opts[<name>]; must include `enabled` (boolean)
---@field schema? fun(cfg: table, check: fun(path: string, value: any, validator: any, optional?: boolean, message?: string))
---@field services? string[]              e.g. { "ai" }; set up before this module's setup()
---@field setup fun(cfg: table)           called lazily on first use, exactly once
---@field commands? table<string, slop.Subcommand>
---@field keymaps? table<string, slop.KeymapSpec>|fun(cfg: table): table<string, slop.KeymapSpec>
---@field health? fun()                   its section in :checkhealth slop (must not require setup())
---@field api? table                      exposed as require("slop").<name>
---@field highlights? table<string, vim.api.keyset.highlight>  Slop<Module><Thing> groups (default = true)
---@field open_keys? string[]             option paths whose children are free-form (no unknown-key warnings)
---@field teardown? fun()                 undo setup() (enables :Slop modules disable without restart)
---@field manifest? slop.ManifestEntry    user modules only: lazy triggers (default { cmd = true })

---@class slop.ServiceSpec
---@field name string
---@field description string
---@field defaults? table                 merged under opts[<name>]
---@field schema? fun(cfg: table, check: function)
---@field setup? fun(cfg: table)          called once, before the first module that declares it is set up
---@field health? fun()
---@field open_keys? string[]

M.RESERVED = { health = true, log = true, modules = true, config = true, setup = true, load = true, version = true }

local SPEC_FIELDS = {
  name = true,
  description = true,
  defaults = true,
  schema = true,
  services = true,
  setup = true,
  commands = true,
  keymaps = true,
  health = true,
  api = true,
  highlights = true,
  open_keys = true,
  teardown = true,
  manifest = true,
}

---@class slop.registry.State
---@field status "loading"|"loaded"|"failed"
---@field api? table
---@field error? string

local state = {} ---@type table<string, slop.registry.State>
local specs = {} ---@type table<string, slop.ModuleSpec|false>
local spec_errors = {} ---@type table<string, string>
local services = {} ---@type table<string, {spec: slop.ServiceSpec, ready: boolean}>
local discovered = nil ---@type string[]?

local function log()
  return require("slop.core.log")
end

local function config()
  return require("slop.config")
end

--- Built-in module names found on the runtimepath (lua/slop/modules/*/init.lua).
---@return string[]
function M.discover()
  if discovered then
    return discovered
  end
  local seen, out = {}, {}
  for _, f in ipairs(api.nvim_get_runtime_file("lua/slop/modules/*/init.lua", true)) do
    local name = f:match("modules[/\\]([^/\\]+)[/\\]init%.lua$")
    if name and not seen[name] then
      seen[name] = true
      out[#out + 1] = name
    end
  end
  table.sort(out)
  discovered = out
  return out
end

--- All module names: manifest ∪ discovered ∪ user modules (sorted).
---@param opts? {enabled?: boolean}  only enabled ones
---@return string[]
function M.names(opts)
  local seen, out = {}, {}
  local function add(n)
    if not seen[n] then
      seen[n] = true
      if not (opts and opts.enabled) or M.is_enabled(n) then
        out[#out + 1] = n
      end
    end
  end
  for n in pairs(require("slop.manifest")) do
    add(n)
  end
  for _, n in ipairs(M.discover()) do
    add(n)
  end
  for n in pairs(config().user_modules()) do
    add(n)
  end
  table.sort(out)
  return out
end

--- Service names found on the runtimepath.
---@return string[]
function M.service_names()
  local seen, out = {}, {}
  for _, f in ipairs(api.nvim_get_runtime_file("lua/slop/services/*/init.lua", true)) do
    local name = f:match("services[/\\]([^/\\]+)[/\\]init%.lua$")
    if name and not seen[name] then
      seen[name] = true
      out[#out + 1] = name
    end
  end
  table.sort(out)
  return out
end

--- "module" | "service" | nil
---@param name string
---@return "module"|"service"|nil
function M.kind(name)
  if type(name) ~= "string" or name == "" or M.RESERVED[name] then
    return nil
  end
  if require("slop.manifest")[name] or config().user_modules()[name] then
    return "module"
  end
  if vim.tbl_contains(M.discover(), name) then
    return "module"
  end
  if services[name] or #api.nvim_get_runtime_file("lua/slop/services/" .. name .. "/init.lua", false) > 0 then
    return "service"
  end
  return nil
end

--- Manifest entry (built-in) or spec.manifest (user module); `{ cmd = true }` otherwise.
---@param name string
---@return slop.ManifestEntry
function M.entry(name)
  local e = require("slop.manifest")[name]
  if e then
    return e
  end
  local um = config().user_modules()[name]
  if um and type(um.manifest) == "table" then
    return um.manifest
  end
  return { cmd = true }
end

---@param name string
---@return boolean
function M.is_enabled(name)
  return config().enabled(name)
end

local function is_list_of_strings(v)
  if type(v) ~= "table" or not vim.islist(v) then
    return false
  end
  for _, s in ipairs(v) do
    if type(s) ~= "string" then
      return false
    end
  end
  return true
end

local function modes_of(m)
  local list = type(m) == "table" and vim.deepcopy(m) or { m }
  table.sort(list)
  return list
end

--- Contract validation of a module spec. Returns a list of human-readable errors (empty = valid).
---@param spec any
---@param name string
---@return string[]
function M.validate_spec(spec, name)
  local errs = {}
  local function err(fmt, ...)
    errs[#errs + 1] = ("%s: " .. fmt):format(name, ...)
  end
  if type(spec) ~= "table" then
    err("spec must be a table, got %s", type(spec))
    return errs
  end
  if M.RESERVED[name] then
    err("'%s' is a reserved name", name)
  end
  if not name:match("^[%l][%l%d_]*$") then
    err("module names must match ^[a-z][a-z0-9_]*$")
  end
  for k in pairs(spec) do
    if not SPEC_FIELDS[k] then
      err("unknown spec field '%s'", tostring(k))
    end
  end
  if spec.name ~= name then
    err("spec.name must be '%s', got %s", name, vim.inspect(spec.name))
  end
  if type(spec.description) ~= "string" or spec.description == "" then
    err("spec.description must be a non-empty string")
  end
  if type(spec.defaults) ~= "table" then
    err("spec.defaults must be a table")
  elseif type(spec.defaults.enabled) ~= "boolean" then
    err("spec.defaults.enabled must be a boolean")
  end
  if type(spec.setup) ~= "function" then
    err("spec.setup must be a function")
  end
  for _, f in ipairs({ "schema", "health", "teardown" }) do
    if spec[f] ~= nil and type(spec[f]) ~= "function" then
      err("spec.%s must be a function", f)
    end
  end
  for _, f in ipairs({ "api", "highlights", "manifest" }) do
    if spec[f] ~= nil and type(spec[f]) ~= "table" then
      err("spec.%s must be a table", f)
    end
  end
  if spec.services ~= nil then
    if not is_list_of_strings(spec.services) then
      err("spec.services must be a list of strings")
    else
      for _, s in ipairs(spec.services) do
        if #api.nvim_get_runtime_file("lua/slop/services/" .. s .. "/init.lua", false) == 0 and not services[s] then
          err("unknown service '%s'", s)
        end
      end
    end
  end
  if spec.open_keys ~= nil and not is_list_of_strings(spec.open_keys) then
    err("spec.open_keys must be a list of strings")
  end
  for hl in pairs(spec.highlights or {}) do
    if type(hl) ~= "string" or not hl:match("^Slop%u") then
      err("highlight group '%s' must be named Slop<Module><Thing>", tostring(hl))
    end
  end
  if spec.commands ~= nil then
    if type(spec.commands) ~= "table" then
      err("spec.commands must be a table")
    else
      for sub, c in pairs(spec.commands) do
        if type(sub) ~= "string" or sub:find("%s") then
          err("command name %s is invalid", vim.inspect(sub))
        elseif type(c) ~= "table" or type(c.impl) ~= "function" then
          err("command '%s' needs an impl function", sub)
        elseif c.complete ~= nil and type(c.complete) ~= "function" then
          err("command '%s': complete must be a function", sub)
        end
      end
    end
  end
  local km = spec.keymaps
  if km ~= nil then
    if type(km) == "function" and type(spec.defaults) == "table" then
      local ok, res = pcall(km, vim.deepcopy(spec.defaults))
      if not ok then
        err("keymaps(cfg) failed with defaults: %s", tostring(res))
        km = nil
      else
        km = res
      end
    end
    if km ~= nil and type(km) ~= "table" then
      err("spec.keymaps must be a table or fun(cfg): table")
    elseif km then
      local util = require("slop.core.util")
      for kname, k in pairs(km) do
        if type(k) ~= "table" then
          err("keymap '%s' must be a table", tostring(kname))
        else
          if type(k.desc) ~= "string" or k.desc == "" then
            err("keymap '%s' needs a desc", kname)
          end
          if type(k.rhs) ~= "function" and type(k.rhs) ~= "string" then
            err("keymap '%s' needs an rhs function|string", kname)
          end
          if type(k.mode) ~= "string" and not is_list_of_strings(k.mode) then
            err("keymap '%s' needs mode string|string[]", kname)
          end
          local lhs = type(spec.defaults) == "table" and util.tbl_get(spec.defaults.keymaps or {}, kname)
          if lhs == nil then
            lhs = k.lhs
          end
          if lhs ~= nil and lhs ~= false and type(lhs) ~= "string" then
            err("default lhs of keymap '%s' must be string|false", kname)
          end
          if type(lhs) == "string" and vim.keycode(lhs) == vim.keycode("<Tab>") then
            err("keymap '%s' must not default to <Tab>", kname)
          end
        end
      end
    end
  end
  -- Built-in modules: manifest consistency.
  local entry = require("slop.manifest")[name]
  if entry and type(spec.defaults) == "table" then
    if (entry.default_enabled ~= false) ~= (spec.defaults.enabled ~= false) then
      err("manifest default_enabled does not match spec.defaults.enabled")
    end
    local util = require("slop.core.util")
    for action, mk in pairs(entry.keys or {}) do
      local k = type(km) == "table" and km[action] or nil
      if not k then
        err("manifest key '%s' has no spec.keymaps entry", action)
      else
        local lhs = util.tbl_get(spec.defaults.keymaps or {}, action)
        if lhs ~= mk.lhs then
          err(
            "manifest key '%s' lhs %s ~= defaults.keymaps.%s %s",
            action,
            vim.inspect(mk.lhs),
            action,
            vim.inspect(lhs)
          )
        end
        if not vim.deep_equal(modes_of(mk.mode), modes_of(k.mode)) then
          err("manifest key '%s' mode differs from spec.keymaps", action)
        end
        if k.buffer or k.ft or k.fallthrough then
          err("manifest key '%s' must be a global keymap in spec.keymaps", action)
        end
      end
    end
  end
  return errs
end

--- Contract validation of a service spec.
---@param spec any
---@param name string
---@return string[]
function M.validate_service(spec, name)
  local errs = {}
  if type(spec) ~= "table" then
    return { name .. ": service must return a table" }
  end
  if spec.name ~= name then
    errs[#errs + 1] = ("%s: spec.name must be '%s'"):format(name, name)
  end
  if type(spec.description) ~= "string" then
    errs[#errs + 1] = name .. ": spec.description must be a string"
  end
  if spec.defaults ~= nil and type(spec.defaults) ~= "table" then
    errs[#errs + 1] = name .. ": spec.defaults must be a table"
  end
  for _, f in ipairs({ "schema", "setup", "health" }) do
    if spec[f] ~= nil and type(spec[f]) ~= "function" then
      errs[#errs + 1] = ("%s: spec.%s must be a function"):format(name, f)
    end
  end
  return errs
end

--- The module's spec (required + contract-validated, NOT set up). nil + error when missing/invalid.
---@param name string
---@return slop.ModuleSpec?, string? err
function M.spec(name)
  if specs[name] ~= nil then
    return specs[name] or nil, spec_errors[name]
  end
  local spec = config().user_modules()[name]
  if spec == nil then
    local ok, res = pcall(require, "slop.modules." .. name)
    if not ok then
      specs[name] = false
      spec_errors[name] = tostring(res)
      return nil, spec_errors[name]
    end
    spec = res
  end
  local errs = M.validate_spec(spec, name)
  if #errs > 0 then
    specs[name] = false
    spec_errors[name] = "invalid module spec:\n  " .. table.concat(errs, "\n  ")
    return nil, spec_errors[name]
  end
  specs[name] = spec
  return spec
end

--- The service's spec (required + validated, NOT set up).
---@param name string
---@return slop.ServiceSpec?, string? err
function M.service_spec(name)
  if services[name] then
    return services[name].spec
  end
  local ok, spec = pcall(require, "slop.services." .. name)
  if not ok then
    return nil, tostring(spec)
  end
  local errs = M.validate_service(spec, name)
  if #errs > 0 then
    return nil, table.concat(errs, "; ")
  end
  services[name] = { spec = spec, ready = false }
  return spec
end

--- Get a service, running its setup(cfg) once. Errors are raised.
---@param name string
---@return table service
function M.service(name)
  local spec, err = M.service_spec(name)
  if not spec then
    error(("slop: service '%s' unavailable: %s"):format(name, err), 2)
  end
  local s = services[name]
  if not s.ready then
    s.ready = true
    if spec.setup then
      spec.setup(config().get(name))
    end
  end
  return spec
end

---@param name string
---@return boolean
function M.is_loaded(name)
  return state[name] ~= nil and state[name].status == "loaded"
end

--- "loaded" | "loading" | "failed" | "disabled" | "available" | "missing"
---@param name string
---@return string status, string? err
function M.status(name)
  local st = state[name]
  if st then
    return st.status, st.error
  end
  if M.kind(name) ~= "module" then
    return "missing"
  end
  if not M.is_enabled(name) then
    return "disabled"
  end
  return "available"
end

--- Load a module once: validate spec + config, set up services, apply keymaps/highlights, call setup(cfg).
--- Returns its api table (spec.api or {}), or nil + error. Disabled modules return nil, "disabled".
---@param name string
---@param opts? {silent?: boolean}  don't notify when disabled
---@return table? api, string? err
function M.load(name, opts)
  opts = opts or {}
  local st = state[name]
  if st then
    if st.status == "failed" then
      return nil, st.error
    end
    return st.api
  end
  if M.kind(name) ~= "module" then
    return nil, "unknown module"
  end
  if not M.is_enabled(name) then
    if not opts.silent then
      log().notify(("slop: module '%s' is disabled"):format(name), vim.log.levels.WARN)
    end
    return nil, "disabled"
  end
  local function fail(err)
    state[name] = { status = "failed", error = err }
    log().notify(("slop: module '%s' failed to load: %s"):format(name, err), vim.log.levels.ERROR)
    return nil, err
  end
  local spec, err = M.spec(name)
  if not spec then
    return fail(err or "spec not found")
  end
  local cfg = config().get(name)
  local cerrs = config().errors(name)
  if #cerrs > 0 then
    return fail("invalid config:\n  " .. table.concat(cerrs, "\n  "))
  end
  state[name] = { status = "loading", api = spec.api or {} }
  for _, svc in ipairs(spec.services or {}) do
    local ok, serr = pcall(M.service, svc)
    if not ok then
      return fail(tostring(serr))
    end
  end
  if spec.highlights then
    require("slop.core.util").hl(spec.highlights)
  end
  local skip = {}
  for action in pairs(M.entry(name).keys or {}) do
    skip[action] = true
  end
  local ok, kerr = pcall(require("slop.core.keymaps").apply, name, spec, cfg, { skip_lhs = skip })
  if not ok then
    return fail("keymaps: " .. tostring(kerr))
  end
  local sok, serr = xpcall(spec.setup, debug.traceback, cfg)
  if not sok then
    return fail(tostring(serr))
  end
  state[name] = { status = "loaded", api = spec.api or {} }
  require("slop.core.events").emit(nil, "ModuleLoaded", { name = name })
  return state[name].api
end

--- Load every enabled module whose manifest entry `provides` the capability (e.g. "secrets").
---@param cap string
function M.load_capability(cap)
  for _, name in ipairs(M.names()) do
    local e = M.entry(name)
    if e.provides and vim.tbl_contains(e.provides, cap) and not state[name] and M.is_enabled(name) then
      M.load(name, { silent = true })
    end
  end
end

--- Handler behind `<Plug>(slop-<module>-<action>)` stubs created at startup.
---@param name string
---@param action string
---@return any
function M.run_keymap(name, action)
  local mod_api = M.load(name)
  if not mod_api then
    return
  end
  local spec = M.spec(name)
  local km = spec and spec.keymaps
  if type(km) == "function" then
    km = km(config().get(name))
  end
  local k = km and km[action]
  if not k then
    log().notify(("slop: %s has no keymap '%s'"):format(name, action), vim.log.levels.ERROR)
    return
  end
  if type(k.rhs) == "string" then
    if k.expr then
      return k.rhs
    end
    api.nvim_feedkeys(vim.keycode(k.rhs), "m", false)
    return
  end
  return k.rhs()
end

--- After an event-triggered load, re-fire the event for the module's own augroup ("slop.<name>"),
--- because autocmds created while an event runs do not see that event.
---@param name string
---@param ev {event: string, buf?: integer, match?: string, data?: any}
function M.replay(name, ev)
  local grp = "slop." .. name
  local ok, acs = pcall(api.nvim_get_autocmds, { group = grp, event = ev.event })
  if not ok or #acs == 0 then
    return
  end
  local o = { group = grp, modeline = false, data = ev.data }
  if ev.event == "User" then
    o.pattern = ev.match
  elseif ev.buf and api.nvim_buf_is_valid(ev.buf) then
    o.buffer = ev.buf
  end
  pcall(api.nvim_exec_autocmds, ev.event, o)
end

--- Enable at runtime (config override) and load.
---@param name string
---@return table? api, string? err
function M.enable(name)
  config().set_enabled(name, true)
  if state[name] and state[name].status == "failed" then
    state[name] = nil
  end
  if M.is_loaded(name) then
    local spec = M.spec(name)
    if spec then
      require("slop.core.keymaps").apply(name, spec, config().get(name))
    end
    return state[name].api
  end
  return M.load(name)
end

--- Disable at runtime. Calls spec.teardown() when present (then the module can be set up again later);
--- otherwise removes its global keymaps and warns that a restart is needed to fully unload it.
---@param name string
function M.disable(name)
  config().set_enabled(name, false)
  require("slop.core.keymaps").remove(name)
  if M.is_loaded(name) then
    local spec = M.spec(name)
    if spec and spec.teardown then
      local ok, err = pcall(spec.teardown)
      if not ok then
        log().notify(("slop: %s teardown failed: %s"):format(name, err), vim.log.levels.ERROR)
      end
      state[name] = nil
    else
      log().notify(("slop: %s has no teardown; restart Neovim to fully unload it"):format(name), vim.log.levels.WARN)
    end
  end
  require("slop.core.events").emit(nil, "ModuleDisabled", { name = name })
end

--- Called by config.setup(): forget failed loads and cached specs of user modules.
function M.on_config_changed()
  for name, st in pairs(state) do
    if st.status == "failed" then
      state[name] = nil
    end
  end
  for name in pairs(specs) do
    if not M.is_loaded(name) then
      specs[name] = nil
      spec_errors[name] = nil
    end
  end
  discovered = nil
end

--- Test helper: forget everything.
function M._reset()
  state, specs, spec_errors, services, discovered = {}, {}, {}, {}, nil
end

return M

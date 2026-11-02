--- Config resolution: defaults < vim.g.slop < setup(opts) (< runtime enable/disable overrides).
---
--- Namespaces:
---   * core:     ui, log, project, secrets (defaults below)
---   * services: e.g. ai (defaults from `lua/slop/services/<name>/init.lua` spec)
---   * modules:  e.g. term (defaults from the module spec); `opts.<module> = false` disables it
---   * `opts.modules = { name = spec }` registers user modules (same contract as built-ins)
---
--- Nothing here touches modules at setup() time: per-namespace config is merged and validated lazily
--- on the first `config.get(ns)`.
---@class slop.ConfigModule
local M = {}

---@alias slop.Opts table<string, any>

---@class slop.Config.Ui
---@field border string|string[]   Border for every slop float ("rounded" default).
---@field spinner string           Spinner style name (core.ui.spinner).
---@field picker "auto"|"fzf"|"builtin"|"select"  Picker backend (core.ui.picker).

---@class slop.Config.Log
---@field level string|integer     Notify threshold ("trace"|"debug"|"info"|"warn"|"error"|"off" or vim.log.levels.*).
---@field max_entries integer      Ring buffer size for :Slop log.

---@class slop.Config.Project
---@field root_markers string[]    Markers for vim.fs.root().
---@field dir string               Project-local folder name (".nvim").

---@class slop.Config.Secrets
---@field block string[]           File globs whose content never reaches AI.
---@field placeholder string       Replacement text for redacted spans.
---@field agent_reads "deny"|"allow"  Whether ACP agents may read blocked files.
---@field detectors boolean        Built-in token detectors (cloud/API keys, JWTs, URL passwords) for AI text.

---@class slop.Config.Core
---@field ui slop.Config.Ui
---@field log slop.Config.Log
---@field project slop.Config.Project
---@field secrets slop.Config.Secrets

M.core_defaults = {
  ui = { border = "rounded", spinner = "dots", picker = "auto" },
  log = { level = "warn", max_entries = 2000 },
  project = { root_markers = { ".git" }, dir = ".nvim" },
  secrets = {
    -- Globs without "/" match the file name, the others match below any directory.
    block = {
      ".env*",
      "*.pem",
      "*.key",
      "*.p12",
      "*.pfx",
      "*secret*",
      "*credential*",
      "*private-key*",
      ".netrc",
      "_netrc",
      ".npmrc",
      ".pypirc",
      ".git-credentials",
      ".kube/config",
      "*kubeconfig*",
      "*service-account*.json",
      "id_rsa",
      "id_dsa",
      "id_ecdsa",
      "id_ed25519",
    },
    placeholder = "<redacted>",
    agent_reads = "deny",
    detectors = true,
  },
}

--- Core namespace names.
M.core_namespaces = { ui = true, log = true, project = true, secrets = true }

--- Top-level keys that are not namespaces.
M.reserved = { modules = true }

M.log_levels = {
  trace = vim.log.levels.TRACE,
  debug = vim.log.levels.DEBUG,
  info = vim.log.levels.INFO,
  warn = vim.log.levels.WARN,
  error = vim.log.levels.ERROR,
  off = vim.log.levels.OFF,
}

local setup_opts = {} ---@type table
local setup_modules = {} ---@type table<string, slop.ModuleSpec>
local overrides = {} ---@type table<string, boolean>
local raw_cache = nil ---@type table?
local g_modules = nil ---@type table<string, slop.ModuleSpec>?
local cache = {} ---@type table<string, table>
local errors = {} ---@type table<string, string[]>
local reported = {} ---@type table<string, boolean>

--- vim.g.slop: a table or a function returning one (not copied).
---@return table?
local function vim_g()
  local g = vim.g.slop
  if type(g) == "function" then
    local ok, res = pcall(g)
    g = ok and res or nil
  end
  return type(g) == "table" and g or nil
end

--- vim.g.slop without `modules`, copied (runtime overrides must not write into it).
local function from_vim_g()
  local out = {}
  for k, v in pairs(vim_g() or {}) do
    if k ~= "modules" then
      out[k] = v
    end
  end
  return vim.deepcopy(out)
end

local function report(key, msg, level)
  if reported[key] then
    return
  end
  reported[key] = true
  require("slop.core.log").notify(msg, level or vim.log.levels.ERROR)
end

local TYPES = {
  ["nil"] = true,
  boolean = true,
  number = true,
  string = true,
  table = true,
  ["function"] = true,
  thread = true,
  userdata = true,
}

--- Validation messages never echo option values ("<path>: expected <what>, got <value>" keeps only type
--- names): the classic mistake `api_key = "sk-..."` would otherwise print the key in notifications,
--- :messages, :Slop log and :checkhealth.
---@param msg string
---@return string
function M.hide_values(msg)
  return (
    msg:gsub(", got ([^\n]*)", function(rest)
      local t = rest:match("^(%l+)$") or rest:match("^(%l+)%. Info: ")
      if t and TYPES[t] then
        return nil -- a type name: keep
      end
      return ", got an invalid value"
    end)
  )
end

--- The name -> spec entries of a `modules` option. Anything else (e.g. a list of specs) is reported and
--- dropped: an integer key would break every sorted module list (:Slop, completion, health).
---@param mods any
---@param origin string  where the option came from, for the message
---@return table<string, slop.ModuleSpec>
local function module_map(mods, origin)
  local out = {}
  if mods == nil then
    return out
  end
  if type(mods) ~= "table" then
    report(
      origin .. ".modules",
      ("slop: %s: `modules` must be a table of name = spec, got %s"):format(origin, type(mods))
    )
    return out
  end
  for k, v in pairs(mods) do
    if type(k) == "string" and type(v) == "table" then
      out[k] = v
    else
      report(
        origin .. ".modules." .. tostring(k),
        ("slop: %s: `modules` maps module names to specs (`modules = { name = spec }`); ignoring [%s] = %s"):format(
          origin,
          vim.inspect(k),
          type(v)
        )
      )
    end
  end
  return out
end

--- Drop every cached/merged value (next get() recomputes).
function M.invalidate()
  raw_cache = nil
  g_modules = nil
  cache = {}
  errors = {}
  reported = {}
end

local function fire_changed()
  pcall(vim.api.nvim_exec_autocmds, "User", { pattern = "SlopConfigChanged", modeline = false })
end

--- Cheap checks of module options that need no module spec. A module whose options are only validated
--- on its first config.get() is never validated when a mistake leaves it disabled
--- (`term = { enabled = "yes" }`, `hello = true`), so report those here.
---@return table<string, string[]>
local function module_errors()
  local out = {}
  local manifest = require("slop.manifest")
  local user_mods = M.user_modules()
  for k, v in pairs(M.raw()) do
    if type(k) == "string" and not (M.core_namespaces[k] or M.reserved[k]) then
      local is_module = manifest[k] or user_mods[k] or require("slop.core.registry").kind(k) == "module"
      if is_module and type(v) ~= "table" and v ~= false then
        out[k] = { ("%s: expected table|false, got %s"):format(k, type(v)) }
      elseif is_module and type(v) == "table" and v.enabled ~= nil and type(v.enabled) ~= "boolean" then
        out[k] = { ("%s.enabled: expected boolean, got %s"):format(k, type(v.enabled)) }
      end
    end
  end
  return out
end

--- Store user options. Does not load any module. Fires `User SlopConfigChanged`.
---@param opts? slop.Opts
function M.setup(opts)
  opts = opts or {}
  if type(opts) ~= "table" then
    report("setup", "slop: setup() expects a table, got " .. type(opts))
    opts = {}
  end
  -- Options are copied, module specs are not: a spec's `api` table is what require("slop").<name> returns,
  -- and specs may hold values that cannot be copied (timers, parsed queries).
  local o = {}
  for k, v in pairs(opts) do
    if k ~= "modules" then
      o[k] = v
    end
  end
  setup_opts = vim.deepcopy(o)
  M.invalidate()
  setup_modules = module_map(opts.modules, "setup()")
  local registry = package.loaded["slop.core.registry"]
  if registry then
    registry.on_config_changed()
  end
  -- Cheap checks that need no module spec: core namespaces (get() reports their errors, once) + top-level keys.
  for ns in pairs(M.core_namespaces) do
    M.errors(ns)
  end
  for ns, msgs in pairs(module_errors()) do
    -- same key as config.get(ns) uses, so the error is not reported twice
    report(ns, "slop: invalid config:\n  " .. table.concat(msgs, "\n  "))
  end
  local unknown = M.unknown_top()
  if #unknown > 0 then
    report("top", "slop: unknown option(s): " .. table.concat(unknown, ", "), vim.log.levels.WARN)
  end
  fire_changed()
end

--- Merged raw user options (vim.g.slop < setup opts < runtime overrides), without defaults.
--- `modules` is excluded (see user_modules()).
---@return table
function M.raw()
  if raw_cache then
    return raw_cache
  end
  local raw = vim.tbl_deep_extend("force", from_vim_g(), setup_opts)
  for name, enabled in pairs(overrides) do
    -- a copy: tbl_deep_extend() shares the sub-tables that only setup() has, and the override must not end
    -- up in the stored setup() options (it would survive set_enabled(name, nil))
    raw[name] = vim.tbl_extend("force", type(raw[name]) == "table" and raw[name] or {}, { enabled = enabled })
  end
  raw_cache = raw
  return raw
end

--- User-registered module specs (`opts.modules` of vim.g.slop and setup()), name -> spec.
---@return table<string, slop.ModuleSpec>
function M.user_modules()
  if not g_modules then
    local g = vim_g()
    g_modules = module_map(g and g.modules, "vim.g.slop")
  end
  local out = {}
  for k, v in pairs(g_modules) do
    out[k] = v
  end
  for k, v in pairs(setup_modules) do
    out[k] = v
  end
  return out
end

--- Runtime enable/disable (used by :Slop modules enable|disable). Fires `User SlopConfigChanged`.
---@param name string
---@param enabled boolean|nil  nil removes the override
function M.set_enabled(name, enabled)
  overrides[name] = enabled
  M.invalidate()
  fire_changed()
end

--- Default config of a namespace (deep copy).
---@param ns string
---@return table
function M.defaults(ns)
  if M.core_namespaces[ns] then
    return vim.deepcopy(M.core_defaults[ns])
  end
  local registry = require("slop.core.registry")
  local kind = registry.kind(ns)
  local spec
  if kind == "module" then
    spec = registry.spec(ns)
  elseif kind == "service" then
    spec = registry.service_spec(ns)
  else
    error(("slop: unknown config namespace '%s'"):format(ns), 2)
  end
  return vim.deepcopy(spec and spec.defaults or { enabled = false })
end

--- Is the module enabled? Never loads code for built-in modules (uses the manifest default).
---@param name string
---@return boolean
function M.enabled(name)
  local r = M.raw()[name]
  if r == false then
    return false
  elseif type(r) == "table" and r.enabled ~= nil then
    return r.enabled == true
  end
  local entry = require("slop.manifest")[name]
  if entry then
    return entry.default_enabled ~= false
  end
  local um = M.user_modules()[name]
  if um then
    return not (type(um.defaults) == "table" and um.defaults.enabled == false)
  end
  local spec = require("slop.core.registry").spec(name)
  return spec ~= nil and spec.defaults.enabled ~= false
end

---@param prefix string
---@param out string[]
---@return fun(path: string, value: any, validator: any, optional?: boolean, message?: string)
function M.checker(prefix, out)
  return function(path, value, validator, optional, message)
    if type(optional) == "string" then
      optional, message = nil, optional
    end
    local name = prefix .. path
    if vim.is_callable(validator) then
      -- Not through vim.validate(): for function validators it reports "got <tostring(value)>", which
      -- prints whatever the user put there (an API key pasted into `api_key`). Report the type only.
      if value == nil and optional == true then
        return
      end
      local ok, valid, info = pcall(validator, value)
      if not ok then
        out[#out + 1] = ("%s: %s"):format(name, M.hide_values((tostring(valid):gsub("^[^\n]-:%d+: ", ""))))
      elseif not valid then
        out[#out + 1] = ("%s: expected %s, got %s"):format(name, message or "?", type(value))
          .. (type(info) == "string" and (". Info: " .. info) or "")
      end
      return
    end
    local ok, err = pcall(vim.validate, name, value, validator, optional, message)
    if not ok then
      out[#out + 1] = (tostring(err):gsub("^[^\n]-:%d+: ", ""))
    end
  end
end

local function is_level(v)
  return (type(v) == "string" and M.log_levels[v] ~= nil) or type(v) == "number"
end

local core_schema = {
  ui = function(c, check)
    check("border", c.border, { "string", "table" })
    check("spinner", c.spinner, "string")
    check("picker", c.picker, function(v)
      return v == "auto" or v == "fzf" or v == "builtin" or v == "select"
    end, false, "'auto'|'fzf'|'builtin'|'select'")
  end,
  log = function(c, check)
    check("level", c.level, is_level, false, "log level name or number")
    check("max_entries", c.max_entries, function(v)
      return type(v) == "number" and v >= 1 and v == math.floor(v)
    end, false, "integer >= 1")
  end,
  project = function(c, check)
    check("root_markers", c.root_markers, "table")
    check("dir", c.dir, function(v)
      return type(v) == "string" and v ~= ""
    end, false, "non-empty string")
  end,
  secrets = function(c, check)
    check("block", c.block, "table")
    check("placeholder", c.placeholder, "string")
    check("agent_reads", c.agent_reads, function(v)
      return v == "deny" or v == "allow"
    end, false, "'deny'|'allow'")
    check("detectors", c.detectors, "boolean")
  end,
}

local function check_keymaps(prefix, km, defaults, out)
  if type(km) ~= "table" then
    out[#out + 1] = prefix .. ": expected table, got " .. type(km)
    return
  end
  for k, v in pairs(km) do
    local path = prefix .. "." .. tostring(k)
    if type(v) == "table" then
      check_keymaps(path, v, type(defaults) == "table" and defaults[k] or nil, out)
    elseif type(v) ~= "string" and v ~= false then
      out[#out + 1] = path .. ": expected string|false, got " .. type(v)
    end
  end
end

--- Validate a merged namespace config. Errors carry "<ns>.<field>" paths.
---@param ns string
---@param cfg table
---@return string[]
function M.validate(ns, cfg)
  local out = {}
  local check = M.checker(ns .. ".", out)
  if M.core_namespaces[ns] then
    core_schema[ns](cfg, check)
    return out
  end
  local registry = require("slop.core.registry")
  local kind = registry.kind(ns)
  local spec = kind == "module" and registry.spec(ns) or kind == "service" and registry.service_spec(ns) or nil
  if kind == "module" then
    check("enabled", cfg.enabled, "boolean")
    if cfg.keymaps ~= nil then
      check_keymaps(ns .. ".keymaps", cfg.keymaps, spec and spec.defaults.keymaps, out)
    end
  end
  if spec and spec.schema then
    local ok, err = pcall(spec.schema, cfg, check)
    if not ok then
      err = M.hide_values((tostring(err):gsub("^[^\n]-:%d+: ", "")))
      if not vim.startswith(err, ns .. ".") then
        err = ns .. "." .. err
      end
      out[#out + 1] = err
    end
  end
  return out
end

--- Resolved config of a namespace. Without `ns`, returns the core namespaces { ui, log, project, secrets }.
--- Invalid or unknown options are reported once via core.log (also listed in :checkhealth slop).
---@overload fun(): slop.Config.Core
---@param ns string
---@return table
function M.get(ns)
  if ns == nil then
    return { ui = M.get("ui"), log = M.get("log"), project = M.get("project"), secrets = M.get("secrets") }
  end
  local cached = cache[ns]
  if cached then
    return cached
  end
  local cfg = M.defaults(ns)
  local user = M.raw()[ns]
  local type_err = nil
  if user == false then
    cfg.enabled = false
  elseif type(user) == "table" then
    cfg = vim.tbl_deep_extend("force", cfg, user)
  elseif user ~= nil then
    -- an error like any other (also listed by :checkhealth), not only a one-off notification
    type_err = ("%s: expected table|false, got %s"):format(ns, type(user))
  end
  cache[ns] = cfg
  errors[ns] = M.validate(ns, cfg)
  if type_err then
    table.insert(errors[ns], 1, type_err)
  end
  if #errors[ns] > 0 then
    report(ns, "slop: invalid config:\n  " .. table.concat(errors[ns], "\n  "))
  end
  local unknown = M.unknown(ns)
  if #unknown > 0 then
    report(ns .. ".unknown", "slop: unknown option(s): " .. table.concat(unknown, ", "), vim.log.levels.WARN)
  end
  return cfg
end

--- Validation errors of a namespace (computes it if needed).
---@param ns string
---@return string[]
function M.errors(ns)
  if not errors[ns] then
    M.get(ns)
  end
  return errors[ns] or {}
end

local function open_paths(ns)
  local set = {}
  if not M.core_namespaces[ns] then
    local registry = require("slop.core.registry")
    local kind = registry.kind(ns)
    local spec = kind == "module" and registry.spec(ns) or kind == "service" and registry.service_spec(ns) or nil
    for _, p in ipairs(spec and spec.open_keys or {}) do
      set[p] = true
    end
  end
  return set
end

local function collect_unknown(user, defaults, prefix, open, out)
  if type(user) ~= "table" or vim.islist(user) or type(defaults) ~= "table" then
    return
  end
  for k, v in pairs(user) do
    local path = prefix == "" and tostring(k) or prefix .. "." .. tostring(k)
    local d = defaults[k]
    if d == nil then
      out[#out + 1] = path
    elseif type(d) == "table" and not open[path] and next(d) ~= nil and not vim.islist(d) then
      collect_unknown(v, d, path, open, out)
    end
  end
end

--- Option paths the user set that do not exist in the namespace defaults (typos).
--- Sub-tables that are empty or lists in the defaults, or listed in spec.open_keys, are free-form.
---@param ns string
---@return string[]
function M.unknown(ns)
  local user = M.raw()[ns]
  local out = {}
  if type(user) ~= "table" then
    return out
  end
  local defaults = M.defaults(ns)
  local open = open_paths(ns)
  local list = {}
  collect_unknown(user, defaults, "", open, list)
  table.sort(list)
  for _, p in ipairs(list) do
    out[#out + 1] = ns .. "." .. p
  end
  return out
end

--- Top-level option keys that are neither a core namespace, a known module/service, nor reserved.
---@return string[]
function M.unknown_top()
  local out = {}
  local manifest = require("slop.manifest")
  local user_mods = M.user_modules()
  for k in pairs(M.raw()) do
    if not (M.core_namespaces[k] or M.reserved[k] or manifest[k] or user_mods[k]) then
      local registry = require("slop.core.registry")
      if not registry.kind(k) then
        out[#out + 1] = tostring(k)
      end
    end
  end
  table.sort(out)
  return out
end

--- Numeric notify threshold from log.level.
---@return integer
function M.log_level()
  local lvl = M.get("log").level
  if type(lvl) == "number" then
    return lvl
  end
  return M.log_levels[lvl] or vim.log.levels.WARN
end

return M

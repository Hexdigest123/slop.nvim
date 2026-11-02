-- slop.nvim bootstrap. Sourced eagerly at startup by every plugin manager.
-- Rule: require nothing but `slop.manifest` here. Everything else is required inside callbacks.
if vim.g.loaded_slop then
  return
end
vim.g.loaded_slop = true

if vim.fn.has("nvim-0.12") == 0 then
  vim.notify_once("slop: slop.nvim requires Neovim >= 0.12", vim.log.levels.ERROR)
  return
end

local api = vim.api
local manifest = require("slop.manifest")
local group = api.nvim_create_augroup("slop.bootstrap", { clear = true })

-- Neovim has no *.rest mapping; treat it as http so `ft` triggers fire.
vim.filetype.add({ extension = { rest = "http" } })

-- 1. Core highlight groups. default = true so colorschemes and users win.
--    Modules declare their own groups (Slop<Module><Thing>) in spec.highlights.
local core_hl = {
  SlopNormal = { link = "NormalFloat" },
  SlopBorder = { link = "FloatBorder" },
  SlopTitle = { link = "FloatTitle" },
  SlopFooter = { link = "FloatFooter" },
  SlopGhost = { link = "Comment" },
  SlopDim = { link = "DiagnosticUnnecessary" },
  SlopSpinner = { link = "DiagnosticInfo" },
  SlopDiffAdd = { link = "DiffAdd" },
  SlopDiffDelete = { link = "DiffDelete" },
  SlopDiffChange = { link = "DiffChange" },
  SlopDiffText = { link = "DiffText" },
  SlopMatch = { link = "Special" },
  SlopSelected = { link = "CursorLine" },
  SlopRedacted = { link = "Comment" },
}

local function set_hl()
  for name, val in pairs(core_hl) do
    val.default = true
    api.nvim_set_hl(0, name, val)
  end
  local util = package.loaded["slop.core.util"]
  if util then
    util.reapply_hl()
  end
end
set_hl()
api.nvim_create_autocmd("ColorScheme", { group = group, callback = set_hl, desc = "slop: re-apply highlight links" })

-- 2. The single :Slop command.
api.nvim_create_user_command("Slop", function(cmd)
  require("slop.core.commands").run(cmd)
end, {
  nargs = "*",
  range = true,
  bang = true,
  desc = "slop.nvim: :Slop <module> <subcommand> [args]",
  complete = function(arg_lead, cmdline, cursor_pos)
    return require("slop.core.commands").complete(arg_lead, cmdline, cursor_pos)
  end,
})

-- Raw user options (vim.g.slop < setup()) without loading slop.config unless setup() already did.
local function user_opts()
  local config = package.loaded["slop.config"]
  if config then
    return config.raw()
  end
  local g = vim.g.slop
  if type(g) == "function" then
    local ok, res = pcall(g)
    g = ok and res or nil
  end
  return type(g) == "table" and g or {}
end

---@return table<string, slop.ManifestEntry>
local function entries()
  local all = {}
  for name, entry in pairs(manifest) do
    all[name] = entry
  end
  local config = package.loaded["slop.config"]
  if config then
    for name, spec in pairs(config.user_modules()) do
      if not all[name] then
        all[name] = type(spec.manifest) == "table" and spec.manifest or { cmd = true }
      end
    end
  end
  return all
end

local function is_enabled(name, entry, opts)
  local o = opts[name]
  if o == false then
    return false
  elseif type(o) == "table" and o.enabled ~= nil then
    return o.enabled == true
  end
  local config = package.loaded["slop.config"]
  local spec = config and config.user_modules()[name]
  if spec and type(spec.defaults) == "table" and spec.defaults.enabled ~= nil then
    return spec.defaults.enabled == true
  end
  return entry.default_enabled ~= false
end

local function modes(m)
  return type(m) == "table" and m or { m }
end

local function plug(name, action)
  return ("<Plug>(slop-%s-%s)"):format(name, (action:gsub("[_.]", "-")))
end

-- 3. <Plug> stubs and lazy triggers. Both are idempotent per module name.
local installed = {} ---@type table<string, boolean>
local triggers = {} ---@type table<string, integer[]>

local function install_plugs(name, entry)
  for action, key in pairs(entry.keys or {}) do
    local expr = key.expr == true
    vim.keymap.set(modes(key.mode), plug(name, action), function()
      return require("slop.core.registry").run_keymap(name, action, { expr = expr })
    end, { desc = key.desc, expr = expr, silent = true })
  end
end

-- Read events whose buffers were opened before slop was sourced late (lazy.nvim `event = "VeryLazy"`, ...):
-- those files never fire them again, so their modules load right away.
local read_events = { BufReadPre = true, BufReadPost = true, BufRead = true, BufNewFile = true }

---@return integer[] buffers showing a file
local function file_buffers()
  local out = {}
  for _, buf in ipairs(api.nvim_list_bufs()) do
    if api.nvim_buf_is_loaded(buf) and vim.bo[buf].buftype == "" and api.nvim_buf_get_name(buf) ~= "" then
      out[#out + 1] = buf
    end
  end
  return out
end

local function install_triggers(name, entry)
  if triggers[name] then
    return
  end
  local ids = {}
  triggers[name] = ids
  --- These triggers are still the live ones (not fired or replaced, plugin not re-sourced).
  local function armed()
    local ok, acs = pcall(api.nvim_get_autocmds, { group = group })
    for _, ac in ipairs(ok and triggers[name] == ids and acs or {}) do
      if ac.id == ids[1] then
        return true
      end
    end
    return false
  end
  ---@param ev table
  ---@param more? table[]  further events to replay (buffers open before the triggers existed)
  local function fire(ev, more)
    if not is_enabled(name, entry, user_opts()) then
      return -- keep the trigger: the module may be enabled later
    end
    for _, id in ipairs(ids) do
      pcall(api.nvim_del_autocmd, id)
    end
    if triggers[name] == ids then
      triggers[name] = nil -- install() arms new ones if this load fails or the module is torn down later
    end
    -- Nothing may escape into the triggering autocmd, not even an error message (invalid config, failed
    -- load): in the BufReadPre of an `:edit` run from Lua it becomes an exception and the file is not read.
    -- So errors are caught and every notification is shown right after.
    local log = require("slop.core.log")
    log.deferred(function()
      local ok, err = xpcall(function()
        local registry = require("slop.core.registry")
        if registry.is_loaded(name) then
          return -- loaded meanwhile (:Slop, a key, require()): its own autocmds see this event anyway
        end
        if registry.load(name, { silent = true, trigger = true }) then
          registry.replay(name, ev)
          for _, e in ipairs(more or {}) do
            registry.replay(name, e)
          end
        end
      end, debug.traceback)
      if not ok then
        log.notify(("slop: lazy-loading %s failed: %s"):format(name, err), vim.log.levels.ERROR)
      end
    end)
  end
  local late = false
  for _, e in ipairs(entry.events or {}) do
    local event, pattern = e:match("^(%S+)%s*(.*)$")
    ids[#ids + 1] = api.nvim_create_autocmd(event, {
      group = group,
      pattern = pattern ~= "" and pattern or nil,
      callback = function(ev)
        fire(ev)
      end,
      desc = "slop: lazy-load " .. name,
    })
    late = late or (read_events[event] and pattern == "") or false
  end
  if late and vim.v.vim_did_enter == 1 then
    -- Scheduled, like the ft case below: the plugin manager calls setup() right after sourcing.
    vim.schedule(function()
      local bufs = armed() and file_buffers() or {}
      if #bufs > 0 then
        local evs = {}
        for _, buf in ipairs(bufs) do
          evs[#evs + 1] = { event = "BufReadPost", buf = buf, match = api.nvim_buf_get_name(buf) }
        end
        fire(table.remove(evs, 1), evs)
      end
    end)
  end
  if entry.ft and #entry.ft > 0 then
    ids[#ids + 1] = api.nvim_create_autocmd("FileType", {
      group = group,
      pattern = entry.ft,
      callback = function(ev)
        fire(ev)
      end,
      desc = "slop: lazy-load " .. name,
    })
    -- Buffers that already have the filetype (slop itself was lazy-loaded late).
    for _, buf in ipairs(api.nvim_list_bufs()) do
      if api.nvim_buf_is_loaded(buf) and vim.tbl_contains(entry.ft, vim.bo[buf].filetype) then
        vim.schedule(function()
          if armed() and api.nvim_buf_is_valid(buf) then
            fire({ event = "FileType", buf = buf, match = vim.bo[buf].filetype })
          end
        end)
        break
      end
    end
  end
end

local function install()
  for name, entry in pairs(entries()) do
    if not installed[name] then
      installed[name] = true
      install_plugs(name, entry)
    end
    local registry = package.loaded["slop.core.registry"]
    if not (registry and registry.is_loaded(name)) then
      install_triggers(name, entry)
    end
  end
end
install()

-- 4. Default keymaps: lhs -> <Plug>. Applied after init.lua (so setup()/mapleader are known) and
--    re-applied whenever the config changes (User SlopConfigChanged, fired by setup() and :Slop modules).
local applied = {} ---@type {mode: string, lhs: string, rhs: string}[]  lhs as mapped (<leader> expanded)

local function sync_keys()
  for _, m in ipairs(applied) do
    local cur = vim.fn.maparg(m.lhs, m.mode, false, true)
    if cur.rhs == m.rhs then
      pcall(vim.keymap.del, m.mode, m.lhs)
    end
  end
  applied = {}
  local opts = user_opts()
  for name, entry in pairs(entries()) do
    if entry.keys and is_enabled(name, entry, opts) then
      local km = type(opts[name]) == "table" and type(opts[name].keymaps) == "table" and opts[name].keymaps or {}
      for action, key in pairs(entry.keys) do
        local lhs = km[action]
        if lhs == nil then
          lhs = key.lhs
        end
        if type(lhs) == "string" and lhs ~= "" then
          local rhs = plug(name, action)
          for _, mode in ipairs(modes(key.mode)) do
            if vim.fn.maparg(lhs, mode) == "" and vim.fn.hasmapto(rhs, mode) == 0 then
              vim.keymap.set(mode, lhs, rhs, { remap = true, desc = key.desc })
              local set = vim.fn.maparg(lhs, mode, false, true)
              -- Remember the lhs as mapped: "<leader>" expands to the mapleader of now, and after a
              -- mapleader change the next sync must still find this map to move it.
              applied[#applied + 1] = { mode = mode, lhs = set.lhs or lhs, rhs = set.rhs or rhs }
            end
          end
        end
      end
    end
  end
end

if vim.v.vim_did_enter == 1 then
  sync_keys()
else
  api.nvim_create_autocmd(
    "VimEnter",
    { group = group, once = true, callback = sync_keys, desc = "slop: default keymaps" }
  )
end

api.nvim_create_autocmd("User", {
  group = group,
  pattern = "SlopConfigChanged",
  callback = function()
    install()
    if vim.v.vim_did_enter == 1 then
      sync_keys()
    end
  end,
  desc = "slop: re-apply triggers and default keymaps",
})

--- Module keymaps.
---
--- A module declares `spec.keymaps` as a table (or `fun(cfg): table`) of name -> slop.KeymapSpec.
--- The lhs always comes from config: `cfg.keymaps[<name>]` (dotted names reach nested tables, e.g.
--- "diff.accept" -> cfg.keymaps.diff.accept). Setting it to `false` disables that keymap.
---
--- Kinds:
---   * global (default): `<Plug>(slop-<module>-<name>)` + lhs -> <Plug> (only if lhs is free and the user
---     has not mapped the <Plug> themselves). Global keymaps listed in the manifest are created at startup by
---     plugin/slop.lua; the rest when the module loads.
---   * `ft = { ... }`: buffer-local in buffers of those filetypes (applied on FileType + already-open buffers).
---   * `buffer = true`: buffer-local, created only when the module calls `keymaps.apply_buf(module, buf)`.
---   * `fallthrough = true` (insert-mode style): rhs returning `false` falls through to the previous mapping
---     of the lhs (e.g. nvim-cmp) or to the native key. Mapped directly on the lhs.
---
--- Rules: never bind <Tab> by default; `desc` is required (shown with a "slop: " prefix).
---@class slop.keymaps
local M = {}

local api = vim.api

---@class slop.KeymapSpec
---@field mode string|string[]       Mode(s), e.g. "n", { "n", "x" }, "i", "t".
---@field rhs fun(): any|string       Handler (module is loaded when it runs). For expr maps, returns keys.
---@field desc string                Required.
---@field lhs? string                Default lhs when cfg.keymaps has no entry for this name (rare; prefer config).
---@field expr? boolean
---@field buffer? boolean            Buffer-local; module applies it with keymaps.apply_buf().
---@field ft? string[]               Buffer-local in these filetypes.
---@field fallthrough? boolean       rhs returning false falls through to the previous mapping / native key.
---@field nowait? boolean
---@field silent? boolean            default true

---@class slop.ResolvedKeymap
---@field module string
---@field name string
---@field lhs string|false
---@field modes string[]
---@field spec slop.KeymapSpec
---@field plug string

local applied = {} ---@type table<string, {mode: string, lhs: string, rhs: string}[]>  global maps per module
local resolved = {} ---@type table<string, slop.ResolvedKeymap[]>

--- `<Plug>(slop-<module>-<name>)`; "_" and "." become "-".
---@param module string
---@param name string
---@return string
function M.plug(module, name)
  return ("<Plug>(slop-%s-%s)"):format(module, (name:gsub("[_.]", "-")))
end

local function modes(m)
  return type(m) == "table" and m or { m }
end

--- Resolve a module's keymaps against its config.
---@param module string
---@param spec slop.ModuleSpec
---@param cfg table
---@return slop.ResolvedKeymap[]
function M.resolve(module, spec, cfg)
  local km = spec.keymaps
  if type(km) == "function" then
    km = km(cfg)
  end
  local out = {}
  for name, k in pairs(km or {}) do
    local lhs = require("slop.core.util").tbl_get(cfg.keymaps or {}, name)
    if lhs == nil then
      lhs = k.lhs
    end
    if type(lhs) ~= "string" or lhs == "" then
      lhs = false
    end
    out[#out + 1] =
      { module = module, name = name, lhs = lhs, modes = modes(k.mode), spec = k, plug = M.plug(module, name) }
  end
  table.sort(out, function(a, b)
    return a.name < b.name
  end)
  return out
end

--- vim.keymap.set wrapper: requires desc, prefixes it with "slop: ", silent by default.
---@param mode string|string[]
---@param lhs string
---@param rhs string|function
---@param opts {desc: string, buf?: integer, expr?: boolean, nowait?: boolean, silent?: boolean, remap?: boolean}
function M.set(mode, lhs, rhs, opts)
  assert(opts and type(opts.desc) == "string" and opts.desc ~= "", "slop: keymaps.set requires opts.desc")
  local desc = vim.startswith(opts.desc, "slop: ") and opts.desc or ("slop: " .. opts.desc)
  vim.keymap.set(mode, lhs, rhs, {
    desc = desc,
    buf = opts.buf,
    expr = opts.expr,
    nowait = opts.nowait,
    silent = opts.silent ~= false,
    remap = opts.remap,
  })
end

--- Buffer-local keymap helper.
---@param buf integer
---@param mode string|string[]
---@param lhs string
---@param rhs string|function
---@param opts {desc: string, expr?: boolean, nowait?: boolean, silent?: boolean}
function M.set_buf(buf, mode, lhs, rhs, opts)
  opts = vim.tbl_extend("force", {}, opts, { buf = buf == 0 and api.nvim_get_current_buf() or buf })
  M.set(mode, lhs, rhs, opts)
end

-- Fall-through ---------------------------------------------------------------------------------

local ours = setmetatable({}, { __mode = "k" }) ---@type table<function, table>

---@param keys string
---@param remap boolean
local function feed(keys, remap)
  api.nvim_feedkeys(keys, remap and "mi" or "ni", false)
end

local function norm(lhs)
  return vim.keycode(lhs)
end

--- The mapping of `lhs` that a fall-through should hand over to (excluding slop fall-through maps).
local function previous(mode, lhs, buf)
  local key = norm(lhs)
  local function find(maps)
    for _, m in ipairs(maps) do
      if norm(m.lhs) == key and not (m.callback and ours[m.callback]) then
        return m
      end
    end
  end
  if buf then
    local m = find(api.nvim_buf_get_keymap(buf, mode))
    if m then
      return m
    end
  end
  return find(api.nvim_get_keymap(mode))
end

local function run_previous(prev, lhs)
  if not prev then
    feed(norm(lhs), false)
    return
  end
  local remap = prev.noremap ~= 1
  if prev.callback then
    local res = prev.callback()
    if prev.expr == 1 and type(res) == "string" and res ~= "" then
      feed(prev.replace_keycodes == 1 and norm(res) or res, remap)
    end
  elseif prev.rhs and prev.rhs ~= "" then
    local rhs = prev.rhs
    if prev.expr == 1 then
      rhs = api.nvim_eval(rhs)
    end
    feed(norm(rhs), remap)
  else
    feed(norm(lhs), false)
  end
end

--- Map `lhs` so that `handler()` runs first; when it returns `false` the key falls through to the mapping
--- that existed before (captured now, or looked up when pressed) or to the native key.
--- The handler runs outside textlock (it may edit the buffer).
---@param mode string
---@param lhs string
---@param handler fun(): boolean?
---@param opts {desc: string, buf?: integer}
---@return fun() fallback  call to perform the fall-through manually
function M.fallthrough(mode, lhs, handler, opts)
  local buf = opts.buf and (opts.buf == 0 and api.nvim_get_current_buf() or opts.buf) or nil
  local captured = previous(mode, lhs, buf)
  if captured and buf and captured.buffer ~= 1 then
    captured = nil -- global maps are looked up at press time (may be (re)defined later, e.g. by cmp)
  end
  local function fallback()
    run_previous(captured or previous(mode, lhs, buf), lhs)
  end
  local function cb()
    local ok, res = pcall(handler)
    if not ok then
      require("slop.core.log").error("keymap %s: %s", lhs, res)
      res = false
    end
    if res == false then
      fallback()
    end
  end
  ours[cb] = { lhs = lhs }
  M.set(mode, lhs, cb, { desc = opts.desc, buf = buf })
  return fallback
end

--- For `expr = true` mappings: returns a function that calls `handler()` and yields `lhs` (the original key)
--- when it returns false, else "". The handler runs under textlock: it must not edit buffers directly
--- (schedule edits, or use keymaps.fallthrough()).
---@param lhs string
---@param handler fun(): boolean?
---@return fun(): string
function M.expr_fallthrough(lhs, handler)
  return function()
    local ok, res = pcall(handler)
    if ok and res ~= false then
      return ""
    end
    return lhs
  end
end

-- Applying module keymaps -----------------------------------------------------------------------

local function define_plug(km)
  local rhs = km.spec.rhs
  vim.keymap.set(km.modes, km.plug, rhs, { desc = "slop: " .. km.spec.desc:gsub("^slop: ", ""), expr = km.spec.expr })
end

local function apply_local(km, buf)
  if not km.lhs then
    return
  end
  for _, mode in ipairs(km.modes) do
    if km.spec.fallthrough then
      M.fallthrough(mode, km.lhs, km.spec.rhs --[[@as fun(): boolean?]], { desc = km.spec.desc, buf = buf })
    else
      M.set(mode, km.lhs, km.spec.rhs, {
        desc = km.spec.desc,
        buf = buf,
        expr = km.spec.expr,
        nowait = km.spec.nowait,
        silent = km.spec.silent,
      })
    end
  end
end

--- Apply a loaded module's keymaps (called by the registry before spec.setup()).
---@param module string
---@param spec slop.ModuleSpec
---@param cfg table
---@param opts? {skip_lhs?: table<string, boolean>}  names whose lhs plugin/slop.lua already manages
---@return slop.ResolvedKeymap[]
function M.apply(module, spec, cfg, opts)
  opts = opts or {}
  local list = M.resolve(module, spec, cfg)
  resolved[module] = list
  applied[module] = applied[module] or {}
  for _, km in ipairs(list) do
    local s = km.spec
    if s.ft then
      if km.lhs then
        api.nvim_create_autocmd("FileType", {
          group = require("slop.core.util").augroup(module),
          pattern = s.ft,
          desc = "slop: " .. module .. " keymap " .. km.name,
          callback = function(ev)
            apply_local(km, ev.buf)
          end,
        })
        for _, b in ipairs(api.nvim_list_bufs()) do
          if api.nvim_buf_is_loaded(b) and vim.tbl_contains(s.ft, vim.bo[b].filetype) then
            apply_local(km, b)
          end
        end
      end
    elseif not s.buffer then
      if s.fallthrough then
        apply_local(km, nil)
      else
        define_plug(km)
        if km.lhs and not (opts.skip_lhs and opts.skip_lhs[km.name]) then
          for _, mode in ipairs(km.modes) do
            if vim.fn.maparg(km.lhs, mode) == "" and vim.fn.hasmapto(km.plug, mode) == 0 then
              vim.keymap.set(mode, km.lhs, km.plug, { remap = true, desc = "slop: " .. s.desc:gsub("^slop: ", "") })
              local set = vim.fn.maparg(km.lhs, mode, false, true)
              table.insert(applied[module], { mode = mode, lhs = km.lhs, rhs = set.rhs })
            end
          end
        end
      end
    end
  end
  return list
end

--- Apply a loaded module's `buffer = true` keymaps to `buf` (all, or only `names`).
---@param module string
---@param buf integer
---@param names? string[]
function M.apply_buf(module, buf, names)
  buf = buf == 0 and api.nvim_get_current_buf() or buf
  for _, km in ipairs(resolved[module] or {}) do
    if km.spec.buffer and (not names or vim.tbl_contains(names, km.name)) then
      apply_local(km, buf)
    end
  end
end

--- Resolved keymaps of a loaded module (for health / docs).
---@param module string
---@return slop.ResolvedKeymap[]
function M.get(module)
  return resolved[module] or {}
end

--- Remove the global lhs mappings created by apply() for a module.
---@param module string
function M.remove(module)
  for _, m in ipairs(applied[module] or {}) do
    local cur = vim.fn.maparg(m.lhs, m.mode, false, true)
    if cur.rhs == m.rhs then
      pcall(vim.keymap.del, m.mode, m.lhs)
    end
  end
  applied[module] = nil
end

return M

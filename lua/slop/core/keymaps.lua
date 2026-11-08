--- Module keymaps.
---
--- A module declares `spec.keymaps` as a table (or `fun(cfg): table`) of name -> slop.KeymapSpec.
--- The lhs always comes from config: `cfg.keymaps[<name>]` (dotted names reach nested tables, e.g.
--- "diff.accept" -> cfg.keymaps.diff.accept). Setting it to `false` disables that keymap.
---
--- Kinds (each also gets a global `<Plug>(slop-<module>-<name>)`, the way to map it yourself):
---   * global (default): `<Plug>(slop-<module>-<name>)` + lhs -> <Plug> (only if lhs is free and the user
---     has not mapped the <Plug> themselves). Global keymaps listed in the manifest are created at startup by
---     plugin/slop.lua; the rest when the module loads.
---   * `ft = { ... }`: buffer-local in buffers of those filetypes (applied on FileType + already-open buffers).
---   * `buffer = true`: buffer-local, created only when the module calls `keymaps.apply_buf(module, buf)`.
---   * `fallthrough = true` (insert-mode style): rhs returning `false` falls through to the previous mapping
---     of the lhs (e.g. nvim-cmp) or to the native key. Mapped directly on the lhs. Its `<Plug>` runs the
---     handler and does nothing when it returns false.
---
--- Handlers installed by apply() only run while their module is loaded and enabled: mappings outlive
--- `:Slop modules disable` and failed setups, and must not keep running a torn-down module.
---
--- Rules: never bind <Tab> by default; `desc` is required (shown with a "slop: " prefix).
---@class slop.keymaps
local M = {}

local api = vim.api

---@class slop.KeymapSpec
---@field mode string|string[]       Mode(s), e.g. "n", { "n", "x" }, "i", "t".
---@field rhs (fun(): any)|string     Handler (module is loaded when it runs). For expr maps, returns keys.
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
local ft_autocmds = {} ---@type table<string, integer[]>  FileType autocmds of ft keymaps per module

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

--- Buffer-local keymap helper (`opts` as for set(), e.g. `nowait = true`).
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
local running = {} ---@type table<function, true>  fall-through callbacks handing their key over right now

---@param keys string
---@param remap boolean
local function feed(keys, remap)
  api.nvim_feedkeys(keys, remap and "mi" or "ni", false)
end

local function norm(lhs)
  return vim.keycode(lhs)
end

--- First mapping of raw keys `key` in `buf` (buffer-local first) or global, except those `skip(m)` rejects.
---@param skip fun(m: table): boolean
local function lookup(mode, key, buf, skip)
  local function find(maps)
    for _, m in ipairs(maps) do
      if norm(m.lhs) == key and not skip(m) then
        return m
      end
    end
  end
  return (buf and find(api.nvim_buf_get_keymap(buf, mode))) or find(api.nvim_get_keymap(mode))
end

local function slop_fallthrough(m)
  return m.callback ~= nil and ours[m.callback] ~= nil
end

--- The mapping a fall-through map replaces when it is set (kept to hand over to). Never a slop fall-through map:
--- that would be its own old version when a module is set up again.
local function replaced(mode, lhs, buf)
  return lookup(mode, norm(lhs), buf, slop_fallthrough)
end

local function handing_over(m)
  return m.callback ~= nil and running[m.callback] ~= nil
end

--- The mapping of `lhs` a pressed fall-through hands over to: the next one, buffer-local before global, also a
--- slop fall-through map (a commit message's `<C-y>` hands over to the AI completion's global one), but none
--- that is handing over already (not itself: no loops).
local function previous(mode, lhs, buf)
  return lookup(mode, norm(lhs), buf, handing_over)
end

--- Does another mapping (in `buf` or global, not the one with callback `self`) start with raw `key` and go on?
local function continued(mode, key, buf, self)
  local function scan(maps)
    for _, m in ipairs(maps) do
      local k = norm(m.lhs)
      if #k > #key and k:sub(1, #key) == key and m.callback ~= self then
        return true
      end
    end
    return false
  end
  return (buf ~= nil and scan(api.nvim_buf_get_keymap(buf, mode))) or scan(api.nvim_get_keymap(mode))
end

--- The next typed key (raw). nil when 'timeout' is set and nothing came within 'timeoutlen': Vim stops
--- waiting for a longer mapping then too.
---@return string?
local function next_key()
  if not vim.o.timeout then
    local ok, c = pcall(vim.fn.getcharstr)
    return ok and c or "\3"
  end
  local c = ""
  vim.wait(vim.o.timeoutlen, function()
    local ok, k = pcall(vim.fn.getcharstr, 0)
    c = ok and k or "\3"
    return c ~= ""
  end, 5)
  return c ~= "" and c or nil
end

--- Count and register the key was typed with (Normal and Visual mode), for keys handed over by feeding.
---@return string
local function typed_prefix()
  local mode = vim.fn.mode(1)
  if not mode:match("^[nvV\22]") or mode:match("^no") then
    return ""
  end
  local p = (vim.v.register ~= "" and vim.v.register ~= '"') and ('"' .. vim.v.register) or ""
  return vim.v.count > 0 and (p .. vim.v.count) or p
end

local function run_previous(prev, lhs)
  if not prev then
    feed(typed_prefix() .. norm(lhs), false)
    return
  end
  local remap = prev.noremap ~= 1
  if prev.callback then
    local res = prev.callback()
    if prev.expr == 1 and type(res) == "string" and res ~= "" then
      feed(typed_prefix() .. (prev.replace_keycodes == 1 and norm(res) or res), remap)
    end
  elseif prev.rhs and prev.rhs ~= "" then
    local rhs = prev.rhs
    if prev.expr == 1 then
      rhs = api.nvim_eval(rhs)
    end
    feed(typed_prefix() .. norm(rhs), remap)
  end
  -- (an empty rhs is <Nop>: the key was disabled on purpose, so nothing runs, not even the native key)
end

--- Map `lhs` so that `handler()` runs first; when it returns `false` the key falls through to the mapping
--- that existed before (captured now, or looked up when pressed) or to the native key, with its count.
--- When other mappings go on from `lhs` (a review's buffer-local `gr` and the 0.11+ global `grn`, `grr`, ...)
--- the following keys are read as if this map did not exist: the longest mapping matching them runs, else
--- they are typed natively (`gr{char}`); <Esc>/<C-c> cancels, 'timeoutlen' applies.
--- The handler runs outside textlock (it may edit the buffer).
---@param mode string
---@param lhs string
---@param handler fun(): boolean?
---@param opts {desc: string, buf?: integer, nowait?: boolean}
---@return fun() fallback  call to perform the fall-through manually
function M.fallthrough(mode, lhs, handler, opts)
  local buf = opts.buf and (opts.buf == 0 and api.nvim_get_current_buf() or opts.buf) or nil
  local captured = replaced(mode, lhs, buf)
  -- keymap dicts hold the buffer id in `buf` (0.12; `buffer` before), 0 for a global map
  if captured and buf and (captured.buf or captured.buffer) == 0 then
    captured = nil -- global maps are looked up at press time (may be (re)defined later, e.g. by cmp)
  end
  local cb
  local function hand_over()
    local key = norm(lhs)
    local prev = captured or previous(mode, lhs, buf)
    if not continued(mode, key, buf, cb) then
      run_previous(prev, lhs)
      return
    end
    local typed = key
    while continued(mode, typed, buf, cb) do
      local c = next_key()
      if c == "\27" or c == "\3" then
        return -- <Esc> / <C-c>
      elseif not c then
        break
      end
      typed = typed .. c
    end
    -- the longest mapping that matches the start of the keys runs, the rest is typed on (mappings apply)
    for n = #typed, #key + 1, -1 do
      local m = lookup(mode, typed:sub(1, n), buf, handing_over)
      if m then
        if n < #typed then
          feed(typed:sub(n + 1), true)
        end
        run_previous(m, lhs)
        return
      end
    end
    if #typed > #key then
      feed(typed:sub(#key + 1), true)
    end
    run_previous(prev, lhs)
  end
  local function fallback()
    local was = running[cb]
    running[cb] = true -- (lookups skip it while the key goes on down the chain)
    local ok, err = pcall(hand_over)
    running[cb] = was
    if not ok then
      error(err, 0)
    end
  end
  cb = function()
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
  M.set(mode, lhs, cb, { desc = opts.desc, buf = buf, nowait = opts.nowait })
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

--- `fn` that only runs while the module is loaded and enabled. Otherwise a fall-through key passes the key
--- on (returns false) and any other key goes through registry.run_keymap(), which loads the module (e.g. a
--- failed one after the config was fixed) or says why it can't. Names the registry doesn't know (apply()
--- used directly) are not guarded.
---@param km slop.ResolvedKeymap
---@param fn function
---@param fallthrough? boolean
---@return function
local function guarded(km, fn, fallthrough)
  return function(...)
    local reg = require("slop.core.registry")
    local status = reg.status(km.module)
    if status == "missing" or ((status == "loaded" or status == "loading") and reg.is_enabled(km.module)) then
      return fn(...)
    end
    if fallthrough then
      return false
    end
    return reg.run_keymap(km.module, km.name, { expr = km.spec.expr == true })
  end
end

--- `<Plug>(slop-<module>-<name>)` for every keymap kind (global, ft, buffer, fallthrough).
---@param km slop.ResolvedKeymap
local function define_plug(km)
  local s = km.spec
  local rhs = s.rhs
  if type(rhs) == "function" then
    local handler = rhs
    local fn = handler
    if s.fallthrough then
      -- there is nothing to fall through to behind a <Plug>: `false` (nothing to do) does nothing
      fn = function()
        local ok, err = pcall(handler)
        if not ok then
          require("slop.core.log").error("keymap %s: %s", km.plug, err)
        end
      end
    end
    rhs = guarded(km, fn)
  end
  vim.keymap.set(km.modes, km.plug, rhs, { desc = "slop: " .. s.desc:gsub("^slop: ", ""), expr = s.expr })
end

local function apply_local(km, buf)
  if not km.lhs then
    return
  end
  local rhs = km.spec.rhs
  for _, mode in ipairs(km.modes) do
    if km.spec.fallthrough then
      M.fallthrough(mode, km.lhs, guarded(km, rhs --[[@as fun(): boolean?]], true), {
        desc = km.spec.desc,
        buf = buf,
        nowait = km.spec.nowait,
      })
    else
      M.set(mode, km.lhs, type(rhs) == "function" and guarded(km, rhs) or rhs, {
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
  -- applying again (enable of a loaded module) must not stack FileType autocmds
  for _, id in ipairs(ft_autocmds[module] or {}) do
    pcall(api.nvim_del_autocmd, id)
  end
  ft_autocmds[module] = {}
  for _, km in ipairs(list) do
    local s = km.spec
    define_plug(km)
    if s.ft then
      if km.lhs then
        table.insert(
          ft_autocmds[module],
          api.nvim_create_autocmd("FileType", {
            group = require("slop.core.util").augroup(module),
            pattern = s.ft,
            desc = "slop: " .. module .. " keymap " .. km.name,
            callback = function(ev)
              apply_local(km, ev.buf)
            end,
          })
        )
        for _, b in ipairs(api.nvim_list_bufs()) do
          if api.nvim_buf_is_loaded(b) and vim.tbl_contains(s.ft, vim.bo[b].filetype) then
            apply_local(km, b)
          end
        end
      end
    elseif s.fallthrough and not s.buffer then
      apply_local(km, nil)
    elseif not s.buffer and km.lhs and not (opts.skip_lhs and opts.skip_lhs[km.name]) then
      for _, mode in ipairs(km.modes) do
        if vim.fn.maparg(km.lhs, mode) == "" and vim.fn.hasmapto(km.plug, mode) == 0 then
          vim.keymap.set(mode, km.lhs, km.plug, { remap = true, desc = "slop: " .. s.desc:gsub("^slop: ", "") })
          local set = vim.fn.maparg(km.lhs, mode, false, true)
          -- the lhs as mapped (<leader> expanded): remove() must find it after a mapleader change
          table.insert(applied[module], { mode = mode, lhs = set.lhs or km.lhs, rhs = set.rhs })
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

--- cloak: optional integrations (all pcall-guarded, none required).
---   * fzf-lua: tag preview buffers with their file path (vim.b.slop_secret_path) so the decoration provider
---     masks them in the same tick they are filled (patch of Previewer.buffer_or_file.preview_buf_post);
---     fallback for unpatched previews: resolve the selected entry of windows with w:fzf_lua_preview.
---   * telescope: User TelescopePreviewerLoaded -> tag the preview buffer (no picker refresh hack).
---   * completion: nvim-cmp (cmp.setup.buffer), blink.cmp / slop complete (vim.b.completion = false) and
---     native 'autocomplete' are disabled in cloaked buffers and restored afterwards.
local M = {}

local api = vim.api

local fzf = { patched = false, error = nil, orig = nil, cls = nil }
---@class slop.cloak.SavedCompletion
---@field completion any         vim.b.completion before
---@field has_ac? boolean        'autocomplete' was saved (autocomplete = its local value, nil = none)
---@field autocomplete? boolean
---@field cmp? boolean           nvim-cmp was disabled (cmp_prev = the buffer config it had)
---@field cmp_prev? table
---@field au? integer            InsertEnter autocmd waiting for a lazy-loaded cmp

local saved = {} ---@type table<integer, slop.cloak.SavedCompletion>
local aus = {} ---@type integer[]  autocmds of setup(), deleted by reconfigure()

--- Absolute path for a (possibly relative) path.
---@param p string?
---@param cwd? string
---@return string?
local function abs(p, cwd)
  if type(p) ~= "string" or p == "" then
    return nil
  end
  if p:match("^%a[%w+.-]*://") then
    return p
  end
  p = vim.fs.normalize(p)
  if p:sub(1, 1) ~= "/" and not p:match("^%a:[/\\]") then
    p = vim.fs.joinpath(cwd or vim.uv.cwd() or ".", p)
  end
  return vim.fs.normalize(p)
end
M.abs = abs

-- fzf-lua ---------------------------------------------------------------------------------------

---@param self table  fzf-lua previewer
---@param entry table
local function fzf_tag(self, entry)
  local buf = self.preview_bufnr
  if type(entry) ~= "table" or type(buf) ~= "number" or not api.nvim_buf_is_valid(buf) then
    return
  end
  local path = entry.path
  if (not path or path == "") and entry.bufnr and api.nvim_buf_is_valid(entry.bufnr) then
    path = api.nvim_buf_get_name(entry.bufnr)
  end
  local cwd = entry.cwd or (type(self.opts) == "table" and self.opts.cwd) or nil
  path = abs(path, cwd)
  local render = require("slop.modules.cloak.render")
  if path and vim.b[buf].slop_secret_path ~= path then
    vim.b[buf].slop_secret_path = path
    render.invalidate(buf)
  end
  -- fzf-lua swaps preview buffers under eventignore (no BufWinEnter) and sets the window options globally,
  -- so every new preview buffer gets the window's wrap/conceallevel: fix them before the first redraw
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    render.apply_win(win)
  end
end

--- Patch fzf-lua's builtin previewer (only if fzf-lua is already loaded, or `force`).
---@param force? boolean  require fzf-lua.previewer.builtin if needed
---@return boolean patched
function M.patch_fzf(force)
  if fzf.patched then
    return true
  end
  local mod = package.loaded["fzf-lua.previewer.builtin"]
  if not mod and force then
    local ok, res = pcall(require, "fzf-lua.previewer.builtin")
    mod = ok and res or nil
  end
  if type(mod) ~= "table" then
    return false
  end
  local cls = mod.buffer_or_file
  if type(cls) ~= "table" or type(cls.preview_buf_post) ~= "function" then
    fzf.error = "fzf-lua previewer.builtin.buffer_or_file.preview_buf_post not found (fallback in use)"
    return false
  end
  local orig = cls.preview_buf_post
  fzf.orig, fzf.cls = orig, cls
  cls.preview_buf_post = function(self, entry, ...)
    pcall(fzf_tag, self, entry)
    return orig(self, entry, ...)
  end
  fzf.patched, fzf.error = true, nil
  return true
end

function M.unpatch_fzf()
  if fzf.patched and fzf.cls then
    fzf.cls.preview_buf_post = fzf.orig
  end
  fzf.patched, fzf.cls, fzf.orig = false, nil, nil
end

local fb_cache = { sel = nil, path = nil }

--- Fallback effective path of an unnamed buffer in an fzf-lua preview window.
---@param win integer
---@return string?
function M.fzf_fallback_path(win)
  if not vim.w[win].fzf_lua_preview then
    return nil
  end
  local f = package.loaded["fzf-lua"]
  if type(f) ~= "table" or type(f.get_info) ~= "function" then
    return nil
  end
  local ok, info = pcall(f.get_info)
  local sel = ok and type(info) == "table" and info.selected or nil
  if type(sel) ~= "string" then
    return nil
  end
  if fb_cache.sel == sel then
    return fb_cache.path
  end
  local pok, pmod = pcall(require, "fzf-lua.path")
  local path
  if pok and type(pmod.entry_to_file) == "function" then
    local eok, e = pcall(pmod.entry_to_file, sel, info)
    if eok and type(e) == "table" then
      path = abs(e.path, info.cwd)
    end
  end
  fb_cache.sel, fb_cache.path = sel, path
  return path
end

-- telescope -------------------------------------------------------------------------------------

---@param ev {buf: integer, data: any}
function M.on_telescope(ev)
  local data = ev.data
  if type(data) ~= "table" or type(data.bufname) ~= "string" or not api.nvim_buf_is_valid(ev.buf) then
    return
  end
  local path = abs(data.bufname)
  if path then
    vim.b[ev.buf].slop_secret_path = path
    local render = require("slop.modules.cloak.render")
    render.invalidate(ev.buf)
    render.refresh(ev.buf)
  end
end

-- completion ------------------------------------------------------------------------------------

--- nvim-cmp's own config of `buf` (cmp.setup.buffer() replaces it wholesale), so a restore can put it back.
---@param buf integer
---@return table?
local function cmp_buffer_config(buf)
  local cc = package.loaded["cmp.config"]
  local c = type(cc) == "table" and type(cc.buffers) == "table" and cc.buffers[buf] or nil
  if type(c) ~= "table" then
    return nil
  end
  c = vim.deepcopy(c)
  c.revision = nil
  return next(c) ~= nil and c or nil
end

--- Disable cmp in `buf` (keeping its own buffer config), or restore that config. Restoring with
--- `{ enabled = true }` would override the user's/cmp's enabled() function (prompt buffers, macros).
---@param buf integer
---@param enabled boolean
---@param prev? table  buffer config to restore
local function cmp_set(buf, enabled, prev)
  local cmp = package.loaded["cmp"]
  if type(cmp) ~= "table" or type(cmp.setup) ~= "table" or not api.nvim_buf_is_valid(buf) then
    return false
  end
  return pcall(api.nvim_buf_call, buf, function()
    cmp.setup.buffer(enabled and (prev or {}) or vim.tbl_extend("force", prev or {}, { enabled = false }))
  end)
end

--- Disable (enabled = false) or restore (true) completion in `buf`.
---@param buf integer
---@param enabled boolean
function M.completion(buf, enabled)
  if not api.nvim_buf_is_valid(buf) then
    saved[buf] = nil
    return
  end
  if not enabled then
    if saved[buf] then
      return
    end
    local s = { completion = vim.b[buf].completion }
    -- 'autocomplete' is global-local (0.12): nil = no local value, the global one applies (vim.bo reads nil too)
    local ok, ac = pcall(api.nvim_get_option_value, "autocomplete", { scope = "local", buf = buf })
    if ok then
      s.has_ac, s.autocomplete = true, ac
      pcall(function()
        vim.bo[buf].autocomplete = false
      end)
    end
    vim.b[buf].completion = false
    s.cmp_prev = cmp_buffer_config(buf)
    if cmp_set(buf, false, s.cmp_prev) then
      s.cmp = true
    else
      -- cmp not loaded yet (lazy on InsertEnter): disable it as soon as it is, before the first TextChangedI.
      s.au = api.nvim_create_autocmd("InsertEnter", {
        group = require("slop.core.util").augroup("cloak"),
        buf = buf,
        desc = "slop: cloak disable nvim-cmp",
        callback = function()
          local function try()
            local cur = saved[buf]
            if cur and not cur.cmp then
              cur.cmp_prev = cmp_buffer_config(buf)
              if cmp_set(buf, false, cur.cmp_prev) then
                cur.cmp = true
                pcall(api.nvim_del_autocmd, cur.au)
                cur.au = nil
              end
            end
          end
          try()
          vim.schedule(try)
        end,
      })
    end
    saved[buf] = s
  else
    local s = saved[buf]
    if not s then
      return
    end
    saved[buf] = nil
    if s.au then
      pcall(api.nvim_del_autocmd, s.au)
    end
    vim.b[buf].completion = s.completion
    if s.has_ac then
      pcall(api.nvim_buf_call, buf, function()
        if s.autocomplete == nil then
          vim.cmd("set autocomplete<") -- global-local: drop the local value, the global one applies again
        else
          vim.bo[buf].autocomplete = s.autocomplete
        end
      end)
    end
    if s.cmp then
      cmp_set(buf, true, s.cmp_prev)
    end
  end
end

-- setup / status ---------------------------------------------------------------------------------

---@param cfg table
function M.setup(cfg)
  local group = require("slop.core.util").augroup("cloak")
  if cfg.fzf_lua ~= false then
    M.patch_fzf(false)
    aus[#aus + 1] = api.nvim_create_autocmd("FileType", {
      group = group,
      pattern = "fzf",
      desc = "slop: cloak fzf-lua previews",
      callback = function()
        M.patch_fzf(true)
      end,
    })
    require("slop.modules.cloak.render")._state.fallback_path = M.fzf_fallback_path
  end
  if cfg.cloak_telescope ~= false then
    aus[#aus + 1] = api.nvim_create_autocmd("User", {
      group = group,
      pattern = "TelescopePreviewerLoaded",
      desc = "slop: cloak telescope previews",
      callback = M.on_telescope,
    })
  end
end

--- Apply a changed config (fzf_lua / cloak_telescope toggled by a later setup()).
---@param cfg table
function M.reconfigure(cfg)
  for _, id in ipairs(aus) do
    pcall(api.nvim_del_autocmd, id)
  end
  aus = {}
  if cfg.fzf_lua == false then
    M.unpatch_fzf()
    require("slop.modules.cloak.render")._state.fallback_path = nil
  end
  M.setup(cfg)
end

function M.teardown()
  M.unpatch_fzf()
  for buf in pairs(saved) do
    M.completion(buf, true)
  end
  aus = {} -- deleted with the augroup
  require("slop.modules.cloak.render")._state.fallback_path = nil
end

---@return {fzf_patched: boolean, fzf_error?: string, fzf_loaded: boolean, telescope: boolean, cmp: boolean, blink: boolean}
function M.status()
  return {
    fzf_patched = fzf.patched,
    fzf_error = fzf.error,
    fzf_loaded = package.loaded["fzf-lua"] ~= nil or #api.nvim_get_runtime_file("lua/fzf-lua/init.lua", false) > 0,
    telescope = package.loaded["telescope"] ~= nil or #api.nvim_get_runtime_file("lua/telescope/init.lua", false) > 0,
    cmp = package.loaded["cmp"] ~= nil or #api.nvim_get_runtime_file("lua/cmp/init.lua", false) > 0,
    blink = package.loaded["blink.cmp"] ~= nil or #api.nvim_get_runtime_file("lua/blink/cmp/init.lua", false) > 0,
  }
end

return M

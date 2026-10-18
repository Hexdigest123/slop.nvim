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
local saved = {} ---@type table<integer, {completion: any, autocomplete: any, cmp: boolean?, au: integer?}>

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
  if path and vim.b[buf].slop_secret_path ~= path then
    vim.b[buf].slop_secret_path = path
    require("slop.modules.cloak.render").invalidate(buf)
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

local function cmp_set(buf, enabled)
  local cmp = package.loaded["cmp"]
  if type(cmp) ~= "table" or type(cmp.setup) ~= "table" or not api.nvim_buf_is_valid(buf) then
    return false
  end
  return pcall(api.nvim_buf_call, buf, function()
    cmp.setup.buffer({ enabled = enabled })
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
    local ok, ac = pcall(function()
      return vim.bo[buf].autocomplete
    end)
    if ok then
      s.autocomplete = ac
      pcall(function()
        vim.bo[buf].autocomplete = false
      end)
    end
    vim.b[buf].completion = false
    if cmp_set(buf, false) then
      s.cmp = true
    else
      -- cmp not loaded yet (lazy on InsertEnter): disable it as soon as it is, before the first TextChangedI.
      s.au = api.nvim_create_autocmd("InsertEnter", {
        group = require("slop.core.util").augroup("cloak"),
        buffer = buf,
        desc = "slop: cloak disable nvim-cmp",
        callback = function()
          local function try()
            if saved[buf] and not saved[buf].cmp and cmp_set(buf, false) then
              saved[buf].cmp = true
              pcall(api.nvim_del_autocmd, saved[buf].au)
              saved[buf].au = nil
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
    if s.autocomplete ~= nil then
      pcall(function()
        vim.bo[buf].autocomplete = s.autocomplete
      end)
    end
    if s.cmp then
      cmp_set(buf, true)
    end
  end
end

-- setup / status ---------------------------------------------------------------------------------

---@param cfg table
function M.setup(cfg)
  local group = require("slop.core.util").augroup("cloak")
  if cfg.fzf_lua ~= false then
    M.patch_fzf(false)
    api.nvim_create_autocmd("FileType", {
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
    api.nvim_create_autocmd("User", {
      group = group,
      pattern = "TelescopePreviewerLoaded",
      desc = "slop: cloak telescope previews",
      callback = M.on_telescope,
    })
  end
end

function M.teardown()
  M.unpatch_fzf()
  for buf in pairs(saved) do
    M.completion(buf, true)
  end
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

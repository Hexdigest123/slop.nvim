--- Discovery of .http/.rest files under the project root (deliberately NOT honouring .gitignore) plus a parse cache.
---@class slop.rest.discover
local M = {}

local uv = vim.uv

M.SKIP = {
  ".git",
  "node_modules",
  "vendor",
  "target",
  "dist",
  "build",
  ".venv",
  "venv",
  ".svelte-kit",
  ".next",
  "__pycache__",
  ".cache",
  ".nvim",
}

M.TTL = 30 -- seconds

---@class slop.rest.Discovered
---@field files string[]        absolute .http/.rest paths, sorted
---@field env_files string[]    http-client(.private).env.json paths
---@field time number

local roots = {} ---@type table<string, slop.rest.Discovered>
local parsed = {} ---@type table<string, {mtime: integer, size: integer, data: slop.rest.File}>

---@return table<string, boolean>, string[]
local function cfg_sets()
  local cfg = require("slop.config").get("rest")
  local skip = {}
  for _, d in ipairs(M.SKIP) do
    skip[d] = true
  end
  for _, d in ipairs(cfg.skip or {}) do
    skip[d] = true
  end
  return skip, cfg.extensions or { "http", "rest" }
end

--- Walk `root` (pure apart from the filesystem).
---@param root string
---@param skip table<string, boolean>
---@param exts string[]
---@return slop.rest.Discovered
function M.scan(root, skip, exts)
  local files, env_files = {}, {}
  local extset = {}
  for _, e in ipairs(exts) do
    extset[e] = true
  end
  for name, kind in
    vim.fs.dir(root, {
      depth = 30,
      skip = function(dir)
        return not skip[vim.fs.basename(dir)]
      end,
    })
  do
    if kind == "file" or kind == "link" then
      local base = vim.fs.basename(name)
      local ext = base:match("%.([^%.]+)$")
      if ext and extset[ext] then
        files[#files + 1] = vim.fs.joinpath(root, name)
      elseif base == "http-client.env.json" or base == "http-client.private.env.json" then
        env_files[#env_files + 1] = vim.fs.joinpath(root, name)
      end
    end
  end
  table.sort(files)
  table.sort(env_files)
  return { files = files, env_files = env_files, time = uv.now() / 1000 }
end

--- Cached discovery for `root` (re-scanned after invalidate() or the TTL).
---@param root string
---@param force? boolean
---@return slop.rest.Discovered
function M.get(root, force)
  local d = roots[root]
  if force or not d or (uv.now() / 1000 - d.time) > M.TTL then
    local skip, exts = cfg_sets()
    d = M.scan(root, skip, exts)
    roots[root] = d
  end
  return d
end

--- Drop the cached file list (all roots, or one) and the parse cache of `file`.
---@param root? string
---@param file? string
function M.invalidate(root, file)
  if root then
    roots[root] = nil
  else
    roots = {}
  end
  if file then
    parsed[vim.fs.normalize(file)] = nil
  end
end

--- Loaded buffer for a path, if any.
---@param path string
---@return integer?
local function loaded_buf(path)
  local nr = vim.fn.bufnr(path)
  if nr > 0 and vim.api.nvim_buf_is_loaded(nr) then
    return nr
  end
  return nil
end

--- Parse a file: from its buffer when loaded (unsaved edits count), else from disk (cached by mtime/size).
---@param path string
---@return slop.rest.File
function M.parse(path)
  path = vim.fs.normalize(path)
  local parser = require("slop.modules.rest.parser")
  local buf = loaded_buf(path)
  if buf then
    return parser.parse(vim.api.nvim_buf_get_lines(buf, 0, -1, false), path)
  end
  local stat = uv.fs_stat(path)
  if not stat then
    return { file = path, vars = {}, requests = {}, warnings = {} }
  end
  local c = parsed[path]
  if c and c.mtime == stat.mtime.sec and c.size == stat.size then
    return c.data
  end
  local text = require("slop.core.project").read_file(path) or ""
  local data = parser.parse(vim.split(text, "\n", { plain = true }), path)
  parsed[path] = { mtime = stat.mtime.sec, size = stat.size, data = data }
  return data
end

--- Every request in every file under `root`, in file then line order.
---@param root string
---@return slop.rest.Request[]
function M.requests(root)
  local out = {}
  local d = M.get(root)
  local files = vim.list_slice(d.files)
  -- loaded http buffers under the root that are not on disk yet
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    local name = vim.api.nvim_buf_get_name(b)
    if vim.api.nvim_buf_is_loaded(b) and vim.bo[b].filetype == "http" and vim.startswith(name, root .. "/") then
      if not vim.tbl_contains(files, name) then
        files[#files + 1] = name
      end
    end
  end
  for _, f in ipairs(files) do
    vim.list_extend(out, M.parse(f).requests)
  end
  return out
end

--- Resolve a dependency name: same file first, then a unique match under the root.
---@param name string
---@param from slop.rest.Request
---@param root string
---@return slop.rest.Request?, string? err
function M.lookup(name, from, root)
  if from and from.file then
    for _, r in ipairs(M.parse(from.file).requests) do
      if r.name == name then
        return r
      end
    end
  end
  local found = {}
  for _, r in ipairs(M.requests(root)) do
    if r.name == name then
      found[#found + 1] = r
    end
  end
  if #found == 0 then
    return nil, ("unknown request '%s'"):format(name)
  end
  if #found > 1 then
    require("slop.core.log").warn(
      "rest: request name '%s' is defined in %d files, using %s",
      name,
      #found,
      require("slop.core.project").relpath(found[1].file, root)
    )
  end
  return found[1]
end

return M

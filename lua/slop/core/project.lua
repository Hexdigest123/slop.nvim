--- Project root and the project-local `<root>/.nvim/` folder.
---
---   project.root(buf?)                 -> "/path/to/repo"  (vim.fs.root(buf, markers) else cwd)
---   project.dir("commit.md")           -> "<root>/.nvim/commit.md" (not created)
---   project.file("rules.md")           -> path if it exists, else nil
---   project.state("rest", "cookies.txt") -> "<root>/.nvim/state/rest/cookies.txt"
---        (creates .nvim/state/rest/ lazily; the first creation of state/ also writes .nvim/.gitignore with "state/")
---   project.read_json(path) / project.write_json(path, data)  (atomic: temp file + rename)
---@class slop.project
local M = {}

local uv = vim.uv

---@class slop.project.Opts
---@field buf? integer   buffer whose root to use (default: current)
---@field root? string   explicit root (skips detection)

local function cfg()
  return require("slop.config").get("project")
end

--- Normalize a buffer name into a filesystem path (handles oil:// and fugitive://).
---@param name string
---@return string?
local function buf_path(name)
  if name == "" then
    return nil
  end
  local oil = name:match("^oil://(.*)$")
  if oil then
    return oil
  end
  local fug = name:match("^fugitive://(.-)/%.git//")
  if fug then
    return fug
  end
  if name:match("^%a[%w+.-]*://") then
    return nil
  end
  return name
end

--- Project root for a buffer: vim.fs.root(<buffer path>, root_markers), else the root of cwd, else cwd.
---@param buf? integer
---@return string
function M.root(buf)
  buf = (buf == nil or buf == 0) and vim.api.nvim_get_current_buf() or buf
  local markers = cfg().root_markers
  local root
  if vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].buftype == "" then
    local path = buf_path(vim.api.nvim_buf_get_name(buf))
    if path then
      root = vim.fs.root(path, markers)
    end
  else
    local path = vim.api.nvim_buf_is_valid(buf) and buf_path(vim.api.nvim_buf_get_name(buf))
    if path and path:sub(1, 1) == "/" then
      root = vim.fs.root(path, markers)
    end
  end
  root = root or vim.fs.root(vim.fn.getcwd(), markers) or vim.fn.getcwd()
  return vim.fs.normalize(root)
end

local function resolve_root(opts)
  return opts and opts.root or M.root(opts and opts.buf)
end

--- Path inside `<root>/<project.dir>/`. A leading table argument is slop.project.Opts.
--- Nothing is created.
---@param ... string|slop.project.Opts
---@return string
function M.dir(...)
  local args = { ... }
  local opts = nil
  if type(args[1]) == "table" then
    opts = table.remove(args, 1)
  end
  return vim.fs.joinpath(resolve_root(opts), cfg().dir, unpack(args))
end

--- `<root>/.nvim/<name>` if it exists (hand-written project files like commit.md, rules.md).
---@param name string
---@param opts? slop.project.Opts
---@return string?
function M.file(name, opts)
  local p = M.dir(opts or {}, name)
  return uv.fs_stat(p) and p or nil
end

---@param path string
---@return boolean ok, string? err
local function mkdirp(path)
  local ok, err = pcall(vim.fn.mkdir, path, "p")
  if not ok then
    return false, tostring(err)
  end
  return true
end

local function ensure_gitignore(nvim_dir)
  local gi = vim.fs.joinpath(nvim_dir, ".gitignore")
  local text = M.read_file(gi)
  if text == nil then
    M.write_file(gi, "state/\n")
    return
  end
  for line in text:gmatch("[^\n]+") do
    local l = vim.trim(line)
    if l == "state/" or l == "state" or l == "/state/" then
      return
    end
  end
  M.write_file(gi, text .. ((text == "" or text:sub(-1) == "\n") and "" or "\n") .. "state/\n")
end

--- Path of a generated state file `<root>/.nvim/state/<module>/<file>` (or the module dir when `file` is nil).
--- Creates the directory lazily; the first creation of `state/` writes `.nvim/.gitignore` containing `state/`.
---@param module string
---@param file? string
---@param opts? slop.project.Opts
---@return string path
function M.state(module, file, opts)
  local nvim_dir = M.dir(opts or {})
  local state_dir = vim.fs.joinpath(nvim_dir, "state")
  local mod_dir = vim.fs.joinpath(state_dir, module)
  if not uv.fs_stat(mod_dir) then
    local fresh = not uv.fs_stat(state_dir)
    assert(mkdirp(mod_dir))
    if fresh then
      ensure_gitignore(nvim_dir)
    end
  end
  return file and vim.fs.joinpath(mod_dir, file) or mod_dir
end

--- Read a whole file.
---@param path string
---@return string? text, string? err
function M.read_file(path)
  local fd, err = uv.fs_open(path, "r", 438)
  if not fd then
    return nil, err
  end
  local stat = uv.fs_fstat(fd)
  local data = stat and uv.fs_read(fd, stat.size, 0) or nil
  uv.fs_close(fd)
  if not data then
    return nil, "read failed: " .. path
  end
  return data
end

--- Atomically write a file: write `<path>.tmp.<pid>.<n>`, fsync, rename over `path`. Creates parent dirs.
---@param path string
---@param text string
---@return boolean ok, string? err
function M.write_file(path, text)
  local dir = vim.fs.dirname(path)
  if not uv.fs_stat(dir) then
    local ok, err = mkdirp(dir)
    if not ok then
      return false, err
    end
  end
  local tmp = ("%s.tmp.%d.%d"):format(path, uv.os_getpid(), uv.hrtime())
  local fd, err = uv.fs_open(tmp, "w", 420)
  if not fd then
    return false, err
  end
  local ok, werr = uv.fs_write(fd, text, 0)
  uv.fs_fsync(fd)
  uv.fs_close(fd)
  if not ok then
    uv.fs_unlink(tmp)
    return false, werr
  end
  local rok, rerr = uv.fs_rename(tmp, path)
  if not rok then
    uv.fs_unlink(tmp)
    return false, rerr
  end
  return true
end

--- Decode a JSON file. Missing file -> nil, "ENOENT..." ; invalid JSON -> nil, err.
---@param path string
---@return any data, string? err
function M.read_json(path)
  local text, err = M.read_file(path)
  if not text then
    return nil, err
  end
  local ok, data = pcall(vim.json.decode, text, { luanil = { object = true, array = true } })
  if not ok then
    return nil, "invalid json in " .. path .. ": " .. tostring(data)
  end
  return data
end

--- Encode and atomically write JSON (pretty, sorted keys).
---@param path string
---@param data any
---@return boolean ok, string? err
function M.write_json(path, data)
  local ok, text = pcall(vim.json.encode, data, { indent = "  ", sort_keys = true })
  if not ok then
    return false, tostring(text)
  end
  return M.write_file(path, text .. "\n")
end

--- Path relative to the root (for display); unchanged if outside.
---@param path string
---@param root? string
---@return string
function M.relpath(path, root)
  root = root or M.root()
  return vim.fs.relpath(root, path) or path
end

return M

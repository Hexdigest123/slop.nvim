--- Environment sources for rest: http-client(.private).env.json (JetBrains format, "$shared") and the nearest .env.
---@class slop.rest.env
local M = {}

M.PUBLIC = "http-client.env.json"
M.PRIVATE = "http-client.private.env.json"

---@param path string
---@return table?
local function read_json(path)
  local data = require("slop.core.project").read_json(path)
  return type(data) == "table" and data or nil
end

--- Directories from `root` down to `dir` (root first). `dir` outside `root` -> just { dir }.
---@param dir string
---@param root string
---@return string[]
local function chain(dir, root)
  local out = {}
  local cur = vim.fs.normalize(dir)
  root = vim.fs.normalize(root)
  while true do
    table.insert(out, 1, cur)
    if cur == root then
      break
    end
    local parent = vim.fs.dirname(cur)
    if parent == cur or not vim.startswith(cur, root) then
      return { vim.fs.normalize(dir) }
    end
    cur = parent
  end
  return out
end

--- Variables of env `name` for an .http file: root-most files first, so the closest file wins; in each
--- directory the public file, then the private one; "$shared" below the named env.
---@param http_file string
---@param root string
---@param name? string|false
---@return table<string, string> vars, string[] files
function M.load(http_file, root, name)
  local vars, files = {}, {}
  for _, dir in ipairs(chain(vim.fs.dirname(http_file), root)) do
    for _, fname in ipairs({ M.PUBLIC, M.PRIVATE }) do
      local path = vim.fs.joinpath(dir, fname)
      local data = vim.uv.fs_stat(path) and read_json(path)
      if data then
        files[#files + 1] = path
        if type(data["$shared"]) == "table" then
          vars = vim.tbl_extend("force", vars, data["$shared"])
        end
        if name and type(data[name]) == "table" then
          vars = vim.tbl_extend("force", vars, data[name])
        end
      end
    end
  end
  return vars, files
end

--- Env names defined in the given env files ("$shared" excluded), sorted.
---@param files string[]
---@return string[]
function M.names(files)
  local seen, out = {}, {}
  for _, path in ipairs(files) do
    local data = read_json(path)
    for k, v in pairs(data or {}) do
      if type(k) == "string" and k ~= "$shared" and type(v) == "table" and not seen[k] then
        seen[k] = true
        out[#out + 1] = k
      end
    end
  end
  table.sort(out)
  return out
end

--- Nearest `filename` (".env") from the .http file's directory upward to the root.
---@param http_file string
---@param root string
---@param filename string|false
---@return table<string, string> vars, string? path
function M.dotenv(http_file, root, filename)
  if not filename or filename == "" then
    return {}, nil
  end
  local dirs = chain(vim.fs.dirname(http_file), root)
  for i = #dirs, 1, -1 do
    local path = vim.fs.joinpath(dirs[i], filename)
    if vim.uv.fs_stat(path) then
      local text = require("slop.core.project").read_file(path)
      return require("slop.modules.rest.vars").parse_dotenv(text or ""), path
    end
  end
  return {}, nil
end

return M

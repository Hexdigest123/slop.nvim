--- Persisted per-project rest state: <root>/.nvim/state/rest/history.json
---   { recent = { "<relpath>#<name|Lline>", ... } (MRU first), env = "<name>"|false, last = { file, name?, line } }
--- Reading never creates anything; the state directory is created on the first write.
---@class slop.rest.history
local M = {}

M.MAX = 50

local cache = {} ---@type table<string, table>
local unwritable = {} ---@type table<string, boolean>  roots already reported as not writable

---@param root string
---@return string
local function read_path(root)
  return require("slop.core.project").dir({ root = root }, "state", "rest", "history.json")
end

--- `<root>/.nvim/state/rest/<name>` (the directory is created, private: 0700). nil when it cannot be created
--- (unwritable root, e.g. cwd "/" or a read-only checkout; reported once): requests still run, but history and
--- the cookie jar are not kept.
---@param root string
---@param name string
---@return string?
function M.state_file(root, name)
  local ok, path = pcall(require("slop.core.project").state, "rest", name, { root = root })
  if not ok then
    if not unwritable[root] then
      unwritable[root] = true
      local msg = "cannot create the state folder of %s (%s): no history, no cookie jar"
      require("slop.core.log").scope("rest").warn(msg, root, tostring(path))
    end
    return nil
  end
  -- cookies and history are nobody else's business
  vim.uv.fs_chmod(vim.fs.dirname(path), 448)
  return path
end

---@param root string
---@return {recent: string[], env: string|false|nil, last: table?}
function M.load(root)
  if cache[root] then
    return cache[root]
  end
  local data = require("slop.core.project").read_json(read_path(root))
  if type(data) ~= "table" then
    data = {}
  end
  data.recent = type(data.recent) == "table" and data.recent or {}
  cache[root] = data
  return data
end

---@param root string
function M.save(root)
  local data = M.load(root)
  local path = M.state_file(root, "history.json")
  if not path then
    return
  end
  local ok, err = require("slop.core.project").write_json(path, data)
  if ok then
    vim.uv.fs_chmod(path, 384)
  else
    require("slop.core.log").scope("rest").warn("could not write %s: %s", path, tostring(err))
  end
end

--- Forget the in-memory cache (tests / root changes).
function M.reset()
  cache, unwritable = {}, {}
end

--- Stable id of a request: "<relpath>#<name>" or "<relpath>#L<line>".
---@param req slop.rest.Request
---@param root string
---@return string
function M.id(req, root)
  local rel = req.file and require("slop.core.project").relpath(req.file, root) or "[buffer]"
  return rel .. "#" .. (req.name or ("L" .. tostring(req.line)))
end

--- Record a run: MRU + last request.
---@param root string
---@param req slop.rest.Request
function M.touch(root, req)
  local data = M.load(root)
  local id = M.id(req, root)
  local recent = { id }
  for _, r in ipairs(data.recent) do
    if r ~= id and #recent < M.MAX then
      recent[#recent + 1] = r
    end
  end
  data.recent = recent
  if req.file then
    data.last = {
      file = require("slop.core.project").relpath(req.file, root),
      name = req.name,
      line = req.line,
    }
  end
  M.save(root)
end

--- MRU rank of an id (1 = most recent), nil when never run.
---@param root string
---@return table<string, integer>
function M.ranks(root)
  local out = {}
  for i, id in ipairs(M.load(root).recent) do
    out[id] = i
  end
  return out
end

---@param root string
---@return string|false|nil env  (false = explicitly none)
function M.env(root)
  return M.load(root).env
end

---@param root string
---@param name string|false
function M.set_env(root, name)
  M.load(root).env = name
  M.save(root)
end

---@param root string
---@return {file: string, name: string?, line: integer}?
function M.last(root)
  local l = M.load(root).last
  return type(l) == "table" and l.file and l or nil
end

return M

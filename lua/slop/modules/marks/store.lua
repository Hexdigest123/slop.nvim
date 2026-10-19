--- marks storage: one list per project, kept in memory and synced with a JSON file.
---
---   <root>/.nvim/state/marks/marks.json                 (a root marker was found)
---   stdpath("data")/slop/marks/<cwd, "/" -> "%">.json   (no project root: keyed by cwd)
---
--- The file is authoritative for membership and order: every structural change re-reads it when its stat changed
--- (another nvim instance wrote it), applies the change and writes it back atomically. Cursor positions recorded on
--- BufLeave live in memory (`touched`) and are merged into the list on the next write.
local M = {}

local uv = vim.uv
local project = require("slop.core.project")
local log = require("slop.core.log").scope("marks")

local FILE = "marks.json"
local VERSION = 1

---@class slop.marks.Item
---@field path string   relative to the list root (absolute when outside it)
---@field row integer   1-based
---@field col integer   0-based

---@class slop.marks.List
---@field root string
---@field file string
---@field project boolean            stored under <root>/.nvim/state (else stdpath("data"))
---@field items slop.marks.Item[]
---@field stamp string?              stat of the file when last read/written
---@field touched table<string, integer[]>  path -> {row, col} not yet written
---@field corrupt boolean?           the file failed to decode (backed up before the next write)

local lists = {} ---@type table<string, slop.marks.List>

local function cfg()
  return require("slop.config").get("marks")
end

local function markers()
  return require("slop.config").get("project").root_markers
end

---@param path string
---@return string?
local function stat_stamp(path)
  local st = uv.fs_stat(path)
  return st and ("%d.%d.%d"):format(st.mtime.sec, st.mtime.nsec, st.size) or nil
end

--- Where the list for the current context lives.
---@param buf? integer
---@return string root, string file, boolean in_project
function M.locate(buf)
  local root
  if cfg().scope == "buffer" then
    root = project.root(buf)
    root = vim.fs.root(root, markers()) == root and root or nil
  else
    local r = vim.fs.root(vim.fn.getcwd(), markers())
    root = r and vim.fs.normalize(r) or nil
  end
  if root then
    return root, project.dir({ root = root }, "state", "marks", FILE), true
  end
  local cwd = vim.fs.normalize(vim.fn.getcwd())
  local key = cwd:gsub("[/\\:]", "%%")
  return cwd, vim.fs.joinpath(vim.fn.stdpath("data"), "slop", "marks", key .. ".json"), false
end

---@param v any
---@return integer?
local function int(v)
  return type(v) == "number" and v == math.floor(v) and v or nil
end

--- Normalize one decoded entry (a table or a bare path string).
---@param e any
---@return slop.marks.Item?
local function decode_item(e)
  if type(e) == "string" then
    e = { path = e }
  end
  if type(e) ~= "table" or type(e.path) ~= "string" or vim.trim(e.path) == "" then
    return nil
  end
  local row, col = int(e.row), int(e.col)
  return { path = vim.trim(e.path), row = row and row >= 1 and row or 1, col = col and col >= 0 and col or 0 }
end

---@param list slop.marks.List
local function read(list)
  list.items, list.corrupt = {}, nil
  list.stamp = stat_stamp(list.file)
  if not list.stamp then
    return
  end
  local data, err = project.read_json(list.file)
  local entries = type(data) == "table" and (vim.islist(data) and data or data.marks) or nil
  if type(entries) ~= "table" then
    list.corrupt = true
    log.warn("ignoring unreadable marks file %s (%s); it is backed up to .bak on the next change", list.file, err)
    return
  end
  local seen = {}
  for _, e in ipairs(entries) do
    local item = decode_item(e)
    if item and not seen[item.path] then
      seen[item.path] = true
      list.items[#list.items + 1] = item
    end
  end
end

--- Merge in-memory cursor positions into the items.
---@param list slop.marks.List
local function apply_touched(list)
  for _, item in ipairs(list.items) do
    local pos = list.touched[item.path]
    if pos then
      item.row, item.col = pos[1], pos[2]
    end
  end
end

--- The list for the current context (loaded on first use, re-read when the file changed on disk).
---@param buf? integer
---@return slop.marks.List
function M.current(buf)
  local root, file, in_project = M.locate(buf)
  local list = lists[file]
  if not list then
    list = { root = root, file = file, project = in_project, items = {}, touched = {} }
    lists[file] = list
    read(list)
    return list
  end
  M.sync(list)
  return list
end

--- Re-read the file if another process changed it (keeps unsaved cursor positions).
---@param list slop.marks.List
function M.sync(list)
  if stat_stamp(list.file) ~= list.stamp then
    read(list)
    apply_touched(list)
  end
end

--- Write the list (with recorded cursor positions) atomically.
---@param list slop.marks.List
---@return boolean ok
function M.save(list)
  apply_touched(list)
  local path = list.file
  if list.project then
    local ok, p = pcall(project.state, "marks", FILE, { root = list.root })
    if not ok then
      log.notify(("cannot create %s: %s"):format(vim.fs.dirname(path), p), vim.log.levels.ERROR)
      return false
    end
    path = p
  end
  if list.corrupt and uv.fs_stat(path) then
    uv.fs_copyfile(path, path .. ".bak")
  end
  local items = {}
  for i, item in ipairs(list.items) do
    items[i] = { path = item.path, row = item.row, col = item.col }
  end
  local ok, err = project.write_json(path, { version = VERSION, marks = items })
  if not ok then
    log.notify(("cannot write %s: %s"):format(path, err), vim.log.levels.ERROR)
    return false
  end
  list.corrupt = nil
  list.touched = {}
  list.stamp = stat_stamp(path)
  return true
end

--- Write every list that has unsaved cursor positions (VimLeavePre).
function M.flush()
  for _, list in pairs(lists) do
    if next(list.touched) then
      M.sync(list)
      M.save(list)
    end
  end
end

--- Absolute path of a stored item.
---@param list slop.marks.List
---@param path string
---@return string
function M.abs(list, path)
  if path:sub(1, 1) == "/" or path:match("^%a:[/\\]") then
    return vim.fs.normalize(path)
  end
  return vim.fs.normalize(vim.fs.joinpath(list.root, path))
end

--- Stored form of a path: relative to the list root when inside it, else absolute.
---@param list slop.marks.List
---@param path string  absolute, or relative to the list root
---@return string
function M.rel(list, path)
  return vim.fs.relpath(list.root, M.abs(list, path)) or M.abs(list, path)
end

---@param list slop.marks.List
---@param path string  stored form
---@return integer? index
function M.index(list, path)
  for i, item in ipairs(list.items) do
    if item.path == path then
      return i
    end
  end
end

--- Record the cursor of a marked file (in memory until the next write).
---@param list slop.marks.List
---@param path string  stored form
---@param row integer
---@param col integer
function M.touch(list, path, row, col)
  local i = M.index(list, path)
  if i then
    list.items[i].row, list.items[i].col = row, col
    list.touched[path] = { row, col }
  end
end

--- Forget every in-memory list (tests, teardown).
function M.reset()
  lists = {}
end

return M

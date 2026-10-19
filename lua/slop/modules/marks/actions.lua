--- marks behaviour: add/remove/select/next/prev/clear and cursor memory. OWNER: marks.
local M = {}

local api = vim.api
local store = require("slop.modules.marks.store")
local events = require("slop.core.events")
local log = require("slop.core.log").scope("marks")

---@alias slop.marks.OpenCmd "edit"|"split"|"vsplit"|"tab"

local OPEN = { edit = "edit", split = "split", vsplit = "vsplit", tab = "tabedit" }

local last = nil ---@type integer?  index of the last selected mark (for next/prev from unmarked buffers)

local function cfg()
  return require("slop.config").get("marks")
end

local function info(msg)
  if cfg().notify then
    log.notify(msg, vim.log.levels.INFO)
  end
end

---@param list slop.marks.List
---@param action string
function M.changed(list, action)
  events.emit("marks", "Changed", { root = list.root, count = #list.items, action = action })
end

--- Absolute path of a buffer that can be marked (a normal file buffer), else nil.
---@param buf integer
---@return string?
local function buf_file(buf)
  if not api.nvim_buf_is_valid(buf) or vim.bo[buf].buftype ~= "" then
    return nil
  end
  local name = api.nvim_buf_get_name(buf)
  if name == "" or name:match("^%a[%w+.-]*://") then
    return nil
  end
  return vim.fs.normalize(name)
end

--- Resolve a user-given path (relative to cwd, or absolute) or the current buffer.
---@param path? string
---@return string? abs, integer? buf  buf = the current buffer when it is the target (its cursor is used)
local function target(path)
  local buf = api.nvim_get_current_buf()
  local cur = buf_file(buf)
  if path and path ~= "" then
    local abs = vim.fs.normalize(vim.fn.fnamemodify(vim.fs.normalize(path), ":p"))
    return abs, abs == cur and buf or nil
  end
  return cur, buf
end

---@param path? string
---@return integer? index
function M.add(path)
  local abs, buf = target(path)
  if not abs then
    log.notify("current buffer is not a file", vim.log.levels.WARN)
    return nil
  end
  local list = store.current()
  local rel = store.rel(list, abs)
  local i = store.index(list, rel)
  if i then
    info(("%s is already mark %d"):format(rel, i))
    return i
  end
  local row, col = 1, 0
  if buf then
    row, col = unpack(api.nvim_win_get_cursor(0))
  end
  list.items[#list.items + 1] = { path = rel, row = row, col = col }
  if not store.save(list) then
    return nil
  end
  info(("marked %s (%d)"):format(rel, #list.items))
  M.changed(list, "add")
  return #list.items
end

---@param path? string
---@return boolean removed
function M.remove(path)
  local abs = target(path)
  if not abs then
    log.notify("current buffer is not a file", vim.log.levels.WARN)
    return false
  end
  local list = store.current()
  local rel = store.rel(list, abs)
  local i = store.index(list, rel)
  if not i then
    info(("%s is not marked"):format(rel))
    return false
  end
  table.remove(list.items, i)
  list.touched[rel] = nil
  if not store.save(list) then
    return false
  end
  info(("unmarked %s"):format(rel))
  M.changed(list, "remove")
  return true
end

function M.clear()
  local list = store.current()
  local n = #list.items
  list.items, list.touched = {}, {}
  if store.save(list) then
    info(("cleared %d mark(s)"):format(n))
    M.changed(list, "clear")
  end
end

---@return slop.marks.Entry[]
function M.list()
  local list = store.current()
  local out = {}
  for i, item in ipairs(list.items) do
    out[i] = { path = item.path, file = store.abs(list, item.path), row = item.row, col = item.col }
  end
  return out
end

--- Open a file (absolute path) with `cmd` and restore `row`/`col`.
---@param file string
---@param row integer
---@param col integer
---@param cmd? slop.marks.OpenCmd
---@return boolean ok
function M.open(file, row, col, cmd)
  local b = vim.fn.bufnr(file)
  if vim.fn.filereadable(file) == 0 and not (b > 0 and api.nvim_buf_is_loaded(b)) then
    log.notify(("file not found: %s"):format(vim.fn.fnamemodify(file, ":~:.")), vim.log.levels.WARN)
    return false
  end
  cmd = cmd or "edit"
  if not (cmd == "edit" and b > 0 and b == api.nvim_get_current_buf()) then
    local ok, err = pcall(vim.cmd, (OPEN[cmd] or "edit") .. " " .. vim.fn.fnameescape(file))
    if not ok then
      log.notify((tostring(err):gsub("^Vim:", "")), vim.log.levels.ERROR)
      return false
    end
  end
  local lines = api.nvim_buf_line_count(0)
  pcall(api.nvim_win_set_cursor, 0, { math.min(math.max(row, 1), lines), math.max(col, 0) })
  return true
end

---@param i integer
---@param opts? {cmd?: slop.marks.OpenCmd}
---@return boolean ok
function M.select(i, opts)
  local list = store.current()
  i = tonumber(i)
  i = i and i == math.floor(i) and i or nil
  local item = i and list.items[i]
  if not item then
    log.notify(
      #list.items == 0 and "no marks in this project"
        or ("no mark %s (%d mark%s)"):format(i or "?", #list.items, #list.items == 1 and "" or "s"),
      vim.log.levels.WARN
    )
    return false
  end
  ---@cast i integer
  last = i
  return M.open(store.abs(list, item.path), item.row, item.col, opts and opts.cmd)
end

---@param step integer  1 or -1
---@return boolean ok
local function cycle(step)
  local list = store.current()
  local n = #list.items
  if n == 0 then
    log.notify("no marks in this project", vim.log.levels.WARN)
    return false
  end
  local file = buf_file(api.nvim_get_current_buf())
  local cur = file and store.index(list, store.rel(list, file)) or last
  local i
  if not cur then
    i = step > 0 and 1 or n
  else
    i = cur + step
    if i < 1 or i > n then
      if not cfg().wrap then
        return false
      end
      i = (i - 1) % n + 1
    end
  end
  return M.select(i)
end

function M.next()
  return cycle(1)
end

function M.prev()
  return cycle(-1)
end

--- Remember the cursor of `buf` (current window) when it is marked.
---@param buf integer
function M.record(buf)
  local file = buf_file(buf)
  if not file or api.nvim_get_current_buf() ~= buf then
    return
  end
  local list = store.current(buf)
  local row, col = unpack(api.nvim_win_get_cursor(0))
  store.touch(list, store.rel(list, file), row, col)
end

function M.setup()
  local group = require("slop.core.util").augroup("marks")
  api.nvim_create_autocmd("BufLeave", {
    group = group,
    desc = "slop: remember the cursor of marked files",
    callback = function(ev)
      M.record(ev.buf)
    end,
  })
  api.nvim_create_autocmd("VimLeavePre", {
    group = group,
    desc = "slop: save marks",
    callback = function()
      local menu = package.loaded["slop.modules.marks.menu"]
      if menu then
        menu.close()
      end
      M.record(api.nvim_get_current_buf())
      store.flush()
    end,
  })
end

return M

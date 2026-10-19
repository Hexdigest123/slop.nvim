--- marks quick menu: an editable float with one path per line (reorder / delete / add by editing lines).
--- The list is saved when the menu closes (close keys, leaving the window, toggling, VimLeavePre). OWNER: marks.
local M = {}

local api = vim.api
local store = require("slop.modules.marks.store")

---@class slop.marks.MenuSession
---@field list slop.marks.List
---@field handle slop.float.Handle
---@field buf integer
---@field lines string[]        last known buffer content (the buffer may be gone when we save)
---@field initial string[]      stored paths when the menu opened
---@field done boolean

local sess = nil ---@type slop.marks.MenuSession?

local function cfg()
  return require("slop.config").get("marks")
end

local function ns()
  return require("slop.core.util").ns("marks")
end

--- Parse menu lines into stored paths (blank lines skipped, duplicates dropped).
---@param list slop.marks.List
---@param lines string[]
---@return string[] paths, table<integer, integer> index_of_line
function M.parse(list, lines)
  local paths, idx, seen = {}, {}, {}
  for n, line in ipairs(lines) do
    local p = vim.trim(line)
    if p ~= "" then
      local rel = store.rel(list, p)
      if not seen[rel] then
        seen[rel] = true
        paths[#paths + 1] = rel
        idx[n] = #paths
      end
    end
  end
  return paths, idx
end

--- Label shown at the right of entry `i`: its index and select key.
---@param i integer
---@return string
local function label(i)
  local key = cfg().keymaps["select_" .. i]
  return type(key) == "string" and key ~= "" and ("%d  %s"):format(i, key) or tostring(i)
end

---@param s slop.marks.MenuSession
local function render(s)
  if not api.nvim_buf_is_valid(s.buf) then
    return
  end
  s.lines = api.nvim_buf_get_lines(s.buf, 0, -1, false)
  local n = ns()
  api.nvim_buf_clear_namespace(s.buf, n, 0, -1)
  local paths, idx = M.parse(s.list, s.lines)
  for lnum, i in pairs(idx) do
    local chunks = {}
    if vim.fn.filereadable(store.abs(s.list, paths[i])) == 0 then
      chunks[#chunks + 1] = { "missing ", "SlopMarksMissing" }
    end
    chunks[#chunks + 1] = { label(i), "SlopMarksIndex" }
    api.nvim_buf_set_extmark(s.buf, n, lnum - 1, 0, { virt_text = chunks, virt_text_pos = "right_align" })
  end
end

--- Apply the edited lines to the list and write it (only when the paths changed).
---@param s slop.marks.MenuSession
local function save(s)
  if s.done then
    return
  end
  s.done = true
  if api.nvim_buf_is_valid(s.buf) then
    s.lines = api.nvim_buf_get_lines(s.buf, 0, -1, false)
  end
  local paths = M.parse(s.list, s.lines)
  if vim.deep_equal(paths, s.initial) then
    return
  end
  local list = s.list
  store.sync(list)
  local old = {}
  for _, item in ipairs(list.items) do
    old[item.path] = item
  end
  local items = {}
  for i, p in ipairs(paths) do
    local o = old[p]
    items[i] = { path = p, row = o and o.row or 1, col = o and o.col or 0 }
  end
  for p in pairs(list.touched) do
    if not old[p] then
      list.touched[p] = nil
    end
  end
  list.items = items
  if store.save(list) then
    require("slop.modules.marks.actions").changed(list, "menu")
  end
end

---@return boolean
function M.is_open()
  return sess ~= nil and not sess.done and sess.handle:is_valid()
end

--- Close the menu (saving it).
function M.close()
  local s = sess
  if not s then
    return
  end
  sess = nil
  save(s)
  s.handle:close()
end

---@return string
local function footer()
  local km = cfg().keymaps
  local parts = {}
  for _, k in ipairs({
    { "menu_open", "open" },
    { "menu_vsplit", "vsplit" },
    { "menu_split", "split" },
    { "menu_tab", "tab" },
  }) do
    if type(km[k[1]]) == "string" then
      parts[#parts + 1] = km[k[1]] .. " " .. k[2]
    end
  end
  local close = cfg().menu.close_keys[1]
  if close then
    parts[#parts + 1] = close .. " close"
  end
  return table.concat(parts, "  ")
end

--- Open the menu for the current project's list.
function M.open()
  if M.is_open() then
    ---@cast sess slop.marks.MenuSession
    sess.handle:focus()
    return
  end
  local list = store.current()
  local cur = vim.fs.normalize(api.nvim_buf_get_name(0))
  local initial, cursor = {}, 1
  for i, item in ipairs(list.items) do
    initial[i] = item.path
    if vim.bo.buftype == "" and store.abs(list, item.path) == cur then
      cursor = i
    end
  end
  local mcfg = cfg().menu
  local s ---@type slop.marks.MenuSession
  local width = 40
  for _, p in ipairs(initial) do
    width = math.max(width, vim.fn.strdisplaywidth(p) + 16)
  end
  local handle = require("slop.core.ui.float").open({
    width = mcfg.width,
    min_width = math.min(width, vim.o.columns - 4),
    height = mcfg.height or math.min(math.max(#initial + 1, 5), math.floor(vim.o.lines * 0.6)),
    title = "marks: " .. vim.fn.fnamemodify(list.root, ":t"),
    footer = footer(),
    close_keys = mcfg.close_keys,
    close_on_leave = true,
    wo = { cursorline = true },
    bo = { filetype = "slopmarks" },
    on_close = function()
      if sess == s then
        sess = nil
      end
      save(s)
    end,
  })
  local buf = handle.buf
  s = { list = list, handle = handle, buf = buf, lines = initial, initial = initial, done = false }
  sess = s
  api.nvim_buf_set_lines(buf, 0, -1, false, initial)
  vim.bo[buf].modified = false
  pcall(api.nvim_win_set_cursor, handle.win, { cursor, 0 })
  render(s)
  local group = require("slop.core.util").augroup("marks")
  api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    group = group,
    buffer = buf,
    desc = "slop: marks menu labels",
    callback = function()
      render(s)
    end,
  })
  api.nvim_create_autocmd("BufWipeout", {
    group = group,
    buffer = buf,
    desc = "slop: save marks menu",
    callback = function()
      if sess == s then
        sess = nil
      end
      save(s)
    end,
  })
  require("slop.core.keymaps").apply_buf("marks", buf)
end

function M.toggle()
  if M.is_open() then
    M.close()
  else
    M.open()
  end
end

--- Open the entry under the cursor (closing and saving the menu first).
---@param cmd? slop.marks.OpenCmd
function M.open_entry(cmd)
  local s = sess
  if not s or api.nvim_get_current_buf() ~= s.buf then
    return
  end
  local lnum = api.nvim_win_get_cursor(0)[1]
  local _, idx = M.parse(s.list, api.nvim_buf_get_lines(s.buf, 0, -1, false))
  M.close()
  if idx[lnum] then
    require("slop.modules.marks.actions").select(idx[lnum], { cmd = cmd })
  end
end

return M

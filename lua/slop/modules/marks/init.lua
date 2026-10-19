--- marks: a per-project list of files with cursor memory and an editable quick menu. Replaces harpoon2.
--- OWNER: marks. Storage in modules/marks/store.lua, behaviour in actions.lua, the menu in menu.lua (required lazily).
local function actions()
  return require("slop.modules.marks.actions")
end

local function menu()
  return require("slop.modules.marks.menu")
end

local function is_size(v)
  return type(v) == "function" or (type(v) == "number" and v > 0)
end

local api = {}

--- Mark `path` (default: the current file). Returns its index.
---@param path? string
---@return integer?
function api.add(path)
  return actions().add(path)
end

--- Unmark `path` (default: the current file).
---@param path? string
---@return boolean
function api.remove(path)
  return actions().remove(path)
end

--- Open the quick menu, or close (and save) it.
function api.toggle_menu()
  menu().toggle()
end

--- Open mark `i` and restore its cursor. `opts.cmd`: "edit" (default) | "split" | "vsplit" | "tab".
---@param i integer
---@param opts? {cmd?: slop.marks.OpenCmd}
---@return boolean
function api.select(i, opts)
  return actions().select(i, opts)
end

--- Open the mark after (before) the current file, or after the last selected one.
---@return boolean
function api.next()
  return actions().next()
end

---@return boolean
function api.prev()
  return actions().prev()
end

---@class slop.marks.Entry
---@field path string   as stored (relative to the project root, absolute when outside it)
---@field file string   absolute path
---@field row integer   remembered cursor line (1-based)
---@field col integer   remembered cursor column (0-based)

--- The current project's marks.
---@return slop.marks.Entry[]
function api.list()
  return actions().list()
end

--- Remove every mark of the current project.
function api.clear()
  actions().clear()
end

--- Path of the current project's marks file.
---@return string
function api.file()
  local _, file = require("slop.modules.marks.store").locate()
  return file
end

local keymaps = {
  add = {
    mode = "n",
    desc = "mark file",
    rhs = function()
      api.add()
    end,
  },
  menu = {
    mode = "n",
    desc = "marks menu",
    rhs = function()
      api.toggle_menu()
    end,
  },
  next = {
    mode = "n",
    desc = "next mark",
    rhs = function()
      api.next()
    end,
  },
  prev = {
    mode = "n",
    desc = "previous mark",
    rhs = function()
      api.prev()
    end,
  },
}
local defaults_keys = { add = "<leader>h", menu = "<C-e>", next = false, prev = false }
for i = 1, 10 do
  keymaps["select_" .. i] = {
    mode = "n",
    desc = "go to mark " .. i,
    rhs = function()
      api.select(i)
    end,
  }
  defaults_keys["select_" .. i] = "<leader>" .. (i % 10)
end
for name, cmd in pairs({ menu_open = "edit", menu_vsplit = "vsplit", menu_split = "split", menu_tab = "tab" }) do
  keymaps[name] = {
    mode = "n",
    buffer = true,
    desc = "marks menu: open " .. (cmd == "edit" and "entry" or "in " .. cmd),
    rhs = function()
      menu().open_entry(cmd)
    end,
  }
end
defaults_keys.menu_open = "<CR>"
defaults_keys.menu_vsplit = "<C-v>"
defaults_keys.menu_split = "<C-x>"
defaults_keys.menu_tab = "<C-t>"

local function complete_paths(lead)
  local ok, list = pcall(api.list)
  return require("slop.core.util").complete_prefix(
    vim.tbl_map(function(e)
      return e.path
    end, ok and list or {}),
    lead
  )
end

local function no_args(fn)
  return {
    impl = function()
      fn()
    end,
  }
end

local commands = {
  menu = { desc = "toggle the quick menu", default = true, impl = api.toggle_menu },
  add = {
    desc = "add [path]: mark the current file (or path)",
    impl = function(args)
      api.add(args[1])
    end,
    complete = function(lead, args)
      return #args <= 1 and vim.fn.getcompletion(lead, "file") or {}
    end,
  },
  remove = {
    desc = "remove [path]: unmark the current file (or path)",
    impl = function(args)
      api.remove(args[1])
    end,
    complete = function(lead, args)
      return #args <= 1 and complete_paths(lead) or {}
    end,
  },
  select = {
    desc = "select {n}: open mark n",
    impl = function(args)
      if not tonumber(args[1]) then
        return require("slop.core.log").notify(
          "usage: :Slop marks select {n}",
          vim.log.levels.ERROR,
          { scope = "marks" }
        )
      end
      api.select(tonumber(args[1]) --[[@as integer]])
    end,
    complete = function(lead, args)
      if #args > 1 then
        return {}
      end
      local ok, list = pcall(api.list)
      local n = ok and #list or 0
      local nums = {}
      for i = 1, n do
        nums[i] = tostring(i)
      end
      return require("slop.core.util").complete_prefix(nums, lead)
    end,
  },
  next = no_args(api.next),
  prev = no_args(api.prev),
  clear = no_args(api.clear),
  list = {
    desc = "list the marks",
    impl = function()
      local list = api.list()
      if #list == 0 then
        return require("slop.core.log").notify("no marks in this project", vim.log.levels.INFO, { scope = "marks" })
      end
      local chunks = {}
      for i, e in ipairs(list) do
        local missing = vim.fn.filereadable(e.file) == 0
        chunks[#chunks + 1] = { ("%2d  "):format(i), "SlopMarksIndex" }
        chunks[#chunks + 1] = { e.path, missing and "SlopMarksMissing" or nil }
        chunks[#chunks + 1] = { (":%d%s"):format(e.row, missing and "  (missing)" or "") .. (i < #list and "\n" or "") }
      end
      vim.api.nvim_echo(chunks, false, {})
    end,
  },
}
commands.next.desc = "open the next mark"
commands.prev.desc = "open the previous mark"
commands.clear.desc = "remove every mark of the project"

---@type slop.ModuleSpec
return {
  name = "marks",
  description = "Per-project file marks with cursor memory and an editable menu (harpoon)",
  defaults = {
    enabled = true,
    scope = "cwd", -- "cwd": project root of the cwd | "buffer": project root of the current buffer
    wrap = true, -- next/prev wrap around
    notify = true, -- confirm add/remove/clear
    menu = {
      width = 0.6, -- (0,1] fraction of the editor, > 1 cells, or fun(columns, lines)
      height = false, -- false = fit the entries; else a size like width
      close_keys = { "q", "<Esc>" },
    },
    keymaps = defaults_keys,
  },
  schema = function(cfg, check)
    check("scope", cfg.scope, function(v)
      return v == "cwd" or v == "buffer"
    end, false, "'cwd'|'buffer'")
    check("wrap", cfg.wrap, "boolean")
    check("notify", cfg.notify, "boolean")
    check("menu", cfg.menu, "table")
    local m = cfg.menu or {}
    check("menu.width", m.width, is_size, false, "positive number or function")
    check("menu.height", m.height, function(v)
      return v == false or is_size(v)
    end, false, "false, positive number or function")
    check("menu.close_keys", m.close_keys, function(v)
      return type(v) == "table" and vim.iter(v):all(function(k)
        return type(k) == "string"
      end)
    end, false, "list of keys")
  end,
  setup = function(_)
    actions().setup()
  end,
  teardown = function()
    local m = package.loaded["slop.modules.marks.menu"]
    if m then
      m.close()
    end
    local store = package.loaded["slop.modules.marks.store"]
    if store then
      store.flush()
    end
    pcall(vim.api.nvim_del_augroup_by_name, "slop.marks")
  end,
  commands = commands,
  keymaps = keymaps,
  highlights = {
    SlopMarksIndex = { link = "SlopDim" },
    SlopMarksMissing = { link = "DiagnosticWarn" },
  },
  health = function()
    local store = require("slop.modules.marks.store")
    local ok, list = pcall(store.current)
    if not ok then
      return vim.health.error("cannot read the marks list: " .. tostring(list))
    end
    vim.health.info(
      ("list: %s (%s)"):format(
        vim.fn.fnamemodify(list.file, ":~"),
        list.project and "project state" or "no project root: keyed by cwd"
      )
    )
    if list.corrupt then
      vim.health.warn("the marks file is not valid JSON; it is backed up to .bak and replaced on the next change")
    end
    local missing = {}
    for _, item in ipairs(list.items) do
      if vim.fn.filereadable(store.abs(list, item.path)) == 0 then
        missing[#missing + 1] = item.path
      end
    end
    if #missing > 0 then
      vim.health.warn(("%d mark(s) point to missing files: %s"):format(#missing, table.concat(missing, ", ")))
    else
      vim.health.ok(("%d mark(s)"):format(#list.items))
    end
  end,
  api = api,
}

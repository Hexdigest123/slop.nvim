--- todo: highlight TODO/FIX/HACK/... comments, list them project-wide, jump between them. Replaces
--- todo-comments.nvim. See :h slop-todo.txt.
---
--- init.lua stays cheap: only the pure keyword tables are required up front; render and search load on use.
local keywords = require("slop.modules.todo.keywords")

local state = {
  cfg = nil, ---@type table?
  kw = nil, ---@type slop.todo.Keywords?
}

local function render()
  return require("slop.modules.todo.render")
end

local function log()
  return require("slop.core.log").scope("todo")
end

local function ready()
  if not state.cfg then
    require("slop").load("todo")
  end
  return state.cfg ~= nil
end

local function compile(cfg)
  state.cfg = cfg
  state.kw = keywords.compile(cfg)
  keywords.apply_highlights(state.kw, cfg.colors)
end

--- Words selected by a keyword filter, warning about unknown names.
---@param filter? string|string[]
---@return table<string, slop.todo.Group>
local function words_for(filter)
  local words, unknown = keywords.select(assert(state.kw), keywords.parse_filter(filter))
  if #unknown > 0 then
    log().notify("unknown keyword(s): " .. table.concat(unknown, ", "), vim.log.levels.WARN)
  end
  return words
end

-- API ------------------------------------------------------------------------------------------

local api = {}

---@class slop.todo.ListOpts: slop.todo.SearchOpts
---@field keywords? string|string[]   "TODO,FIX" or { "TODO", "FIX" }; a group name includes its aliases
---@field open? boolean               qf(): open the quickfix window (default true)

--- Search the project (async); `cb(results, err?)` runs on the main loop.
---@param opts? slop.todo.ListOpts
---@param cb fun(results: slop.todo.Result[], err?: string)
function api.search(opts, cb)
  if not ready() then
    return cb({}, "todo is not loaded")
  end
  opts = opts or {}
  require("slop.modules.todo.search").run(opts, words_for(opts.keywords), cb)
end

---@param r slop.todo.Result
---@param root string
---@return slop.picker.Chunks
local function format(r, root)
  local g = state.kw and state.kw.groups[r.group]
  local hl = g and g.hl or "Comment"
  local rel = vim.fs.relpath(root, r.path) or vim.fn.fnamemodify(r.path, ":~")
  return {
    { (g and g.icon ~= "" and g.icon or "") .. r.keyword, hl },
    { " " },
    { ("%s:%d"):format(rel, r.lnum), "SlopDim" },
    { " " .. r.message },
  }
end

---@param r slop.todo.Result
---@param action? string
local function open(r, action)
  local cmd = ({ vsplit = "vsplit", split = "split", tab = "tabedit" })[action or ""] or "edit"
  if vim.fs.normalize(vim.api.nvim_buf_get_name(0)) ~= r.path or cmd ~= "edit" then
    vim.cmd(cmd .. " " .. vim.fn.fnameescape(r.path))
  end
  vim.cmd("normal! m'")
  pcall(vim.api.nvim_win_set_cursor, 0, { r.lnum, r.col - 1 })
  vim.cmd("normal! zv")
end

--- Pick a todo of the project (core.ui.picker) and jump to it.
---@param opts? slop.todo.ListOpts
function api.list(opts)
  if not ready() then
    return
  end
  opts = opts or {}
  local root = opts.root or require("slop.core.project").root()
  local o = vim.tbl_extend("force", opts, { root = root })
  require("slop.core.ui.picker").pick(function(cb)
    api.search(o, function(results, err)
      if err then
        log().notify(err, vim.log.levels.ERROR)
      end
      cb(results)
    end)
  end, {
    prompt = "Todo",
    title = "Todo comments",
    format = function(r)
      return format(r, root)
    end,
    preview = function(r)
      return { path = r.path, lnum = r.lnum }
    end,
    actions = { ["<C-v>"] = "vsplit", ["<C-s>"] = "split", ["<C-t>"] = "tab" },
    on_select = function(r, action)
      if r then
        open(r, action)
      end
    end,
  })
end

--- Put the project's todos in the quickfix list (and open it unless opts.open == false).
---@param opts? slop.todo.ListOpts
function api.qf(opts)
  opts = opts or {}
  api.search(opts, function(results, err)
    if err then
      return log().notify(err, vim.log.levels.ERROR)
    end
    local items = {}
    for _, r in ipairs(results) do
      items[#items + 1] = { filename = r.path, lnum = r.lnum, col = r.col, text = vim.trim(r.line) }
    end
    vim.fn.setqflist({}, " ", { title = "slop todo", items = items })
    if #items == 0 then
      log().notify("no todo comments found", vim.log.levels.INFO)
    elseif opts.open ~= false then
      vim.cmd("botright copen")
    end
  end)
end

---@class slop.todo.JumpOpts
---@field keywords? string|string[]
---@field wrap? boolean    default 'wrapscan'
---@field count? integer   default v:count1

---@param dir 1|-1
---@param opts? slop.todo.JumpOpts
---@return boolean jumped
local function jump(dir, opts)
  if not ready() then
    return false
  end
  opts = opts or {}
  local words = words_for(opts.keywords)
  local wrap = opts.wrap
  if wrap == nil then
    wrap = vim.o.wrapscan
  end
  local buf = vim.api.nvim_get_current_buf()
  local cur = vim.api.nvim_win_get_cursor(0)
  local pos = { cur[1] - 1, cur[2] }
  local found
  for _ = 1, math.max(opts.count or vim.v.count1, 1) do
    local p = render().find(buf, found or pos, dir, words, wrap)
    if not p then
      break
    end
    found = p
  end
  if not found then
    log().notify("no more todo comments to jump to", vim.log.levels.INFO)
    return false
  end
  vim.cmd("normal! m'")
  vim.api.nvim_win_set_cursor(0, { found[1] + 1, found[2] })
  vim.cmd("normal! zv")
  return true
end

--- Jump to the next todo comment of the buffer.
---@param opts? slop.todo.JumpOpts
---@return boolean jumped
function api.jump_next(opts)
  return jump(1, opts)
end

--- Jump to the previous todo comment of the buffer.
---@param opts? slop.todo.JumpOpts
---@return boolean jumped
function api.jump_prev(opts)
  return jump(-1, opts)
end

--- Toggle highlights and signs (all buffers).
function api.toggle()
  if ready() then
    render().set_enabled(not render().is_enabled())
  end
end

function api.enable()
  if ready() then
    render().set_enabled(true)
  end
end

function api.disable()
  if ready() then
    render().set_enabled(false)
  end
end

---@return boolean
function api.is_enabled()
  return state.cfg ~= nil and render().is_enabled()
end

--- Compiled keyword groups (after setup).
---@return slop.todo.Keywords?
function api.keywords()
  ready()
  return state.kw
end

-- Spec -----------------------------------------------------------------------------------------

local function complete_keywords(lead)
  local names = {}
  local kw = state.kw or keywords.compile(require("slop.config").get("todo"))
  for w in pairs(kw.by_word) do
    names[#names + 1] = w
  end
  -- complete the last item of a comma list: "TODO,FI" -> "TODO,FIX"
  local head, tail = lead:match("^(.*,)([^,]*)$")
  head, tail = head or "", tail or lead
  return vim.tbl_map(function(n)
    return head .. n
  end, require("slop.core.util").complete_prefix(names, tail))
end

local HL = keywords.highlights

---@type slop.ModuleSpec
return {
  name = "todo",
  description = "Highlight, list and jump between TODO/FIX/HACK/... comments",
  defaults = {
    enabled = true,
    signs = true, -- sign column icons (per keyword: keywords.X.signs = false)
    sign_priority = 8,
    keywords = vim.deepcopy(keywords.defaults), -- add your own; `NAME = false` removes a default group
    colors = vim.deepcopy(keywords.colors), -- color name -> highlight group(s) / "#hex", first existing wins
    highlight = {
      keyword = "wide", -- "wide" | "bg" | "fg" | false: keyword badge (wide = one extra cell each side)
      after = "fg", -- "fg" | false: rest of the comment in the group color
      multiline = true, -- continue onto following comment lines indented past the keyword
      multiline_context = 10, -- max continuation lines
      comments_only = true, -- treesitter comment check (else a 'commentstring' heuristic)
      max_line_len = 400, -- skip longer lines
      exclude = {}, -- filetypes never highlighted
    },
    max_filesize = 1024 * 1024, -- bytes; larger buffers are not highlighted (false = no limit)
    search = {
      backend = "auto", -- "auto" (rg > git grep > lua) | "rg" | "git" | "lua"
      args = {}, -- extra rg arguments, e.g. { "--hidden", "--glob=!.git" }
    },
    keymaps = { list = "<leader>xt", next = false, prev = false },
  },
  open_keys = { "keywords", "colors" },
  schema = function(cfg, check)
    check("signs", cfg.signs, "boolean")
    check("sign_priority", cfg.sign_priority, "number")
    check("colors", cfg.colors, "table")
    check("highlight", cfg.highlight, "table")
    local hc = type(cfg.highlight) == "table" and cfg.highlight or {}
    check("highlight.keyword", hc.keyword, function(v)
      return v == false or v == "wide" or v == "bg" or v == "fg"
    end, false, "'wide'|'bg'|'fg'|false")
    check("highlight.after", hc.after, function(v)
      return v == false or v == "fg"
    end, false, "'fg'|false")
    check("highlight.multiline", hc.multiline, "boolean")
    check("highlight.multiline_context", hc.multiline_context, "number")
    check("highlight.comments_only", hc.comments_only, "boolean")
    check("highlight.max_line_len", hc.max_line_len, "number")
    check("highlight.exclude", hc.exclude, "table")
    check("max_filesize", cfg.max_filesize, function(v)
      return v == false or type(v) == "number"
    end, false, "number or false")
    check("search", cfg.search, "table")
    local sc = type(cfg.search) == "table" and cfg.search or {}
    check("search.backend", sc.backend, function(v)
      return v == "auto" or v == "rg" or v == "git" or v == "lua"
    end, false, "'auto'|'rg'|'git'|'lua'")
    check("search.args", sc.args, "table")
    local errs = keywords.validate(cfg.keywords)
    if #errs > 0 then
      error("todo." .. table.concat(errs, "\n  todo."), 0)
    end
  end,
  setup = function(cfg)
    compile(cfg)
    render().start(cfg, state.kw)
    local group = require("slop.core.util").augroup("todo")
    vim.api.nvim_create_autocmd("ColorScheme", {
      group = group,
      desc = "slop: todo highlight colors",
      callback = function()
        if state.kw and state.cfg then
          keywords.apply_highlights(state.kw, state.cfg.colors)
        end
      end,
    })
    vim.api.nvim_create_autocmd("User", {
      group = group,
      pattern = "SlopConfigChanged",
      desc = "slop: todo live reconfig",
      callback = function()
        local config = require("slop.config")
        local new = config.get("todo")
        if new.enabled and #config.errors("todo") == 0 and state.cfg then
          compile(new)
          render().reconfigure(new, state.kw)
        end
      end,
    })
  end,
  teardown = function()
    render().stop()
    pcall(vim.api.nvim_del_augroup_by_name, "slop.todo")
    state.cfg, state.kw = nil, nil
  end,
  commands = {
    list = {
      desc = "pick a todo of the project [KEYWORDS,...]",
      default = true,
      impl = function(args)
        api.list({ keywords = args })
      end,
      complete = complete_keywords,
    },
    qf = {
      desc = "todos of the project in the quickfix list [KEYWORDS,...]",
      impl = function(args)
        api.qf({ keywords = args })
      end,
      complete = complete_keywords,
    },
    next = {
      desc = "jump to the next todo [KEYWORDS,...]",
      impl = function(args, cmd)
        api.jump_next({ keywords = args, count = cmd and cmd.count and cmd.count > 0 and cmd.count or 1 })
      end,
      complete = complete_keywords,
    },
    prev = {
      desc = "jump to the previous todo [KEYWORDS,...]",
      impl = function(args, cmd)
        api.jump_prev({ keywords = args, count = cmd and cmd.count and cmd.count > 0 and cmd.count or 1 })
      end,
      complete = complete_keywords,
    },
    toggle = {
      desc = "toggle todo highlights",
      impl = function()
        api.toggle()
      end,
    },
    enable = {
      desc = "show todo highlights",
      impl = function()
        api.enable()
      end,
    },
    disable = {
      desc = "hide todo highlights",
      impl = function()
        api.disable()
      end,
    },
  },
  keymaps = {
    list = {
      mode = "n",
      desc = "todo list",
      rhs = function()
        api.list()
      end,
    },
    next = {
      mode = "n",
      desc = "next todo comment",
      rhs = function()
        api.jump_next()
      end,
    },
    prev = {
      mode = "n",
      desc = "previous todo comment",
      rhs = function()
        api.jump_prev()
      end,
    },
  },
  highlights = HL,
  health = function()
    local cfg = require("slop.config").get("todo")
    local errs = keywords.validate(cfg.keywords)
    if #errs == 0 then
      local kw = keywords.compile(cfg)
      local n = 0
      for _ in pairs(kw.by_word) do
        n = n + 1
      end
      vim.health.ok(("%d keyword group(s), %d keyword(s): %s"):format(#kw.order, n, table.concat(kw.order, " ")))
    else
      for _, e in ipairs(errs) do
        vim.health.error(e)
      end
    end
    local backend = require("slop.modules.todo.search").backend(cfg.search.backend, vim.fn.getcwd())
    if backend == "rg" then
      vim.health.ok("project search: rg")
    elseif backend == "git" then
      vim.health.ok("project search: git grep (install ripgrep for non-git projects)")
    else
      vim.health.warn("project search: Lua fallback (slow on big trees); install ripgrep")
    end
    vim.health.info(
      ("highlights: keyword=%s, after=%s, comments_only=%s (treesitter, else 'commentstring'), signs=%s"):format(
        tostring(cfg.highlight.keyword),
        tostring(cfg.highlight.after),
        tostring(cfg.highlight.comments_only),
        tostring(cfg.signs)
      )
    )
    if package.loaded["todo-comments"] or vim.fn.exists(":TodoQuickFix") == 2 then
      vim.health.warn("todo-comments.nvim is also installed: remove it (double highlights and signs)")
    end
  end,
  api = api,
}

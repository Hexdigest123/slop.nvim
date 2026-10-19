-- todo rendering: comment detection, draw items, decoration provider (visible rows only), signs, jumps, toggles.
local h = require("helpers")

local api = vim.api

describe("todo render", function()
  local dir, todo
  before_each(function()
    h.reset()
    vim.notify = function() end
    vim.cmd("silent! %bwipe!")
    vim.cmd("silent! only")
    vim.o.columns, vim.o.lines = 80, 24
    h.source_plugin()
    dir = h.tmpdir("todo")
  end)
  after_each(function()
    pcall(function()
      require("slop.core.registry").disable("todo")
    end)
    vim.cmd("silent! %bwipe!")
  end)

  local function load(opts)
    require("slop").setup({ todo = opts or {} })
    todo = assert(require("slop").load("todo"))
    return todo
  end

  local function open(name, text, opts)
    load(opts)
    local path = dir .. "/" .. name
    h.write(path, text)
    vim.cmd.edit(vim.fn.fnameescape(path))
    vim.cmd("redraw!")
    return api.nvim_get_current_buf()
  end

  --- { row = { "col-end_col:hl[!]" } } of rows srow..erow ("!" = keyword badge).
  local function items(buf, srow, erow)
    local out = {}
    for row, its in pairs(require("slop.modules.todo.render").items(buf, srow, erow)) do
      out[row] = vim.tbl_map(function(it)
        return ("%d-%d:%s%s"):format(it.col, it.end_col, it.hl, it.badge and "!" or "")
      end, its)
    end
    return out
  end

  local function signs(buf)
    vim.wait(20)
    local out = {}
    for _, m in
      ipairs(api.nvim_buf_get_extmarks(buf, require("slop.core.util").ns("todo.signs"), 0, -1, {
        details = true,
      }))
    do
      out[#out + 1] = { m[2], m[4].sign_hl_group }
    end
    return out
  end

  local LUA = table.concat({
    "local x = 1 -- TODO: fix this",
    "-- FIX(alice): broken",
    "--       continued here",
    "-- unrelated",
    'local s = "TODO: not a comment"',
    "-- NOTE no colon",
    "--[[ HACK: block ]] local y = 2",
    "",
  }, "\n")

  it("highlights todos in treesitter comments only (wide badge + comment text, multiline)", function()
    local buf = open("a.lua", LUA)
    assert.truthy(vim.treesitter.get_parser(buf, nil, { error = false }), "bundled lua parser")
    assert.are.same({
      [0] = { "14-21:SlopTodoTodo!", "21-29:SlopTodoTodoText" },
      [1] = { "2-15:SlopTodoFix!", "15-21:SlopTodoFixText" },
      [2] = { "9-23:SlopTodoFixText" },
      [6] = { "4-11:SlopTodoHack!", "11-17:SlopTodoHackText" },
    }, items(buf, 0, 7))
  end)

  it("keyword styles bg / fg / false and after = false", function()
    local buf = open("a.lua", "-- TODO: x\n", { highlight = { keyword = "bg" } })
    assert.are.same({ [0] = { "3-8:SlopTodoTodo!", "8-10:SlopTodoTodoText" } }, items(buf, 0, 0))
    require("slop").setup({ todo = { highlight = { keyword = "fg", after = false } } })
    assert.are.same({ [0] = { "3-8:SlopTodoTodo" } }, items(buf, 0, 0))
    require("slop").setup({ todo = { highlight = { keyword = false } } })
    assert.are.same({ [0] = { "8-10:SlopTodoTodoText" } }, items(buf, 0, 0))
  end)

  it("multiline stops at blank lines, new todos, and lines not indented past the keyword", function()
    local buf = open(
      "m.lua",
      table.concat({
        "-- TODO: one",
        "--       two",
        "--       three",
        "-- four",
        "--       five",
        "",
        "  -- NOTE: a",
        "  --   b",
        "",
        "  --   c",
      }, "\n")
    )
    local got = items(buf, 0, 9)
    assert.not_nil(got[1])
    assert.not_nil(got[2])
    assert.is_nil(got[3])
    assert.is_nil(got[4], "continuation chain broken by 'four'")
    assert.are.same({ "7-8:SlopTodoNoteText" }, got[7])
    assert.is_nil(got[9])
    require("slop").setup({ todo = { highlight = { multiline = false } } })
    assert.is_nil(items(buf, 0, 9)[1])
  end)

  it("falls back to a 'commentstring' heuristic without a parser", function()
    local buf = open("x.sh", "echo 'TODO: no'\n# TODO: yes\nx=1 # FIX: tail\n")
    assert.equal("sh", vim.bo[buf].filetype)
    assert.falsy(vim.treesitter.get_parser(buf, nil, { error = false }))
    local got = items(buf, 0, 2)
    assert.is_nil(got[0])
    assert.not_nil(got[1])
    assert.not_nil(got[2])
    local R = require("slop.modules.todo.render")
    vim.bo[buf].commentstring = "/* %s */"
    assert.are.same({ true, 11 }, { R.heuristic(buf, "/* TODO: x */ code", 3) })
    assert.are.same({ true }, { R.heuristic(buf, " * TODO: inside a block", 3) })
    assert.are.same({ false }, { R.heuristic(buf, "x = TODO: y", 4) })
  end)

  it("comments_only = false highlights anywhere", function()
    local buf = open("a.lua", 'local s = "TODO: in a string"\n', { highlight = { comments_only = false } })
    assert.not_nil(items(buf, 0, 0)[0])
  end)

  it("skips special buffers, excluded filetypes, big files and long lines", function()
    local buf = open("a.lua", "-- TODO: x\n", { highlight = { exclude = { "lua" } } })
    assert.are.same({}, items(buf, 0, 0))
    require("slop").setup({ todo = {} })
    assert.not_nil(items(buf, 0, 0)[0])
    local scratch = api.nvim_create_buf(false, true)
    api.nvim_buf_set_lines(scratch, 0, -1, false, { "-- TODO: x" })
    vim.bo[scratch].filetype = "lua"
    assert.are.same({}, items(scratch, 0, 0))
    require("slop").setup({ todo = { max_filesize = 8 } })
    assert.are.same({}, items(buf, 0, 0))
    require("slop").setup({ todo = { highlight = { max_line_len = 5 } } })
    assert.are.same({}, items(buf, 0, 0))
  end)

  it("draws ephemeral marks for visible rows only", function()
    local lines = {}
    for i = 1, 2000 do
      lines[i] = ("-- TODO: item %d"):format(i)
    end
    local buf = open("big.lua", table.concat(lines, "\n") .. "\n")
    local rows = {}
    local orig = api.nvim_buf_set_extmark
    local ns = require("slop.core.util").ns("todo")
    api.nvim_buf_set_extmark = function(b, n, r, c, o)
      if n == ns then
        assert.is_true(o.ephemeral)
        rows[r] = true
      end
      return orig(b, n, r, c, o)
    end
    vim.cmd("normal! 1000Gzt")
    vim.cmd("redraw!")
    api.nvim_buf_set_extmark = orig
    local drawn = vim.tbl_keys(rows)
    table.sort(drawn)
    assert.truthy(#drawn > 0 and #drawn <= vim.o.lines, #drawn)
    assert.equal(999, drawn[1])
    local st = require("slop.modules.todo.render")._state.bufs[buf]
    local cached = vim.tbl_count(st.items)
    assert.truthy(cached < 100, "only visible rows computed: " .. cached)
  end)

  it("places signs for visible rows after the redraw; toggle clears and restores them", function()
    local buf = open("a.lua", LUA)
    assert.are.same({ { 0, "SlopTodoTodo" }, { 1, "SlopTodoFix" }, { 6, "SlopTodoHack" } }, signs(buf))
    todo.disable()
    assert.is_false(todo.is_enabled())
    vim.cmd("redraw!")
    assert.are.same({}, signs(buf))
    todo.toggle()
    vim.cmd("redraw!")
    assert.equal(3, #signs(buf))
    -- edits re-reconcile visible rows
    api.nvim_buf_set_lines(buf, 3, 4, false, { "-- WARN: new" })
    vim.cmd("redraw!")
    assert.are.same(
      { 0, 1, 3, 6 },
      vim.tbl_map(function(s)
        return s[1]
      end, signs(buf))
    )
  end)

  it("signs = false and per-keyword signs = false", function()
    local buf = open("a.lua", LUA, { signs = false })
    assert.are.same({}, signs(buf))
    require("slop").setup({ todo = { keywords = { TODO = { signs = false } } } })
    vim.cmd("redraw!")
    assert.are.same({ { 1, "SlopTodoFix" }, { 6, "SlopTodoHack" } }, signs(buf))
  end)

  it("does not draw while disabled and stops after teardown", function()
    local buf = open("a.lua", LUA)
    require("slop.core.registry").disable("todo")
    vim.cmd("redraw!")
    assert.are.same({}, signs(buf))
  end)

  it("jump_next / jump_prev skip non-comments, filter keywords, wrap, count", function()
    open("a.lua", LUA)
    api.nvim_win_set_cursor(0, { 1, 0 })
    local function pos()
      local c = api.nvim_win_get_cursor(0)
      return { c[1], c[2] }
    end
    assert.is_true(todo.jump_next())
    assert.are.same({ 1, 15 }, pos())
    todo.jump_next()
    assert.are.same({ 2, 3 }, pos())
    todo.jump_next()
    assert.are.same({ 7, 5 }, pos(), "string TODO and colon-less NOTE skipped")
    todo.jump_next()
    assert.are.same({ 1, 15 }, pos(), "wrapscan")
    todo.jump_prev()
    assert.are.same({ 7, 5 }, pos())
    assert.is_false(todo.jump_next({ wrap = false }))
    assert.are.same({ 7, 5 }, pos())
    api.nvim_win_set_cursor(0, { 1, 0 })
    todo.jump_next({ keywords = "HACK" })
    assert.are.same({ 7, 5 }, pos())
    api.nvim_win_set_cursor(0, { 1, 0 })
    todo.jump_next({ count = 2 })
    assert.are.same({ 2, 3 }, pos())
    vim.cmd("Slop todo prev")
    assert.are.same({ 1, 15 }, pos())
  end)

  it("configured colors replace the default links; new keywords get groups", function()
    open("a.lua", "-- TODO: x\n-- SAFETY: y\n", {
      keywords = { TODO = { color = "#ff0000" }, SAFETY = { color = "warning", icon = "!" } },
    })
    assert.equal(0xff0000, api.nvim_get_hl(0, { name = "SlopTodoTodo" }).fg)
    assert.equal("DiagnosticWarn", api.nvim_get_hl(0, { name = "SlopTodoSafety" }).link)
    assert.equal("SlopTodoSafety", api.nvim_get_hl(0, { name = "SlopTodoSafetyText" }).link)
    assert.equal("DiagnosticError", api.nvim_get_hl(0, { name = "SlopTodoFix" }).link)
    assert.not_nil(items(0, 0, 1)[1])
    vim.cmd("doautocmd ColorScheme")
    assert.equal(0xff0000, api.nvim_get_hl(0, { name = "SlopTodoTodo" }).fg)
  end)

  it("rejects invalid config", function()
    require("slop").setup({ todo = { highlight = { keyword = "loud" }, keywords = { X = { alt = "Y" } } } })
    local errs = table.concat(require("slop.config").errors("todo"), "\n")
    assert.matches("todo.highlight.keyword", errs)
    assert.matches("todo.keywords.X.alt", errs)
    assert.are.same({}, require("slop.config").unknown("todo"))
    require("slop").setup({ todo = { keywords = { MINE = {} }, colors = { mine = "#000000" }, typo = 1 } })
    assert.are.same({ "todo.typo" }, require("slop.config").unknown("todo"))
  end)
end)

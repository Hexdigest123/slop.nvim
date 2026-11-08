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

  it("a doc-comment language injected into a comment (jsdoc, luadoc, doxygen) still counts as the comment", function()
    -- stand-in for jsdoc/luadoc/doxygen (not bundled): markdown injected into `---` comments; its trees have no
    -- comment node at the keyword, the host tree's comment does
    vim.treesitter.query.set(
      "lua",
      "injections",
      [[
(comment content: (_) @injection.content
  (#lua-match? @injection.content "^%-")
  (#set! injection.language "markdown"))
]]
    )
    local ok, res = pcall(function()
      local buf = open("doc.lua", '--- TODO: in a doc comment\nlocal s = "--- TODO: not a comment"\n')
      local parser = vim.treesitter.get_parser(buf)
      parser:parse(true)
      assert.equal("markdown_inline", parser:language_for_range({ 0, 4, 0, 5 }):lang(), "keyword in the injected tree")
      api.nvim_win_set_cursor(0, { 2, 0 })
      return { items(buf, 0, 1), todo.jump_next({ wrap = false }), todo.jump_prev(), api.nvim_win_get_cursor(0) }
    end)
    vim.treesitter.query.set("lua", "injections", nil)
    assert.is_true(ok, res)
    assert.are.same({ [0] = { "3-10:SlopTodoTodo!", "10-26:SlopTodoTodoText" } }, res[1])
    assert.is_false(res[2], "the string is no comment")
    assert.is_true(res[3])
    assert.are.same({ 1, 4 }, res[4])
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

  it("a closed fold costs one row: the rows inside it are neither matched nor signed", function()
    local lines = {}
    for i = 1, 3000 do
      lines[i] = ("-- TODO: item %d"):format(i)
    end
    local buf = open("fold.lua", table.concat(lines, "\n") .. "\n")
    vim.wo.foldmethod = "manual"
    vim.cmd("2,2990fold") -- closed: rows 1-2989 are one screen row
    vim.cmd("redraw!")
    vim.wait(20)
    local K = require("slop.modules.todo.keywords")
    local orig, n = K.match, 0
    K.match = function(...)
      n = n + 1
      return orig(...)
    end
    local ok, err = pcall(function()
      api.nvim_buf_set_text(buf, 0, 0, 0, 0, { " " }) -- a new changedtick: every drawn row is computed again
      vim.cmd("redraw")
      vim.wait(20) -- the sign update after the redraw
    end)
    K.match = orig
    assert.is_true(ok, err)
    assert.truthy(n < 200, "rows matched for one redraw: " .. n)
    local rows = {}
    for _, s in ipairs(signs(buf)) do
      rows[s[1]] = true
    end
    assert.truthy(rows[0] and rows[1] and rows[2990], "the drawn rows keep their signs")
    assert.is_nil(rows[1500], "no sign placed inside the fold")
  end)

  it("places signs for visible rows after the redraw; toggle clears and restores them", function()
    local buf = open("a.lua", LUA)
    assert.are.same({ { 0, "SlopTodoTodo" }, { 1, "SlopTodoFix" }, { 6, "SlopTodoHack" } }, signs(buf))
    local events = {}
    vim.api.nvim_create_autocmd("User", {
      pattern = "SlopTodoToggled",
      callback = function(ev)
        events[#events + 1] = ev.data.enabled
      end,
    })
    todo.disable()
    assert.is_false(todo.is_enabled())
    assert.are.same({ false }, events)
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

  it("covers buffers already open when the module loads; signs per window, unchanged signs kept", function()
    local lines = { "-- TODO: top" }
    for i = 2, 300 do
      lines[i] = "local _ = " .. i
    end
    lines[200] = "-- FIX: far"
    local path = dir .. "/pre.lua"
    h.write(path, table.concat(lines, "\n") .. "\n")
    vim.cmd.edit(vim.fn.fnameescape(path))
    local buf = api.nvim_get_current_buf()
    vim.cmd("redraw!")
    load()
    vim.cmd("split")
    vim.cmd("normal! 200Gzz")
    vim.cmd("redraw!")
    local got = signs(buf)
    assert.are.same({ { 0, "SlopTodoTodo" }, { 199, "SlopTodoFix" } }, got)
    local ns = require("slop.core.util").ns("todo.signs")
    local id = api.nvim_buf_get_extmarks(buf, ns, 0, 0, {})[1][1]
    api.nvim_buf_set_lines(buf, 5, 6, false, { "local changed = true" })
    vim.cmd("redraw!")
    vim.wait(20)
    assert.equal(id, api.nvim_buf_get_extmarks(buf, ns, 0, 0, {})[1][1], "sign not re-created")
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

  it("a module disabled and enabled again starts drawing again, even after `:Slop todo disable`", function()
    local buf = open("a.lua", LUA)
    vim.cmd("Slop todo disable")
    require("slop.core.registry").disable("todo")
    require("slop.core.registry").enable("todo")
    assert.is_true(require("slop").todo.is_enabled())
    vim.cmd("redraw!")
    assert.equal(3, #signs(buf))
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

  it("a long jump over many non-comment matches parses a few times, and still sees injected comments", function()
    local L = { "local M = {}" }
    for i = 1, 3000 do
      L[#L + 1] = ('local s%d = "TODO: not a comment"'):format(i)
    end
    vim.list_extend(L, { "vim.cmd([[", '" TODO: in an injected vim comment', "]])", "return M" })
    open("far.lua", table.concat(L, "\n") .. "\n")
    api.nvim_win_set_cursor(0, { 1, 0 })
    local parser = vim.treesitter.get_parser(0)
    local LT = getmetatable(parser).__index
    local orig, n = LT.parse, 0
    LT.parse = function(self, ...)
      n = n + (self == parser and 1 or 0)
      return orig(self, ...)
    end
    local ok, res = pcall(todo.jump_next, { wrap = false })
    LT.parse = orig
    assert.is_true(ok, res)
    assert.is_true(res)
    assert.are.same({ 3003, 2 }, api.nvim_win_get_cursor(0), "the TODO in the vim.cmd() string's vim comment")
    assert.truthy(n < 50, "parses for one jump: " .. n)
  end)

  it("next/prev are unmapped by default; mapped keys take a count", function()
    open("a.lua", LUA)
    for _, lhs in ipairs({ "]t", "[t", "]T", "[T" }) do
      assert.falsy((vim.fn.maparg(lhs, "n", false, true).desc or ""):match("slop"), lhs)
    end
    assert.truthy(vim.fn.maparg("<Plug>(slop-todo-next)", "n") ~= "")
    require("slop.core.registry").disable("todo")
    require("slop").setup({ todo = { keymaps = { next = "]x", prev = "[x" } } })
    require("slop.core.registry").enable("todo")
    assert.matches("slop%-todo%-next", vim.fn.maparg("]x", "n"))
    api.nvim_win_set_cursor(0, { 1, 0 })
    h.feed("2]x")
    assert.are.same({ 2, 3 }, api.nvim_win_get_cursor(0))
    h.feed("[x")
    assert.are.same({ 1, 15 }, api.nvim_win_get_cursor(0))
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
    -- a later setup() changing a user group's color applies right away (not only after :colorscheme)
    require("slop").setup({ todo = { keywords = { SAFETY = { color = "#00ff00", icon = "!" } } } })
    assert.equal(0x00ff00, api.nvim_get_hl(0, { name = "SlopTodoSafety" }).fg)
    vim.cmd("doautocmd ColorScheme")
    assert.equal(0x00ff00, api.nvim_get_hl(0, { name = "SlopTodoSafety" }).fg)
  end)

  it("parses only the highlighter's ranges: edits cause no extra injected-tree re-parses", function()
    local L = { "local M = {}" }
    for i = 1, 30 do
      L[#L + 1] = ('vim.cmd("highlight G%d guifg=#%06x")'):format(i, i)
      L[#L + 1] = ("local y%d = %d -- TODO: tidy %d"):format(i, i, i)
    end
    vim.g._ts_force_sync_parsing = true
    local buf = open("inj.lua", table.concat(L, "\n") .. "\n")
    vim.treesitter.start(buf, "lua")
    vim.fn.winrestview({ topline = 25, lnum = 35, col = 2 })
    vim.cmd("redraw!")
    local LT = getmetatable(vim.treesitter.get_parser(buf)).__index
    local orig, reparsed = LT._parse_regions, 0
    LT._parse_regions = function(self, ...)
      local changes, n, t = orig(self, ...)
      if self:lang() == "vim" then
        reparsed = reparsed + (n or 0)
      end
      return changes, n, t
    end
    local function edits()
      reparsed = 0
      for _ = 1, 5 do
        local line = api.nvim_buf_get_lines(buf, 34, 35, false)[1]
        local c = line:find(" =", 1, true) -- inside "local yN", a row without an injection
        api.nvim_buf_set_text(buf, 34, c - 1, 34, c - 1, { "x" })
        vim.cmd("redraw")
      end
      return reparsed
    end
    local ok, res = pcall(function()
      local with = edits()
      todo.disable()
      return { with, edits() }
    end)
    LT._parse_regions = orig
    vim.g._ts_force_sync_parsing = nil
    assert.is_true(ok, res)
    assert.truthy(res[2] > 0, "the highlighter re-parses some injections anyway")
    assert.equal(res[2], res[1], "todo highlighting adds none")
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

  it('a color that is not "#rrggbb" is a config error, not a failing setup()', function()
    require("slop").setup({ todo = { keywords = { TODO = { color = "#abc" } }, colors = { mine = "#1234" } } })
    local errs = table.concat(require("slop.config").errors("todo"), "\n")
    assert.matches("todo.keywords.TODO.color", errs)
    assert.matches("todo.colors.mine", errs)
    local _, err = require("slop.core.registry").load("todo")
    assert.matches("^invalid config", tostring(err))
    -- loaded with a valid config, a later invalid one is reported and not applied
    require("slop").setup({ todo = {} })
    todo = assert(require("slop").load("todo"))
    vim.v.errmsg = ""
    local ok, e = pcall(require("slop").setup, { todo = { keywords = { TODO = { color = "#abc" } } } })
    assert.is_true(ok, e)
    assert.equal("", vim.v.errmsg)
    assert.equal("DiagnosticInfo", api.nvim_get_hl(0, { name = "SlopTodoTodo" }).link)
  end)
end)

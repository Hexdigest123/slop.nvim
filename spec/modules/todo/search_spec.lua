-- todo project search: rg / git grep / Lua backends agree, keyword filters, quickfix, picker, commands.
local h = require("helpers")

local api = vim.api

describe("todo search", function()
  local root, todo
  before_each(function()
    h.reset()
    vim.notify = function() end
    vim.cmd("silent! %bwipe!")
    h.source_plugin()
    root = h.tmpdir("todo-proj")
    h.write(root .. "/a.lua", "local x = 1 -- TODO: first\n-- FIX(bob): second\n-- TODO without colon\n")
    h.write(root .. "/sub/b.c", "// NOTE: third\nint MYTODO: x;\n/* HACK: fourth */\n")
    h.write(root .. "/sub/with:colon.txt", "XXX: fifth\n")
    h.write(root .. "/.hidden/c.lua", "-- TODO: hidden\n")
    h.write(root .. "/bin.dat", "TODO: binary\0\0\0")
    require("slop").setup({ todo = {} })
    todo = assert(require("slop").load("todo"))
  end)
  after_each(function()
    pcall(function()
      require("slop.core.registry").disable("todo")
    end)
    package.loaded["slop.core.ui.picker"] = nil
  end)

  local function search(opts)
    local done
    todo.search(vim.tbl_extend("force", { root = root }, opts or {}), function(r, err)
      done = { r, err }
    end)
    assert.is_true(vim.wait(5000, function()
      return done ~= nil
    end))
    return done[1], done[2]
  end

  local function short(results)
    return vim.tbl_map(function(r)
      return ("%s:%d:%d %s %s"):format(vim.fs.relpath(root, r.path), r.lnum, r.col, r.keyword, r.message)
    end, results)
  end

  local EXPECTED = {
    "a.lua:1:16 TODO first",
    "a.lua:2:4 FIX second",
    "sub/b.c:1:4 NOTE third",
    "sub/b.c:3:4 HACK fourth */",
    "sub/with:colon.txt:1:1 XXX fifth",
  }

  it("lua backend (no external tools): skips hidden and binary files", function()
    local r = search({ backend = "lua" })
    assert.are.same(EXPECTED, short(r))
    assert.equal("bob", r[2].author)
    assert.equal("FIX", r[2].group)
    assert.equal("-- FIX(bob): second", r[2].line)
  end)

  it("rg backend gives the same results", function()
    if vim.fn.executable("rg") == 0 then
      return pending("rg not installed")
    end
    assert.are.same(EXPECTED, short(search({ backend = "rg" })))
  end)

  it("git grep backend gives the same results (tracked + untracked), lua fallback outside a repo", function()
    if vim.fn.executable("git") == 0 then
      return pending("git not installed")
    end
    h.write(root .. "/.gitignore", ".hidden/\nbin.dat\n")
    vim.system({ "git", "init", "-q" }, { cwd = root }):wait()
    vim.system({ "git", "add", "a.lua" }, { cwd = root }):wait()
    assert.are.same(EXPECTED, short(search({ backend = "git" })))
    local plain = h.tmpdir("todo-plain")
    h.write(plain .. "/x.lua", "-- TODO: plain\n")
    local r = search({ backend = "git", root = plain })
    assert.are.same(
      { "x.lua:1:4 TODO plain" },
      vim.tbl_map(function(x)
        return ("%s:%d:%d %s %s"):format(vim.fs.relpath(plain, x.path), x.lnum, x.col, x.keyword, x.message)
      end, r)
    )
  end)

  it("keyword filter: group names include aliases", function()
    assert.are.same({ "a.lua:2:4 FIX second" }, short(search({ backend = "lua", keywords = "FIX" })))
    assert.are.same(
      { "a.lua:1:16 TODO first", "sub/with:colon.txt:1:1 XXX fifth" },
      short(search({ backend = "lua", keywords = { "TODO,WARN" } }))
    )
  end)

  it("backend auto picks rg, then git, then lua", function()
    local S = require("slop.modules.todo.search")
    local exe = vim.fn.executable
    vim.fn.executable = function(name)
      return name == "git" and 1 or 0
    end
    local ok, res = pcall(function()
      return { S.backend("auto", root), S.backend("auto", h.root) }
    end)
    vim.fn.executable = exe
    assert.is_true(ok, res)
    assert.are.same({ "lua", "git" }, res)
    assert.equal("rg", S.backend("rg", root))
  end)

  it("qf fills the quickfix list", function()
    todo.qf({ root = root, backend = "lua", open = false })
    assert.is_true(vim.wait(5000, function()
      return #vim.fn.getqflist() > 0
    end))
    local qf = vim.fn.getqflist({ items = true, title = true })
    assert.equal("slop todo", qf.title)
    assert.equal(5, #qf.items)
    local first = qf.items[1]
    assert.equal(root .. "/a.lua", vim.fs.normalize(api.nvim_buf_get_name(first.bufnr)))
    assert.are.same({ 1, 16, "local x = 1 -- TODO: first" }, { first.lnum, first.col, first.text })
  end)

  it("list opens the picker with formatted items and jumps to the selection", function()
    local seen
    package.loaded["slop.core.ui.picker"] = {
      pick = function(items, opts)
        items(function(list)
          seen = { list = list, opts = opts }
        end)
      end,
    }
    require("slop").setup({ todo = { search = { backend = "lua" } } })
    todo.list({ root = root })
    assert.is_true(vim.wait(5000, function()
      return seen ~= nil
    end))
    assert.equal(5, #seen.list)
    local chunks = seen.opts.format(seen.list[2])
    assert.equal("SlopTodoFix", chunks[1][2])
    assert.matches("FIX$", chunks[1][1])
    assert.equal("a.lua:2", chunks[3][1])
    assert.are.same({ path = root .. "/a.lua", lnum = 2 }, seen.opts.preview(seen.list[2]))
    seen.opts.on_select(seen.list[4])
    assert.equal(root .. "/sub/b.c", vim.fs.normalize(api.nvim_buf_get_name(0)))
    assert.are.same({ 3, 3 }, api.nvim_win_get_cursor(0))
    seen.opts.on_select(nil)
  end)

  it(":Slop todo qf KEYWORDS and completion", function()
    vim.cmd.cd(root)
    require("slop").setup({ todo = { search = { backend = "lua" } } })
    vim.cmd("Slop todo qf NOTE,HACK")
    assert.is_true(vim.wait(5000, function()
      return #vim.fn.getqflist() == 2
    end))
    vim.cmd("cclose")
    local c = vim.fn.getcompletion("Slop todo list TODO,FI", "cmdline")
    assert.truthy(vim.tbl_contains(c, "TODO,FIX"), vim.inspect(c))
    assert.truthy(vim.tbl_contains(c, "TODO,FIXME"), vim.inspect(c))
    vim.cmd.cd(h.root)
  end)
end)

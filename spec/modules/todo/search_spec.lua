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

  it("a pick that cannot open the file (E37, 'nohidden') reports the error instead of raising it", function()
    local seen
    package.loaded["slop.core.ui.picker"] = {
      pick = function(items, opts)
        items(function(list)
          seen = { list = list, opts = opts }
        end)
      end,
    }
    local notes = {}
    vim.notify = function(msg, level)
      notes[#notes + 1] = { msg = tostring(msg), level = level }
    end
    require("slop").setup({ todo = { search = { backend = "lua" } } })
    todo.list({ root = root })
    assert.is_true(vim.wait(5000, function()
      return seen ~= nil
    end))
    vim.cmd.enew()
    local buf = api.nvim_get_current_buf()
    api.nvim_buf_set_lines(buf, 0, -1, false, { "unsaved" })
    vim.o.hidden = false
    local ok, err = pcall(seen.opts.on_select, seen.list[4], "edit")
    vim.o.hidden = true
    vim.bo[buf].modified = false
    assert.is_true(ok, err)
    assert.equal(buf, api.nvim_get_current_buf(), "stayed in the modified buffer")
    assert.are.same({ 1, 0 }, api.nvim_win_get_cursor(0))
    local last = notes[#notes]
    assert.matches("^slop: todo: E37: ", last.msg)
    assert.equal(vim.log.levels.ERROR, last.level)
  end)

  it("qf and the picker show secrets of cloaked / blocked files redacted", function()
    require("slop").setup({
      todo = { search = { backend = "lua" } },
      cloak = { patterns = { { file_pattern = "*.yaml", cloak_pattern = "(password: )%S+", replace = "%1" } } },
    })
    local p = h.tmpdir("todo-redact")
    h.write(p .. "/app.yaml", "password: s3cr3t # FIXME: rotate\n")
    h.write(p .. "/deploy/credentials.txt", "TODO: rotate token abc123\n")
    h.write(p .. "/main.lua", "-- TODO: normal\n")
    todo.qf({ root = p, open = false })
    assert.is_true(vim.wait(5000, function()
      return #vim.fn.getqflist() == 3
    end))
    assert.are.same(
      { "password: <redacted> # FIXME: rotate", "<redacted>", "-- TODO: normal" },
      vim.tbl_map(function(i)
        return i.text
      end, vim.fn.getqflist())
    )
    local seen
    package.loaded["slop.core.ui.picker"] = {
      pick = function(items, opts)
        items(function(list)
          seen = { list = list, opts = opts }
        end)
      end,
    }
    todo.list({ root = p })
    assert.is_true(vim.wait(5000, function()
      return seen ~= nil
    end))
    assert.are.same(
      { " rotate", " <redacted>", " normal" },
      vim.tbl_map(function(r)
        return seen.opts.format(r)[4][1]
      end, seen.list)
    )
    assert.equal("TODO: rotate token abc123", seen.list[2].line, "search() results stay raw")
  end)

  it("user rg / git configuration does not change the parsed output", function()
    if vim.fn.executable("rg") == 0 or vim.fn.executable("git") == 0 then
      return pending("rg or git not installed")
    end
    local rc = h.tmpdir("rgrc") .. "/ripgreprc"
    h.write(rc, "--column\n--trim\n--max-columns=10\n")
    local old = vim.env.RIPGREP_CONFIG_PATH
    vim.env.RIPGREP_CONFIG_PATH = rc
    local ok, res = pcall(search, { backend = "rg" })
    vim.env.RIPGREP_CONFIG_PATH = old
    assert.is_true(ok, res)
    assert.are.same(EXPECTED, short(res))
    h.write(root .. "/.gitignore", ".hidden/\nbin.dat\n")
    vim.system({ "git", "init", "-q" }, { cwd = root }):wait()
    vim.system({ "git", "config", "grep.column", "true" }, { cwd = root }):wait()
    vim.system({ "git", "config", "grep.fullName", "true" }, { cwd = root }):wait()
    assert.are.same(EXPECTED, short(search({ backend = "git" })))
  end)

  it("all backends skip the same files (ignored, hidden, node_modules, > 1 MiB) and agree on boundaries", function()
    if vim.fn.executable("rg") == 0 or vim.fn.executable("git") == 0 then
      return pending("rg or git not installed")
    end
    local p = h.tmpdir("todo-parity")
    h.write(p .. "/.gitignore", "build/\n")
    h.write(p .. "/src/a.lua", "-- TODO: kept\n")
    h.write(p .. "/src/uni.txt", "éTODO: after a non-ASCII letter\n")
    h.write(p .. "/.github/ci.yml", "# TODO: hidden, tracked\n")
    h.write(p .. "/build/gen.c", "// TODO: gitignored\n")
    h.write(p .. "/node_modules/x/i.js", "// TODO: node_modules\n")
    h.write(p .. "/src/big.c", "// TODO: big\n" .. ("x"):rep(1024 * 1024) .. "\n")
    vim.system({ "git", "init", "-q" }, { cwd = p }):wait()
    vim.system({ "git", "add", "-A" }, { cwd = p }):wait()
    for _, backend in ipairs({ "rg", "git", "lua" }) do
      local r = search({ backend = backend, root = p })
      assert.are.same(
        { "src/a.lua:1:4 TODO kept", "src/uni.txt:1:3 TODO after a non-ASCII letter" },
        vim.tbl_map(function(x)
          return ("%s:%d:%d %s %s"):format(vim.fs.relpath(p, x.path), x.lnum, x.col, x.keyword, x.message)
        end, r),
        backend
      )
    end
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

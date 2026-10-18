local h = require("helpers")

describe("services.ai.context", function()
  local ctx, secrets
  local api = vim.api

  local function file_buf(path, lines, ft)
    h.write(path, table.concat(lines, "\n") .. "\n")
    vim.cmd.edit(vim.fn.fnameescape(path))
    local b = api.nvim_get_current_buf()
    if ft then
      vim.bo[b].filetype = ft
    end
    return b
  end

  before_each(function()
    h.reset()
    vim.notify = function() end
    vim.cmd("silent! %bwipeout!")
    ctx = require("slop.services.ai.context")
    secrets = require("slop.core.secrets")
    require("slop.services.ai.context.edits").reset()
    secrets.register({
      name = "test",
      spans = function(_, lines, first_row)
        local out = {}
        for i, l in ipairs(lines) do
          local s, e = l:find("SECRET%w*")
          if s then
            out[#out + 1] = { row = first_row + i - 1, col = s - 1, end_col = e }
          end
        end
        return out
      end,
    })
  end)

  describe("budget helpers (pure, table-driven)", function()
    it("take_tail / take_head keep whole lines", function()
      local L = { "aaaa", "bb", "cccccc", "d" }
      local cases = {
        { "tail", 100, { "aaaa", "bb", "cccccc", "d" }, true },
        { "tail", 8, { "cccccc", "d" }, false },
        { "tail", 1, { "d" }, false },
        { "head", 7, { "aaaa", "bb" }, false },
        { "head", 2, { "aa" }, false },
        { "head", 100, L, true },
      }
      for _, c in ipairs(cases) do
        local fn = c[1] == "tail" and ctx.take_tail or ctx.take_head
        local got, done = fn(L, c[2])
        assert.are.same(c[3], got, c[1] .. " " .. c[2])
        assert.equal(c[4], done, c[1] .. " " .. c[2] .. " complete")
      end
      assert.are.same({ "xyz" }, (ctx.take_tail({ "abcxyz" }, 3)))
      assert.are.same({}, (ctx.take_tail({}, 3)))
    end)

    it("split_budget is 35/15/35/15 and resolve_budget handles auto", function()
      assert.are.same({ prefix = 3500, suffix = 1500, stable = 3500, volatile = 1500 }, ctx.split_budget(10000))
      assert.equal(16000, ctx.resolve_budget("auto"))
      assert.equal(800, ctx.resolve_budget(800))
    end)

    it("pack keeps blocks in priority order within the budget", function()
      local kept, used = ctx.pack({ "aaaa", "bbbbbbbbbb", "cc", "" }, 9)
      assert.are.same({ "aaaa", "cc" }, kept)
      assert.equal(8, used)
    end)

    it("comment uses commentstring with a fallback", function()
      assert.are.same({ "-- a", "--" }, ctx.comment({ "a", "" }, "-- %s"))
      assert.are.same({ "/* x */" }, ctx.comment({ "x" }, "/* %s */"))
      assert.are.same({ "# y" }, ctx.comment({ "y" }, ""))
    end)

    it("apply_spans replaces right-to-left per row", function()
      assert.are.same(
        { "a=<r> b=<r>", "ok" },
        ctx.apply_spans({ "a=xx b=yyy", "ok" }, {
          { row = 5, col = 2, end_col = 4 },
          { row = 5, col = 7, end_col = 10 },
        }, 5, "<r>")
      )
    end)
  end)

  describe("fim()", function()
    it("prefix ends at the cursor, suffix starts with the rest of the line; header path marker", function()
      local dir = h.tmpdir("proj")
      vim.fn.mkdir(dir .. "/.git", "p")
      vim.cmd.cd(dir)
      local b = file_buf(dir .. "/src/app.lua", { "local a = 1", "local b = foo(2)", "return a" }, "lua")
      local c = ctx.fim(b, 1, 14, { neighbors = false, recent_edits = false, ring = false })
      assert.is_nil(c.blocked)
      assert.matches("^%-%- Path: src/app%.lua\n", c.prompt)
      assert.matches("local a = 1\nlocal b = foo%($", c.prompt)
      assert.equal("2)\nreturn a", c.suffix)
      assert.equal("local a = 1\nlocal b = foo(", c.parts.prefix)
      assert.matches("^Indentation: ", c.meta.indent)
      assert.equal("lua", c.meta.filetype)
    end)

    it("redacts secrets in prefix, suffix and across the cursor", function()
      local b = file_buf(h.tmpdir("r") .. "/x.lua", { "k = SECRET1", "v = SECRETABC + 1", "w = SECRET2" }, "lua")
      local c = ctx.fim(b, 1, 9, { neighbors = false, recent_edits = false, ring = false, scope = false })
      assert.falsy(c.prompt:find("SECRET", 1, true))
      assert.falsy(c.suffix:find("SECRET", 1, true))
      assert.matches("k = <redacted>\nv = <redacted>$", c.prompt)
      assert.equal("<redacted> + 1\nw = <redacted>", c.suffix)
    end)

    it("blocked buffers return blocked = true and no text", function()
      local b = file_buf(h.tmpdir("b") .. "/.env", { "TOKEN=abc" })
      local c = ctx.fim(b, 0, 3)
      assert.is_true(c.blocked)
      assert.equal("", c.prompt)
      assert.equal("", c.suffix)
    end)

    it("respects the budget: suffix ~15%, prefix gets the rest, cut on line boundaries", function()
      local lines = {}
      for i = 1, 400 do
        lines[i] = ("line %03d xxxxxxxxxxxxxxxxxxxxxxxxxx"):format(i)
      end
      local b = file_buf(h.tmpdir("big") .. "/big.txt", lines, "text")
      local c = ctx.fim(b, 200, 0, { budget = 2000, neighbors = false, recent_edits = false, ring = false })
      assert.truthy(#c.suffix <= 300 + 40)
      assert.truthy(#c.prompt <= 2000)
      assert.truthy(#c.prompt + #c.suffix <= 2000)
      assert.truthy(#c.prompt > 1500)
      -- whole lines only (besides the cursor line)
      local first_prefix_line = c.parts.prefix:match("^[^\n]*")
      assert.matches("^line %d%d%d x+$", first_prefix_line)
      assert.matches("^line 201", c.suffix)
      assert.is_false(c.meta.prefix_complete)
    end)

    it("unused prefix share flows to the suffix near the top of the file", function()
      local lines = { "top" }
      for i = 1, 300 do
        lines[#lines + 1] = ("after %03d yyyyyyyyyyyyyyyyyyyyyyyyy"):format(i)
      end
      local b = file_buf(h.tmpdir("top") .. "/t.txt", lines, "text")
      local c = ctx.fim(b, 0, 3, { budget = 2000, neighbors = false, recent_edits = false, ring = false })
      assert.truthy(#c.suffix > 1000, "suffix got " .. #c.suffix)
      assert.truthy(#c.prompt + #c.suffix <= 2000, ("%d + %d: %s"):format(#c.prompt, #c.suffix, c.prompt))
    end)

    it("adds scope signatures that fall above the prefix cut", function()
      local lines = { "function M.handler(req, res)" }
      for i = 1, 200 do
        lines[#lines + 1] = ("  local v%d = %d"):format(i, i)
      end
      lines[#lines + 1] = "  "
      lines[#lines + 1] = "end"
      local b = file_buf(h.tmpdir("sc") .. "/s.lua", lines, "lua")
      local c = ctx.fim(b, 201, 2, { budget = 1500, neighbors = false, recent_edits = false, ring = false })
      assert.matches("%-%- Enclosing scope of the code below:\n%-%- function M%.handler%(req, res%)", c.prompt)
      -- small function fully in the prefix: no scope block
      local b2 = file_buf(h.tmpdir("sc2") .. "/s2.lua", { "function f()", "  ", "end" }, "lua")
      local c2 = ctx.fim(b2, 1, 2, { neighbors = false, recent_edits = false, ring = false })
      assert.equal("", c2.parts.scope)
    end)

    it("includes diagnostics near the cursor", function()
      local b = file_buf(h.tmpdir("dg") .. "/d.lua", { "local x = y", "" }, "lua")
      local ns = api.nvim_create_namespace("test.diag")
      vim.diagnostic.set(
        ns,
        b,
        { { lnum = 0, col = 10, message = "undefined global 'y'", severity = vim.diagnostic.severity.WARN } }
      )
      local c = ctx.fim(b, 1, 0, { neighbors = false, recent_edits = false, ring = false })
      assert.matches(
        "%-%- Consider the following lua diagnostics from [^\n]*d%.lua:\n%-%- 1:11 %- undefined global 'y'",
        c.prompt
      )
    end)

    it("neighbour snippets: Jaccard picks the similar buffer, skips blocked ones, best last", function()
      local dir = h.tmpdir("nb")
      file_buf(
        dir .. "/other.lua",
        { "local function compute_total(items, tax_rate)", "  return items * tax_rate", "end" },
        "lua"
      )
      file_buf(dir .. "/unrelated.lua", { "print('hello world banana')" }, "lua")
      file_buf(dir .. "/.env.lua", { "compute_total tax_rate items" }, "lua")
      local b = file_buf(dir .. "/main.lua", { "local total = compute_total(items, tax_rate)", "" }, "lua")
      local c = ctx.fim(b, 1, 0, { recent_edits = false, ring = false })
      assert.matches("%-%- Compare this snippet from [^\n]*other%.lua:\n%-%- local function compute_total", c.prompt)
      assert.falsy(c.prompt:find(".env.lua", 1, true))
      assert.falsy(c.prompt:find("hello world banana", 1, true) and not c.prompt:find("unrelated", 1, true))
    end)

    it("recent edits are recorded as diffs and rendered with copilot's wording", function()
      local edits = require("slop.services.ai.context.edits")
      local dir = h.tmpdir("ed")
      local o = file_buf(dir .. "/lib.lua", { "local A = 1", "return A" }, "lua")
      edits.snapshot(o)
      api.nvim_buf_set_lines(o, 0, 1, false, { "local A = 2 -- SECRETX" })
      edits.flush(o)
      local b = file_buf(dir .. "/main.lua", { "x", "" }, "lua")
      local c = ctx.fim(b, 1, 0, { neighbors = false, ring = false })
      assert.matches("These are recently edited files%. Do not suggest code that has been deleted%.", c.prompt)
      assert.matches("%-%- File: [^\n]*lib%.lua", c.prompt)
      assert.matches("%-%- %-local A = 1\n%-%- %+local A = 2 %-%- <redacted>", c.prompt)
      assert.matches("%-%- End of recent edits", c.prompt)
      assert.falsy(c.prompt:find("SECRETX", 1, true))
    end)

    it("ring chunks (e.g. yanked text) from other buffers are added as snippets", function()
      local edits = require("slop.services.ai.context.edits")
      local dir = h.tmpdir("rg")
      local o = file_buf(
        dir .. "/yank.lua",
        { "local function alpha(delta)", "  return beta_gamma + delta", "end", "local z = 1" },
        "lua"
      )
      edits.ring_add(o, 0, api.nvim_buf_get_lines(o, 0, 3, false))
      local b = file_buf(dir .. "/main.lua", { "x", "" }, "lua")
      local c = ctx.fim(b, 1, 0, { neighbors = false, recent_edits = false })
      assert.matches(
        "%-%- Compare this snippet from [^\n]*yank%.lua:\n%-%- local function alpha%(delta%)",
        c.parts.ring
      )
    end)
  end)

  describe("files / file / rules (edit)", function()
    it("lists project files without blocked ones, reads live buffers first, redacts", function()
      local dir = h.tmpdir("files")
      h.write(dir .. "/a.lua", "return 'SECRET42'\n")
      h.write(dir .. "/sub/b.txt", "bee\n")
      h.write(dir .. "/.env", "X=1\n")
      local files = ctx.files(dir)
      assert.truthy(vim.tbl_contains(files, "a.lua"))
      assert.truthy(vim.tbl_contains(files, "sub/b.txt"))
      assert.falsy(vim.tbl_contains(files, ".env"))
      local f = assert(ctx.file("a.lua", { root = dir }))
      assert.equal(dir .. "/a.lua", f.path)
      assert.equal("a.lua", f.rel)
      assert.equal("return '<redacted>'\n", f.text)
      assert.equal("lua", f.filetype)
      vim.cmd.edit(vim.fn.fnameescape(dir .. "/sub/b.txt"))
      api.nvim_buf_set_lines(0, 0, -1, false, { "live" })
      assert.equal("live", ctx.file(dir .. "/sub/b.txt").text)
      local none, err = ctx.file(".env", { root = dir })
      assert.is_nil(none)
      assert.matches("blocked", err)
      assert.is_nil((ctx.file("missing", { root = dir })))
      h.write(dir .. "/big.txt", string.rep("x\n", 100))
      local big = ctx.file("big.txt", { root = dir, max_bytes = 11 })
      assert.is_true(big.truncated)
      assert.equal("x\nx\nx\nx\nx\n", big.text)
    end)

    it("rules: existing files in order, walk-up from a subdir (root first)", function()
      local dir = h.tmpdir("rules")
      h.write(dir .. "/AGENTS.md", "root agents")
      h.write(dir .. "/.nvim/rules.md", "nvim rules SECRET9")
      h.write(dir .. "/pkg/sub/AGENTS.md", "sub agents")
      local r = ctx.rules(dir, { ".nvim/rules.md", "AGENTS.md", "CLAUDE.md" })
      assert.are.same(
        { ".nvim/rules.md", "AGENTS.md" },
        vim.tbl_map(function(x)
          return x.rel
        end, r)
      )
      assert.equal("nvim rules <redacted>", r[1].text)
      local w = ctx.rules(dir, { "AGENTS.md" }, { from = dir .. "/pkg/sub" })
      assert.are.same(
        { "AGENTS.md", "pkg/sub/AGENTS.md" },
        vim.tbl_map(function(x)
          return x.rel
        end, w)
      )
    end)
  end)
end)

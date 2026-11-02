local h = require("helpers")

describe("keymaps", function()
  before_each(function()
    h.reset()
    vim.notify = function() end
    vim.g.mapleader = " "
  end)

  it("plugin creates <Plug> stubs and default lhs for enabled modules", function()
    h.source_plugin()
    assert.truthy(vim.fn.maparg("<Plug>(slop-term-toggle)", "n") ~= "")
    assert.truthy(vim.fn.maparg("<Plug>(slop-term-send)", "x") ~= "")
    assert.truthy(vim.fn.maparg("<Plug>(slop-edit-edit)", "x") ~= "")
    assert.equal("<Plug>(slop-term-toggle)", vim.fn.maparg(" \\", "n"))
    assert.equal("<Plug>(slop-term-send)", vim.fn.maparg(" \\", "x"))
    assert.equal("", vim.fn.maparg(" sH", "n"), "hello is disabled")
    assert.equal(1, #vim.tbl_filter(function(n)
      return n:match("^slop")
    end, h.loaded()))
  end)

  it("respects false, overrides and user mappings; re-syncs on setup()", function()
    vim.keymap.set("n", "<leader>rr", "<Cmd>echo 'mine'<CR>")
    h.source_plugin()
    assert.equal("<Cmd>echo 'mine'<CR>", vim.fn.maparg(" rr", "n"))
    require("slop").setup({ term = { keymaps = { toggle = false, split = "<leader>ts" } }, hello = { enabled = true } })
    assert.equal("", vim.fn.maparg(" \\", "n"))
    assert.equal("<Plug>(slop-term-split)", vim.fn.maparg(" ts", "n"))
    assert.equal("", vim.fn.maparg(" |-", "n"))
    assert.equal("<Plug>(slop-hello-greet)", vim.fn.maparg(" sH", "n"))
    require("slop").setup({ term = false })
    assert.equal("", vim.fn.maparg(" ts", "n"))
    assert.equal("", vim.fn.maparg(" sH", "n"))
  end)

  it("<Plug> stub loads the module and runs the handler", function()
    h.source_plugin()
    require("slop").setup({ hello = { enabled = true, silent = true } })
    h.feed("<Plug>(slop-hello-greet)")
    local api = require("slop").hello
    assert.equal(1, api.count())
  end)

  it("resolve() supports fun(cfg) keymaps and dotted names", function()
    local km = require("slop.core.keymaps")
    local spec = {
      keymaps = function(cfg)
        return {
          ["diff.accept"] = { mode = "n", buffer = true, desc = "accept", rhs = function() end },
          extra = { mode = "n", desc = "extra " .. cfg.n, rhs = function() end },
        }
      end,
    }
    local list = km.resolve("mod", spec, { n = 1, keymaps = { diff = { accept = "ga" }, extra = false } })
    assert.equal("ga", list[1].lhs)
    assert.equal("<Plug>(slop-mod-diff-accept)", list[1].plug)
    assert.is_false(list[2].lhs)
    assert.equal("extra 1", list[2].spec.desc)
  end)

  it("apply_buf() and ft keymaps are buffer-local", function()
    local km = require("slop.core.keymaps")
    local hit = 0
    local spec = {
      keymaps = {
        local_one = {
          mode = "n",
          buffer = true,
          desc = "local",
          rhs = function()
            hit = hit + 1
          end,
        },
        ft_one = {
          mode = "n",
          ft = { "slopft" },
          desc = "ft",
          rhs = function()
            hit = hit + 10
          end,
        },
      },
    }
    km.apply("m", spec, { keymaps = { local_one = "<F2>", ft_one = "<F3>" } })
    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_set_current_buf(buf)
    km.apply_buf("m", buf)
    vim.bo[buf].filetype = "slopft"
    h.feed("<F2><F3>")
    assert.equal(11, hit)
    local other = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_set_current_buf(other)
    assert.equal("", vim.fn.maparg("<F2>", "n"))
  end)

  it("fallthrough() inserts the native key when the handler returns false", function()
    local km = require("slop.core.keymaps")
    local active = false
    km.fallthrough("i", "<C-y>", function()
      if not active then
        return false
      end
      vim.api.nvim_put({ "X" }, "c", false, true)
    end, { desc = "test" })
    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_set_current_buf(buf)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "abc", "" })
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    h.feed("a<C-y><Esc>", "tx") -- native i_CTRL-Y copies the char above
    assert.equal("a", vim.api.nvim_buf_get_lines(buf, 1, 2, false)[1])
    active = true
    vim.api.nvim_buf_set_lines(buf, 1, 2, false, { "" })
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    h.feed("i<C-y><Esc>", "tx")
    assert.equal("X", vim.api.nvim_buf_get_lines(buf, 1, 2, false)[1])
  end)

  it("fallthrough() hands over to a previous mapping", function()
    local km = require("slop.core.keymaps")
    local prev = 0
    vim.keymap.set("i", "<C-e>", function()
      prev = prev + 1
    end)
    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_set_current_buf(buf)
    km.fallthrough("i", "<C-e>", function()
      return false
    end, { desc = "test", buf = buf })
    h.feed("i<C-e><Esc>", "tx")
    assert.equal(1, prev)
  end)

  it("fallthrough() keeps an earlier buffer-local mapping in any buffer, and honours <Nop>", function()
    local km = require("slop.core.keymaps")
    vim.api.nvim_create_buf(true, false)
    local buf = vim.api.nvim_create_buf(true, false)
    assert.not_equal(1, buf)
    vim.api.nvim_set_current_buf(buf)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "" })
    vim.keymap.set("i", "<C-y>", "PREV", { buf = buf }) -- e.g. an ftplugin's map, defined before slop's
    km.fallthrough("i", "<C-y>", function()
      return false
    end, { desc = "test", buf = buf })
    h.feed("i<C-y><Esc>", "tx")
    assert.equal("PREV", vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1])
    -- a key disabled with <Nop> stays disabled: not even the native i_CTRL-Y runs
    local other = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_set_current_buf(other)
    vim.api.nvim_buf_set_lines(other, 0, -1, false, { "abc", "" })
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    vim.keymap.set("i", "<C-y>", "<Nop>")
    km.fallthrough("i", "<C-y>", function()
      return false
    end, { desc = "test" })
    h.feed("a<C-y><Esc>", "tx")
    assert.equal("", vim.api.nvim_buf_get_lines(other, 1, 2, false)[1])
  end)

  it("a nowait fall-through `gr` behaves as if unmapped when other maps go on from it (grn, grx, gr<Esc>)", function()
    local km = require("slop.core.keymaps")
    for _, lhs in ipairs({ "grn", "grr", "gra", "gri", "grt", "grx" }) do
      pcall(vim.keymap.del, "n", lhs) -- the 0.11+ LSP defaults: replaced by test maps below
    end
    local renamed = 0
    vim.keymap.set("n", "grn", function()
      renamed = renamed + 1
    end)
    vim.keymap.set("n", "grr", "<Nop>")
    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_set_current_buf(buf)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "abc" })
    vim.bo[buf].modified = false
    -- like a diff review's reject key: nothing to reject here
    km.fallthrough("n", "gr", function()
      return false
    end, { desc = "reject", buf = buf, nowait = true })
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    h.feed("grn")
    assert.equal(1, renamed)
    assert.are.same({ "abc" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
    assert.is_false(vim.bo[buf].modified)
    h.feed("grx") -- no grx map: Vim's own gr{char}
    assert.are.same({ "xbc" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "abc" })
    h.feed("gr<Esc>")
    assert.are.same({ "abc" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
    -- the count is kept
    h.feed("2grz")
    assert.are.same({ "zzc" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
    -- nothing follows within 'timeoutlen': handed to Vim's gr (which then waits for its char itself;
    -- here the end of the fed keys aborts it, like :normal)
    local saved = vim.o.timeoutlen
    vim.o.timeoutlen = 20
    local t0 = vim.uv.hrtime()
    h.feed("gr")
    vim.o.timeoutlen = saved
    assert.truthy((vim.uv.hrtime() - t0) / 1e6 < 900, "does not wait for a key forever")
    assert.are.same({ "zzc" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
    assert.equal(1, renamed)
  end)

  it("every keymap kind gets a <Plug>; a fall-through one does nothing when there is nothing to do", function()
    local km = require("slop.core.keymaps")
    local hits = {}
    local function rhs(name, ret)
      return function()
        hits[#hits + 1] = name
        return ret
      end
    end
    km.apply("kinds", {
      keymaps = {
        g = { mode = "n", desc = "global", rhs = rhs("g") },
        f = { mode = "n", ft = { "slopkinds" }, desc = "ft", rhs = rhs("f") },
        b = { mode = "n", buffer = true, desc = "buffer", rhs = rhs("b") },
        t = { mode = "i", fallthrough = true, desc = "fallthrough", rhs = rhs("t", false) },
      },
    }, { keymaps = { g = "<F6>", f = "<F7>", b = "<F8>", t = "<C-t>" } })
    for name, mode in pairs({ g = "n", f = "n", b = "n", t = "i" }) do
      assert.truthy(vim.fn.maparg(km.plug("kinds", name), mode) ~= "", name)
    end
    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_set_current_buf(buf)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "" })
    h.feed("<Plug>(slop-kinds-g)<Plug>(slop-kinds-f)<Plug>(slop-kinds-b)")
    h.feed("i<Plug>(slop-kinds-t)<Esc>")
    assert.are.same({ "g", "f", "b", "t" }, hits)
    assert.equal("", vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1], "no native key behind the <Plug>")
  end)

  it("set(), set_buf() and fallthrough() pass nowait through", function()
    local km = require("slop.core.keymaps")
    local buf = vim.api.nvim_get_current_buf()
    km.set("n", "<F10>", function() end, { desc = "x", nowait = true })
    km.set_buf(buf, "n", "<F11>", function() end, { desc = "x", nowait = true })
    km.fallthrough("n", "<F12>", function()
      return false
    end, { desc = "x", buf = buf, nowait = true })
    assert.equal(1, vim.fn.maparg("<F10>", "n", false, true).nowait)
    assert.equal(1, vim.fn.maparg("<F11>", "n", false, true).nowait)
    assert.equal(1, vim.fn.maparg("<F12>", "n", false, true).nowait)
    km.set("n", "<S-F10>", function() end, { desc = "x" })
    assert.equal(0, vim.fn.maparg("<S-F10>", "n", false, true).nowait)
  end)

  it("a mapleader change + setup() moves the default keys to the new leader", function()
    h.source_plugin()
    assert.equal("<Plug>(slop-term-toggle)", vim.fn.maparg(" \\", "n"))
    vim.g.mapleader = ","
    require("slop").setup({})
    assert.equal("", vim.fn.maparg(" \\", "n"))
    assert.equal("<Plug>(slop-term-toggle)", vim.fn.maparg(",\\", "n"))
    assert.equal("<Plug>(slop-marks-add)", vim.fn.maparg(",h", "n"))
  end)

  it("remove() finds the lhs maps after a mapleader change; apply() again does not stack autocmds", function()
    local km = require("slop.core.keymaps")
    local spec = {
      keymaps = {
        go = { mode = "n", desc = "go", rhs = function() end },
        f = { mode = "n", ft = { "slopx" }, desc = "ft", rhs = function() end },
      },
    }
    km.apply("lead", spec, { keymaps = { go = "<leader>q", f = "<F7>" } })
    km.apply("lead", spec, { keymaps = { go = "<leader>q", f = "<F7>" } })
    assert.equal(1, #vim.api.nvim_get_autocmds({ group = "slop.lead", event = "FileType" }))
    assert.equal("<Plug>(slop-lead-go)", vim.fn.maparg(" q", "n"))
    vim.g.mapleader = ","
    km.remove("lead")
    assert.equal("", vim.fn.maparg(" q", "n"))
  end)

  it("expr_fallthrough() returns the original key or ''", function()
    local km = require("slop.core.keymaps")
    local f = km.expr_fallthrough("<C-n>", function()
      return false
    end)
    assert.equal("<C-n>", f())
    local g = km.expr_fallthrough("<C-n>", function()
      return true
    end)
    assert.equal("", g())
  end)

  it("set() requires desc and prefixes it", function()
    local km = require("slop.core.keymaps")
    assert.has_error(function()
      km.set("n", "<F5>", function() end, {})
    end, "desc")
    km.set("n", "<F5>", function() end, { desc = "thing" })
    assert.equal("slop: thing", vim.fn.maparg("<F5>", "n", false, true).desc)
  end)
end)

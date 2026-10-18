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

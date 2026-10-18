local h = require("helpers")

local function complete(line)
  return vim.fn.getcompletion(line, "cmdline")
end

describe(":Slop", function()
  local notes
  before_each(function()
    h.reset()
    notes = {}
    vim.notify = function(msg, level)
      notes[#notes + 1] = { msg = msg, level = level }
    end
    h.source_plugin()
  end)

  it("exists with range support", function()
    local cmd = vim.api.nvim_get_commands({}).Slop
    assert.truthy(cmd)
    assert.equal("*", cmd.nargs)
    assert.truthy(cmd.range ~= nil)
  end)

  it("completes core subcommands and enabled modules", function()
    local items = complete("Slop ")
    for _, n in ipairs({ "health", "log", "modules", "term", "cloak", "complete", "commit", "rest", "edit" }) do
      assert.truthy(vim.tbl_contains(items, n), n)
    end
    assert.falsy(vim.tbl_contains(items, "hello"), "hello is disabled by default")
    assert.are.same({ "term" }, complete("Slop te"))
    assert.are.same({ "modules" }, complete("Slop mo"))
  end)

  it("completes module subcommands and their args, with a range prefix", function()
    require("slop").setup({ hello = { enabled = true, silent = true } })
    assert.truthy(vim.tbl_contains(complete("Slop "), "hello"))
    assert.are.same({ "greet" }, complete("Slop hello "))
    assert.are.same({ "neovim" }, complete("Slop hello greet n"))
    assert.are.same({ "hello" }, complete("'<,'>Slop hel"))
    assert.are.same({ "greet" }, complete("'<,'>Slop! hello g"))
    -- completion does not set the module up
    assert.is_false(require("slop.core.registry").is_loaded("hello"))
  end)

  it("completes :Slop modules enable|disable", function()
    assert.are.same({ "disable", "enable" }, complete("Slop modules "))
    assert.are.same({ "hello" }, complete("Slop modules enable h"))
    assert.truthy(vim.tbl_contains(complete("Slop modules disable "), "term"))
  end)

  it("dispatches subcommands, default subcommands and args", function()
    require("slop").setup({ hello = { enabled = true, silent = true } })
    local got = {}
    require("slop.core.events").on("hello", "Greet", function(d)
      got[#got + 1] = d.text
    end)
    vim.cmd("Slop hello greet you")
    vim.cmd("Slop hello")
    vim.cmd("Slop hello there")
    assert.are.same({ "Hello, you!", "Hello, world!", "Hello, there!" }, got)
  end)

  it("reports unknown modules and disabled modules", function()
    vim.cmd("Slop nope")
    assert.matches("unknown module", notes[#notes].msg)
    vim.cmd("Slop hello")
    assert.matches("disabled", notes[#notes].msg)
    vim.cmd("Slop")
    assert.matches("usage", notes[#notes].msg)
  end)

  it(":Slop modules enable loads, :Slop log opens the log", function()
    vim.g.slop = { hello = { silent = true } }
    vim.cmd("Slop modules enable hello")
    assert.is_true(require("slop.core.registry").is_loaded("hello"))
    vim.cmd("Slop log")
    assert.equal("sloplog", vim.bo.filetype)
  end)
end)

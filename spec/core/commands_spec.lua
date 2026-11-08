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

  it("completes abbreviated command names (:Sl, :Slo) and after a count", function()
    assert.truthy(vim.tbl_contains(complete("Sl term "), "toggle"))
    assert.are.same({ "enable" }, complete("Slo modules en"))
    assert.are.same({ "term" }, complete("5Sl te"))
  end)

  it("completes the word at the cursor, not at the end of the line", function()
    local c = require("slop.core.commands")
    -- what Nvim passes a Lua completion: the whole line, the cursor position (bytes before it) and an
    -- arg_lead that runs on to the end of the line
    assert.are.same({ "term" }, c.complete("te toggle", "Slop te toggle", 7))
    assert.truthy(vim.tbl_contains(c.complete(" float", "Slop term  float", 10), "toggle"))
    assert.are.same({ "enable" }, c.complete("en hello", "Slop modules en hello", 15))
    -- and on a real command line: <Tab> after "te" with more text behind the cursor
    local line
    local id = vim.api.nvim_create_autocmd("CmdlineChanged", {
      callback = function()
        line = vim.fn.getcmdline()
      end,
    })
    h.feed(":Slop te toggle<Home>" .. ("<Right>"):rep(7) .. "<Tab><C-c>", "tx")
    vim.api.nvim_del_autocmd(id)
    assert.equal("Slop term toggle", line)
  end)

  it("a word with escaped blanks (`my\\ file`) is one argument, as typed, also mid-line", function()
    local seen
    require("slop").setup({
      modules = {
        esc = {
          name = "esc",
          description = "completion test",
          defaults = { enabled = true },
          setup = function() end,
          commands = {
            open = {
              impl = function() end,
              complete = function(lead, args)
                seen = { lead = lead, args = vim.deepcopy(args) }
                return #args <= 1 and { [[my\ file.lua]] } or {}
              end,
            },
          },
        },
      },
    })
    assert.are.same({ [[my\ file.lua]] }, complete([[Slop esc open my\ fi]]))
    assert.are.same({ lead = [[my\ fi]], args = { [[my\ fi]] } }, seen)
    local c = require("slop.core.commands")
    local line = [[Slop esc open my\ fi more]]
    assert.are.same({ [[my\ file.lua]] }, c.complete([[my\ fi more]], line, #[[Slop esc open my\ fi]]))
    assert.are.same({ lead = [[my\ fi]], args = { [[my\ fi]] } }, seen)
    -- an escaped backslash does not escape the blank after it
    c.complete("", [[Slop esc open a\\ ]], 0)
    assert.are.same({ lead = "", args = { [[a\\]], "" } }, seen)
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

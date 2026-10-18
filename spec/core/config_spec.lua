local h = require("helpers")

describe("config", function()
  local config, notes
  before_each(function()
    h.reset()
    notes = {}
    vim.notify = function(msg, level)
      notes[#notes + 1] = { msg = msg, level = level }
    end
    config = require("slop.config")
  end)

  it("has core defaults", function()
    local c = config.get()
    assert.equal("rounded", c.ui.border)
    assert.equal("warn", c.log.level)
    assert.are.same({ ".git" }, c.project.root_markers)
    assert.equal("<redacted>", c.secrets.placeholder)
    assert.truthy(vim.tbl_contains(c.secrets.block, ".env*"))
  end)

  it("resolves defaults < vim.g.slop < setup(opts)", function()
    vim.g.slop = { ui = { border = "single", spinner = "line" }, log = { level = "info" } }
    config.setup({ ui = { border = "double" } })
    local ui = config.get("ui")
    assert.equal("double", ui.border)
    assert.equal("line", ui.spinner)
    assert.equal("auto", ui.picker)
    assert.equal("info", config.get("log").level)
  end)

  it("accepts vim.g.slop as a function", function()
    vim.g.slop = function()
      return { ui = { picker = "builtin" } }
    end
    config.invalidate()
    assert.equal("builtin", config.get("ui").picker)
  end)

  it("replaces lists instead of merging them", function()
    config.setup({ project = { root_markers = { "package.json" } } })
    assert.are.same({ "package.json" }, config.get("project").root_markers)
  end)

  it("collects module defaults from the module spec", function()
    local c = config.get("hello")
    assert.equal("Hello", c.greeting)
    assert.equal(false, c.enabled)
    config.setup({ hello = { enabled = true, target = "you" } })
    c = config.get("hello")
    assert.equal(true, c.enabled)
    assert.equal("you", c.target)
    assert.equal("Hello", c.greeting)
  end)

  it("module = false disables, { enabled = false } too", function()
    assert.is_true(config.enabled("term"))
    config.setup({ term = false, cloak = { enabled = false } })
    assert.is_false(config.enabled("term"))
    assert.is_false(config.get("term").enabled)
    assert.is_false(config.enabled("cloak"))
    assert.is_false(config.enabled("hello"))
  end)

  it("reports validation errors with <ns>.<field> paths", function()
    config.setup({ ui = { picker = "nope" } })
    assert.are.same({ "ui.picker: expected 'auto'|'fzf'|'builtin'|'select', got nope" }, config.errors("ui"))
    assert.matches("invalid config", notes[1].msg)
    config.setup({ hello = { greeting = 1, keymaps = { greet = 2 } } })
    local errs = config.errors("hello")
    table.sort(errs)
    assert.are.same(
      { "hello.greeting: expected string, got number", "hello.keymaps.greet: expected string|false, got number" },
      errs
    )
  end)

  it("warns about unknown keys", function()
    config.setup({ ui = { bordr = "x" }, hello = { greting = "x", keymaps = { gret = "x" } }, bogus = 1 })
    assert.are.same({ "ui.bordr" }, config.unknown("ui"))
    assert.are.same({ "hello.greting", "hello.keymaps.gret" }, config.unknown("hello"))
    assert.are.same({ "bogus" }, config.unknown_top())
    local found = false
    for _, n in ipairs(notes) do
      if n.msg:match("unknown option") then
        found = true
      end
    end
    assert.truthy(found)
  end)

  it("treats open_keys and empty/list defaults as free-form", function()
    config.setup({
      ai = { providers = { mine = { kind = "chat", url = "u", model = "m" } } },
      edit = { presets = { x = {} } },
    })
    assert.are.same({}, config.unknown("ai"))
    assert.are.same({}, config.unknown("edit"))
  end)

  it("validates the ai service schema", function()
    config.setup({ ai = { providers = { bad = { kind = "x", url = "u", model = "m", api_key = "sk-literal key" } } } })
    local errs = config.errors("ai")
    assert.equal(2, #errs)
  end)

  it("normalizes log levels", function()
    assert.equal(vim.log.levels.WARN, config.log_level())
    config.setup({ log = { level = "debug" } })
    assert.equal(vim.log.levels.DEBUG, config.log_level())
    config.setup({ log = { level = vim.log.levels.ERROR } })
    assert.equal(vim.log.levels.ERROR, config.log_level())
  end)

  it("setup() is idempotent and fires User SlopConfigChanged", function()
    local n = 0
    vim.api.nvim_create_autocmd("User", {
      pattern = "SlopConfigChanged",
      callback = function()
        n = n + 1
      end,
    })
    config.setup({ ui = { border = "single" } })
    config.setup({ ui = { border = "single" } })
    assert.equal(2, n)
    assert.equal("single", config.get("ui").border)
  end)

  it("registers user modules from opts.modules", function()
    config.setup({
      modules = {
        mine = { name = "mine", description = "d", defaults = { enabled = true, x = 1 }, setup = function() end },
      },
    })
    assert.truthy(config.user_modules().mine)
    assert.equal(1, config.get("mine").x)
    assert.are.same({}, config.unknown_top())
  end)

  it("runtime overrides via set_enabled", function()
    config.set_enabled("hello", true)
    assert.is_true(config.enabled("hello"))
    config.set_enabled("hello", nil)
    assert.is_false(config.enabled("hello"))
  end)
end)

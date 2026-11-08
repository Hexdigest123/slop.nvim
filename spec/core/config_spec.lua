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
    assert.are.same({ "ui.picker: expected 'auto'|'fzf'|'builtin'|'select', got string" }, config.errors("ui"))
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

  it("removing an override restores the setup() value (the override is not written into it)", function()
    config.setup({ term = { layout = "float" } })
    config.set_enabled("term", false)
    assert.is_false(config.enabled("term"))
    config.set_enabled("term", nil)
    assert.is_true(config.enabled("term"))
    assert.are.same({ layout = "float" }, config.raw().term)
  end)

  it("never echoes option values in validation errors, notifications or the log", function()
    local key = "sk-FAKE0000-0000-NOTAREALKEY"
    config.setup({ ai = { providers = { codestral = { api_key = key } } } })
    local errs = config.errors("ai")
    assert.are.same({ "ai.providers.codestral.api_key: expected env var name|function|false, got string" }, errs)
    for _, n in ipairs(notes) do
      assert.falsy(n.msg:find(key, 1, true), n.msg)
    end
    for _, e in ipairs(require("slop.core.log").entries()) do
      assert.falsy(e.msg:find(key, 1, true), e.msg)
    end
    -- errors a schema throws itself (vim.validate with a function validator) are cleaned too
    config.setup({
      modules = {
        thrower = {
          name = "thrower",
          description = "d",
          defaults = { enabled = true, token = "" },
          setup = function() end,
          schema = function(cfg)
            vim.validate("token", cfg.token, function(v)
              return v == ""
            end, "an empty string")
          end,
        },
      },
      thrower = { token = key },
    })
    assert.are.same({ "thrower.token: expected an empty string, got an invalid value" }, config.errors("thrower"))
    assert.equal("x: expected y, got number", config.hide_values("x: expected y, got number"))
  end)

  it("log.max_entries must be an integer >= 1", function()
    config.setup({ log = { max_entries = 2.5 } })
    assert.are.same({ "log.max_entries: expected integer >= 1, got number" }, config.errors("log"))
    config.setup({ log = { max_entries = 0 } })
    assert.equal(1, #config.errors("log"))
    local reported = vim.tbl_filter(function(n)
      return n.msg:find("log.max_entries", 1, true) ~= nil
    end, notes)
    assert.equal(2, #reported, "once per setup() call")
  end)

  it("secrets: detectors on by default, a boolean; common credential files are blocked", function()
    local c = config.get("secrets")
    assert.is_true(c.detectors)
    for _, g in ipairs({ ".netrc", "_netrc", ".npmrc", ".pypirc", ".git-credentials", ".kube/config" }) do
      assert.truthy(vim.tbl_contains(c.block, g), g)
    end
    for _, g in ipairs({ "*kubeconfig*", "*service-account*.json", "id_rsa", "id_dsa", "id_ecdsa", "id_ed25519" }) do
      assert.truthy(vim.tbl_contains(c.block, g), g)
    end
    local secrets = require("slop.core.secrets")
    for _, p in ipairs({ "/h/.kube/config", "/h/.ssh/id_ed25519", "/p/gcp-service-account-1.json", "/h/.netrc" }) do
      assert.is_true(secrets.is_blocked(p), p)
    end
    assert.is_false(secrets.is_blocked("/h/.ssh/id_ed25519.pub"))
    config.setup({ secrets = { detectors = "yes" } })
    assert.are.same({ "secrets.detectors: expected boolean, got string" }, config.errors("secrets"))
    config.setup({ secrets = { detectors = false } })
    assert.is_false(config.get("secrets").detectors)
  end)

  it("secrets.block must be a list of globs; project.root_markers a list of markers", function()
    -- a map is no list: every default glob would be gone and nothing blocked, silently
    config.setup({ secrets = { block = { env = ".env*" } } })
    assert.are.same({ "secrets.block: expected list of file globs, got table" }, config.errors("secrets"))
    config.setup({ secrets = { block = { "*.x", 5 } } })
    assert.equal(1, #config.errors("secrets"))
    config.setup({ secrets = { block = { "*.x" } } })
    assert.are.same({}, config.errors("secrets"))
    -- a marker vim.fs.root() cannot use throws from every project.root() outside a match of the others
    config.setup({ project = { root_markers = { ".git", 1 } } })
    assert.are.same(
      { "project.root_markers: expected list of markers (name, list of names or function), got table" },
      config.errors("project")
    )
    config.setup({
      project = {
        root_markers = {
          { ".git", "Makefile" },
          "package.json",
          function()
            return false
          end,
        },
      },
    })
    assert.are.same({}, config.errors("project"))
  end)

  it("a table where one key belongs, or a key where a group belongs, is reported (it disabled the keys)", function()
    config.setup({ hello = { keymaps = { greet = { "<F1>", "<F2>" } } } })
    assert.are.same({ "hello.keymaps.greet: expected string|false, got table" }, config.errors("hello"))
    -- a group of keys (the edit diff review keys) takes a table, or false for all of them
    config.setup({ edit = { keymaps = { diff = { accept = "<F3>" } } } })
    assert.are.same({}, config.errors("edit"))
    config.setup({ edit = { keymaps = { diff = false } } })
    assert.are.same({}, config.errors("edit"))
    config.setup({ edit = { keymaps = { diff = "ga" } } })
    assert.are.same({ "edit.keymaps.diff: expected table|false, got string" }, config.errors("edit"))
    config.setup({ edit = { keymaps = { diff = { accept = { "ga" } } } } })
    assert.are.same({ "edit.keymaps.diff.accept: expected string|false, got table" }, config.errors("edit"))
  end)

  it("setup() reports a bad startup key at once (it is not mapped: the module would not load through it)", function()
    config.setup({ term = { keymaps = { toggle = { "<C-\\>" } } } })
    local text = table.concat(
      vim.tbl_map(function(n)
        return n.msg
      end, notes),
      "\n"
    )
    assert.matches("term%.keymaps%.toggle: expected string|false, got table", text)
    assert.falsy(package.loaded["slop.modules.term"], "no module code loaded for it")
  end)

  it("reports option mistakes that leave a module disabled", function()
    config.setup({ term = { enabled = "yes" }, hello = true })
    local text = table.concat(
      vim.tbl_map(function(n)
        return n.msg
      end, notes),
      "\n"
    )
    assert.matches("term%.enabled: expected boolean, got string", text)
    assert.matches("hello: expected table|false, got boolean", text)
    assert.is_false(config.enabled("term"))
    assert.truthy(vim.tbl_contains(config.errors("hello"), "hello: expected table|false, got boolean"))
  end)

  it("opts.modules: only name = spec entries; specs are used as given", function()
    local timer = assert(vim.uv.new_timer()) -- userdata in a module table must not break setup()
    local api = { timer = timer }
    local mine = {
      name = "mine",
      description = "d",
      defaults = { enabled = true },
      api = api,
      setup = function()
        api.ready = true
      end,
    }
    config.setup({ modules = { mine = mine, { name = "listed" } } })
    timer:close()
    assert.equal(mine, config.user_modules().mine)
    assert.is_nil(config.user_modules()[1])
    assert.matches("ignoring %[1%] = table", notes[1].msg)
    local registry = require("slop.core.registry")
    assert.truthy(vim.tbl_contains(registry.names(), "mine"))
    assert.equal(api, require("slop").mine)
    assert.is_true(api.ready)
  end)

  it("vim.g.slop as a function also registers modules", function()
    vim.g.slop = function()
      return {
        modules = {
          gmod = { name = "gmod", description = "d", defaults = { enabled = true }, setup = function() end },
        },
      }
    end
    config.invalidate()
    assert.truthy(config.user_modules().gmod)
    assert.equal("module", require("slop.core.registry").kind("gmod"))
  end)
end)

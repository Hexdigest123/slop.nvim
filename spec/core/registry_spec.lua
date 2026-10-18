local h = require("helpers")

local function fake(name, extra)
  return vim.tbl_extend("force", {
    name = name,
    description = "fake " .. name,
    defaults = { enabled = true },
    setup = function() end,
  }, extra or {})
end

describe("registry", function()
  local registry, config
  before_each(function()
    h.reset()
    vim.notify = function() end
    registry = require("slop.core.registry")
    config = require("slop.config")
  end)

  it("discovers every built-in module", function()
    local names = registry.names()
    for _, n in ipairs({ "cloak", "commit", "complete", "edit", "hello", "rest", "term" }) do
      assert.truthy(vim.tbl_contains(names, n), n)
    end
    assert.equal("module", registry.kind("term"))
    assert.equal("service", registry.kind("ai"))
    assert.is_nil(registry.kind("health"))
    assert.is_nil(registry.kind("nope"))
  end)

  it("contract: every built-in module spec is valid and matches the manifest", function()
    for _, name in ipairs(registry.names()) do
      local spec, err = registry.spec(name)
      assert.truthy(spec, err)
      assert.are.same({}, registry.validate_spec(spec, name))
      assert.are.same({}, config.errors(name), name)
    end
    for name in pairs(require("slop.manifest")) do
      assert.truthy(vim.tbl_contains(registry.discover(), name), "manifest entry without module dir: " .. name)
    end
  end)

  it("contract: every service spec is valid", function()
    for _, name in ipairs(registry.service_names()) do
      local spec, err = registry.service_spec(name)
      assert.truthy(spec, err)
      assert.are.same({}, config.errors(name))
    end
  end)

  it("rejects invalid specs with useful errors", function()
    local errs = registry.validate_spec({ name = "x", defaults = {}, typo = 1 }, "x")
    local text = table.concat(errs, "\n")
    assert.matches("unknown spec field 'typo'", text)
    assert.matches("description", text)
    assert.matches("defaults.enabled", text)
    assert.matches("setup must be a function", text)
    errs = registry.validate_spec(
      fake("y", {
        defaults = { enabled = true, keymaps = { a = "<Tab>" } },
        keymaps = { a = { mode = "i", rhs = function() end } },
        services = { "nope" },
      }),
      "y"
    )
    text = table.concat(errs, "\n")
    assert.matches("needs a desc", text)
    assert.matches("<Tab>", text)
    assert.matches("unknown service 'nope'", text)
    assert.truthy(#registry.validate_spec(fake("log"), "log") > 0)
  end)

  it("loads once and returns the api", function()
    config.setup({ hello = { enabled = true, silent = true } })
    local api = registry.load("hello")
    assert.truthy(api and api.greet)
    assert.equal(api, registry.load("hello"))
    assert.equal(1, api.setups())
    assert.is_true(registry.is_loaded("hello"))
    assert.equal(api, require("slop").hello)
  end)

  it("does not load disabled modules", function()
    local api, err = registry.load("hello", { silent = true })
    assert.is_nil(api)
    assert.equal("disabled", err)
    assert.equal("disabled", registry.status("hello"))
    assert.has_error(function()
      return require("slop").hello.greet
    end, "unavailable")
  end)

  it("sets up declared services before the module", function()
    local order = {}
    package.preload["slop.services.fakesvc"] = function()
      return {
        name = "fakesvc",
        description = "d",
        defaults = { x = 1 },
        setup = function(cfg)
          order[#order + 1] = "svc:" .. cfg.x
        end,
      }
    end
    -- the service must be resolvable on the rtp for validation; register it first
    assert.truthy(registry.service_spec("fakesvc"))
    config.setup({
      modules = {
        m = fake("m", {
          services = { "fakesvc" },
          setup = function()
            order[#order + 1] = "module"
          end,
        }),
      },
    })
    assert.truthy(registry.load("m"))
    registry.load("m")
    assert.are.same({ "svc:1", "module" }, order)
  end)

  it("marks modules with setup errors as failed without retrying", function()
    local calls = 0
    config.setup({
      modules = {
        boom = fake("boom", {
          setup = function()
            calls = calls + 1
            error("kaboom")
          end,
        }),
      },
    })
    local api, err = registry.load("boom")
    assert.is_nil(api)
    assert.matches("kaboom", err)
    registry.load("boom")
    assert.equal(1, calls)
    assert.equal("failed", registry.status("boom"))
  end)

  it("refuses to load modules with invalid config", function()
    config.setup({ hello = { enabled = true, greeting = 42 } })
    local api, err = registry.load("hello")
    assert.is_nil(api)
    assert.matches("hello.greeting", err)
  end)

  it("load_capability loads enabled providers only", function()
    config.setup({ modules = { prov = fake("prov", { manifest = { provides = { "thing" } } }) } })
    registry.load_capability("thing")
    assert.is_true(registry.is_loaded("prov"))
  end)

  it("enable/disable at runtime", function()
    local torn = false
    config.setup({ modules = { t = fake("t", {
      teardown = function()
        torn = true
      end,
    }) } })
    assert.truthy(registry.load("t"))
    registry.disable("t")
    assert.is_true(torn)
    assert.equal("disabled", registry.status("t"))
    assert.truthy(registry.enable("t"))
    assert.is_true(registry.is_loaded("t"))
  end)

  it("replays the trigger event into the module augroup", function()
    local seen
    config.setup({
      modules = {
        ev = fake("ev", {
          setup = function()
            vim.api.nvim_create_autocmd("User", {
              group = require("slop.core.util").augroup("ev"),
              pattern = "SlopTestX",
              callback = function(a)
                seen = a.data
              end,
            })
          end,
        }),
      },
    })
    registry.load("ev")
    registry.replay("ev", { event = "User", match = "SlopTestX", data = { ok = 1 } })
    assert.are.same({ ok = 1 }, seen)
  end)
end)

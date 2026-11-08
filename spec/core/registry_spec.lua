local h = require("helpers")

local real_notify = vim.notify -- ERROR level echoes with err=true: that is what breaks a read

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

  it("direct loads report problems synchronously (only lazy-load triggers defer them)", function()
    local notes = {}
    vim.notify = function(msg)
      notes[#notes + 1] = msg
    end
    config.setup({ hello = { enabled = true, greeting = 42 } })
    assert.is_nil(registry.load("hello"))
    assert.matches("hello%.greeting", table.concat(notes, "\n"))
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

  it(
    "a setup() that disables a loaded module unloads it like :Slop modules disable; enabling loads it again",
    function()
      local torn, setups = 0, 0
      local spec = fake("offm", {
        setup = function()
          setups = setups + 1
          vim.api.nvim_create_autocmd("User", {
            group = require("slop.core.util").augroup("offm"),
            pattern = "SlopOffmProbe",
            callback = function() end,
          })
        end,
        teardown = function()
          torn = torn + 1
          pcall(vim.api.nvim_del_augroup_by_name, "slop.offm")
        end,
      })
      local disabled = {}
      vim.api.nvim_create_autocmd("User", {
        pattern = "SlopModuleDisabled",
        callback = function(ev)
          disabled[#disabled + 1] = ev.data.name
        end,
      })
      config.setup({ modules = { offm = spec } })
      assert.truthy(registry.load("offm"))
      config.setup({ modules = { offm = spec }, offm = false })
      assert.equal(1, torn)
      assert.equal("disabled", registry.status("offm"))
      assert.are.same({ "offm" }, disabled)
      assert.equal(0, #vim.api.nvim_get_autocmds({ event = "User", pattern = "SlopOffmProbe" }))
      config.setup({ modules = { offm = spec }, offm = { enabled = false } }) -- still off: nothing to do
      assert.equal(1, torn)
      assert.are.same({ "offm" }, disabled)
      config.setup({ modules = { offm = spec } })
      assert.truthy(registry.load("offm"))
      assert.equal(2, setups)
      -- a module without teardown stays loaded: say once that a restart is needed
      local notes = {}
      vim.notify = function(msg)
        notes[#notes + 1] = msg
      end
      local kept = fake("keptm")
      config.setup({ modules = { keptm = kept } })
      assert.truthy(registry.load("keptm"))
      config.setup({ modules = { keptm = kept }, keptm = false })
      config.setup({ modules = { keptm = kept }, keptm = false })
      assert.equal(1, #vim.tbl_filter(function(m)
        return m:find("keptm has no teardown", 1, true) ~= nil
      end, notes))
    end
  )

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

  it("a disabled module's <Plug> stops running its handler, also when the user mapped it", function()
    local notes, ran = {}, { off = 0, kept = 0 }
    vim.notify = function(msg)
      notes[#notes + 1] = msg
    end
    local function km(name)
      return {
        go = {
          mode = "n",
          desc = "go",
          rhs = function()
            ran[name] = ran[name] + 1
          end,
        },
      }
    end
    config.setup({
      modules = {
        off = fake("off", { teardown = function() end, keymaps = km("off") }),
        kept = fake("kept", { keymaps = km("kept") }), -- no teardown: stays loaded when disabled
      },
    })
    assert.truthy(registry.load("off") and registry.load("kept"))
    vim.keymap.set("n", "<F5>", "<Plug>(slop-off-go)")
    h.feed("<F5><Plug>(slop-kept-go)")
    assert.are.same({ off = 1, kept = 1 }, ran)
    registry.disable("off")
    registry.disable("kept")
    h.feed("<F5><Plug>(slop-kept-go)")
    assert.are.same({ off = 1, kept = 1 }, ran)
    assert.matches("module 'kept' is disabled", notes[#notes])
    assert.truthy(registry.enable("off"))
    h.feed("<F5>")
    assert.equal(2, ran.off)
  end)

  it("a failed setup: its keys report it (also :Slop), partial setup is undone, keys work once fixed", function()
    local notes, ran, broken, torn = {}, 0, true, false
    vim.notify = function(msg)
      notes[#notes + 1] = msg
    end
    local spec = fake("flaky", {
      setup = function()
        vim.api.nvim_create_autocmd("User", {
          group = require("slop.core.util").augroup("flaky"),
          pattern = "SlopFlakyProbe",
          callback = function() end,
        })
        if broken then
          error("boom")
        end
      end,
      teardown = function()
        torn = true
      end,
      commands = { run = { default = true, impl = function() end } },
      keymaps = {
        go = {
          mode = "n",
          desc = "go",
          rhs = function()
            ran = ran + 1
          end,
        },
      },
    })
    config.setup({ modules = { flaky = spec } })
    assert.is_nil(registry.load("flaky"))
    assert.is_true(torn)
    assert.equal(0, #vim.api.nvim_get_autocmds({ event = "User", pattern = "SlopFlakyProbe" }))
    h.feed("<Plug>(slop-flaky-go)")
    assert.equal(0, ran)
    assert.matches("'flaky' is unavailable %(failed to load: .*boom", notes[#notes])
    local n = #notes
    require("slop.core.commands").run({ fargs = { "flaky" } })
    assert.equal(n + 1, #notes, ":Slop reports the failure again")
    assert.is_nil(registry.load("flaky", { silent = true }))
    -- API access (e.g. from a statusline) does not notify each time, the error tells why
    assert.has_error(function()
      return require("slop").flaky.x
    end, "unavailable")
    assert.equal(n + 1, #notes)
    broken = false
    config.setup({ modules = { flaky = spec } }) -- the user fixed the cause
    h.feed("<Plug>(slop-flaky-go)")
    assert.equal(1, ran)
    assert.is_true(registry.is_loaded("flaky"))
  end)

  it("a bad highlight group fails the load instead of leaving it 'loading'", function()
    config.setup({ modules = { badhl = fake("badhl", { highlights = { SlopBadhlX = { fg = "notacolor" } } }) } })
    local api, err = registry.load("badhl")
    assert.is_nil(api)
    assert.matches("highlights", err)
    assert.equal("failed", registry.status("badhl"))
    assert.is_nil(registry.load("badhl"))
  end)
end)

describe("lazy triggers (plugin/slop.lua)", function()
  local registry, config, notes
  before_each(function()
    h.reset()
    notes = {}
    vim.notify = function(msg)
      notes[#notes + 1] = msg
    end
    vim.cmd("silent! %bwipe!")
    registry = require("slop.core.registry")
    config = require("slop.config")
  end)

  --- setup() with the built-in event-triggered modules off (isolates the module under test).
  local function setup(opts)
    config.setup(vim.tbl_extend("force", { cloak = false, todo = false, context = false, progress = false }, opts))
  end

  --- A user module loaded by `events`; its setup() records `handles` events of its own augroup.
  local function module(name, events, handles, extra)
    local calls = {}
    local spec = vim.tbl_extend("force", fake(name), {
      manifest = { cmd = true, events = events },
      setup = function()
        for _, ev in ipairs(handles) do
          vim.api.nvim_create_autocmd(ev, {
            group = require("slop.core.util").augroup(name),
            callback = function(a)
              calls[#calls + 1] = ev .. ":" .. vim.fs.basename(a.match)
            end,
          })
        end
      end,
    }, extra or {})
    return spec, calls
  end

  local function file(name, text)
    local p = h.tmpdir("trig") .. "/" .. name
    h.write(p, text or "x\n")
    return p
  end

  it("replays the trigger once; a module loaded before its trigger does not see it twice", function()
    local lazy, lazy_calls = module("lazym", { "BufReadPost" }, { "BufReadPost" })
    local eager, eager_calls = module("eagerm", { "BufReadPost" }, { "BufReadPost" })
    setup({ modules = { lazym = lazy, eagerm = eager } })
    h.source_plugin()
    assert.truthy(registry.load("eagerm"))
    vim.cmd.edit(file("a.txt"))
    assert.are.same({ "BufReadPost:a.txt" }, lazy_calls)
    assert.are.same({ "BufReadPost:a.txt" }, eager_calls)
  end)

  it("re-arms the triggers after a failed load once setup() fixes the config", function()
    local spec, calls = module("fixm", { "BufReadPost" }, { "BufReadPost" }, {
      defaults = { enabled = true, n = 1 },
      schema = function(cfg, check)
        check("n", cfg.n, "number")
      end,
    })
    setup({ modules = { fixm = spec }, fixm = { n = "x" } })
    h.source_plugin()
    vim.cmd.edit(file("a.txt"))
    assert.equal("failed", registry.status("fixm"))
    setup({ modules = { fixm = spec } })
    -- the file that is already open gets the module too (scheduled), later reads trigger as usual
    assert.truthy(vim.wait(1000, function()
      return registry.is_loaded("fixm")
    end))
    assert.are.same({ "BufReadPost:a.txt" }, calls)
    vim.cmd.edit(file("b.txt"))
    assert.are.same({ "BufReadPost:a.txt", "BufReadPost:b.txt" }, calls)
  end)

  it("a module handler that fails on the replayed event is reported after the read (not dropped)", function()
    local spec = vim.tbl_extend("force", fake("brokenm"), {
      manifest = { cmd = true, events = { "BufReadPre" } },
      setup = function()
        vim.api.nvim_create_autocmd("BufReadPre", {
          group = require("slop.core.util").augroup("brokenm"),
          callback = function()
            error("handler bug")
          end,
        })
      end,
    })
    setup({ modules = { brokenm = spec } })
    h.source_plugin()
    local p = file("r.txt", "kept\n")
    assert.truthy(pcall(vim.cmd.edit, p))
    assert.are.same({ "kept" }, vim.api.nvim_buf_get_lines(0, 0, -1, false))
    assert.truthy(
      vim.wait(1000, function()
        return table.concat(notes, "\n"):find("brokenm.*BufReadPre.*handler bug") ~= nil
      end),
      table.concat(notes, "\n")
    )
  end)

  it("a module enabled by a later setup() loads for the files and filetypes already open", function()
    local spec, calls = module("laterm", { "BufReadPost" }, { "BufReadPost" })
    local ftspec = vim.tbl_extend("force", fake("laterft"), { manifest = { cmd = true, ft = { "slopft2" } } })
    setup({ modules = { laterm = spec, laterft = ftspec }, laterm = false, laterft = false })
    h.source_plugin()
    vim.cmd.edit(file("open.txt"))
    vim.bo.filetype = "slopft2"
    vim.wait(50)
    assert.is_false(registry.is_loaded("laterm"))
    assert.is_false(registry.is_loaded("laterft"))
    setup({ modules = { laterm = spec, laterft = ftspec } })
    assert.truthy(vim.wait(1000, function()
      return registry.is_loaded("laterm") and registry.is_loaded("laterft")
    end))
    assert.are.same({ "BufReadPost:open.txt" }, calls)
  end)

  it("replays a non-buffer event with its pattern (LspProgress kind)", function()
    local seen = {}
    local spec = vim.tbl_extend("force", fake("lspm"), {
      manifest = { cmd = true, events = { "LspProgress" } },
      setup = function()
        vim.api.nvim_create_autocmd("LspProgress", {
          group = require("slop.core.util").augroup("lspm"),
          pattern = "begin",
          callback = function(a)
            seen[#seen + 1] = vim.fs.basename(a.match)
          end,
        })
      end,
    })
    setup({ modules = { lspm = spec } })
    h.source_plugin()
    vim.cmd.edit(file("b.txt"))
    local data = { client_id = 1, params = { token = 1, value = { kind = "begin", title = "t" } } }
    vim.api.nvim_exec_autocmds("LspProgress", { pattern = "begin", modeline = false, data = data })
    assert.is_true(registry.is_loaded("lspm"))
    assert.are.same({ "begin" }, seen)
  end)

  it("a throwing SlopModuleLoaded handler cannot abort the read that triggered the load", function()
    vim.g.slop_test_allow_stderr = true -- Nvim prints the handler's error on stderr: expected here
    local spec = module("prem", { "BufReadPre" }, {})
    setup({ modules = { prem = spec } })
    h.source_plugin()
    local fired = false
    vim.api.nvim_create_autocmd("User", {
      group = vim.api.nvim_create_augroup("slop.spec.user", { clear = true }), -- (h.reset() removes it)
      pattern = "SlopModuleLoaded",
      callback = function(ev)
        if ev.data.name == "prem" then
          fired = true
          error("user bug (expected in this spec)")
        end
      end,
    })
    local p = file("keep.txt", "precious\n")
    assert.truthy(pcall(vim.cmd.edit, p))
    assert.are.same({ "precious" }, vim.api.nvim_buf_get_lines(0, 0, -1, false))
    assert.is_true(registry.is_loaded("prem"))
    assert.truthy(
      vim.wait(1000, function()
        return fired
      end),
      "fired right after the read"
    )
  end)

  it("an invalid config of a module loaded by a file read is reported after the read, never aborts it", function()
    vim.notify = real_notify
    config.setup({ cloak = { render = "bogus" }, todo = false, context = false, progress = false })
    h.source_plugin()
    local p = file("conf.yaml", "a: 1\nb: 2\n")
    local ok, err = pcall(vim.cmd.edit, p)
    assert.truthy(ok, err)
    assert.are.same({ "a: 1", "b: 2" }, vim.api.nvim_buf_get_lines(0, 0, -1, false))
    assert.equal("failed", registry.status("cloak"))
    assert.truthy(
      vim.wait(1000, function()
        return vim.fn.execute("messages"):find("cloak.render: expected", 1, true) ~= nil
      end),
      "the notification is shown right after"
    )
  end)

  it("sourced late (lazy.nvim VeryLazy): read-event modules load for the files already open", function()
    vim.cmd.edit(file("late.txt"))
    local spec, calls = module("latem", { "BufReadPre", "BufNewFile" }, { "BufReadPost" })
    setup({ modules = { latem = spec } })
    h.source_plugin()
    assert.is_false(registry.is_loaded("latem"), "scheduled: the plugin manager's setup() comes first")
    assert.truthy(vim.wait(1000, function()
      return registry.is_loaded("latem")
    end))
    assert.are.same({ "BufReadPost:late.txt" }, calls)
  end)

  it("sourced late: an ft module gets FileType replayed for every buffer that already has the filetype", function()
    local seen = {}
    local bufs = {}
    for i = 1, 3 do
      vim.cmd.edit(file(("f%d.slopft"):format(i)))
      vim.bo.filetype = "slopft"
      bufs[i] = vim.api.nvim_get_current_buf()
    end
    local spec = vim.tbl_extend("force", fake("ftm"), {
      manifest = { cmd = true, ft = { "slopft" } },
      setup = function()
        vim.api.nvim_create_autocmd("FileType", {
          group = require("slop.core.util").augroup("ftm"),
          pattern = "slopft",
          callback = function(a)
            seen[#seen + 1] = a.buf
          end,
        })
      end,
    })
    setup({ modules = { ftm = spec } })
    h.source_plugin()
    assert.truthy(vim.wait(1000, function()
      return registry.is_loaded("ftm")
    end))
    vim.wait(50)
    table.sort(seen)
    assert.are.same(bufs, seen)
  end)

  it("a user module's broken manifest is reported and stops neither the other modules nor plugin/slop.lua", function()
    for _, order in ipairs({ "setup first (vim.pack)", "plugin first (lazy.nvim)" }) do
      h.reset()
      notes = {}
      registry, config = require("slop.core.registry"), require("slop.config")
      local mods = {
        badev = fake("badev", { manifest = { events = { "BufReadPots" } } }),
        badkey = fake("badkey", {
          defaults = { enabled = true, keymaps = { x = "<F9>" } },
          manifest = { keys = { x = { mode = "?", lhs = "<F9>", desc = "x" } } },
        }),
      }
      local calls = {}
      for i = 1, 6 do -- several, so that some come after the broken ones in pairs() order
        local name = "good" .. i
        mods[name] = module(name, { "BufReadPost" }, { "BufReadPost" }, {
          defaults = { enabled = true, keymaps = { run = "<F" .. i .. ">" } },
          keymaps = { run = { mode = "n", desc = "run", rhs = function() end } },
        })
        mods[name].manifest.keys = { run = { mode = "n", lhs = "<F" .. i .. ">", desc = "run " .. name } }
        local setup_fn = mods[name].setup
        mods[name].setup = function()
          calls[#calls + 1] = name
          setup_fn()
        end
      end
      if order == "setup first (vim.pack)" then
        setup({ modules = mods })
        assert.truthy(pcall(h.source_plugin), order)
      else
        h.source_plugin()
        setup({ modules = mods })
      end
      for i = 1, 6 do
        assert.equal("<Plug>(slop-good" .. i .. "-run)", vim.fn.maparg("<F" .. i .. ">", "n"), order)
      end
      assert.equal("<Plug>(slop-term-toggle)", vim.fn.maparg(" \\", "n"), order)
      vim.cmd.edit(file("a.txt"))
      assert.equal(6, #calls, order)
      assert.truthy(
        vim.wait(1000, function()
          local text = table.concat(notes, "\n")
          return text:find("'badev'.*BufReadPots") ~= nil and text:find("'badkey'") ~= nil
        end),
        order .. ": " .. table.concat(notes, "\n")
      )
      vim.cmd("silent! %bwipe!")
    end
  end)

  it("first press through a stub: string rhs keeps order and count; expr keys load outside textlock", function()
    -- selene: allow(global_usage)
    _G.slop_counts = {} -- read by the mapping's <Cmd>lua rhs below
    setup({
      modules = {
        strm = vim.tbl_extend("force", fake("strm"), {
          defaults = { enabled = true, keymaps = { go = "<F4>" } },
          manifest = { cmd = true, keys = { go = { mode = "n", lhs = "<F4>", desc = "strm go" } } },
          keymaps = {
            go = { mode = "n", desc = "strm go", rhs = "<Cmd>lua table.insert(_G.slop_counts, vim.v.count)<CR>AX<Esc>" },
          },
        }),
        exprm = vim.tbl_extend("force", fake("exprm"), {
          defaults = { enabled = true, keymaps = { go = "<F3>" } },
          manifest = { cmd = true, keys = { go = { mode = "n", lhs = "<F3>", desc = "exprm go", expr = true } } },
          setup = function()
            -- not allowed under textlock (E565)
            vim.api.nvim_buf_set_lines(vim.api.nvim_create_buf(false, true), 0, -1, false, { "ready" })
          end,
          keymaps = {
            go = {
              mode = "n",
              desc = "exprm go",
              expr = true,
              rhs = function()
                return "AE<Esc>"
              end,
            },
          },
        }),
      },
    })
    h.source_plugin()
    local buf = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "" })
    h.feed("3<F4>AY<Esc>")
    assert.equal("XY", vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1])
    -- selene: allow(global_usage)
    assert.are.same({ 3 }, _G.slop_counts)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "" })
    h.feed("<F3>")
    assert.truthy(vim.wait(1000, function()
      return registry.is_loaded("exprm")
    end))
    h.feed("", "tx") -- run the key pressed again
    assert.equal("E", vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1])
    -- selene: allow(global_usage)
    _G.slop_counts = nil
  end)

  it("first press through a stub in operator-pending mode keeps the operator and register", function()
    setup({
      modules = {
        opm = vim.tbl_extend("force", fake("opm"), {
          defaults = { enabled = true, keymaps = { word = "<F2>" } },
          manifest = { cmd = true, keys = { word = { mode = "o", lhs = "<F2>", desc = "opm word" } } },
          keymaps = { word = { mode = "o", desc = "opm word", rhs = "iw" } },
        }),
      },
    })
    h.source_plugin()
    local buf = vim.api.nvim_get_current_buf()
    for _ = 1, 2 do -- the stub, then the real <Plug>
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "one two three" })
      vim.api.nvim_win_set_cursor(0, { 1, 4 })
      vim.fn.setreg("a", "")
      h.feed('"ad<F2>')
      assert.equal("one  three", vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1])
      assert.equal("two", vim.fn.getreg("a"))
    end
  end)
end)

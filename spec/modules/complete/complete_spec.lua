local h = require("helpers")
local mock = require("services.ai.mock_server")

-- Integration tests: the real engine + ai service + context against a mock Codestral server.
-- Insert mode: each test body runs inside an insert-mode mapping (<F12>) so nvim_get_mode() is "i" and vim.wait()
-- pumps the mock server; TextChangedI is simulated with engine.sync() after programmatic edits.

describe("complete module", function()
  local api = vim.api
  local srv, engine, ghost, responses, buf

  local function sse_fim(text_chunks)
    local out = {}
    for _, t in ipairs(text_chunks) do
      out[#out + 1] = mock.sse({ choices = { { delta = { content = t } } } })
    end
    out[#out + 1] = mock.sse("[DONE]")
    return out
  end

  local function setup(extra)
    local mine = responses or {}
    srv = mock.start(function(req, res)
      local body = vim.json.decode(req.body)
      local r = table.remove(mine, 1) or { "" }
      if r.status then
        res.json(r.status, { message = "boom" })
      elseif body.stream then
        res.stream(200, sse_fim(r), { delay = r.delay or 2 })
      else
        res.json(200, { choices = { { message = { content = table.concat(r) } } } })
      end
    end)
    local opts = vim.tbl_deep_extend("force", {
      ai = { providers = { mock = { kind = "fim", service = "mistral", url = srv.url, model = "m", api_key = false } } },
      complete = {
        provider = "mock",
        debounce = 10,
        context = { neighbors = false, recent_edits = false, ring = false, diagnostics = false },
      },
    }, extra or {})
    require("slop").setup(opts)
    assert(require("slop.core.registry").load("complete"))
    engine = require("slop.modules.complete.engine")
    ghost = require("slop.core.ui.ghost")
  end

  local function open(lines, name, ft)
    local path = h.tmpdir("c") .. "/" .. (name or "main.lua")
    h.write(path, table.concat(lines, "\n") .. "\n")
    vim.cmd.edit(vim.fn.fnameescape(path))
    buf = api.nvim_get_current_buf()
    vim.bo[buf].filetype = ft or "lua"
    return buf
  end

  local function text()
    local g = ghost.get(buf)
    return g and g.text or nil
  end

  local function wait_ghost(expected, settled)
    local ok = vim.wait(3000, function()
      return text() == expected and (not settled or engine.status(buf).state ~= "loading")
    end, 5)
    assert(ok, ("ghost: expected %s, got %s"):format(vim.inspect(expected), vim.inspect(text())))
  end

  local function type_text(s)
    local r, c = unpack(api.nvim_win_get_cursor(0))
    local lines = vim.split(s, "\n", { plain = true })
    api.nvim_buf_set_text(buf, r - 1, c, r - 1, c, lines)
    local nr = r - 1 + #lines - 1
    local nc = #lines == 1 and c + #s or #lines[#lines]
    api.nvim_win_set_cursor(0, { nr + 1, nc })
    engine.sync(buf)
  end

  --- run fn in insert mode (append at cursor); errors are re-raised after <Esc>
  local function insert(fn, keys)
    local err
    vim.keymap.set("i", "<F12>", function()
      local ok, e = xpcall(fn, debug.traceback)
      if not ok then
        err = e
      end
    end)
    h.feed((keys or "A") .. "<F12><Esc>")
    if err then
      error(err, 0)
    end
  end

  local function lines()
    return api.nvim_buf_get_lines(buf, 0, -1, false)
  end

  before_each(function()
    h.reset()
    vim.notify = function() end
    vim.cmd("silent! %bwipeout!")
    responses = nil
    package.loaded["cmp"] = nil
  end)
  after_each(function()
    if engine then
      engine.teardown()
    end
    if srv then
      srv.stop()
      srv = nil
    end
  end)

  it("auto-triggers after the debounce, streams into ghost text, sends prefix/suffix", function()
    responses = { { "foo", "(bar)" } }
    setup()
    local started, finished = 0, nil
    require("slop.core.events").on("complete", "RequestStarted", function()
      started = started + 1
    end)
    require("slop.core.events").on("complete", "RequestFinished", function(d)
      finished = d
    end)
    open({ "local x = ", "return x" })
    api.nvim_win_set_cursor(0, { 1, 9 })
    insert(function()
      engine.sync(buf)
      wait_ghost("foo(bar)")
      assert.is_true(engine.visible(buf))
      vim.wait(50, function()
        return finished ~= nil
      end)
    end)
    assert.equal(1, started)
    assert.is_true(finished.ok)
    assert.equal(1, #srv.requests)
    local body = vim.json.decode(srv.requests[1].body)
    assert.matches("local x = $", body.prompt)
    assert.matches("^%-%- Path: ", body.prompt)
    assert.equal("\nreturn x", body.suffix)
    assert.are.same({ "\n\n" }, body.stop)
    assert.equal(256, body.max_tokens)
    assert.is_true(body.stream)
    -- InsertLeave clears
    assert.is_false(ghost.is_visible(buf))
  end)

  it("typed-through keeps the suggestion without new requests; accept inserts; full accept re-triggers", function()
    responses = { { "foo(bar)" }, { "" } }
    setup()
    open({ "local x = " })
    insert(function()
      engine.sync(buf)
      wait_ghost("foo(bar)")
      type_text("fo")
      assert.equal("o(bar)", text())
      assert.equal(1, #srv.requests)
      assert.is_true(engine.accept_word())
      assert.equal("(bar)", text())
      assert.is_true(engine.accept())
      assert.is_false(ghost.is_visible(buf))
      -- a new request is scheduled from the new position
      vim.wait(1000, function()
        return #srv.requests == 2
      end)
      assert.equal(2, #srv.requests)
    end)
    assert.are.same({ "local x = foo(bar)" }, lines())
  end)

  it("accept_line walks a multi-line suggestion; undo removes one accept", function()
    responses = { { "if a then\n  b()\nend" } }
    setup({ complete = { cache = false } })
    open({ "" })
    vim.bo[buf].undolevels = 100
    insert(function()
      engine.sync(buf)
      wait_ghost("if a then\n  b()\nend")
      assert.is_true(engine.accept_line())
      assert.equal("\n  b()\nend", text())
      assert.is_true(engine.accept_n_lines(2))
      assert.is_false(engine.visible(buf))
    end, "i")
    assert.are.same({ "if a then", "  b()", "end" }, lines())
    vim.cmd("silent normal! u")
    assert.are.same({ "if a then" }, lines())
  end)

  it("dismiss clears and suppresses until the next change; actions return false when nothing is visible", function()
    responses = { { "xyz" } }
    setup()
    open({ "a = " })
    insert(function()
      assert.is_false(engine.accept())
      assert.is_false(engine.next())
      assert.is_false(engine.dismiss())
      engine.sync(buf)
      wait_ghost("xyz")
      assert.is_true(engine.dismiss())
      assert.is_false(ghost.is_visible(buf))
      engine.sync(buf) -- CursorMovedI without a change: no new request
      vim.wait(80)
      assert.equal(1, #srv.requests)
    end)
  end)

  it("next fetches an alternative lazily (non-streamed, higher temperature); prev wraps; counter shown", function()
    responses = { { "one" }, { "two" }, { "one" } }
    setup()
    open({ "v = " })
    insert(function()
      engine.sync(buf)
      wait_ghost("one")
      assert.is_true(engine.next())
      wait_ghost("two")
      local m = api.nvim_buf_get_extmarks(buf, require("slop.core.util").ns("ghost"), 0, -1, { details = true })[1]
      assert.equal(" (2/2)", m[4].virt_text[2][1])
      local body = vim.json.decode(srv.requests[2].body)
      assert.is_false(body.stream)
      assert.equal(0.4, body.temperature)
      assert.is_true(engine.prev())
      assert.equal("one", text())
      assert.is_true(engine.prev())
      assert.equal("two", text())
      -- third fetch returns a duplicate -> exhausted, wraps
      assert.is_true(engine.next())
      vim.wait(1000, function()
        return #srv.requests == 3 and engine.status(buf).state ~= "loading"
      end)
      assert.equal("one", text())
      assert.is_true(engine.next())
      assert.equal(3, #srv.requests)
    end)
  end)

  it("typing away from a streaming suggestion cancels it and re-requests", function()
    responses = { { "aaa", "bbb", "ccc", "ddd", delay = 60 }, { "zzz" } }
    setup()
    open({ "q = " })
    insert(function()
      engine.sync(buf)
      wait_ghost("aaa")
      type_text("X")
      assert.is_false(ghost.is_visible(buf))
      vim.wait(1000, function()
        return text() == "zzz"
      end)
      assert.equal("zzz", text())
      assert.equal(2, #srv.requests)
    end)
  end)

  it("prefix cache serves a position again without a request", function()
    responses = { { "cached()" } }
    setup()
    open({ "z = " })
    insert(function()
      engine.sync(buf)
      wait_ghost("cached()", true)
      engine.reset(buf)
      assert.is_true(engine.trigger(buf, { manual = true }))
      assert.equal("cached()", text())
      type_text("cac")
      engine.reset(buf)
      engine.trigger(buf, { manual = true })
      assert.equal("hed()", text())
      assert.equal(1, #srv.requests)
    end)
  end)

  it("gates: blocked files, vim.b.completion=false, excluded filetypes, mid-line text, auto toggle", function()
    setup()
    open({ "TOKEN=" }, ".env", "sh")
    insert(function()
      assert.is_false(engine.trigger(buf, { manual = true }))
    end)
    open({ "x" }, "a.lua")
    vim.b[buf].completion = false
    insert(function()
      assert.is_false(engine.trigger(buf, { manual = true }))
    end)
    open({ "x" }, "b.txt", "help")
    insert(function()
      assert.is_false(engine.trigger(buf, { manual = true }))
    end)
    open({ "foo(bar)" }, "c.lua")
    api.nvim_win_set_cursor(0, { 1, 3 })
    insert(function()
      assert.is_false(engine.trigger(buf, { manual = true }))
    end, "i")
    require("slop").complete.toggle()
    open({ "y = " }, "d.lua")
    insert(function()
      engine.sync(buf)
      vim.wait(60)
      assert.is_false(ghost.is_visible(buf))
      assert.equal(false, (engine.allowed(buf, false)))
      assert.is_true((engine.allowed(buf, true)))
    end)
    assert.equal(0, #srv.requests)
  end)

  it("mid-line before closers: single-line request with a newline stop", function()
    responses = { { "a, b)\nmore" } }
    setup()
    open({ "f()" })
    api.nvim_win_set_cursor(0, { 1, 2 })
    insert(function()
      engine.trigger(buf, { manual = true })
      wait_ghost("a, b")
    end, "i")
    local body = vim.json.decode(srv.requests[1].body)
    assert.are.same({ "\n\n", "\n" }, body.stop)
    assert.equal(")", body.suffix)
  end)

  it("does not trigger over another owner's ghost text (commit)", function()
    setup()
    open({ "" }, "COMMIT_EDITMSG", "gitcommit")
    insert(function()
      ghost.show(buf, 0, 0, "feat: x", { id = "slop.commit:1" })
      assert.is_false(engine.trigger(buf, { manual = true }))
      assert.is_false(engine.accept())
      assert.equal("feat: x", text())
    end)
  end)

  it("lazy-loads on InsertEnter in a buffer opened before the plugin loaded; keymaps fall through", function()
    responses = { { "ok()" } }
    srv = mock.start(function(_, res)
      local r = table.remove(responses, 1) or { "" }
      res.stream(200, sse_fim(r))
    end)
    h.source_plugin()
    require("slop").setup({
      ai = { providers = { mock = { kind = "fim", service = "mistral", url = srv.url, model = "m", api_key = false } } },
      complete = { provider = "mock", debounce = 10 },
    })
    open({ "", "below" })
    api.nvim_win_set_cursor(0, { 1, 0 })
    assert.is_false(require("slop.core.registry").is_loaded("complete"))
    ghost = require("slop.core.ui.ghost")
    vim.keymap.set("i", "<F11>", function()
      vim.wait(3000, function()
        return text() == "ok()"
      end, 5)
    end)
    -- <C-e> with nothing visible falls through to native (inserts the char below); then the suggestion is accepted
    h.feed("i<C-e><Esc>")
    assert.are.same({ "b", "below" }, lines())
    engine = require("slop.modules.complete.engine")
    api.nvim_buf_set_lines(buf, 0, 1, false, { "" })
    api.nvim_win_set_cursor(0, { 1, 0 })
    h.feed("i<F11><C-y><Esc>")
    assert.are.same({ "ok()", "below" }, lines())
  end)

  it("cmp source: pcall-registered when cmp is loaded; serves the engine's items", function()
    responses = { { "from_engine" } }
    local registered = {}
    package.loaded["cmp"] = {
      register_source = function(name, src)
        registered[name] = src
      end,
      visible = function()
        return false
      end,
    }
    setup({ complete = { frontend = "both" } })
    assert.not_nil(registered.slop)
    local src = registered.slop
    assert.equal("slop", src:get_debug_name())
    open({ "w = " })
    local got
    insert(function()
      engine.sync(buf)
      wait_ghost("from_engine")
      src:complete({ context = { bufnr = buf, option = {} } }, function(res)
        got = res
      end)
    end)
    assert.equal(1, #got.items)
    assert.equal("from_engine", got.items[1].insertText)
    assert.equal("from_engine", got.items[1].label)
    assert.is_true(got.isIncomplete)
  end)

  it("cmp-only frontend: no ghost, the source drives a request", function()
    responses = { { "menu_item\nsecond" } }
    package.loaded["cmp"] = {
      register_source = function(_, src)
        package.loaded["cmp"].src = src
      end,
    }
    setup({ complete = { frontend = "cmp" } })
    open({ "m = " })
    local got
    insert(function()
      engine.sync(buf)
      vim.wait(60)
      assert.equal(0, #srv.requests)
      package.loaded["cmp"].src:complete({ context = { bufnr = buf, option = { reason = "manual" } } }, function(res)
        got = res
      end)
      vim.wait(2000, function()
        return got ~= nil
      end)
      assert.is_false(ghost.is_visible(buf))
    end)
    assert.equal("menu_item …", got.items[1].label)
    assert.equal("menu_item\nsecond", got.items[1].insertText)
  end)

  it("missing API key: one notification, no request, never throws", function()
    vim.uv.os_unsetenv("NOPE_KEY")
    setup({ ai = { providers = { mock = { api_key = "NOPE_KEY" } } } })
    local notes = {}
    vim.notify = function(msg)
      notes[#notes + 1] = msg
    end
    open({ "k = " })
    insert(function()
      engine.trigger(buf, { manual = true })
      vim.wait(100)
      engine.trigger(buf, { manual = true })
      vim.wait(100)
    end)
    assert.equal(0, #srv.requests)
    assert.equal(1, #notes)
    assert.matches("NOPE_KEY is not set", notes[1])
  end)

  it("commands, api and health", function()
    h.source_plugin()
    setup()
    local c = require("slop")
    assert.is_true(c.complete.is_enabled())
    vim.cmd("Slop complete disable")
    assert.is_false(c.complete.is_enabled())
    vim.cmd("Slop complete enable")
    open({ "x" })
    vim.cmd("Slop complete toggle buffer")
    assert.is_false(c.complete.is_enabled())
    assert.is_true(engine.auto)
    vim.cmd("Slop complete provider codestral")
    assert.equal("codestral", c.complete.status().provider)
    assert.are.same(
      { "codestral", "mistral_chat", "mock" },
      require("slop.core.commands").complete("", "Slop complete provider ", 23)
    )
    local spec = require("slop.modules.complete")
    local ok = pcall(spec.health)
    assert.is_true(ok)
  end)

  local function wait_settled(n)
    vim.wait(2000, function()
      return #srv.requests == n and engine.status(buf).state ~= "loading"
    end, 5)
    vim.wait(20)
  end

  it("an empty response does not stop suggestions: typing on requests again", function()
    responses = { { "" }, { "second()" } }
    setup()
    open({ "local x = " })
    insert(function()
      engine.sync(buf)
      wait_settled(1)
      type_text("f")
      wait_ghost("second()")
    end)
    assert.equal(2, #srv.requests)
  end)

  it("a failed request (HTTP 500) does not stop suggestions either", function()
    responses = { { status = 500 }, { "second()" } }
    setup()
    open({ "local x = " })
    insert(function()
      engine.sync(buf)
      wait_settled(1)
      type_text("f")
      wait_ghost("second()")
    end)
    assert.equal(2, #srv.requests)
  end)

  it("a streamed candidate that post-processing rejects is not shown (duplicate of the next line)", function()
    responses = { { "\nreturn x" } }
    setup({ complete = { cache = false } })
    open({ "local x = ", "return x" })
    api.nvim_win_set_cursor(0, { 1, 9 })
    insert(function()
      engine.sync(buf)
      wait_settled(1)
      assert.is_nil(text())
      assert.is_false(engine.accept())
    end)
    assert.are.same({ "local x = ", "return x" }, lines())
  end)

  it("every RequestStarted gets a RequestFinished, also when typing cancels the request", function()
    responses = { { "aaa", "bbb", "ccc", "ddd", delay = 60 }, { "zzz" } }
    setup()
    local started, finished = {}, {}
    require("slop.core.events").on("complete", "RequestStarted", function(d)
      started[#started + 1] = d.id
    end)
    require("slop.core.events").on("complete", "RequestFinished", function(d)
      finished[#finished + 1] = d
    end)
    open({ "q = " })
    insert(function()
      engine.sync(buf)
      wait_ghost("aaa")
      type_text("X") -- stale while streaming: cancelled
      wait_ghost("zzz", true)
    end)
    assert.equal(2, #started)
    assert.are.same(
      started,
      vim.tbl_map(function(d)
        return d.id
      end, finished)
    )
    assert.is_false(finished[1].ok)
    assert.equal("cancelled", finished[1].error)
    assert.is_true(finished[2].ok)
  end)

  it("<M-n> + a non-digit: the key goes back in front of pending typeahead, multibyte intact", function()
    responses = { { "if a then\n  b()\nend" } }
    setup({ complete = { cache = false } })
    open({ "" })
    insert(function()
      engine.sync(buf)
      wait_ghost("if a then\n  b()\nend")
      -- typeahead as during a macro replay: <M-n> — z <Esc> ("—" is E2 80 94: contains K_SPECIAL)
      api.nvim_feedkeys("—z", "mti", true)
      api.nvim_feedkeys(vim.keycode("<M-n>"), "mti", false)
    end, "i")
    assert.are.same({ "if a then—z" }, lines())
  end)

  describe("native popup menu visible (0.12 'autocomplete', i_CTRL-N, omnifunc)", function()
    local probes, calls
    local function spy(name)
      local orig = engine[name]
      engine[name] = function(...)
        calls[#calls + 1] = name
        return orig(...)
      end
    end
    local function prepare()
      responses = { { "ghost_text()" } }
      setup({ complete = { cache = false } })
      open({ "x = " })
      probes, calls = {}, {}
      spy("next")
      spy("dismiss")
      spy("accept")
      vim.keymap.set("i", "<F10>", function()
        probes[#probes + 1] = { line = api.nvim_get_current_line(), pum = vim.fn.pumvisible() }
      end)
    end
    after_each(function()
      vim.o.completeopt = "menu,popup"
    end)

    it("<C-n>, <C-y> (item selected) and <C-e> go to the menu, not to the ghost", function()
      prepare()
      insert(function()
        engine.sync(buf)
        wait_ghost("ghost_text()")
        vim.fn.complete(vim.fn.col("."), { "alpha", "beta" }) -- inserts and selects "alpha"
        -- queued in reverse: "i" inserts at the front of the typeahead
        api.nvim_feedkeys(vim.keycode("<F10><C-y><F10>"), "mti", false)
        -- <C-n> through slop's map (Vim leaves it unmapped in complete() mode, 'autocomplete' maps it)
        vim.fn.maparg("<C-n>", "i", false, true).callback()
      end)
      assert.are.same({ { line = "x = beta", pum = 1 }, { line = "x = beta", pum = 0 } }, probes)
      assert.are.same({}, calls)

      prepare()
      insert(function()
        engine.sync(buf)
        wait_ghost("ghost_text()")
        vim.fn.complete(vim.fn.col("."), { "alpha", "beta" })
        api.nvim_feedkeys(vim.keycode("<C-e><F10>"), "mti", false)
      end)
      assert.are.same({ { line = "x = ", pum = 0 } }, probes) -- the menu closed and restored the typed text
      assert.are.same({}, calls)
    end)

    it("<C-y> still accepts the ghost when no menu item is selected", function()
      prepare()
      vim.o.completeopt = "menu,noselect"
      insert(function()
        engine.sync(buf)
        wait_ghost("ghost_text()")
        vim.fn.complete(vim.fn.col("."), { "alpha", "beta" })
        api.nvim_feedkeys(vim.keycode("<C-y><F10>"), "mti", false)
      end)
      assert.are.same({ { line = "x = ghost_text()", pum = 0 } }, probes)
      assert.are.same({ "accept" }, calls)
    end)
  end)

  it("disabling the module unregisters the nvim-cmp source", function()
    local src, unregistered = nil, {}
    package.loaded["cmp"] = {
      register_source = function(_, s)
        src = s
        return 7
      end,
      unregister_source = function(id)
        unregistered[#unregistered + 1] = id
      end,
    }
    setup({ complete = { frontend = "cmp" } })
    open({ "m = " })
    assert.is_true(src:is_available())
    require("slop.core.registry").disable("complete")
    assert.are.same({ 7 }, unregistered)
    assert.is_false(src:is_available())
    -- a cmp that kept the source object anyway gets nothing, and nothing is sent
    local got
    insert(function()
      src:complete({ context = { bufnr = buf, option = { reason = "manual" } } }, function(res)
        got = res
      end)
      vim.wait(100)
    end)
    assert.are.same({}, got.items)
    assert.equal(0, #srv.requests)
  end)

  it("health never prints an api_key value that is not an env var name", function()
    local orig = vim.health
    for _, pasted in ipairs({ "sk-live-PASTED0123456789abcdef", "aB3dE5fG7hJ9kL1mN3pQ5rS7tU9vW1xY" }) do
      require("slop").setup({
        ai = {
          providers = {
            p = { kind = "fim", service = "mistral", url = "http://127.0.0.1:9", model = "m", api_key = pasted },
          },
        },
        complete = { provider = "p" },
      })
      local out = {}
      vim.health = setmetatable({}, {
        __index = function(_, kind)
          return function(msg, advice)
            out[#out + 1] = kind .. ": " .. tostring(msg) .. " " .. vim.inspect(advice)
          end
        end,
      })
      local ok, err = pcall(require("slop.modules.complete").health)
      vim.health = orig
      assert(ok, err)
      local all = table.concat(out, "\n")
      assert.is_nil(all:find(pasted, 1, true), all)
      assert.matches(pasted:find("-", 1, true) and "environment variable NAME" or "named by api_key", all)
    end
  end)
end)

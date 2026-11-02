local h = require("helpers")

local function wait(fn, ms)
  return vim.wait(ms or 3000, fn, 10)
end

local function buf_text(buf)
  return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
end

describe("core.term", function()
  local term, api, events

  before_each(function()
    h.reset()
    vim.notify = function() end
    pcall(vim.cmd, "silent! only")
    vim.o.columns, vim.o.lines = 120, 40
    term = require("slop.core.term")
    events = require("slop.core.events")
    api = vim.api
  end)

  after_each(function()
    for _, t in ipairs(term.list({ hidden = true })) do
      t:kill()
    end
  end)

  it("spawns hidden: terminal buffer, job running, not shown, Open event", function()
    local ev
    events.on("term", "Open", function(d)
      ev = d
    end)
    local t = assert(term.spawn({ cmd = { "sh" }, cwd = h.tmpdir("t") }))
    assert.equal(1, t.id)
    assert.equal("sh", t.name)
    assert.equal("terminal", vim.bo[t.buf].buftype)
    assert.equal("hide", vim.bo[t.buf].bufhidden)
    assert.equal("slopterm", vim.bo[t.buf].filetype)
    assert.equal(1, vim.b[t.buf].slop_term)
    assert.is_true(t:is_running())
    assert.is_false(t:is_visible())
    wait(function()
      return ev ~= nil
    end)
    assert.are.same({ id = 1, name = "sh", owner = "term" }, ev)
    assert.equal(t, term.get(1))
    assert.equal(t, term.get("sh"))
    assert.equal(t, term.from_buf(t.buf))
  end)

  it("reports an error for a non-executable command", function()
    local t, err = term.spawn({ cmd = { "/nonexistent/slop-cmd" } })
    assert.is_nil(t)
    assert.truthy(err)
    assert.equal(0, #term.list({ hidden = true }))
  end)

  it("show/hide/toggle keep the job and scrollback", function()
    local t = assert(term.spawn({ cmd = { "sh" } }))
    local buf, job = t.buf, t.job
    t:show()
    assert.is_true(t:is_visible())
    assert.equal("float", t:layout_of())
    assert.equal(buf, api.nvim_get_current_buf())
    assert.is_true(vim.wo.winfixbuf)
    local c = api.nvim_win_get_config(t.win)
    assert.equal(" sh ", c.title[1][1])
    t:hide()
    assert.is_false(t:is_visible())
    assert.is_true(t:is_running())
    t:toggle()
    assert.is_true(t:is_visible())
    assert.equal(buf, t.buf)
    assert.equal(job, t.job)
    t:toggle()
    assert.is_false(t:is_visible())
    assert.is_true(api.nvim_buf_is_valid(buf))
  end)

  it("hide returns to the origin window", function()
    local origin = api.nvim_get_current_win()
    local t = assert(term.spawn({ cmd = { "sh" } }))
    t:show()
    assert.not_equal(origin, api.nvim_get_current_win())
    t:hide()
    assert.equal(origin, api.nvim_get_current_win())
  end)

  it("switches layouts (moves the window, same job)", function()
    local t = assert(term.spawn({ cmd = { "sh" } }))
    local job = t.job
    t:show({ layout = "float" })
    t:toggle({ layout = "split" })
    local wins = t:windows()
    assert.equal(1, #wins)
    assert.equal("split", t:layout_of(wins[1]))
    assert.is_false(require("slop.core.ui.float").is_float(wins[1]))
    assert.is_true(vim.wo[wins[1]].winfixheight)
    assert.equal(math.floor(40 * 0.3), api.nvim_win_get_height(wins[1]))
    t:toggle({ layout = "vsplit" })
    wins = t:windows()
    assert.equal(1, #wins)
    assert.equal("vsplit", t:layout_of(wins[1]))
    assert.equal(job, t.job)
    -- same layout again => hide
    t:toggle({ layout = "vsplit" })
    assert.is_false(t:is_visible())
    assert.equal(1, #api.nvim_tabpage_list_wins(0))
  end)

  it("reuses the layout slot (one float window) for another terminal", function()
    local a = assert(term.spawn({ cmd = { "sh" }, name = "a" }))
    local b = assert(term.spawn({ cmd = { "sh" }, name = "b" }))
    a:show()
    local win = a.win
    b:show()
    assert.equal(win, b.win)
    assert.is_false(a:is_visible())
    assert.equal(" b ", api.nvim_win_get_config(win).title[1][1])
    assert.equal(b, term.last())
  end)

  it("hiding the last window of a tab keeps the window", function()
    local t = assert(term.spawn({ cmd = { "sh" } }))
    t:show({ layout = "split" })
    vim.cmd("only")
    assert.equal(1, #api.nvim_tabpage_list_wins(0))
    t:hide()
    assert.equal(1, #api.nvim_tabpage_list_wins(0))
    assert.not_equal(t.buf, api.nvim_get_current_buf())
    assert.is_true(t:is_running())
  end)

  it("send: encodes plain lines, dedent and bracketed paste", function()
    assert.equal("ls\r", term.encode("ls"))
    assert.equal("ls\r", term.encode("ls\n"))
    assert.equal("ls", term.encode("ls", { submit = false }))
    assert.equal("\27[200~a\r  b\27[201~\r", term.encode({ "  a", "    b" }))
    assert.equal("a\r  b\r", term.encode({ "  a", "    b" }, { paste = false }))
    assert.equal("  a\r", term.encode({ "  a" }, { dedent = false }))
    assert.equal("\27[200~x\27[201~\r", term.encode("x", { paste = true }))
  end)

  it("send: delivers text to the job", function()
    local t = assert(term.spawn({ cmd = { "sh" } }))
    assert.is_true(t:send("echo slop-$((40+2))"))
    assert.truthy(wait(function()
      return buf_text(t.buf):find("slop%-42") ~= nil
    end))
    t:send({ "echo one", "echo two" }, { paste = false, show = true })
    assert.truthy(wait(function()
      return buf_text(t.buf):find("two\n") ~= nil or buf_text(t.buf):find("\ntwo") ~= nil
    end))
    assert.is_true(t:is_visible())
  end)

  it("exit cleanup: close_on_exit wipes and unregisters, emits Exit", function()
    local ev
    events.on("term", "Exit", function(d)
      ev = d
    end)
    local t = assert(term.spawn({ cmd = { "sh" } }))
    local buf = t.buf
    t:show()
    t:send("exit 0")
    assert.truthy(wait(function()
      return not api.nvim_buf_is_valid(buf) and ev ~= nil
    end))
    assert.equal(0, ev.code)
    assert.equal(0, #term.list())
    assert.equal(1, #api.nvim_tabpage_list_wins(0))
  end)

  it("exit: close_on_exit=false / 'success' keep the buffer on failure", function()
    local codes = {}
    local a = assert(term.spawn({
      cmd = { "sh", "-c", "exit 3" },
      close_on_exit = false,
      on_exit = function(_, c)
        codes[#codes + 1] = c
      end,
    }))
    local b = assert(term.spawn({ cmd = { "sh", "-c", "exit 4" }, close_on_exit = "success" }))
    local c = assert(term.spawn({ cmd = { "sh", "-c", "exit 0" }, close_on_exit = "success" }))
    local cbuf = c.buf
    assert.truthy(wait(function()
      return a.exit_code ~= nil and b.exit_code ~= nil and not api.nvim_buf_is_valid(cbuf)
    end))
    assert.equal(3, a.exit_code)
    assert.are.same({ 3 }, codes)
    assert.is_true(api.nvim_buf_is_valid(a.buf))
    assert.is_true(api.nvim_buf_is_valid(b.buf))
    assert.is_false(a:is_running())
    assert.equal(a, term.get(a.id))
    assert.is_nil(term.get(c.id))
    assert.is_false(a:send("x"))
  end)

  it("kill wipes the buffer and unregisters; ids are gap-filling", function()
    local a = assert(term.spawn({ cmd = { "sh" } }))
    local b = assert(term.spawn({ cmd = { "sh" } }))
    assert.equal(2, b.id)
    local buf = a.buf
    a:show()
    a:kill()
    assert.is_false(api.nvim_buf_is_valid(buf))
    assert.is_nil(term.get(1))
    local c = assert(term.spawn({ cmd = { "sh" } }))
    assert.equal(1, c.id)
  end)

  it("list filters hidden and owner", function()
    term.spawn({ cmd = { "sh" }, owner = "task", hidden = true })
    term.spawn({ cmd = { "sh" } })
    assert.equal(1, #term.list())
    assert.equal(2, #term.list({ hidden = true }))
    assert.equal(1, #term.list({ hidden = true, owner = "task" }))
  end)

  it("hide_on_leave hides the float when focus leaves; mode is remembered", function()
    local origin = api.nvim_get_current_win()
    local t = assert(term.spawn({ cmd = { "sh" }, hide_on_leave = true }))
    t:show()
    assert.equal("t", t.mode)
    api.nvim_set_current_win(origin)
    assert.truthy(wait(function()
      return not t:is_visible()
    end))
    assert.is_true(t:is_running())
  end)

  it("kill() + show() restarts the terminal; the old job's exit does not touch the new one", function()
    local exits = {}
    events.on("term", "Exit", function(d)
      if d.name == "runner" then
        exits[#exits + 1] = d.code
      end
    end)
    local t = assert(term.spawn({ cmd = { "sh" }, name = "runner" }))
    local old_job = t.job
    t:kill()
    t:show({ enter = false })
    local job, buf = t.job, t.buf
    assert.not_equal(old_job, job)
    vim.wait(800) -- the killed job's exit arrives meanwhile
    assert.is_true(api.nvim_buf_is_valid(buf))
    assert.equal(buf, t.buf)
    assert.is_nil(t.exit_code)
    assert.is_true(t:is_running())
    assert.equal(t, term.get(t.id))
    assert.are.same({}, exits)
  end)

  it("a restarted terminal whose id was taken meanwhile gets a new id", function()
    local a = assert(term.spawn({ cmd = { "sh", "-c", "exit 0" }, name = "task" }))
    assert.truthy(wait(function()
      return term.get(a.id) == nil
    end))
    local b = assert(term.spawn({ cmd = { "sh" }, name = "shell" }))
    assert.equal(a.id, b.id) -- ids are gap-filling
    a:show({ enter = false })
    assert.not_equal(a.id, b.id)
    assert.equal(a, term.get(a.id))
    assert.equal(b, term.get(b.id))
    assert.equal(b, term.from_buf(b.buf))
    assert.equal(a, term.from_buf(a.buf))
    assert.equal(2, #term.list({ hidden = true }))
  end)

  it("a hidden spawn does not leave the current window in Insert mode (user TermOpen startinsert)", function()
    -- needs Neovim's main loop (startinsert takes effect there): drive a child nvim over RPC
    local chan = vim.fn.jobstart(
      { vim.v.progpath, "--embed", "--headless", "--clean", "-u", "NONE", "--cmd", "set rtp^=" .. h.root },
      { rpc = true }
    )
    local ok, err = pcall(function()
      vim.rpcrequest(
        chan,
        "nvim_exec_lua",
        [[
        vim.api.nvim_create_autocmd("TermOpen", { command = "startinsert" })
        local t = require("slop.core.term").spawn({ cmd = { "sh" }, cwd = vim.fn.getcwd() })
        t:send("echo hi")
        t:show({ layout = "split", enter = false })
      ]],
        {}
      )
      vim.wait(300)
      local mode = vim.rpcrequest(chan, "nvim_get_mode").mode
      local bt = vim.rpcrequest(chan, "nvim_exec_lua", "return vim.bo.buftype", {})
      assert.equal("n", mode)
      assert.equal("", bt, "focus stays in the source window")
    end)
    vim.fn.jobstop(chan)
    assert(ok, err)
  end)

  --- Run `code` in a child nvim (its main loop applies a pending startinsert) and return the child's mode and the
  --- 'buftype' of its current window afterwards. `keys` are typed first.
  local function in_child(code, keys)
    local chan = vim.fn.jobstart(
      { vim.v.progpath, "--embed", "--headless", "--clean", "-u", "NONE", "--cmd", "set rtp^=" .. h.root },
      { rpc = true }
    )
    local ok, res = pcall(function()
      if keys then
        vim.rpcrequest(chan, "nvim_input", keys)
        vim.wait(100)
      end
      vim.rpcrequest(chan, "nvim_exec_lua", code, {})
      vim.wait(300)
      return {
        mode = vim.rpcrequest(chan, "nvim_get_mode").mode,
        buftype = vim.rpcrequest(chan, "nvim_exec_lua", "return vim.bo.buftype", {}),
      }
    end)
    vim.fn.jobstop(chan)
    assert(ok, res)
    return res
  end

  it("a terminal shown with startinsert and closed in the same tick leaves no Insert mode behind", function()
    local spawn = 'local t = require("slop.core.term").spawn({ cmd = { "sh" }, cwd = vim.fn.getcwd() })\n'
    assert.are.same({ mode = "t", buftype = "terminal" }, in_child(spawn .. "t:show()"), "show() alone")
    local normal = { mode = "n", buftype = "" }
    assert.are.same(normal, in_child(spawn .. "t:show()\nt:kill()"), "show + kill")
    assert.are.same(normal, in_child(spawn .. 't:show({ layout = "split" })\nt:kill()'), "split: show + kill")
    assert.are.same(normal, in_child(spawn .. "t:show()\nvim.api.nvim_win_close(t.win, true)"), "window closed")
    assert.are.same(
      normal,
      in_child(spawn .. "local o = vim.api.nvim_get_current_win()\nt:show()\nvim.api.nvim_set_current_win(o)"),
      "focus moved back"
    )
    -- an Insert mode the user is in is left alone
    assert.are.same({ mode = "i", buftype = "" }, in_child(spawn .. "t:show()\nt:kill()", "i"), "user's Insert mode")
    -- a hidden spawn in the same tick does not cancel show()'s Terminal mode
    assert.are.same(
      { mode = "t", buftype = "terminal" },
      in_child(spawn .. 't:show()\nrequire("slop.core.term").spawn({ cmd = { "sh" }, hidden = true })'),
      "show + hidden spawn"
    )
  end)

  it(
    "close_on_exit = false keeps a 'shell' terminal that exits 0 (Neovim's TermClose default would delete it)",
    function()
      local shell = vim.o.shell
      vim.o.shell = vim.fn.exepath("sh") -- 'shell' is normally an absolute path ($SHELL)
      local ok, err = pcall(function()
        local t = assert(term.spawn({ cmd = { vim.o.shell }, close_on_exit = false }))
        local buf = t.buf
        t:show({ layout = "split" })
        t:send("exit 0")
        assert.truthy(wait(function()
          return t.exit_code ~= nil
        end))
        vim.wait(100)
        assert.equal(0, t.exit_code)
        assert.is_true(api.nvim_buf_is_valid(buf))
        assert.equal(t, term.get(t.id))
        -- the default still applies to other terminals
        vim.cmd("botright new | terminal")
        local tbuf = api.nvim_get_current_buf()
        api.nvim_chan_send(vim.bo[tbuf].channel, "exit 0\r")
        assert.truthy(wait(function()
          return not api.nvim_buf_is_valid(tbuf)
        end))
      end)
      vim.o.shell = shell
      assert(ok, err)
    end
  )

  it("the default cmd honours a 'shell' with arguments; start errors carry no traceback", function()
    local shell = vim.o.shell
    vim.o.shell = "sh -e"
    local t, err = term.spawn({ cwd = h.tmpdir("t") })
    vim.o.shell = shell
    assert.truthy(t, err)
    assert.are.same({ "sh", "-e" }, t.cmd)
    assert.is_true(t:is_running())
    local bad, e = term.spawn({ cmd = { "/nonexistent/slop-cmd" } })
    assert.is_nil(bad)
    assert.falsy(e:find("traceback", 1, true), e)
    assert.matches("not executable", e)
  end)

  it("multi-line send: bracketed paste markers only when the program enabled bracketed paste", function()
    local dir = h.tmpdir("paste")
    local function received(enable)
      local file = dir .. (enable and "/on" or "/off")
      local script = "stty -echo; " .. (enable and "printf '\\033[?2004h'; " or "") .. "cat > " .. file
      local t = assert(term.spawn({ cmd = { "sh", "-c", script }, close_on_exit = false }))
      vim.wait(300)
      assert.is_true(t:send({ "echo one", "echo two" }))
      vim.wait(100)
      vim.fn.chansend(t.job, "\4")
      assert.truthy(wait(function()
        return t.exit_code ~= nil
      end))
      return table.concat(vim.fn.readfile(file, "b"), "\n")
    end
    assert.equal("echo one\necho two\n", received(false))
    assert.equal("\27[200~echo one\necho two\27[201~\n", received(true))
  end)

  it("a terminal shown in another terminal's float slot gets its own window options and size", function()
    local a = assert(term.spawn({ cmd = { "sh" }, name = "a", wo = { winhighlight = "Normal:ErrorMsg" } }))
    local b = assert(term.spawn({
      cmd = { "sh" },
      name = "b",
      wo = { winhighlight = "Normal:DiffAdd", winblend = 30 },
      float = { width = 50, height = 10 },
    }))
    a:show()
    assert.equal("Normal:ErrorMsg", vim.wo[a.win].winhighlight)
    b:show()
    assert.equal(a.win, b.win)
    assert.equal("Normal:DiffAdd", vim.wo[b.win].winhighlight)
    assert.equal(30, vim.wo[b.win].winblend)
    assert.equal(50, api.nvim_win_get_width(b.win))
    assert.equal(10, api.nvim_win_get_height(b.win))
    assert.is_true(vim.wo[b.win].winfixbuf)
    a:show()
    assert.equal("Normal:ErrorMsg", vim.wo[a.win].winhighlight)
    assert.equal(0, vim.wo[a.win].winblend)
    assert.not_equal(50, api.nvim_win_get_width(a.win), "b's float size does not stick")
  end)

  it("float is resized on VimResized", function()
    local t = assert(term.spawn({
      cmd = { "sh" },
      float = {
        width = function(c)
          return c - 20
        end,
        height = function(_, l)
          return l - 10
        end,
      },
    }))
    t:show()
    assert.equal(100, api.nvim_win_get_width(t.win))
    vim.o.columns, vim.o.lines = 90, 30
    api.nvim_exec_autocmds("VimResized", {})
    assert.equal(70, api.nvim_win_get_width(t.win))
    assert.equal(20, api.nvim_win_get_height(t.win))
  end)
end)

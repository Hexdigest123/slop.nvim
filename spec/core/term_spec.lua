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

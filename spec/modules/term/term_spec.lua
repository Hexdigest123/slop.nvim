local h = require("helpers")

local function wait(fn, ms)
  return vim.wait(ms or 3000, fn, 10)
end

local function buf_text(buf)
  return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
end

describe("term module", function()
  local api, slop, root

  before_each(function()
    h.reset()
    vim.notify = function() end
    pcall(vim.cmd, "silent! %bwipeout!")
    pcall(vim.cmd, "silent! only")
    vim.o.columns, vim.o.lines = 120, 40
    root = h.tmpdir("proj")
    vim.fn.mkdir(root .. "/.git", "p")
    vim.fn.mkdir(root .. "/sub", "p")
    vim.cmd.cd(root .. "/sub")
    h.source_plugin()
    slop = require("slop")
    slop.setup({ term = { shell = "sh" } })
    api = vim.api
  end)

  after_each(function()
    local core = package.loaded["slop.core.term"]
    for _, t in ipairs(core and core.list({ hidden = true }) or {}) do
      t:kill()
    end
  end)

  it("is not loaded until used; manifest keys map to <Plug>", function()
    assert.is_false(require("slop.core.registry").is_loaded("term"))
    assert.equal("<Plug>(slop-term-toggle)", vim.fn.maparg(" \\", "n"))
    assert.equal("<Plug>(slop-term-send)", vim.fn.maparg(" \\", "x"))
  end)

  it("<leader>\\ toggles a float shell at the project root, sized editor-20 x editor-10", function()
    h.feed(" \\")
    local t = assert(slop.term.term())
    assert.equal(root, t.cwd)
    assert.are.same({ "sh" }, t.cmd)
    assert.is_true(t:is_visible())
    local win = t:windows()[1]
    local c = api.nvim_win_get_config(win)
    assert.equal("editor", c.relative)
    assert.equal(100, c.width)
    assert.equal(30, c.height)
    assert.equal("╭", c.border[1])
    assert.equal(" sh ", c.title[1][1])
    assert.matches("FloatBorder:SlopTermBorder", vim.wo[win].winhighlight)
    assert.equal("Normal", api.nvim_get_hl(0, { name = "SlopTermNormal" }).link)
    -- <esc><esc> buffer-local terminal-mode map
    local m = vim.fn.maparg("<Esc><Esc>", "t", false, true)
    assert.equal(1, m.buffer)
    assert.equal(vim.keycode("<C-\\><C-n>"), vim.keycode(m.rhs))
  end)

  it("toggle persists the job and scrollback", function()
    local t = assert(slop.term.toggle())
    local job, buf = t.job, t.buf
    t:send("echo marker-$((6*7))")
    assert.truthy(wait(function()
      return buf_text(buf):find("marker%-42") ~= nil
    end))
    slop.term.toggle()
    assert.is_false(t:is_visible())
    assert.is_true(t:is_running())
    local t2 = slop.term.toggle()
    assert.equal(t, t2)
    assert.equal(job, t2.job)
    assert.truthy(buf_text(t2.buf):find("marker%-42"))
  end)

  it("hides when focus leaves the float and remembers the mode", function()
    local origin = api.nvim_get_current_win()
    local t = assert(slop.term.toggle())
    assert.not_equal(origin, api.nvim_get_current_win())
    vim.cmd.stopinsert()
    api.nvim_set_current_win(origin)
    assert.truthy(wait(function()
      return not t:is_visible()
    end))
    assert.equal("n", t.mode)
    assert.is_true(t:is_running())
  end)

  it("layout switch: split / vsplit keys and :Slop term toggle <layout>", function()
    local t = assert(slop.term.toggle())
    local job = t.job
    slop.term.toggle("split")
    assert.equal("split", t:layout_of())
    assert.equal(1, #t:windows())
    vim.cmd("Slop term toggle vsplit")
    assert.equal("vsplit", t:layout_of())
    assert.equal(job, t.job)
    vim.cmd("Slop term vsplit") -- default subcommand receives the layout
    assert.is_false(t:is_visible())
    h.feed(" |-")
    assert.equal("split", t:layout_of())
    -- plain toggle hides whatever is visible, then shows in config layout
    slop.term.toggle()
    assert.is_false(t:is_visible())
    slop.term.toggle()
    assert.equal("float", t:layout_of())
  end)

  it("config layout = split is used by the plain toggle", function()
    slop.setup({ term = { shell = "sh", layout = "split", split = { size = 7 } } })
    local t = assert(slop.term.toggle())
    assert.equal("split", t:layout_of())
    assert.equal(7, api.nvim_win_get_height(t:windows()[1]))
  end)

  it("unknown layout is rejected without spawning", function()
    assert.is_nil(slop.term.toggle("tab"))
    assert.is_nil(slop.term.term())
  end)

  it("send: api, :Slop term send/exec, reveal", function()
    assert.is_true(slop.term.send("echo api-$((1+1))"))
    local t = assert(slop.term.term())
    assert.is_true(t:is_visible())
    assert.truthy(wait(function()
      return buf_text(t.buf):find("api%-2") ~= nil
    end))
    t:hide()
    vim.cmd("Slop term exec echo exec-$((2+2))")
    assert.truthy(wait(function()
      return buf_text(t.buf):find("exec%-4") ~= nil
    end))
    t:hide()
    api.nvim_buf_set_lines(0, 0, -1, false, { "echo line-$((3+3))", "echo line-$((4+4))" })
    vim.cmd("1,2Slop term send")
    assert.truthy(wait(function()
      return buf_text(t.buf):find("line%-8") ~= nil
    end))
  end)

  it("<leader>\\ in visual mode sends the selection", function()
    local src = api.nvim_get_current_win()
    api.nvim_buf_set_lines(0, 0, -1, false, { "  echo vis-$((5+5))", "  echo vis-$((6+6))", "rest" })
    api.nvim_win_set_cursor(0, { 1, 0 })
    h.feed("Vj \\")
    local t = assert(slop.term.term())
    assert.truthy(wait(function()
      return buf_text(t.buf):find("vis%-12") ~= nil
    end))
    assert.truthy(buf_text(t.buf):find("vis%-10"))
    assert.is_false(buf_text(t.buf):find("rest") ~= nil)
    assert.is_true(t:is_visible())
    assert.not_equal(src, api.nvim_get_current_win()) -- float gets focus
    assert.is_nil(vim.fn.mode():match("^[vV]"))
  end)

  it("charwise selection sends only the selected text", function()
    api.nvim_buf_set_lines(0, 0, -1, false, { "xx echo cw-$((7+7)) yy" })
    api.nvim_win_set_cursor(0, { 1, 3 })
    h.feed("v15l \\")
    local t = assert(slop.term.term())
    assert.truthy(wait(function()
      return buf_text(t.buf):find("cw%-14") ~= nil
    end))
  end)

  it("exit cleanup: shell exit closes the float and wipes; next toggle respawns", function()
    local t = assert(slop.term.toggle())
    local buf, job = t.buf, t.job
    t:send("exit")
    assert.truthy(wait(function()
      return not api.nvim_buf_is_valid(buf)
    end))
    assert.is_nil(slop.term.term())
    assert.equal(1, #api.nvim_tabpage_list_wins(0))
    local t2 = assert(slop.term.toggle())
    assert.not_equal(job, t2.job)
    assert.is_true(t2:is_running())
  end)

  it(":Slop term kill", function()
    local t = assert(slop.term.toggle())
    local buf = t.buf
    vim.cmd("Slop term kill")
    assert.is_false(api.nvim_buf_is_valid(buf))
    assert.is_nil(slop.term.term())
  end)

  it("float is resized on VimResized", function()
    local t = assert(slop.term.toggle())
    vim.o.columns, vim.o.lines = 150, 50
    api.nvim_exec_autocmds("VimResized", {})
    local win = t:windows()[1]
    assert.equal(130, api.nvim_win_get_width(win))
    assert.equal(40, api.nvim_win_get_height(win))
  end)

  it("schema rejects bad options", function()
    slop.setup({ term = { layout = "tab", close_on_exit = "x", float = { width = -1 } } })
    local errs = table.concat(require("slop.config").errors("term"), "\n")
    assert.matches("term%.layout", errs)
    assert.matches("term%.close_on_exit", errs)
    assert.matches("term%.float%.width", errs)
    slop.setup({ term = { shell = { "sh", "-i" }, cwd = "cwd", close_on_exit = "success", float = { title = "T" } } })
    assert.are.same({}, require("slop.config").errors("term"))
    assert.are.same({}, require("slop.config").unknown("term"))
  end)

  it("command completion offers layouts", function()
    assert.are.same({ "split" }, require("slop.core.commands").complete("sp", "Slop term toggle sp", 0))
    local subs = require("slop.core.commands").complete("", "Slop term ", 0)
    for _, s in ipairs({ "toggle", "send", "exec", "kill" }) do
      assert.truthy(vim.tbl_contains(subs, s), s)
    end
  end)

  it("health section runs", function()
    local health = require("slop.core.registry").spec("term").health
    assert.truthy(health)
    local ok = pcall(function()
      vim.health.start("term")
      health()
    end)
    assert.is_true(ok)
  end)
end)

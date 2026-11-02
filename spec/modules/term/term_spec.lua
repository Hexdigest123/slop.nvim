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
    assert.equal(1, m.buf or m.buffer)
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

  it(":Slop term send/exec keep the text as typed; exec expands only :!-style items", function()
    local actions = require("slop.modules.term.actions")
    local sent = {}
    local orig = actions.send
    actions.send = function(data)
      sent[#sent + 1] = data
      return true
    end
    vim.cmd.edit(vim.fn.fnameescape(root .. "/sub/my file.txt"))
    vim.cmd([[Slop term send grep  -E 'a\.b|c   d' x]])
    vim.cmd([[Slop term exec printf '\%s\n' "a    b" 'c\\d' '\<w\>' %:t:S]])
    vim.cmd.enew()
    vim.cmd([[Slop term exec echo %  \%]]) -- nothing to expand `%` to: sent unexpanded
    actions.send = orig
    assert.equal([[grep  -E 'a\.b|c   d' x]], sent[1])
    assert.equal([[printf '%s\n' "a    b" 'c\\d' '\<w\>' 'my file.txt']], sent[2])
    assert.equal([[echo %  \%]], sent[3])
  end)

  it("a blockwise `$` selection sends every line to its end, like `y`", function()
    vim.cmd.stopinsert() -- a startinsert left pending by an earlier test's terminal would eat the keys below
    local actions = require("slop.modules.term.actions")
    api.nvim_buf_set_lines(
      0,
      0,
      -1,
      false,
      { "short", "a much longer line", "", "mid line", "\tx tab", "日本語テキスト" }
    )
    local in_visual
    vim.keymap.set("x", "<F3>", function()
      in_visual = actions.selection()
    end, { buf = 0 })
    -- what `y` yanks for each block: a line ending left of the block is blanks, a tab or wide char cut by the left
    -- edge becomes spaces (yanking here instead trips a headless redraw assertion of Nvim after the split tests)
    local from3 = { "ort", "much longer line", (" "):rep(17), "d line", "      x tab", "本語テキスト" }
    local cases = {
      { { 1, 2 }, "<C-v>5j$", from3 },
      { { 6, 3 }, "<C-v>5k$", from3 }, -- from inside a wide char
      { { 1, 0 }, "<C-v>5j$", { "short", "a much longer line", "", "mid line", "\tx tab", "日本語テキスト" } },
      { { 2, 4 }, "<C-v>2j$", { "ch longer line", (" "):rep(15), "line" } },
      { { 4, 1 }, "<C-v>2j$", { "id line", "       x tab", " 本語テキスト" } },
    }
    for _, c in ipairs(cases) do
      api.nvim_win_set_cursor(0, c[1])
      h.feed(c[2] .. "<F3><Esc>")
      assert.are.same(c[3], in_visual, c[2])
      assert.are.same(c[3], actions.selection(), "after Visual mode: " .. c[2])
      assert.equal("n", api.nvim_get_mode().mode)
    end
    -- without `$` the block keeps its right edge
    api.nvim_win_set_cursor(0, { 1, 1 })
    h.feed("<C-v>jl<F3><Esc>")
    assert.are.same({ "ho", " m" }, in_visual)
    assert.are.same({ "ho", " m" }, actions.selection())
  end)

  it("a kept terminal whose shell exited is replaced by toggle (once hidden) and by send", function()
    slop.setup({ term = { shell = "sh", close_on_exit = "success" } })
    local t = assert(slop.term.toggle())
    local buf = t.buf
    t:send("false; exit") -- like <C-d> after a failing command: status 1, the buffer is kept
    assert.truthy(wait(function()
      return t.exit_code ~= nil
    end))
    assert.equal(1, t.exit_code)
    assert.is_true(t:is_visible())
    slop.term.toggle() -- still shown (readable): toggle hides it
    assert.is_false(t:is_visible())
    assert.is_true(api.nvim_buf_is_valid(buf))
    local t2 = assert(slop.term.toggle()) -- hidden and exited: a new shell
    assert.not_equal(t, t2)
    assert.is_true(t2:is_running())
    assert.is_false(api.nvim_buf_is_valid(buf))
    t2:send("exit 3")
    assert.truthy(wait(function()
      return t2.exit_code ~= nil
    end))
    assert.is_true(slop.term.send("echo again-$((2+3))"))
    local t3 = assert(slop.term.term())
    assert.not_equal(t2, t3)
    assert.truthy(wait(function()
      return buf_text(t3.buf):find("again%-5") ~= nil
    end))
  end)

  it("shell strings are parsed like 'shell': arguments, program paths with spaces", function()
    local actions = require("slop.modules.term.actions")
    assert.are.same({ "sh", "-l" }, actions.shell_cmd("  sh  -l "))
    assert.are.same({ "a", "b" }, actions.shell_cmd({ "a", "b" }))
    local exe = root .. "/my tools/my sh"
    h.write(exe, '#!/bin/sh\nexec sh "$@"\n')
    vim.uv.fs_chmod(exe, 493) -- 0755
    assert.are.same({ exe }, actions.shell_cmd(exe))
    assert.are.same({ exe, "-l" }, actions.shell_cmd('"' .. exe .. '" -l'))
    local shell = vim.o.shell
    vim.o.shell = "sh -l"
    local default = actions.shell_cmd("")
    vim.o.shell = shell
    assert.are.same({ "sh", "-l" }, default)
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

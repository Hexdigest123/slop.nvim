local h = require("helpers")

local api = vim.api

local function lsp(kind, token, value, client_id)
  value.kind = kind
  api.nvim_exec_autocmds("LspProgress", {
    pattern = kind,
    modeline = false,
    data = { client_id = client_id or 7, params = { token = token, value = value } },
  })
end

local function echo(text, opts)
  return api.nvim_echo({ { text } }, false, vim.tbl_extend("force", { kind = "progress", source = "myplug" }, opts))
end

local function ai(event, data)
  api.nvim_exec_autocmds("User", { pattern = "SlopAi" .. event, modeline = false, data = data })
end

local function wait(fn, ms)
  return vim.wait(ms or 2000, fn, 10)
end

describe("progress module", function()
  local slop, p, view, clients

  local function setup(opts)
    require("slop.config").setup({ progress = opts or {} })
    p = slop.progress
    view = require("slop.modules.progress.view")
  end

  local function text()
    local buf = assert(view.buf())
    return table.concat(api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
  end

  -- the window redraws on the next tick once it is open
  local function shows(pat)
    wait(function()
      return text():match(pat) ~= nil
    end)
    return text()
  end

  before_each(function()
    h.reset()
    vim.notify = function() end
    pcall(vim.cmd, "silent! only")
    pcall(vim.cmd, "silent! tabonly")
    vim.o.columns, vim.o.lines = 100, 30
    vim.o.laststatus, vim.o.cmdheight = 2, 1
    vim.o.messagesopt = "hit-enter,history:500,progress:c"
    clients = { [7] = { name = "lua_ls", stopped = false } }
    vim.lsp.get_client_by_id = function(id)
      local c = clients[id]
      return c
          and {
            name = c.name,
            is_stopped = function()
              return c.stopped
            end,
          }
        or nil
    end
    h.source_plugin()
    slop = require("slop")
  end)

  after_each(function()
    local reg = package.loaded["slop.core.registry"]
    if reg and reg.is_loaded("progress") then
      reg.disable("progress")
    end
  end)

  it("spec is valid and not loaded at startup", function()
    local reg = require("slop.core.registry")
    local spec = assert(reg.spec("progress"))
    assert.are.same({}, reg.validate_spec(spec, "progress"))
    assert.is_false(reg.is_loaded("progress"))
  end)

  it("lazy-loads on the manifest events and handles the triggering event (replay)", function()
    -- what the lead adds to lua/slop/manifest.lua
    h.reset()
    require("slop.manifest").progress =
      { events = { "LspProgress", "Progress", "User SlopAiRequestStarted" }, cmd = true }
    h.source_plugin()
    local reg = require("slop.core.registry")
    lsp("begin", "t1", { title = "Indexing", message = "1/3" })
    assert.is_true(reg.is_loaded("progress"))
    local items = require("slop").progress.items()
    assert.equal(1, #items)
    assert.equal("lua_ls", items[1].group)
    assert.equal("Indexing", items[1].title)

    for _, trigger in ipairs({ "native", "ai" }) do
      reg.disable("progress")
      require("slop.config").set_enabled("progress", true)
      reg._reset()
      h.source_plugin()
      if trigger == "native" then
        echo("hello", { status = "running", title = "t" })
      else
        ai("RequestStarted", { id = 1, kind = "chat", provider = "mistral" })
      end
      assert.is_true(reg.is_loaded("progress"), trigger)
      assert.equal(1, #require("slop").progress.items(), trigger)
    end
    require("slop.manifest").progress = nil
  end)

  it("LSP progress: begin/report/end with title, message, percent; linger then the window closes", function()
    setup({ linger = 80 })
    lsp("begin", "t1", { title = "Indexing", message = "1/3", percentage = 10 })
    local win = assert(view.win())
    assert.matches("lua_ls", shows("lua_ls"))
    assert.matches("1/3 %(10%%%)  Indexing", shows("1/3 %(10%%%)  Indexing"))
    lsp("report", "t1", { title = "Indexing", message = "2/3", percentage = 66 })
    assert.matches("2/3 %(66%%%)", shows("2/3 %(66%%%)"))
    lsp("end", "t1", { title = "Indexing", message = "done" })
    assert.matches("done  Indexing ✓", shows("done  Indexing ✓"))
    assert.equal("success", p.items()[1].status)
    assert.equal(1, #p.history())
    assert.truthy(wait(function()
      return view.win() == nil
    end))
    assert.is_false(api.nvim_win_is_valid(win))
    assert.equal(0, #p.items())
  end)

  it("LSP: unknown `end` is ignored, ignored clients are dropped, stopped clients are swept", function()
    setup({ ignore = { "copilot" } })
    lsp("end", "x", { title = "late" })
    assert.equal(0, #p.items())
    clients[8] = { name = "copilot", stopped = false }
    lsp("begin", "c", { title = "suggest" }, 8)
    assert.equal(0, #p.items())
    lsp("begin", "t", { title = "Indexing" })
    clients[7].stopped = true
    assert.truthy(wait(function()
      local it = p.items()[1]
      return it and it.status == "cancel"
    end))
    assert.matches("⊘", shows("⊘"))
  end)

  it("native progress messages (nvim_echo kind=progress), failed status and error mark", function()
    setup()
    local id = echo("compiling", { status = "running", percent = 40, title = "build" })
    assert.matches("myplug", shows("myplug"))
    assert.matches("compiling %(40%%%)  build", shows("compiling %(40%%%)  build"))
    echo("boom", { id = id, status = "failed", title = "build" })
    assert.matches("boom  build ✗", shows("boom  build ✗"))
    local hl = vim.tbl_map(function(m)
      return m[4].hl_group
    end, api.nvim_buf_get_extmarks(view.buf(), -1, 0, -1, { details = true }))
    assert.truthy(vim.tbl_contains(hl, "SlopProgressError"))
    assert.truthy(vim.tbl_contains(hl, "SlopProgressGroup"))
  end)

  it("drops Progress messages that only mirror LSP progress", function()
    setup()
    echo("x", { status = "running", source = "vim.lsp", id = "lsp.1" })
    assert.equal(0, #p.items())
    slop.setup({ progress = { sources = { lsp = false } } })
    echo("x", { status = "running", source = "vim.lsp", id = "lsp.2" })
    assert.equal(1, #p.items())
  end)

  it("AI requests: chat shown, fim hidden by default; error -> failed, cancelled -> cancel", function()
    setup()
    ai("RequestStarted", { id = 1, kind = "chat", provider = "mistral", model = "codestral", source = "commit" })
    ai("RequestStarted", { id = 2, kind = "fim", provider = "mistral" })
    local items = p.items()
    assert.equal(1, #items)
    assert.equal("slop", items[1].group)
    assert.equal("commit", items[1].title)
    assert.equal("mistral · codestral", items[1].message)
    ai("RequestFinished", { id = 2, kind = "fim" })
    ai("RequestFinished", { id = 1, kind = "chat", error = "HTTP 500" })
    assert.equal("failed", p.items()[1].status)
    assert.matches("HTTP 500  commit ✗", shows("HTTP 500  commit ✗"))
    ai("RequestStarted", { id = 3, kind = "chat", provider = "x" })
    ai("RequestFinished", { id = 3, error = "cancelled" })
    assert.equal("cancel", p.items()[2].status)
  end)

  it("AI fim can be enabled", function()
    setup({ sources = { ai = { fim = true } } })
    ai("RequestStarted", { id = 1, kind = "fim", provider = "codestral" })
    assert.equal(1, #p.items())
    assert.equal("ai", p.items()[1].title)
  end)

  it("dedupes an AI request with slop's own spinner.progress (either order)", function()
    setup()
    local spinner = require("slop.core.ui.spinner")
    local prog = spinner.progress({ title = "slop rest", message = "asking AI…" })
    ai("RequestStarted", { id = 1, kind = "chat", provider = "mistral", source = "rest" })
    assert.equal(1, #p.items())
    assert.equal("slop rest", p.items()[1].title)
    ai("RequestFinished", { id = 1 })
    prog:finish("success", "done")
    assert.equal(1, #p.history())
    assert.equal("mistral", p.history()[1].detail)

    ai("RequestStarted", { id = 2, kind = "chat", provider = "openai", source = "rest" })
    local prog2 = spinner.progress({ title = "slop rest", message = "asking AI…" })
    local running = vim.tbl_filter(function(i)
      return i.status == "running"
    end, p.items())
    assert.equal(1, #running)
    assert.equal("native", running[1].origin)
    ai("RequestFinished", { id = 2 })
    prog2:finish("success", "done")
    assert.equal(2, #p.history())
  end)

  it("window: bottom-right above statusline + cmdline, unfocusable, borderless, winblend; relayout", function()
    setup()
    local cur = api.nvim_get_current_win()
    echo("working", { status = "running", title = "t" })
    local win = assert(view.win())
    assert.equal(cur, api.nvim_get_current_win())
    local c = api.nvim_win_get_config(win)
    assert.equal("editor", c.relative)
    assert.equal("SE", c.anchor)
    assert.equal(30 - 1 - 1, c.row)
    assert.equal(99, c.col)
    assert.is_false(c.focusable)
    assert.equal("none", c.border)
    assert.equal(100, vim.wo[win].winblend)
    assert.equal(2, c.height)
    -- right-aligned
    for _, l in ipairs(api.nvim_buf_get_lines(view.buf(), 0, -1, false)) do
      assert.equal(c.width, vim.fn.strdisplaywidth(l))
    end
    vim.o.columns, vim.o.lines = 80, 20
    api.nvim_exec_autocmds("VimResized", {})
    c = api.nvim_win_get_config(win)
    assert.equal(18, c.row)
    assert.equal(79, c.col)
    vim.o.laststatus = 0
    c = api.nvim_win_get_config(win)
    assert.equal(19, c.row)
    -- long messages are truncated to max_width
    echo(string.rep("x", 200), { status = "running", title = "t", source = "long" })
    wait(function()
      return api.nvim_win_get_config(win).width == 40
    end)
    c = api.nvim_win_get_config(win)
    assert.equal(40, c.width)
    assert.matches("…", shows("…"))
  end)

  it("window follows the current tabpage and honours a configured border", function()
    setup({ window = { border = "rounded" } })
    echo("working", { status = "running", title = "t" })
    local c = api.nvim_win_get_config((assert(view.win())))
    assert.equal("╭", c.border[1])
    vim.cmd.tabnew()
    local tab = api.nvim_get_current_tabpage()
    api.nvim_exec_autocmds("TabEnter", {})
    assert.equal(tab, api.nvim_win_get_tabpage((assert(view.win()))))
  end)

  it("toggle hides the window but keeps tracking; clear empties it; commands", function()
    setup()
    echo("working", { status = "running", title = "t" })
    assert.is_false(p.toggle())
    assert.is_nil(view.win())
    echo("more", { status = "running", title = "u" })
    assert.equal(2, #p.items())
    vim.cmd("Slop progress toggle")
    assert.not_nil(view.win())
    vim.cmd("Slop progress clear")
    assert.equal(0, #p.items())
    assert.is_nil(view.win())
    echo("x", { status = "success", title = "v" })
    assert.equal(1, #p.history())
    vim.cmd("Slop progress clear history")
    assert.equal(0, #p.history())
    assert.are.same(
      { "all", "history", "items" },
      require("slop.core.commands").complete("", "Slop progress clear ", 20)
    )
  end)

  it(":Slop progress history opens a float with the finished tasks, newest first", function()
    setup()
    echo("first", { status = "success", title = "a" })
    echo("second", { status = "failed", title = "b" })
    vim.cmd("Slop progress history")
    local buf = api.nvim_get_current_buf()
    assert.equal("slopprogresshistory", vim.bo[buf].filetype)
    local lines = api.nvim_buf_get_lines(buf, 0, -1, false)
    assert.equal(2, #lines)
    assert.matches("✗  myplug  b  second", lines[1])
    assert.matches("✓  myplug  a  first", lines[2])
    h.feed("q")
    assert.not_equal(buf, api.nvim_get_current_buf())
  end)

  it("suppress_echo empties the progress: item of 'messagesopt'; teardown restores it", function()
    setup()
    assert.equal("hit-enter,history:500,progress:", vim.o.messagesopt)
    -- core.ui.spinner shares the augroup: teardown must keep its cancel listener
    local cancelled = false
    local prog = require("slop.core.ui.spinner").progress({
      title = "x",
      on_cancel = function()
        cancelled = true
      end,
    })
    require("slop.core.registry").disable("progress")
    assert.equal("hit-enter,history:500,progress:c", vim.o.messagesopt)
    echo("", { id = prog.id, status = "cancel", source = "slop" })
    assert.is_true(cancelled)
    assert.equal(0, #vim.tbl_filter(function(a)
      return a.desc and a.desc:match("^slop: progress ") and a.desc ~= "slop: progress cancel"
    end, api.nvim_get_autocmds({ group = "slop.progress" })))
  end)

  it("suppress_echo = false leaves 'messagesopt' alone; with_progress appends a missing item", function()
    setup({ suppress_echo = false })
    echo("x", { status = "running" })
    assert.equal("hit-enter,history:500,progress:c", vim.o.messagesopt)
    local s = require("slop.modules.progress.sources")
    assert.equal("hit-enter,progress:", s.with_progress("hit-enter", ""))
  end)

  it("schema rejects bad values; health runs without setup", function()
    require("slop.config").setup({ progress = { linger = "x", window = { winblend = 200 } } })
    local errs = table.concat(require("slop.config").errors("progress"), "\n")
    assert.matches("progress.linger", errs)
    assert.matches("progress.window.winblend", errs)
    require("slop.config").setup({})
    local spec = require("slop.core.registry").spec("progress")
    local out = {}
    local orig = vim.health
    vim.health = {
      ok = function(m)
        out[#out + 1] = m
      end,
      info = function(m)
        out[#out + 1] = m
      end,
      warn = function(m)
        out[#out + 1] = m
      end,
      error = function(m)
        out[#out + 1] = m
      end,
    }
    local ok, err = pcall(spec.health)
    vim.health = orig
    assert.is_true(ok, err)
    assert.matches("sources: lsp, native, ai.chat", table.concat(out, "\n"))
    assert.is_false(require("slop.core.registry").is_loaded("progress"))
  end)
end)

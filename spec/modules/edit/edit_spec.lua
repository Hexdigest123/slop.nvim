local h = require("helpers")
local mock = require("services.ai.acp.mock")

local api = vim.api

local function lines(buf)
  return api.nvim_buf_get_lines(buf or 0, 0, -1, false)
end

describe("edit module (mock ACP agent)", function()
  local edit, diff, reqmod, dir, log, done
  local function setup(plan, opts)
    log = mock.setup(plan, vim.tbl_deep_extend("force", { edit = { agent = "mock" } }, opts or {}))
    edit = require("slop").edit
    diff = require("slop.core.ui.diff")
    reqmod = require("slop.modules.edit.request")
    done = {}
    require("slop.core.events").on("edit", "Done", function(d)
      done[#done + 1] = d
    end)
  end
  local function open(name, content)
    local path = dir .. "/" .. name
    h.write(path, content)
    vim.cmd.edit(path)
    return api.nvim_get_current_buf(), path
  end
  local function wait_review(buf)
    return mock.wait(function()
      return #diff.list(buf) > 0 or #done > 0
    end)
  end
  local function prompts()
    return log.received("session/prompt")
  end
  local function prompt_text(i)
    local p = prompts()[i or 1]
    return p and p.params.prompt[1].text or ""
  end

  before_each(function()
    h.reset()
    vim.cmd("silent! %bwipeout!")
    vim.notify = function() end
    dir = h.tmpdir("edit")
    vim.fn.mkdir(dir .. "/.git", "p")
    vim.cmd.cd(dir)
  end)
  after_each(function()
    pcall(function()
      require("slop").edit.cancel("all")
      require("slop.core.ui.diff").close_all()
      require("slop.services.ai.acp").stop_all()
    end)
  end)

  it("round-trips a linewise region: progress, replacement, inline diff, accept = one undo", function()
    setup({ turns = { { { thought = "hmm" }, { sleep = 150 }, { replace_region = "upper" } } } })
    local buf = open("a.lua", "local a = 1\nlocal b = 2\nlocal c = 3\n")
    local id = edit.start({ lines = { 1, 2 }, instruction = "shout" })
    assert.truthy(id)
    local req = reqmod.active[id]
    assert.truthy(req.mark)
    mock.wait(function()
      return req.status_id ~= nil
    end, 2000)
    assert.truthy(req.status_id, "status virt_lines drawn while running")
    assert.truthy(wait_review(buf))
    assert.equal("review", req.state)
    assert.same({ "local a = 1", "LOCAL B = 2", "LOCAL C = 3" }, lines(buf))
    local text = prompt_text()
    assert.truthy(text:find("<region>\nlocal b = 2\nlocal c = 3\n</region>", 1, true))
    assert.truthy(text:find("Instruction: shout", 1, true))
    assert.truthy(text:find("File: a.lua", 1, true))
    diff.list(buf)[1]:accept_all()
    assert.equal("accepted", done[1].result)
    assert.is_nil(reqmod.active[id])
    assert.same({ "local a = 1", "LOCAL B = 2", "LOCAL C = 3" }, lines(buf))
    vim.cmd("silent undo")
    assert.same({ "local a = 1", "local b = 2", "local c = 3" }, lines(buf))
    mock.wait(function()
      return #log.received("session/close") == 1
    end)
    assert.equal(1, #log.received("session/close"))
  end)

  it("keeps the prefix/suffix of a charwise region", function()
    setup({ turns = { { { replace_region = "upper" } } } })
    local buf = open("b.lua", "print(foo, bar)\n")
    edit.start({ range = { 0, 6, 0, 9 }, linewise = false, instruction = "up" })
    assert.truthy(wait_review(buf))
    assert.same({ "print(FOO, bar)" }, lines(buf))
    assert.truthy(prompt_text():find("<region>\nfoo\n</region>", 1, true))
    diff.list(buf)[1]:accept_all()
  end)

  it("rejects edit permissions with the agent's optionId and falls back to the rejected diff", function()
    local path = h.tmpdir("p") .. "/ignored"
    setup({
      turns = {
        {
          {
            permission = {
              toolCall = {
                toolCallId = "t1",
                kind = "edit",
                title = "Edit c.lua",
                content = { { type = "diff", path = "__PATH__", oldText = "x = 1", newText = "x = 42" } },
              },
              options = {
                { optionId = "allow-once", kind = "allow_once" },
                { optionId = "reject", kind = "reject_once" },
              },
            },
          },
          {
            permission = {
              toolCall = { toolCallId = "t2", kind = "read", title = "Read" },
              options = { { optionId = "yes", kind = "allow_once" }, { optionId = "no", kind = "reject_once" } },
            },
          },
          { chunk = "I tried to edit the file." },
        },
      },
    })
    local buf, file = open("c.lua", "x = 1\n")
    -- patch the plan path now that we know it (the mock reads the plan when it starts)
    local plan = vim.json.decode(h.read(log.path:gsub("log%.ndjson$", "plan.json")))
    plan.turns[1][1].permission.toolCall.content[1].path = file
    h.write(log.path:gsub("log%.ndjson$", "plan.json"), vim.json.encode(plan))
    assert.truthy(path)
    edit.start({ lines = { 0, 0 }, instruction = "answer" })
    assert.truthy(wait_review(buf))
    local outcomes = vim.tbl_map(function(e)
      return e.result.outcome.optionId
    end, log.responses("session/request_permission"))
    assert.same({ "reject", "yes" }, outcomes)
    assert.same({ "x = 42" }, lines(buf))
    diff.list(buf)[1]:reject_all()
    assert.same({ "x = 1" }, lines(buf))
    assert.equal("rejected", done[1].result)
  end)

  it("falls back to the last code fence, and shows raw output when nothing usable came back", function()
    setup({
      by_prompt = {},
      turns = {
        { { chunk = "Here:\n```lua\nreturn 2\n```\n" } },
        { { chunk = "Sorry, I can't." } },
      },
    })
    local buf = open("d.lua", "return 1\n")
    edit.start({ lines = { 0, 0 }, instruction = "two" })
    assert.truthy(wait_review(buf))
    assert.same({ "return 2" }, lines(buf))
    diff.list(buf)[1]:accept_all()
    done = {}
    edit.start({ lines = { 0, 0 }, instruction = "three" })
    mock.wait(function()
      return #done > 0
    end)
    assert.equal("failed", done[1].result)
    local raw
    for _, b in ipairs(api.nvim_list_bufs()) do
      if api.nvim_buf_get_name(b):match("slop://edit/output") then
        raw = b
      end
    end
    assert.truthy(raw)
    assert.same({ "Sorry, I can't." }, lines(raw))
  end)

  it("conflict guard: an edited region is diffed against the current text and never auto-applied", function()
    setup({ turns = { { { sleep = 300 }, { replace_region = "upper" } } } }, { edit = { apply = "auto" } })
    local buf = open("e.lua", "aaa\nbbb\nccc\n")
    edit.start({ lines = { 0, 1 }, instruction = "x" })
    vim.wait(50)
    api.nvim_buf_set_lines(buf, 1, 2, false, { "BBB-user" })
    assert.truthy(wait_review(buf))
    local hd = diff.list(buf)[1]
    assert.truthy(hd and hd:is_active(), "conflict must be reviewed")
    assert.truthy(hd.opts.conflict)
    assert.same({ "AAA", "BBB", "ccc" }, lines(buf))
    hd:reject_all()
    assert.same({ "aaa", "BBB-user", "ccc" }, lines(buf))
  end)

  it("apply = auto accepts everything without review", function()
    setup({ turns = { { { replace_region = "upper" } } } }, { edit = { apply = "auto" } })
    local buf = open("f.lua", "abc\n")
    edit.start({ lines = { 0, 0 }, instruction = "x" })
    mock.wait(function()
      return #done > 0
    end)
    assert.equal("accepted", done[1].result)
    assert.same({ "ABC" }, lines(buf))
  end)

  it("cancel sends session/cancel and restores the region", function()
    setup({ turns = { { { chunk = "working..." }, { wait_cancel = true } } } })
    local buf = open("g.lua", "keep\n")
    local id = edit.start({ lines = { 0, 0 }, instruction = "slow" })
    mock.wait(function()
      return reqmod.active[id] and reqmod.active[id].state == "running" and reqmod.active[id].message ~= ""
    end)
    assert.is_true(edit.cancel())
    assert.equal("cancelled", done[1].result)
    mock.wait(function()
      return #log.received("session/cancel") > 0
    end)
    assert.equal(1, #log.received("session/cancel"))
    assert.same({ "keep" }, lines(buf))
    assert.same({}, api.nvim_buf_get_extmarks(buf, require("slop.core.util").ns("edit.region"), 0, -1, {}))
    assert.is_false(edit.cancel())
  end)

  it("runs concurrent requests and cancels the one under the cursor", function()
    setup({
      by_prompt = {},
      turns = { { { wait_cancel = true } }, { { sleep = 100 }, { replace_region = "upper" } } },
    })
    local buf = open("h.lua", "one\ntwo\nthree\nfour\n")
    local id1 = edit.start({ lines = { 0, 0 }, instruction = "first" })
    local id2 = edit.start({ lines = { 3, 3 }, instruction = "second" })
    assert.equal(2, #edit.requests())
    mock.wait(function()
      return #prompts() == 2
    end)
    api.nvim_win_set_cursor(0, { 1, 0 })
    assert.is_true(edit.cancel())
    assert.equal("cancelled", reqmod.active[id1] == nil and done[1].result or "?")
    assert.truthy(wait_review(buf))
    mock.wait(function()
      return #diff.list(buf) > 0
    end)
    assert.equal(id2, done[2] == nil and id2 or nil)
    assert.same({ "one", "two", "three", "FOUR" }, lines(buf))
    diff.list(buf)[1]:accept_all()
  end)

  it("refines in the same session", function()
    setup({ turns = { { { replace_region = "upper" } }, { { replace_region = "lower" } } } })
    local buf = open("i.lua", "MiXeD\n")
    local id = edit.start({ lines = { 0, 0 }, instruction = "x" })
    assert.truthy(wait_review(buf))
    assert.same({ "MIXED" }, lines(buf))
    local req = reqmod.active[id]
    assert.is_true(req:refine("lower please"))
    assert.same({ "MiXeD" }, lines(buf))
    mock.wait(function()
      local d = diff.list(buf)[1]
      return d ~= nil and lines(buf)[1] == "mixed"
    end)
    assert.same({ "mixed" }, lines(buf))
    assert.equal(1, #log.received("session/new"))
    assert.equal(2, #prompts())
    assert.equal(prompts()[1].params.sessionId, prompts()[2].params.sessionId)
    assert.matches("lower please", prompt_text(2))
    diff.list(buf)[1]:accept_all()
    assert.equal("accepted", done[1].result)
  end)

  it("explain shows a float, tests opens a scratch buffer", function()
    setup({
      turns = {
        { { chunk = "# What\nIt adds." } },
        { { chunk = "<slop:replacement>\ntest('adds')\n</slop:replacement>" } },
      },
    })
    local buf = open("j.lua", "return 1 + 1\n")
    edit.start({ lines = { 0, 0 }, preset = "explain" })
    mock.wait(function()
      return #done > 0
    end)
    assert.equal("explained", done[1].result)
    local fwin = api.nvim_get_current_win()
    assert.equal("markdown", vim.bo[api.nvim_win_get_buf(fwin)].filetype)
    assert.same({ "# What", "It adds." }, lines(api.nvim_win_get_buf(fwin)))
    assert.matches("Markdown", prompt_text(1))
    api.nvim_win_close(fwin, true)
    api.nvim_set_current_buf(buf)
    edit.start({ lines = { 0, 0 }, preset = "tests" })
    mock.wait(function()
      return #done > 1
    end)
    assert.equal("scratch", done[2].result)
    local sbuf = api.nvim_get_current_buf()
    assert.matches("slop://edit/tests", api.nvim_buf_get_name(sbuf))
    assert.equal("lua", vim.bo[sbuf].filetype)
    assert.same({ "test('adds')" }, lines(sbuf))
    assert.same({ "return 1 + 1" }, lines(buf))
  end)

  it("includes rules files, @file mentions and diagnostics; serves reads from the live buffer", function()
    setup({ turns = { { { read = { path = "__SELF__" } }, { replace_region = "same" } } } })
    h.write(dir .. "/AGENTS.md", "Always use tabs.")
    h.write(dir .. "/util.lua", "return { helper = true }")
    h.write(dir .. "/.env", "TOKEN=secret")
    local buf, file = open("k.lua", "local x = 1\n")
    local plan_path = log.path:gsub("log%.ndjson$", "plan.json")
    local plan = vim.json.decode(h.read(plan_path))
    plan.turns[1][1].read.path = file
    h.write(plan_path, vim.json.encode(plan))
    api.nvim_buf_set_lines(buf, 0, 1, false, { "local x = 2 -- unsaved" })
    vim.diagnostic.set(
      api.nvim_create_namespace("test"),
      buf,
      { { lnum = 0, col = 0, message = "unused x", severity = 1 } }
    )
    edit.start({ lines = { 0, 0 }, preset = "fix", instruction = "see @util.lua and @.env" })
    mock.wait(function()
      return #done > 0 or #diff.list(buf) > 0
    end)
    local text = prompt_text()
    assert.truthy(text:find('<project_rules path="AGENTS.md">\nAlways use tabs.', 1, true))
    assert.equal("resource", prompts()[1].params.prompt[2].type)
    assert.equal("return { helper = true }", prompts()[1].params.prompt[2].resource.text)
    assert.is_nil(vim.inspect(prompts()[1].params):find("TOKEN=secret", 1, true))
    assert.truthy(text:find("line 1: [ERROR] unused x", 1, true))
    assert.equal("local x = 2 -- unsaved", log.responses("fs/read_text_file")[1].result.content)
  end)

  it("refuses blocked buffers and cloaked regions without contacting the agent", function()
    setup({})
    open(".env", "TOKEN=abc\n")
    assert.is_nil(edit.start({ lines = { 0, 0 }, instruction = "x" }))
    open("key.txt", "-----BEGIN RSA PRIVATE KEY-----\nMIIBOgIBAAJBAK\n-----END RSA PRIVATE KEY-----\n")
    assert.is_nil(edit.start({ lines = { 1, 1 }, instruction = "x" }))
    assert.same({}, log.entries())
  end)

  it("opens the prompt float from the keymap and the command with a range", function()
    setup({ default_turn = { { replace_region = "upper" } } })
    h.source_plugin()
    local buf = open("l.lua", "a\nb\nc\n")
    vim.cmd("2,3Slop edit run make it loud")
    assert.truthy(wait_review(buf))
    assert.same({ "a", "B", "C" }, lines(buf))
    diff.list(buf)[1]:accept_all()
    api.nvim_win_set_cursor(0, { 1, 0 })
    h.feed("V<leader>aa")
    local hd = api.nvim_get_current_win()
    assert.not_equal("", api.nvim_win_get_config(hd).relative)
    local pbuf = api.nvim_win_get_buf(hd)
    assert.equal("slopprompt", vim.bo[pbuf].filetype)
    local items = vim.tbl_map(function(i)
      return i.word
    end, require("slop.core.ui.input")._completefunc(0, "#ex"))
    assert.truthy(vim.tbl_contains(items, "#explain"))
    api.nvim_buf_set_lines(pbuf, 0, -1, false, { "upper" })
    h.feed("<C-s>")
    assert.truthy(mock.wait(function()
      return lines(buf)[1] == "A"
    end))
    assert.same({ "A", "B", "C" }, lines(buf))
    vim.cmd("Slop edit agent mock")
    assert.equal("mock", edit.agent())
  end)
end)

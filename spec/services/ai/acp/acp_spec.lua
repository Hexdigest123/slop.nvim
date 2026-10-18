local h = require("helpers")
local mock = require("services.ai.acp.mock")

local api = vim.api

local ALLOW_REJECT = {
  { optionId = "allow-once", name = "Allow once", kind = "allow_once" },
  { optionId = "allow-always", name = "Always", kind = "allow_always" },
  { optionId = "reject", name = "Reject", kind = "reject_once" },
}

local function run_turn(client, text, handlers)
  local res = {}
  client:new_session({}, function(session, err)
    res.session, res.err = session, err
    if not session then
      res.done = true
      return
    end
    handlers = handlers or {}
    res.updates = {}
    session:prompt({ { type = "text", text = text or "hi" } }, {
      on_update = function(u)
        table.insert(res.updates, u)
        if handlers.on_update then
          handlers.on_update(u)
        end
      end,
      on_permission = handlers.on_permission,
      on_done = function(stop, derr)
        res.stop, res.done_err, res.done = stop, derr, true
      end,
    })
  end)
  return res
end

describe("services.ai.acp", function()
  local acp
  before_each(function()
    h.reset()
    vim.notify = function() end
    acp = require("slop.services.ai.acp")
  end)
  after_each(function()
    if acp then
      acp.stop_all()
    end
  end)

  describe("rpc transport", function()
    it("frames split chunks, decodes nulls to nil and answers unknown methods with -32601", function()
      local rpc = require("slop.services.ai.acp.rpc")
      local notes = {}
      local r = assert(rpc.spawn({
        cmd = { "cat" },
        on_notification = function(m, p)
          notes[#notes + 1] = { m, p }
        end,
      }))
      r:_feed('{"jsonrpc":"2.0","method":"a","params":{"x":null,')
      r:_feed('"y":[1]}}\n{"jsonrpc":"2.0","method":"b"}\nnot json\n')
      mock.wait(function()
        return #notes == 2
      end)
      assert.equal("a", notes[1][1])
      assert.is_nil(notes[1][2].x)
      assert.same({ 1 }, notes[1][2].y)
      assert.matches("stdout: not json", r:stderr_tail())
      -- `cat` echoes our request back: we answer it with -32601, the echo of that answer resolves our request
      local got
      r:request("terminal/create", { a = 1 }, function(result, err)
        got = { result = result, err = err }
      end)
      mock.wait(function()
        return got ~= nil
      end)
      assert.equal(-32601, got.err.code)
      r:kill()
      mock.wait(function()
        return not r:is_running()
      end)
      assert.is_false(r:is_running())
    end)

    it("times out requests and fails pending ones on exit", function()
      local rpc = require("slop.services.ai.acp.rpc")
      local exited
      local r = assert(rpc.spawn({
        cmd = { "sleep", "30" },
        on_exit = function(code)
          exited = code
        end,
      }))
      local t, p
      r:request("slow", nil, function(_, err)
        t = err
      end, { timeout = 30 })
      r:request("forever", nil, function(_, err)
        p = err
      end, { timeout = false })
      mock.wait(function()
        return t ~= nil
      end)
      assert.equal(-32800, t.code)
      r:kill()
      mock.wait(function()
        return p ~= nil and exited ~= nil
      end)
      assert.matches("agent exited", p.message)
    end)

    it("reports a missing executable", function()
      local r, err = require("slop.services.ai.acp.rpc").spawn({ cmd = { "slop-no-such-agent-xyz" } })
      assert.is_nil(r)
      assert.matches("not found", err)
    end)
  end)

  describe("client", function()
    it("initializes once, advertises only fs.readTextFile, and streams a turn", function()
      local log = mock.setup({ turns = { { { chunk = "hel" }, { chunk = "lo" }, { stop = "end_turn" } } } })
      local client = acp.client({ agent = "mock" })
      assert.equal(client, acp.client("mock"))
      local res = run_turn(client)
      assert.truthy(mock.wait(function()
        return res.done
      end))
      assert.equal("end_turn", res.stop)
      assert.is_nil(res.done_err)
      assert.equal("ready", client.state)
      assert.equal("mock", client.info.name)
      local text = ""
      for _, u in ipairs(res.updates) do
        text = text .. acp.block_text(u.content)
      end
      assert.equal("hello", text)
      local init = log.received("initialize")
      assert.equal(1, #init)
      assert.equal(1, init[1].params.protocolVersion)
      assert.same(
        { fs = { readTextFile = true, writeTextFile = false }, terminal = false },
        init[1].params.clientCapabilities
      )
      local new = log.received("session/new")[1]
      assert.same({}, new.params.mcpServers)
      assert.equal("/", new.params.cwd:sub(1, 1))
      -- a second session reuses the same process
      local res2 = run_turn(client)
      mock.wait(function()
        return res2.done
      end)
      assert.equal(1, #log.received("initialize"))
      assert.equal(2, #log.received("session/new"))
    end)

    it("answers unknown agent->client requests with -32601", function()
      local log =
        mock.setup({ turns = { { { request = { method = "terminal/create", params = { command = "ls" } } } } } })
      local res = run_turn(acp.client("mock"))
      mock.wait(function()
        return res.done
      end)
      local r = log.responses("terminal/create")[1]
      assert.equal(-32601, r.error.code)
      assert.equal("end_turn", res.stop)
    end)

    it("serves fs/read_text_file from live buffers, slices, redacts and refuses blocked paths", function()
      local dir = h.tmpdir("acpfs")
      local file = dir .. "/a.lua"
      h.write(file, "one\ntwo\nthree\nfour\n")
      local key = dir .. "/key.txt"
      h.write(key, "x\n-----BEGIN RSA PRIVATE KEY-----\nSECRETBODY\n-----END RSA PRIVATE KEY-----\n")
      local env = dir .. "/.env"
      h.write(env, "TOKEN=abc\n")
      vim.cmd.edit(file)
      api.nvim_buf_set_lines(0, 1, 2, false, { "TWO (unsaved)" })
      local log = mock.setup({
        turns = {
          {
            { read = { path = file, line = 2, limit = 2 } },
            { read = { path = file } },
            { read = { path = key } },
            { read = { path = env } },
            { read = { path = dir .. "/missing.txt" } },
            { read = { path = "relative.txt" } },
          },
        },
      })
      local res = run_turn(acp.client("mock"))
      mock.wait(function()
        return res.done
      end)
      local r = log.responses("fs/read_text_file")
      assert.equal(6, #r)
      assert.equal("TWO (unsaved)\nthree", r[1].result.content)
      assert.equal("one\nTWO (unsaved)\nthree\nfour", r[2].result.content)
      assert.is_nil(r[3].result.content:find("SECRETBODY", 1, true))
      assert.matches("<redacted>", r[3].result.content)
      assert.matches("secrets policy", r[4].error.message)
      assert.equal(-32002, r[5].error.code)
      assert.equal(-32602, r[6].error.code)
    end)

    it("applies the default permission policy with the agent's own optionIds", function()
      local dir = h.tmpdir("acpperm")
      local log = mock.setup({
        turns = {
          {
            { permission = { toolCall = { toolCallId = "1", kind = "read" }, options = ALLOW_REJECT } },
            { permission = { toolCall = { toolCallId = "2", kind = "edit" }, options = ALLOW_REJECT } },
            { permission = { toolCall = { toolCallId = "3", kind = "execute" }, options = ALLOW_REJECT } },
            {
              permission = {
                toolCall = { toolCallId = "4", kind = "read", locations = { { path = dir .. "/.env" } } },
                options = ALLOW_REJECT,
              },
            },
            {
              permission = {
                toolCall = { toolCallId = "5", kind = "delete" },
                options = { { optionId = "ok", kind = "allow_once" } },
              },
            },
            { permission = { toolCall = { toolCallId = "6" }, options = ALLOW_REJECT } },
          },
        },
      })
      local res = run_turn(acp.client("mock"))
      mock.wait(function()
        return res.done
      end)
      local outcomes = vim.tbl_map(function(e)
        return e.result.outcome.optionId or e.result.outcome.outcome
      end, log.responses("session/request_permission"))
      assert.same({ "allow-once", "reject", "reject", "reject", "cancelled", "reject" }, outcomes)
    end)

    it("passes permission requests to the turn handler and returns its choice", function()
      local log = mock.setup({
        turns = { { { permission = { toolCall = { toolCallId = "1", kind = "edit" }, options = ALLOW_REJECT } } } },
      })
      local seen
      local res = run_turn(acp.client("mock"), "x", {
        on_permission = function(req, respond)
          seen = req
          respond("allow-always")
        end,
      })
      mock.wait(function()
        return res.done
      end)
      assert.equal("edit", seen.toolCall.kind)
      assert.equal("allow-always", log.responses("session/request_permission")[1].result.outcome.optionId)
    end)

    it("cancel sends session/cancel and answers pending permissions with cancelled", function()
      local log = mock.setup({
        turns = {
          {
            { chunk = "working" },
            { permission = { toolCall = { toolCallId = "1", kind = "edit" }, options = ALLOW_REJECT } },
            { wait_cancel = true },
          },
        },
      })
      local res
      res = run_turn(acp.client("mock"), "x", {
        on_permission = function() end, -- never answers
        on_update = function()
          vim.schedule(function()
            res.session:cancel()
          end)
        end,
      })
      mock.wait(function()
        return res.done
      end)
      assert.equal("cancelled", res.stop)
      assert.equal(1, #log.received("session/cancel"))
      assert.equal("cancelled", log.responses("session/request_permission")[1].result.outcome.outcome)
      assert.is_false(res.session:is_busy())
    end)

    it("fails the running turn with the stderr tail when the agent dies, then respawns", function()
      local log = mock.setup({
        by_prompt = { die = { { stderr = "panic: boom" }, { sleep = 50 }, { exit = 3 } } },
        default_turn = {},
      })
      local client = acp.client("mock")
      local res = run_turn(client, "die")
      mock.wait(function()
        return res.done
      end)
      assert.is_nil(res.stop)
      assert.matches("exited", res.done_err.message)
      assert.matches("panic: boom", res.done_err.stderr)
      mock.wait(function()
        return client.state == "idle"
      end)
      assert.equal("idle", client.state)
      local res2 = run_turn(client)
      mock.wait(function()
        return res2.done
      end)
      assert.equal("end_turn", res2.stop)
      assert.equal(2, #log.received("initialize"))
    end)

    it("reports startup failures with stderr and tolerates non-JSON stdout", function()
      mock.setup({ init_exit = 2 })
      local err
      acp.client("mock"):start(function(e)
        err = e or false
      end)
      mock.wait(function()
        return err ~= nil
      end)
      assert.matches("fatal startup error", err)

      h.reset()
      acp = require("slop.services.ai.acp")
      mock.setup({ init_garbage = true })
      local client = acp.client("mock")
      local ok
      client:start(function(e)
        ok = e == nil
      end)
      mock.wait(function()
        return ok ~= nil
      end)
      assert.is_true(ok)
      assert.matches("log in", client:stderr_tail())
    end)

    it("rejects protocol version mismatches and unknown agents", function()
      mock.setup({ init = { protocolVersion = 2, agentCapabilities = {} } })
      local err
      acp.client("mock"):start(function(e)
        err = e
      end)
      mock.wait(function()
        return err ~= nil
      end)
      assert.matches("protocol version 2", err)
      local uerr
      acp.client("nope"):start(function(e)
        uerr = e
      end)
      assert.matches("unknown ACP agent 'nope'", uerr)
    end)

    it("authenticates when auth_method is configured", function()
      local log, cfg = mock.setup({})
      cfg.auth_method = "api-key"
      require("slop").setup({ ai = { agents = { mock = cfg } } })
      local err = 0
      acp.client("mock"):start(function(e)
        err = e
      end)
      mock.wait(function()
        return err ~= 0
      end)
      assert.is_nil(err)
      assert.equal("api-key", log.received("authenticate")[1].params.methodId)
    end)

    it("replaces a client whose config changed and stops agents", function()
      local _, cfg = mock.setup({})
      local c1 = acp.client("mock")
      local started
      c1:start(function(e)
        started = e == nil
      end)
      mock.wait(function()
        return started
      end)
      cfg.env.EXTRA = "1"
      require("slop").setup({ ai = { agents = { mock = cfg } } })
      local c2 = acp.client("mock")
      assert.not_equal(c1, c2)
      assert.equal("stopped", c1.state)
      mock.wait(function()
        return not c1:is_running()
      end)
      assert.is_false(c1:is_running())
    end)

    it("closes sessions with session/close when supported", function()
      local log = mock.setup({})
      local client = acp.client("mock")
      local res = run_turn(client)
      mock.wait(function()
        return res.done
      end)
      res.session:close()
      mock.wait(function()
        return #log.received("session/close") == 1
      end)
      assert.equal(1, #log.received("session/close"))
      assert.is_nil(client.sessions[res.session.id])
    end)
  end)

  describe("decide", function()
    it("picks allow/reject options by kind", function()
      local id, verdict = acp.decide({ toolCall = { kind = "search" }, options = ALLOW_REJECT })
      assert.equal("allow-once", id)
      assert.equal("allow", verdict)
      id, verdict = acp.decide({ toolCall = { kind = "move" }, options = ALLOW_REJECT })
      assert.equal("reject", id)
      assert.equal("reject", verdict)
      id = acp.decide({
        toolCall = { kind = "read" },
        options = { { optionId = "always", kind = "allow_always" }, { optionId = "never", kind = "reject_always" } },
      })
      assert.equal("always", id)
      id = acp.decide({ toolCall = { kind = "read", rawInput = { file_path = "/x/id.pem" } }, options = ALLOW_REJECT })
      assert.equal("reject", id)
      id = acp.decide({ toolCall = { kind = "edit" }, options = ALLOW_REJECT }, { allow = { "edit" } })
      assert.equal("allow-once", id)
    end)
  end)
end)

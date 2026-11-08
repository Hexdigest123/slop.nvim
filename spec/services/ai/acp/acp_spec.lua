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

    it("signals the pid itself when its process group can't be signalled", function()
      local r = assert(require("slop.services.ai.acp.rpc").spawn({ cmd = { "sleep", "30" } }))
      local real_kill, pids = vim.uv.kill, {}
      -- uv.kill reports failure by returning nil (it does not throw)
      vim.uv.kill = function(pid, sig)
        pids[#pids + 1] = pid
        if pid < 0 then
          return nil, "ESRCH: no such process", "ESRCH"
        end
        return real_kill(pid, sig)
      end
      local ok, err = pcall(r.kill_now, r)
      vim.uv.kill = real_kill
      assert(ok, err)
      assert.same({ -r.pid, r.pid, -r.pid, r.pid }, pids)
      mock.wait(function()
        return not r:is_running()
      end)
      assert.is_false(r:is_running())
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
      local outside = h.tmpdir("acpfs-outside") .. "/other.txt"
      h.write(outside, "not yours\n")
      vim.cmd.cd(dir)
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
            { read = { path = outside } },
          },
        },
      })
      local res = run_turn(acp.client("mock"))
      mock.wait(function()
        return res.done
      end)
      local r = log.responses("fs/read_text_file")
      assert.equal(7, #r)
      assert.equal("TWO (unsaved)\nthree", r[1].result.content)
      assert.equal("one\nTWO (unsaved)\nthree\nfour", r[2].result.content)
      assert.is_nil(r[3].result.content:find("SECRETBODY", 1, true))
      assert.matches("<redacted>", r[3].result.content)
      assert.matches("secrets policy", r[4].error.message)
      assert.equal(-32002, r[5].error.code)
      assert.equal(-32602, r[6].error.code)
      assert.matches("outside the project root", r[7].error.message)
    end)

    it("never expands environment variables in a path it reads (their values would come back in errors)", function()
      local secret = "sk-live-ENVLEAK0123456789abcdef"
      vim.uv.os_setenv("SLOP_TEST_LEAK", secret)
      local dir = h.tmpdir("acpenv")
      vim.cmd.cd(dir)
      local paths = { "$SLOP_TEST_LEAK", "/$SLOP_TEST_LEAK", dir .. "/$SLOP_TEST_LEAK.txt" }
      local turn = {}
      for _, p in ipairs(paths) do
        turn[#turn + 1] = { read = { path = p } }
      end
      local log = mock.setup({ turns = { turn } }, { ai = { agents = { mock = { read_outside_root = true } } } })
      local res = run_turn(acp.client("mock"))
      mock.wait(function()
        return res.done
      end)
      local r = log.responses("fs/read_text_file")
      assert.equal(#paths, #r)
      for i, e in ipairs(r) do
        assert.is_nil(vim.json.encode(e):find("ENVLEAK", 1, true), paths[i] .. ": " .. vim.json.encode(e))
      end
      -- the read API itself, any root policy
      for _, p in ipairs(paths) do
        for _, outside in ipairs({ false, true }) do
          local text, err = acp.read_text_file({ path = p }, { root = dir, read_outside_root = outside })
          assert.is_nil(vim.json.encode({ text or "", err or {} }):find("ENVLEAK", 1, true), p)
        end
      end
    end)

    it("refuses binary files (their bytes are no valid JSON text) instead of sending them", function()
      local dir = h.tmpdir("acpbin")
      h.write(dir .. "/image.png", "\137PNG\r\n\26\n\0\0\0\rIHDR\0\0\0\1\255\216\255")
      h.write(dir .. "/ok.txt", "plain\n")
      vim.cmd.cd(dir)
      local log = mock.setup({
        turns = { { { read = { path = dir .. "/image.png" } }, { read = { path = dir .. "/ok.txt" } } } },
      })
      local res = run_turn(acp.client("mock"))
      mock.wait(function()
        return res.done
      end)
      local r = log.responses("fs/read_text_file")
      assert.equal(2, #r)
      assert.is_nil(r[1].result)
      assert.matches("binary", r[1].error and r[1].error.message or "")
      assert.equal("plain", r[2].result and r[2].result.content)
    end)

    it("refuses reads through a symlink to a blocked file and serves a linked file's live buffer", function()
      local dir = h.tmpdir("acplink")
      h.write(dir .. "/.env", "API_KEY=sk-live-1234567890abcdef\n")
      h.write(dir .. "/real.lua", "on disk\n")
      assert(vim.uv.fs_symlink(dir .. "/.env", dir .. "/settings.txt"))
      assert(vim.uv.fs_symlink(dir .. "/.env", dir .. "/link.env"))
      assert(vim.uv.fs_symlink(dir .. "/real.lua", dir .. "/alias.lua"))
      vim.cmd.cd(dir)
      vim.cmd.edit(dir .. "/real.lua")
      api.nvim_buf_set_lines(0, 0, -1, false, { "unsaved" })
      local log = mock.setup({
        turns = {
          {
            { read = { path = dir .. "/settings.txt" } },
            { read = { path = dir .. "/link.env" } },
            { read = { path = dir .. "/alias.lua" } },
          },
        },
      })
      local res = run_turn(acp.client("mock"))
      mock.wait(function()
        return res.done
      end)
      local r = log.responses("fs/read_text_file")
      assert.equal(3, #r)
      assert.is_nil(r[1].result)
      assert.matches("secrets policy", r[1].error.message)
      assert.matches("secrets policy", r[2].error.message)
      assert.equal("unsaved", r[3].result.content)
    end)

    it("secrets.agent_reads: deny refuses blocked files, allow serves them redacted; writes stay refused", function()
      local dir = h.tmpdir("acpreads")
      h.write(dir .. "/.env", "API_KEY=sk-live-1234567890abcdef\n# local settings\n")
      h.write(dir .. "/id.pem", "-----BEGIN RSA PRIVATE KEY-----\nSECRETBODY\n-----END RSA PRIVATE KEY-----\n")
      assert(vim.uv.fs_symlink(dir .. "/.env", dir .. "/settings.txt"))
      vim.cmd.cd(dir)
      local function read_perm(id, path)
        return {
          permission = {
            toolCall = { toolCallId = id, kind = "read", locations = { { path = path } } },
            options = ALLOW_REJECT,
          },
        }
      end
      local plan = {
        turns = {
          {
            { read = { path = dir .. "/.env" } },
            { read = { path = dir .. "/id.pem" } },
            { read = { path = dir .. "/settings.txt" } },
            read_perm("r1", dir .. "/.env"),
            read_perm("r2", dir .. "/settings.txt"),
          },
        },
      }
      local function run(opts)
        local log = mock.setup(plan, opts)
        local res = run_turn(acp.client("mock"))
        mock.wait(function()
          return res.done
        end)
        local outcomes = vim.tbl_map(function(e)
          return e.result.outcome.optionId
        end, log.responses("session/request_permission"))
        return log.responses("fs/read_text_file"), outcomes
      end
      local edit_env =
        { toolCall = { kind = "edit", locations = { { path = dir .. "/.env" } } }, options = ALLOW_REJECT }
      local policy = { allow = { "read", "edit", "move", "delete" } }

      -- deny (default): unchanged
      assert.equal("deny", require("slop.config").get("secrets").agent_reads)
      local reads, outcomes = run()
      assert.equal(3, #reads)
      for _, r in ipairs(reads) do
        assert.is_nil(r.result)
        assert.matches("secrets policy", r.error.message)
      end
      assert.same({ "reject", "reject" }, outcomes)
      assert.equal("reject", (acp.decide(edit_env, policy)))

      -- allow: served, with every secret value still redacted
      acp.stop_all()
      reads, outcomes = run({ secrets = { agent_reads = "allow" } })
      assert.equal(3, #reads)
      local env = reads[1].result.content
      assert.matches("^API_KEY=", env)
      assert.is_nil(env:find("sk-live-1234567890abcdef", 1, true))
      assert.matches("<redacted>", env)
      assert.matches("# local settings", env)
      local pem = reads[2].result.content
      assert.matches("BEGIN RSA PRIVATE KEY", pem)
      assert.is_nil(pem:find("SECRETBODY", 1, true))
      assert.equal(env, reads[3].result.content) -- through the symlink: the target's rules apply
      -- a permission lets the agent read with its OWN tools (opencode asks before reading *.env), which slop cannot
      -- redact: refused like any other blocked path, only slop's own fs/read_text_file serves them (redacted)
      assert.same({ "reject", "reject" }, outcomes)
      local read_env =
        { toolCall = { kind = "read", locations = { { path = dir .. "/.env" } } }, options = ALLOW_REJECT }
      assert.equal("reject", (acp.decide(read_env)))
      -- writes, moves and deletes of blocked files stay refused
      assert.equal("reject", (acp.decide(edit_env, policy)))
      for _, kind in ipairs({ "move", "delete" }) do
        local req = { toolCall = { kind = kind, locations = { { path = dir .. "/id.pem" } } }, options = ALLOW_REJECT }
        assert.equal("reject", (acp.decide(req, policy)))
      end
      -- other kinds keep their policy
      assert.equal("reject", (acp.decide({ toolCall = { kind = "execute" }, options = ALLOW_REJECT })))
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

    it("decides permissions on everything the agent announced for the tool call", function()
      local dir = h.tmpdir("acpmerge")
      local function tool(id, kind, path)
        return {
          tool = { toolCallId = id, title = "Read", kind = kind, status = "pending", locations = { { path = path } } },
        }
      end
      local function perm(tc)
        return { permission = { toolCall = tc, options = ALLOW_REJECT } }
      end
      local turn = {
        -- a: the path came with the tool_call notification, the request repeats only the kind
        tool("a", "read", dir .. "/.env"),
        perm({ toolCallId = "a", kind = "read" }),
        -- b: the request carries only the id (the kind came with the notification)
        tool("b", "read", dir .. "/a.lua"),
        perm({ toolCallId = "b" }),
        -- c: a later update adds a blocked path
        tool("c", "read", dir .. "/a.lua"),
        { tool_update = { toolCallId = "c", locations = { { path = dir .. "/x.pem" } } } },
        perm({ toolCallId = "c" }),
      }
      local log = mock.setup({ turns = { turn, turn } })
      local client = acp.client("mock")
      local res = run_turn(client) -- no turn handler: acp.decide() on the merged call
      mock.wait(function()
        return res.done
      end)
      local seen = {}
      local res2 = run_turn(client, "x", {
        on_permission = function(req, respond)
          seen[#seen + 1] = req.toolCall
          respond((acp.decide(req)))
        end,
      })
      mock.wait(function()
        return res2.done
      end)
      local outcomes = vim.tbl_map(function(e)
        return e.result.outcome.optionId
      end, log.responses("session/request_permission"))
      assert.same({ "reject", "allow-once", "reject", "reject", "allow-once", "reject" }, outcomes)
      assert.equal("read", seen[2].kind)
      assert.equal(dir .. "/.env", seen[1].locations[1].path)
      assert.equal(2, #seen[3].locations)
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

    it("a restart while the previous process is still being killed keeps the new process", function()
      local log = mock.setup({ init = { protocolVersion = 2, agentCapabilities = {} } })
      local plan = (log.path:gsub("log%.ndjson$", "plan.json"))
      local client = acp.client("mock")
      local first, second, old
      client:start(function(e)
        first, old = e, client._rpc
        -- retry at once (the rejected process is being killed); the new process is healthy
        h.write(plan, vim.json.encode(vim.empty_dict()))
        client:start(function(e2)
          second = e2 or false
        end)
      end)
      mock.wait(function()
        return second ~= nil and old ~= nil and old._exited
      end)
      assert.matches("protocol version 2", first)
      assert.is_false(second)
      assert.is_true(old._exited)
      assert.equal("ready", client.state)
      assert.is_true(client:is_running())
      assert.not_equal(old, client._rpc)
      local res = run_turn(client)
      mock.wait(function()
        return res.done
      end)
      assert.equal("end_turn", res.stop)
      -- the client still owns the new process: stop() ends it
      local rpc = client._rpc
      client:stop()
      mock.wait(function()
        return not rpc:is_running()
      end)
      assert.is_false(rpc:is_running())
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

    it("a setup() that keeps cmd/env keeps the process but applies the other agent options", function()
      local dir = h.tmpdir("acpcfg")
      local outside = h.tmpdir("acpcfg-outside") .. "/other.txt"
      h.write(outside, "not yours\n")
      vim.cmd.cd(dir)
      local turn = { { read = { path = outside } } }
      local log, cfg = mock.setup(
        { turns = { turn, turn } },
        { ai = { agents = { mock = { read_outside_root = true } } } }
      )
      local client = acp.client("mock")
      local res = run_turn(client)
      mock.wait(function()
        return res.done
      end)
      -- read_outside_root dropped again (e.g. the config file re-sourced)
      require("slop").setup({ ai = { agents = { mock = cfg } } })
      local same = acp.client("mock")
      assert.equal(client, same)
      local res2 = run_turn(same)
      mock.wait(function()
        return res2.done
      end)
      local r = log.responses("fs/read_text_file")
      assert.equal(2, #r)
      assert.equal("not yours", r[1].result and r[1].result.content)
      assert.is_nil(r[2].result)
      assert.matches("outside the project root", r[2].error and r[2].error.message or "")
      assert.equal(1, #log.received("initialize"))
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

  describe("config", function()
    it("validates the documented agent options (not only at first use)", function()
      local config = require("slop.config")
      local function errs(agent)
        return table.concat(config.validate("ai", { providers = {}, agents = { x = agent } }), "\n")
      end
      local good = {
        cmd = { "x", "acp" },
        env = { A = "1" },
        auth_method = "key",
        timeout = 1000,
        init_timeout = 5000,
        read_outside_root = false,
      }
      assert.equal("", errs(good))
      local bad = {
        cmd = {},
        env = "A=1",
        auth_method = 3,
        timeout = "30s",
        init_timeout = 0,
        read_outside_root = "yes",
      }
      for field, value in pairs(bad) do
        local agent = vim.deepcopy(good)
        agent[field] = value
        assert.matches("ai%.agents%.x%." .. field, errs(agent))
      end
      assert.matches("ai%.agents%.x%.env", errs(vim.tbl_extend("force", good, { env = { A = { "nested" } } })))
      assert.matches("ai%.agents%.x%.cmd", errs(vim.tbl_extend("force", good, { cmd = { "x", 1 } })))
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

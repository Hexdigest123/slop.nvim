local h = require("helpers")
local mock = require("services.ai.mock_server")

describe("core.http", function()
  local http, srv
  before_each(function()
    h.reset()
    vim.notify = function() end
    http = require("slop.core.http")
  end)
  after_each(function()
    if srv then
      srv.stop()
      srv = nil
    end
  end)

  local function run(opts)
    local out = {}
    opts.on_done = function(res, err)
      out.n = (out.n or 0) + 1
      out.res, out.err = res, err
      out.fast = vim.in_fast_event()
    end
    out.handle = http.request(opts)
    assert.is_true(
      mock.wait(function()
        return out.n ~= nil
      end, 8000),
      "request did not finish"
    )
    vim.wait(30) -- make sure on_done is not called twice
    return out
  end

  describe("build_args (pure)", function()
    it("builds method, headers, body via stdin, query, flags", function()
      local args, stdin = http.build_args({
        url = "http://x/y",
        headers = { { "X-A", "1" }, { "X-Empty", "" } },
        query = { b = "x y", a = 1 },
        body = { k = "v" },
        timeout = 1500,
        follow_redirects = true,
        cookie_jar = "/tmp/jar",
        http_version = "1.1",
      })
      assert.equal('{"k":"v"}', stdin)
      local s = table.concat(args, " ")
      assert.matches("^%-sS %-%-globoff %-X POST", s)
      assert.matches("%-H X%-A: 1", s)
      assert.matches("%-H X%-Empty;", s)
      assert.matches("%-H Content%-Type: application/json", s)
      assert.matches("%-%-data%-binary @%-", s)
      assert.matches("%-%-max%-time 1%.500", s)
      assert.matches("%-L", s)
      assert.matches("%-b /tmp/jar %-c /tmp/jar", s)
      assert.matches("%-%-http1%.1", s)
      assert.equal("http://x/y?a=1&b=x%20y", args[#args])
      for _, a in ipairs(args) do
        assert.falsy(a:find('"k"', 1, true), "body must not be in argv")
      end
    end)

    it("defaults to GET without a body and keeps dict headers sorted", function()
      local args, stdin =
        http.build_args({ url = "http://x/?z=1", headers = { B = "2", A = "1" }, query = { q = "?" } })
      assert.is_nil(stdin)
      local s = table.concat(args, " ")
      assert.matches("%-X GET", s)
      assert.truthy(s:find("-H A: 1 -H B: 2", 1, true))
      assert.equal("http://x/?z=1&q=%3F", args[#args])
      assert.equal("--head", http.build_args({ url = "u", method = "head" })[3])
    end)

    it("parses the last hop of a -D dump", function()
      local list, map, status = http.parse_headers(
        "HTTP/1.1 302 Found\r\nLocation: /b\r\n\r\nHTTP/2 200\r\nA: 1\r\nset-cookie: x\r\nA: 2\r\n\r\n"
      )
      assert.equal(200, status)
      assert.are.same({ { "A", "1" }, { "set-cookie", "x" }, { "A", "2" } }, list)
      assert.equal("2", map.a)
    end)
  end)

  describe("decoders (pure)", function()
    it("sse: split chunks, multi-line data, comments, CRLF, flush", function()
      local evs = {}
      local feed = http.sse_decoder(function(ev)
        evs[#evs + 1] = ev
      end)
      feed(": keepalive\n\nevent: delta\nda")
      feed("ta: a\r\ndata: b\r\n\r\ndata: [DONE]\n")
      assert.equal(1, #evs)
      feed(nil)
      assert.are.same({ { event = "delta", data = "a\nb" }, { data = "[DONE]" } }, evs)
    end)

    it("ndjson: split objects, blank lines, errors", function()
      local objs, errs = {}, {}
      local feed = http.ndjson_decoder(function(o)
        objs[#objs + 1] = o
      end, function(l)
        errs[#errs + 1] = l
      end)
      feed('{"a":1}\n\n{"b"')
      feed(':2}\nnope\n{"c":3}')
      feed(nil)
      assert.are.same({ { a = 1 }, { b = 2 }, { c = 3 } }, objs)
      assert.are.same({ "nope" }, errs)
    end)
  end)

  describe("request against a mock server", function()
    it("sends method, headers, query, stdin body; returns status, headers, meta, body", function()
      srv = mock.start(function(req, res)
        res.json(201, { method = req.method, got = vim.json.decode(req.body), q = req.query }, { ["X-Reply"] = "yes" })
      end)
      local out =
        run({ url = srv.url .. "/p", query = { a = "b c" }, body = { hello = "wörld" }, headers = { X = "1" } })
      assert.is_nil(out.err)
      assert.equal(1, out.n)
      assert.is_false(out.fast)
      assert.equal(201, out.res.status)
      assert.equal("yes", out.res.headers["x-reply"])
      assert.equal("application/json", out.res.headers["content-type"])
      local j = out.res:json()
      assert.equal("POST", j.method)
      assert.equal("wörld", j.got.hello)
      assert.equal("a=b%20c", j.q)
      assert.equal(201, out.res.meta.response_code)
      assert.truthy(out.res.meta.time_total)
      assert.truthy(out.res.meta.size_download > 0)
      assert.equal("1", srv.requests[1].headers["x"])
      assert.equal("application/json", srv.requests[1].headers["content-type"])
    end)

    it("reports status >= 400 as kind=http with the response", function()
      srv = mock.start(function(_, res)
        res.json(401, { error = { message = "bad key" } })
      end)
      local out = run({ url = srv.url })
      assert.is_nil(out.res)
      assert.equal("http", out.err.kind)
      assert.equal(401, out.err.code)
      assert.equal("bad key", out.err.response:json().error.message)
    end)

    it("streams SSE chunks incrementally on the main loop", function()
      srv = mock.start(function(_, res)
        res.stream(200, { mock.sse({ t = "a" }), 'data: {"t":', '"b"}\n\n', mock.sse("[DONE]") }, { delay = 10 })
      end)
      local chunks, fast = {}, false
      local out = run({
        url = srv.url,
        method = "POST",
        body = "{}",
        stream = "sse",
        on_chunk = function(ev, handle)
          fast = fast or vim.in_fast_event()
          assert.is_true(handle:is_active())
          chunks[#chunks + 1] = ev.data
        end,
      })
      assert.is_nil(out.err)
      assert.is_false(fast)
      assert.are.same({ '{"t":"a"}', '{"t":"b"}', "[DONE]" }, chunks)
      assert.equal("", out.res.body)
      assert.equal("text/event-stream", out.res.headers["content-type"])
    end)

    it("streams ndjson and raw", function()
      srv = mock.start(function(_, res)
        res.stream(200, { '{"n":1}\n{"n"', ":2}\n" }, { headers = { ["Content-Type"] = "application/x-ndjson" } })
      end)
      local objs = {}
      run({
        url = srv.url,
        stream = "ndjson",
        on_chunk = function(o)
          objs[#objs + 1] = o.n
        end,
      })
      assert.are.same({ 1, 2 }, objs)
      srv.stop()
      srv = mock.start(function(_, res)
        res.stream(200, { "ab", "cd" }, { headers = { ["Content-Type"] = "text/plain" } })
      end)
      local raw = {}
      run({
        url = srv.url,
        stream = "raw",
        on_chunk = function(s)
          raw[#raw + 1] = s
        end,
      })
      assert.equal("abcd", table.concat(raw))
    end)

    it("keeps the raw body of a streamed HTTP error", function()
      srv = mock.start(function(_, res)
        res.json(429, { message = "slow down" })
      end)
      local out = run({ url = srv.url, stream = "sse", on_chunk = function() end })
      assert.equal("http", out.err.kind)
      assert.equal("slow down", out.err.response:json().message)
    end)

    it("times out", function()
      srv = mock.start(function(_, res)
        res.hang()
      end)
      local out = run({ url = srv.url, timeout = 300 })
      assert.equal("timeout", out.err.kind)
      assert.equal(1, out.n)
    end)

    it("cancel() reports cancelled exactly once and stops chunks", function()
      srv = mock.start(function(_, res)
        res.stream(200, { mock.sse("1"), mock.sse("2"), mock.sse("3") }, { delay = 100, hang = true })
      end)
      local chunks, out = {}, {}
      local handle
      handle = http.request({
        url = srv.url,
        stream = "sse",
        on_chunk = function(ev)
          chunks[#chunks + 1] = ev.data
          handle:cancel()
        end,
        on_done = function(res, err)
          out.n = (out.n or 0) + 1
          out.res, out.err = res, err
        end,
      })
      mock.wait(function()
        return out.n ~= nil
      end)
      vim.wait(300)
      assert.equal(1, out.n)
      assert.equal("cancelled", out.err.kind)
      assert.are.same({ "1" }, chunks)
      assert.is_false(handle:is_active())
    end)

    it("reports connection failures as kind=curl", function()
      local tmp = mock.start(function() end)
      local url = tmp.url
      tmp.stop()
      local out = run({ url = url, timeout = 2000 })
      assert.equal("curl", out.err.kind)
      assert.equal(7, out.err.code)
    end)

    it("uses a cookie jar", function()
      local jar = h.tmpdir("jar") .. "/cookies.txt"
      srv = mock.start(function(req, res)
        if req.path == "/set" then
          res.send(200, "ok", { ["Set-Cookie"] = "sid=abc; Path=/" })
        else
          res.send(200, req.headers.cookie or "none")
        end
      end)
      run({ url = srv.url .. "/set", cookie_jar = jar })
      local out = run({ url = srv.url .. "/get", cookie_jar = jar })
      assert.equal("sid=abc", out.res.body)
    end)

    it("http.curl runs raw args and reports exit code + stdout", function()
      srv = mock.start(function(_, res)
        res.send(200, "raw!")
      end)
      local got
      http.curl({ "-sS", srv.url }, {
        on_exit = function(code, stdout)
          got = { code, stdout }
        end,
      })
      mock.wait(function()
        return got ~= nil
      end)
      assert.are.same({ 0, "raw!" }, got)
    end)

    it("delivers a final SSE event / NDJSON line that has no trailing newline", function()
      srv = mock.start(function(_, res)
        res.stream(200, { "data: a\n\n", "data: b" })
      end)
      local chunks = {}
      local out = run({
        url = srv.url,
        stream = "sse",
        on_chunk = function(ev)
          chunks[#chunks + 1] = ev.data
        end,
      })
      assert.is_nil(out.err)
      assert.are.same({ "a", "b" }, chunks)
      srv.stop()
      srv = mock.start(function(_, res)
        res.stream(200, { '{"n":1}\n', '{"n":2}' }, { headers = { ["Content-Type"] = "application/x-ndjson" } })
      end)
      local objs = {}
      run({
        url = srv.url,
        stream = "ndjson",
        on_chunk = function(o)
          objs[#objs + 1] = o.n
        end,
      })
      assert.are.same({ 1, 2 }, objs)
    end)
  end)

  describe("curl invocation", function()
    local real_system, calls
    before_each(function()
      -- record every spawned argv (and the process) while still running the real curl
      real_system, calls = vim.system, {}
      vim.system = function(cmd, opts, cb)
        local call = { cmd = vim.deepcopy(cmd) }
        calls[#calls + 1] = call
        call.obj = real_system(cmd, opts, cb)
        return call.obj
      end
    end)
    after_each(function()
      vim.system = real_system
    end)

    local function header_file(cmd)
      for i, a in ipairs(cmd) do
        if a == "-H" and (cmd[i + 1] or ""):sub(1, 1) == "@" then
          return cmd[i + 1]:sub(2)
        end
      end
    end

    it("starts curl with -q and passes every -H value through a private file, never on argv", function()
      srv = mock.start(function(req, res)
        res.json(
          200,
          { key = req.headers["x-api-key"], auth = req.headers.authorization, empty = req.headers["x-empty"] }
        )
      end)
      local args = http.build_args({
        url = srv.url,
        headers = { { "x-api-key", "sk-FAKE-argv-secret" }, { "Authorization", "Bearer tok-123" }, { "X-Empty", "" } },
      })
      local snapshot = vim.deepcopy(args)
      local got, file, mode, content
      http.curl(args, {
        on_exit = function(code, stdout)
          got = { code = code, body = vim.json.decode(stdout) }
        end,
      })
      local cmd = calls[1].cmd
      file = header_file(cmd)
      local st = file and vim.uv.fs_stat(file)
      mode = st and st.mode % 512
      content = file and table.concat(vim.fn.readfile(file), "\n")
      mock.wait(function()
        return got ~= nil
      end)
      assert.equal("curl", cmd[1])
      assert.equal("-q", cmd[2], "-q must be the first curl argument (~/.curlrc is ignored)")
      for _, a in ipairs(cmd) do
        assert.falsy(a:find("sk-FAKE", 1, true) or a:find("tok-123", 1, true), "secret on argv: " .. a)
      end
      assert.truthy(file, "no -H @file in " .. table.concat(cmd, " "))
      assert.equal(384, mode, "header file must be 0600")
      assert.equal("x-api-key: sk-FAKE-argv-secret\nAuthorization: Bearer tok-123\nX-Empty;", content)
      assert.are.same(snapshot, args, "the caller's args are not modified")
      assert.equal(0, got.code)
      assert.are.same({ key = "sk-FAKE-argv-secret", auth = "Bearer tok-123", empty = "" }, got.body)
      assert.is_nil(vim.uv.fs_stat(file), "header file removed after the run")
    end)

    it("finds -H in short clusters and does not take option values for -H", function()
      srv = mock.start(function(req, res)
        res.send(200, (req.headers["x-a"] or "-") .. "," .. (req.headers["x-b"] or "-"))
      end)
      local got
      http.curl({ "-w", "|-H", "-HX-A: 1", "-sH", "X-B: 2", "--url", srv.url }, {
        on_exit = function(_, stdout)
          got = stdout
        end,
      })
      mock.wait(function()
        return got ~= nil
      end)
      assert.equal("1,2|-H", got)
      local cmd = calls[1].cmd
      assert.falsy(vim.tbl_contains(cmd, "-HX-A: 1") or vim.tbl_contains(cmd, "X-B: 2"))
      assert.truthy(vim.tbl_contains(cmd, "|-H"), "-w value stays")
      assert.truthy(vim.tbl_contains(cmd, "-s"), "the rest of the -sH cluster stays")
    end)

    it("removes the header file on cancel, timeout, HTTP error and spawn failure", function()
      local function file_after(handler, extra)
        srv = mock.start(handler)
        local n = #calls
        local done
        local o = vim.tbl_extend("force", {
          url = srv.url,
          headers = { Authorization = "Bearer x" },
          on_done = function(_, err)
            done = err and err.kind or "ok"
          end,
        }, extra or {})
        local hd = http.request(o)
        local file = header_file(calls[n + 1].cmd)
        assert.truthy(vim.uv.fs_stat(file), "header file exists while curl runs")
        if o.cancel_after then
          vim.wait(o.cancel_after)
          hd:cancel()
        end
        mock.wait(function()
          return done ~= nil
        end, 5000)
        srv.stop()
        srv = nil
        vim.wait(50)
        return done, vim.uv.fs_stat(file)
      end
      local kind, st = file_after(function(_, res)
        res.hang()
      end, { cancel_after = 100 })
      assert.equal("cancelled", kind)
      assert.is_nil(st)
      kind, st = file_after(function(_, res)
        res.hang()
      end, { timeout = 300 })
      assert.equal("timeout", kind)
      assert.is_nil(st)
      kind, st = file_after(function(_, res)
        res.json(401, {})
      end)
      assert.equal("http", kind)
      assert.is_nil(st)
      -- curl not on PATH: nothing is left behind either
      local path, n = vim.env.PATH, #calls
      vim.env.PATH = "/nonexistent"
      local err
      http.request({
        url = "http://127.0.0.1:9/",
        headers = { Authorization = "Bearer x" },
        on_done = function(_, e)
          err = e
        end,
      })
      vim.env.PATH = path
      mock.wait(function()
        return err ~= nil
      end)
      assert.equal("spawn", err.kind)
      local file = header_file(calls[n + 1].cmd)
      assert.truthy(file)
      assert.is_nil(vim.uv.fs_stat(file))
    end)

    it("ignores ~/.curlrc (--fail / --include / --verbose there do not change results)", function()
      local home = h.tmpdir("curlhome")
      vim.fn.writefile({ "--fail", "--include", "--verbose" }, home .. "/.curlrc")
      srv = mock.start(function(_, res)
        res.json(401, { error = { message = "bad key" } })
      end)
      local out = run({ url = srv.url, env = { CURL_HOME = home }, headers = { ["x-api-key"] = "sk-FAKE-rc" } })
      assert.equal("http", out.err.kind)
      assert.equal(401, out.err.code)
      assert.equal("bad key", out.err.response:json().error.message)
      srv.stop()
      srv = mock.start(function(_, res)
        res.stream(200, { "short" }, { headers = { ["Content-Length"] = "100" } })
      end)
      out = run({ url = srv.url, env = { CURL_HOME = home }, headers = { ["x-api-key"] = "sk-FAKE-rc" } })
      assert.equal("curl", out.err.kind)
      assert.falsy(out.err.message:find("sk-FAKE-rc", 1, true), "a verbose trace leaked the key into the error")
    end)

    it("reports a curl killed by a signal as an error, not as a truncated success", function()
      srv = mock.start(function(_, res)
        res.stream(200, { 'data: {"t":"partial"}\n\n' }, { hang = true })
      end)
      local out = {}
      http.request({
        url = srv.url,
        stream = "sse",
        on_chunk = function() end,
        on_done = function(res, err)
          out.res, out.err, out.n = res, err, (out.n or 0) + 1
        end,
      })
      vim.wait(300)
      vim.uv.kill(calls[1].obj.pid, "sigkill")
      mock.wait(function()
        return out.n ~= nil
      end)
      assert.is_nil(out.res)
      assert.equal("curl", out.err.kind)
      assert.matches("signal 9", out.err.message)
    end)
  end)
end)

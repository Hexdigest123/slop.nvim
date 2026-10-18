local h = require("helpers")

local FILES = { headers = "/t/h", body = "/t/b" }

local function base(over)
  return vim.tbl_extend("force", {
    method = "GET",
    url = "http://x.test/a",
    headers = {},
    timeout = 30000,
    follow = false,
  }, over or {})
end

describe("rest runner", function()
  local runner
  before_each(function()
    h.reset()
    vim.notify = function() end
    require("slop").setup({})
    runner = require("slop.modules.rest.runner")
  end)

  describe("build_args()", function()
    local tail = { "-D", "/t/h", "-o", "/t/b", "-w", "%{json}", "--url" }
    local cases = {
      {
        "plain GET",
        base(),
        { "-sS", "--globoff", "-X", "GET", "--max-time", "30" },
        nil,
      },
      {
        "POST body on stdin, headers in order",
        base({ method = "POST", headers = { { "A", "1" }, { "A", "2" }, { "Empty", "" } }, body = "{}" }),
        {
          "-sS",
          "--globoff",
          "-X",
          "POST",
          "-H",
          "A: 1",
          "-H",
          "A: 2",
          "-H",
          "Empty;",
          "--data-binary",
          "@-",
          "--max-time",
          "30",
        },
        "{}",
      },
      {
        "HEAD uses --head and never sends a body",
        base({ method = "HEAD", body = "x" }),
        { "-sS", "--globoff", "--head", "--max-time", "30" },
        nil,
      },
      {
        "redirects, timeout, insecure, http2",
        base({ follow = true, timeout = 2500, insecure = true, version = "HTTP/2" }),
        { "-sS", "--globoff", "-X", "GET", "-L", "--max-redirs", "10", "--max-time", "2.5", "-k", "--http2" },
        nil,
      },
      {
        "cookie jar -b/-c",
        base({ cookie_jar = "/j.txt", version = "HTTP/1.1" }),
        { "-sS", "--globoff", "-X", "GET", "--max-time", "30", "-b", "/j.txt", "-c", "/j.txt", "--http1.1" },
        nil,
      },
      {
        "explicit Cookie header skips -b but keeps -c",
        base({ cookie_jar = "/j.txt", headers = { { "Cookie", "a=b" } } }),
        { "-sS", "--globoff", "-X", "GET", "-H", "Cookie: a=b", "--max-time", "30", "-c", "/j.txt" },
        nil,
      },
    }
    for _, c in ipairs(cases) do
      it(c[1], function()
        local args, stdin = runner.build_args(c[2], FILES)
        local want = vim.list_extend(vim.deepcopy(c[3]), tail)
        want[#want + 1] = c[2].url
        assert.are.same(want, args)
        assert.equal(c[4], stdin)
      end)
    end
  end)

  describe("resolve()", function()
    local parser = require("slop.modules.rest.parser")
    local function req(text, file)
      return parser.parse(vim.split(text, "\n", { plain = true }), file or "/nowhere/a.http").requests[1]
    end
    local function opts(ctx, over)
      return vim.tbl_extend("force", {
        ctx = ctx or { process = false },
        timeout = 30000,
        follow_redirects = true,
        cookie_jar = "/jar",
      }, over or {})
    end

    it("expands url/headers/body, encodes spaces, applies defaults and directives", function()
      local r = req('# @no-redirect\n# @timeout 3s\nPOST {{base}}/a b\nX-T: {{t}}\n\n{"t": "{{t}}"}')
      local out = assert(runner.resolve(r, opts({ file = { base = "http://h", t = "v" } }, { headers = { UA = "x" } })))
      assert.equal("http://h/a%20b", out.url)
      assert.are.same({ { "X-T", "v" }, { "UA", "x" } }, out.headers)
      assert.equal('{"t": "v"}', out.body)
      assert.equal(3000, out.timeout)
      assert.is_false(out.follow)
      assert.equal("/jar", out.cookie_jar)
    end)

    it("@no-cookie-jar and cookies=false drop the jar", function()
      assert.is_nil(runner.resolve(req("# @no-cookie-jar\nGET /a"), opts()).cookie_jar)
      assert.is_nil(runner.resolve(req("GET /a"), opts(nil, { cookie_jar = false })).cookie_jar)
    end)

    it("blocks on unresolved variables and names them", function()
      local out, err, missing = runner.resolve(req("GET {{base}}/{{id}}\nAuthorization: Bearer {{token}}"), opts())
      assert.is_nil(out)
      assert.equal("unresolved variables: {{base}}, {{id}}, {{token}}", err)
      assert.are.same({ "base", "id", "token" }, missing)
    end)

    it("Basic auth shorthand is base64-encoded after expansion", function()
      local out =
        runner.resolve(req("GET /a\nAuthorization: Basic {{u}}:{{p}}"), opts({ file = { u = "ann", p = "pw" } }))
      assert.are.same({ { "Authorization", "Basic " .. vim.base64.encode("ann:pw") } }, out.headers)
      assert.equal("Basic " .. vim.base64.encode("a:b c"), runner.basic_auth("Basic a:b c"))
      assert.equal("Basic " .. vim.base64.encode("user:pass"), runner.basic_auth("Basic user pass"))
      assert.equal("Basic YWxhZGRpbjpvcGVu", runner.basic_auth("Basic YWxhZGRpbjpvcGVu"))
      assert.equal("Bearer x:y", runner.basic_auth("Bearer x:y"))
    end)

    it("splices < includes raw (no variable expansion) relative to the .http file", function()
      local dir = h.tmpdir("inc")
      h.write(dir .. "/data/p.json", '{"raw": "{{notexpanded}}"}\n')
      local r = req("POST /a\n\n{{pre}}\n< ./data/p.json", dir .. "/a.http")
      local out = assert(runner.resolve(r, opts({ file = { pre = "first" } })))
      assert.equal('first\n{"raw": "{{notexpanded}}"}', out.body)
      local missing = req("POST /a\n\n< ./nope.json", dir .. "/a.http")
      local o2, err = runner.resolve(missing, opts())
      assert.is_nil(o2)
      assert.matches("body include not found", err)
    end)
  end)

  it("parse_headers() takes the last hop", function()
    local status, reason, version, headers = runner.parse_headers(
      "HTTP/1.1 302 Found\r\nLocation: /b\r\n\r\nHTTP/2 200 \r\nContent-Type: application/json\r\nX-A: 1\r\n\r\n"
    )
    assert.equal(200, status)
    assert.is_nil(reason)
    assert.equal("2", version)
    assert.are.same({ { "Content-Type", "application/json" }, { "X-A", "1" } }, headers)
    assert.equal(0, (runner.parse_headers("")))
  end)

  describe("execute() against a mock server (real curl)", function()
    local mock, srv
    before_each(function()
      mock = require("services.ai.mock_server")
    end)
    after_each(function()
      if srv then
        srv:stop()
        srv = nil
      end
    end)

    local function run(r)
      local got
      runner.execute(r, function(res, err)
        got = { res = res, err = err }
      end)
      assert.is_true(vim.wait(10000, function()
        return got ~= nil
      end, 10))
      return got.res, got.err
    end

    it("sends method, headers, body via stdin and returns status/headers/body/meta", function()
      srv = mock.start(function(req, res)
        res.send(201, vim.json.encode({ got = req.body, ct = req.headers["content-type"] }), {
          ["Content-Type"] = "application/json",
          ["X-Test"] = "yes",
        })
      end)
      local res, err = run(base({
        method = "POST",
        url = srv.url .. "/items?ids[]=1",
        headers = { { "Content-Type", "application/json" } },
        body = '{"a": 1}',
      }))
      assert.is_nil(err)
      assert.equal(201, res.status)
      assert.equal("Created", res.reason)
      assert.equal("application/json", res.content_type)
      assert.are.same({ got = '{"a": 1}', ct = "application/json" }, vim.json.decode(res.body))
      assert.equal("POST", srv.requests[1].method)
      assert.equal("ids[]=1", srv.requests[1].query)
      local found = false
      for _, hd in ipairs(res.headers) do
        found = found or (hd[1]:lower() == "x-test" and hd[2] == "yes")
      end
      assert.is_true(found)
      assert.truthy(res.time_ms >= 0)
      assert.equal(#res.body, res.size)
    end)

    it("uses the cookie jar across requests", function()
      srv = mock.start(function(req, res)
        if req.path == "/login" then
          res.send(200, "ok", { ["Set-Cookie"] = "sid=abc123; Path=/" })
        else
          res.send(200, req.headers.cookie or "none")
        end
      end)
      local jar = h.tmpdir("jar") .. "/cookies.txt"
      run(base({ url = srv.url .. "/login", cookie_jar = jar }))
      local res = run(base({ url = srv.url .. "/me", cookie_jar = jar }))
      assert.equal("sid=abc123", res.body)
      assert.truthy(h.read(jar):find("abc123", 1, true))
    end)

    it("reports connection errors from %{json} errormsg", function()
      local res, err = run(base({ url = "http://127.0.0.1:1/x", timeout = 3000 }))
      assert.is_nil(res)
      assert.equal("curl", err.kind)
      assert.matches("onnect", err.message)
    end)
  end)
end)

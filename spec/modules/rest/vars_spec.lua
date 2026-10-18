local h = require("helpers")
local vars = require("slop.modules.rest.vars")

describe("rest vars", function()
  describe("precedence: prompt > file > env > .env > process", function()
    local cases = {
      { "prompt wins", { prompt = { x = "P" }, file = { x = "F" }, env = { x = "E" }, dotenv = { x = "D" } }, "P" },
      { "file over env", { file = { x = "F" }, env = { x = "E" }, dotenv = { x = "D" } }, "F" },
      { "env over .env", { env = { x = "E" }, dotenv = { x = "D" } }, "E" },
      {
        ".env over process",
        {
          dotenv = { x = "D" },
          process = function()
            return "PROC"
          end,
        },
        "D",
      },
      {
        "process last",
        {
          process = function(n)
            return n == "x" and "PROC" or nil
          end,
        },
        "PROC",
      },
    }
    for _, c in ipairs(cases) do
      it(c[1], function()
        local out, missing = vars.expand("{{x}}", c[2])
        assert.equal(c[3], out)
        assert.are.same({}, missing)
      end)
    end

    it("process env can be disabled", function()
      vim.env.SLOP_REST_TEST_VAR = "yes"
      assert.equal("yes", (vars.expand("{{SLOP_REST_TEST_VAR}}", {})))
      local out, missing = vars.expand("{{SLOP_REST_TEST_VAR}}", { process = false })
      assert.equal("{{SLOP_REST_TEST_VAR}}", out)
      assert.are.same({ "SLOP_REST_TEST_VAR" }, missing)
    end)
  end)

  it("expands nested file vars (file var referencing env), whitespace inside braces", function()
    local ctx = { file = { base = "{{HOST}}/api", url = "{{ base }}/users" }, env = { HOST = "http://h" } }
    assert.equal("http://h/api/users?x=1", (vars.expand("{{url}}?x=1", ctx)))
  end)

  it("reports every unresolved variable once and keeps the text", function()
    local out, missing = vars.expand("{{a}}/{{b}}/{{a}}/{{ok}}", { file = { ok = "1" }, process = false })
    assert.equal("{{a}}/{{b}}/{{a}}/1", out)
    assert.are.same({ "a", "b" }, missing)
    assert.equal("unresolved variables: {{a}}, {{b}}", vars.unresolved_message(missing))
    assert.equal("unresolved variable: {{a}}", vars.unresolved_message({ "a" }))
  end)

  it("detects cycles instead of looping", function()
    local _, missing = vars.expand("{{a}}", { file = { a = "{{b}}", b = "{{a}}" }, process = false })
    assert.are.same({ "a" }, missing)
  end)

  it("prompt answers are not re-expanded", function()
    assert.equal("{{raw}}", (vars.expand("{{p}}", { prompt = { p = "{{raw}}" } })))
  end)

  describe("dynamic variables", function()
    it("$uuid / $random.uuid", function()
      local a = vars.expand("{{$uuid}}", {})
      local b = vars.expand("{{$random.uuid}}", {})
      assert.matches("^%x%x%x%x%x%x%x%x%-%x%x%x%x%-4%x%x%x%-[89ab]%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$", a)
      assert.not_equal(a, b)
    end)
    it("$timestamp / $isoTimestamp", function()
      local ts = tonumber((vars.expand("{{$timestamp}}", {})))
      assert.truthy(ts and math.abs(ts - os.time()) < 5)
      assert.matches("^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%dZ$", (vars.expand("{{$isoTimestamp}}", {})))
    end)
    it("$randomInt [min max]", function()
      for _ = 1, 20 do
        local n = tonumber((vars.expand("{{$randomInt 5 7}}", {})))
        assert.truthy(n >= 5 and n <= 7)
      end
      local d = tonumber((vars.expand("{{$randomInt}}", {})))
      assert.truthy(d >= 0 and d <= 1000)
    end)
    it("$processEnv / $dotenv", function()
      vim.env.SLOP_REST_PE = "pe"
      assert.equal("pe", (vars.expand("{{$processEnv SLOP_REST_PE}}", {})))
      assert.equal("dv", (vars.expand("{{$dotenv K}}", { dotenv = { K = "dv" } })))
      local _, missing = vars.expand("{{$dotenv MISSING}}", { dotenv = {} })
      assert.are.same({ "$dotenv MISSING" }, missing)
    end)
    it("user dynamic functions and unknown names", function()
      local ctx = {
        dynamic = {
          hello = function(args)
            return "hi " .. args
          end,
        },
      }
      assert.equal("hi bob", (vars.expand("{{$hello bob}}", ctx)))
      local _, missing = vars.expand("{{$nope}}", ctx)
      assert.are.same({ "$nope" }, missing)
    end)
  end)

  describe("chaining", function()
    local res = {
      status = 200,
      headers = { { "Content-Type", "application/json" }, { "X-Request-Id", "rid-1" } },
      body = vim.json.encode({ token = "tok", user = { id = 7, tags = { "a", "b" } }, ["odd key"] = true }),
    }
    local ctx = {
      response = function(name)
        return name == "login" and res or nil
      end,
    }
    local cases = {
      { "{{login.response.body.$.token}}", "tok" },
      { "{{login.response.body.$.user.id}}", "7" },
      { "{{login.response.body.$.user.tags[1]}}", "b" },
      { "{{login.response.body.$['odd key']}}", "true" },
      { "{{login.response.body.$.user.tags}}", '["a","b"]' },
      { "{{login.response.headers.x-request-id}}", "rid-1" },
    }
    for _, c in ipairs(cases) do
      it(c[1], function()
        local out, missing = vars.expand(c[1], ctx)
        assert.are.same({}, missing)
        assert.equal(c[2], out)
      end)
    end
    it("raw body with * and missing paths/responses are unresolved", function()
      assert.equal(res.body, (vars.expand("{{login.response.body.*}}", ctx)))
      local _, m1 = vars.expand("{{login.response.body.$.nope}}", ctx)
      local _, m2 = vars.expand("{{other.response.body.$.x}}", ctx)
      assert.equal(1, #m1)
      assert.equal(1, #m2)
    end)
    it("chain_ref() and refs()", function()
      assert.are.same({ "a.b", "login", "body", "$.x" }, {
        "a.b",
        vars.chain_ref("login.response.body.$.x"),
      })
      local n, k, p = vars.chain_ref("my req.response.headers.Location")
      assert.are.same({ "my req", "headers", "Location" }, { n, k, p })
      assert.is_nil(vars.chain_ref("x.response.cookies.a"))
      assert.are.same({ "a", "b.response.body.*" }, vars.refs("{{ a }} {{b.response.body.*}}"))
    end)
  end)

  it("parse_dotenv()", function()
    local env = vars.parse_dotenv(table.concat({
      "# comment",
      "A=1",
      "export B = two ",
      'C="quoted # not comment"',
      "D='single'",
      "E=value # trailing comment",
      'F="multi\\nline"',
      "",
      "garbage line",
    }, "\n"))
    assert.are.same({
      A = "1",
      B = "two",
      C = "quoted # not comment",
      D = "single",
      E = "value",
      F = "multi\nline",
    }, env)
  end)
end)

describe("rest env files", function()
  local env
  before_each(function()
    h.reset()
    require("slop").setup({})
    env = require("slop.modules.rest.env")
  end)

  it("merges $shared and the env, closest file and private file win", function()
    local root = h.tmpdir("envroot")
    h.write(
      root .. "/http-client.env.json",
      vim.json.encode({ ["$shared"] = { s = "root-shared", a = "shared" }, dev = { a = "root-dev", b = "root-b" } })
    )
    h.write(root .. "/http-client.private.env.json", vim.json.encode({ dev = { secret = "root-private" } }))
    h.write(root .. "/api/http-client.env.json", vim.json.encode({ dev = { b = "api-b" }, prod = { a = "p" } }))
    h.write(root .. "/api/x.http", "GET /")
    local v, files = env.load(root .. "/api/x.http", root, "dev")
    assert.are.same({ s = "root-shared", a = "root-dev", b = "api-b", secret = "root-private" }, v)
    assert.equal(3, #files)
    local none = env.load(root .. "/api/x.http", root, nil)
    assert.are.same({ s = "root-shared", a = "shared" }, none)
    assert.are.same({ "dev", "prod" }, env.names(files))
  end)

  it("nearest .env upward to the root", function()
    local root = h.tmpdir("dotroot")
    h.write(root .. "/.env", "A=root\n")
    h.write(root .. "/sub/deeper/x.http", "GET /")
    local v, path = env.dotenv(root .. "/sub/deeper/x.http", root, ".env")
    assert.are.same({ A = "root" }, v)
    assert.equal(root .. "/.env", path)
    h.write(root .. "/sub/.env", "A=sub\n")
    assert.are.same({ A = "sub" }, (env.dotenv(root .. "/sub/deeper/x.http", root, ".env")))
    assert.are.same({}, (env.dotenv(root .. "/sub/deeper/x.http", root, false)))
  end)
end)

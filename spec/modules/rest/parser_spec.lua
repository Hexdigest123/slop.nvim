local parser = require("slop.modules.rest.parser")

local function parse(text)
  return parser.parse(vim.split(text, "\n", { plain = true }), "/p/api.http")
end

--- Fixture table: { name, input, expect = function(parsed) ... end } or a partial request table to compare.
local fixtures = {
  {
    "minimal GET with title",
    "### Get users\nGET https://x.test/users",
    { { title = "Get users", name = "Get users", method = "GET", url = "https://x.test/users", line = 2 } },
  },
  {
    "method-less url defaults to GET",
    "https://x.test/a\n\n###\n{{base}}/b",
    { { method = "GET", url = "https://x.test/a" }, { method = "GET", url = "{{base}}/b" } },
  },
  {
    "HTTP version is split off",
    "POST https://x.test/a HTTP/1.1",
    { { method = "POST", url = "https://x.test/a", version = "HTTP/1.1" } },
  },
  {
    "all methods are recognised",
    "###\nPATCH /a\n###\nDELETE /b\n###\nHEAD /c\n###\nOPTIONS /d\n###\nPUT /e",
    {
      { method = "PATCH" },
      { method = "DELETE" },
      { method = "HEAD" },
      { method = "OPTIONS" },
      { method = "PUT" },
    },
  },
  {
    "multi-line query continuation",
    "GET https://x.test/search\n    ?q=1\n    &page=2\n    #frag",
    { { url = "https://x.test/search?q=1&page=2#frag" } },
  },
  {
    "headers in order with duplicates and comments between",
    "GET /a\nAccept: a\n# a comment\nX-Dup: 1\nX-Dup: 2\n// other comment",
    { { headers = { { "Accept", "a" }, { "X-Dup", "1" }, { "X-Dup", "2" } } } },
  },
  {
    "body after a blank line, trailing blank lines trimmed",
    'POST /a\nContent-Type: application/json\n\n{\n  "a": 1\n}\n\n\n### next\nGET /b',
    { { body = '{\n  "a": 1\n}', stop = 6 }, { method = "GET", start = 9 } },
  },
  {
    "body may contain # lines and blank lines",
    "POST /a\n\nline1\n\n# not a comment\nline3",
    { { body = "line1\n\n# not a comment\nline3" } },
  },
  {
    "body include line kept verbatim",
    "POST /a\n\n< ./payload.json",
    { { body = "< ./payload.json" } },
  },
  {
    "directives (# and //)",
    "### t\n# @name login\n// @depends a, b\n# @prompt otp One-time password\n# @prompt code\n"
      .. "# @no-cookie-jar\n# @no-redirect\n# @timeout 2.5s\nPOST /login",
    {
      {
        name = "login",
        title = "t",
        meta = {
          depends = { "a", "b" },
          prompt = { { name = "otp", desc = "One-time password" }, { name = "code" } },
          no_cookie_jar = true,
          no_redirect = true,
          timeout = 2500,
        },
      },
    },
  },
  {
    "@name = value form and directives after the request line",
    "# @name=first\nGET /a\n# @timeout 500ms\nAccept: x",
    { { name = "first", meta = { depends = {}, prompt = {}, timeout = 500 }, headers = { { "Accept", "x" } } } },
  },
  {
    "Basic auth header is kept for the runner",
    "GET /a\nAuthorization: Basic user:pass",
    { { headers = { { "Authorization", "Basic user:pass" } } } },
  },
  {
    "CRLF line endings",
    "### a\r\nGET /a\r\nAccept: x\r\n\r\nbody\r\n",
    { { url = "/a", headers = { { "Accept", "x" } }, body = "body" } },
  },
  {
    "blocks without a request line are not requests",
    "@a = 1\n# just a comment\n\n### empty\n\n### real\nGET /x",
    { { title = "real", url = "/x" } },
  },
}

describe("rest parser fixtures", function()
  for _, f in ipairs(fixtures) do
    it(f[1], function()
      local out = parse(f[2])
      assert.equal(#f[3], #out.requests, vim.inspect(out.requests))
      for i, want in ipairs(f[3]) do
        local got = out.requests[i]
        for k, v in pairs(want) do
          assert.are.same(v, got[k], ("request %d field %s"):format(i, k))
        end
        assert.equal("/p/api.http", got.file)
      end
    end)
  end
end)

describe("rest parser", function()
  it("collects file variables outside bodies with their line", function()
    local out =
      parse("@base = http://h\n@token = {{login.response.body.$.t}}\n\n### a\n@inner = 2\nGET /a\n\n@notvar = 3")
    assert.are.same({
      { name = "base", value = "http://h", line = 1 },
      { name = "token", value = "{{login.response.body.$.t}}", line = 2 },
      { name = "inner", value = "2", line = 5 },
    }, out.vars)
    assert.equal("@notvar = 3", out.requests[1].body)
  end)

  it("file_vars(): last declaration above wins, else first below", function()
    local out = parse("@a = 1\n### x\nGET /x\n### y\n@a = 2\n@b = late\nGET /y")
    assert.are.same({ a = "1", b = "late" }, parser.file_vars(out, out.requests[1]))
    assert.are.same({ a = "2", b = "late" }, parser.file_vars(out, out.requests[2]))
  end)

  it("ignores script blocks and response handlers with warnings", function()
    local out = parse(
      "### a\nPOST /a\n\n{\"x\":1}\n\n> {%\n  client.global.set('t', response.body.t);\n%}\n>> ./out.json\n### b\n"
        .. "< {% request.variables.set('a', 1) %}\nGET /b"
    )
    assert.equal(2, #out.requests)
    assert.equal('{"x":1}', out.requests[1].body)
    assert.equal("/b", out.requests[2].url)
    assert.equal(3, #out.warnings)
    assert.matches("script blocks", out.warnings[1].msg)
    assert.matches("not supported", out.warnings[2].msg)
    assert.equal(2, #out.requests[1].warnings)
  end)

  it("warns about a missing blank line before the body (lenient)", function()
    local out = parse("POST /a\nContent-Type: text/plain\nhello there")
    assert.equal("hello there", out.requests[1].body)
    assert.matches("missing blank line", out.warnings[1].msg)
    local json = parse('POST /a\nContent-Type: application/json\n{"a": 1}')
    assert.equal('{"a": 1}', json.requests[1].body)
    assert.equal(0, #json.warnings)
  end)

  it("warns about invalid @timeout values", function()
    local out = parse("# @timeout soon\nGET /a")
    assert.is_nil(out.requests[1].meta.timeout)
    assert.matches("invalid @timeout", out.warnings[1].msg)
  end)

  it("parse_duration()", function()
    assert.equal(10000, parser.parse_duration("10s"))
    assert.equal(10000, parser.parse_duration("10"))
    assert.equal(250, parser.parse_duration("250ms"))
    assert.equal(120000, parser.parse_duration("2m"))
    assert.is_nil(parser.parse_duration("x"))
  end)

  it("at() finds the request containing a line (or the closest above)", function()
    local out = parse("@a = 1\n\n### one\nGET /1\n\n### two\nGET /2\nAccept: x\n")
    assert.equal("/1", parser.at(out, 3).url)
    assert.equal("/1", parser.at(out, 5).url)
    assert.equal("/2", parser.at(out, 6).url)
    assert.equal("/2", parser.at(out, 9).url)
    assert.is_nil(parser.at(out, 1))
  end)

  it("is pure: no vim.api use", function()
    local saved = vim.api
    vim.api = setmetatable({}, {
      __index = function()
        error("vim.api used")
      end,
    })
    local ok, err = pcall(parse, "### a\nGET /a\n\nbody")
    vim.api = saved
    assert.is_true(ok, tostring(err))
  end)
end)

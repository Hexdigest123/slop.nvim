-- cloak pattern matching: cloak.nvim semantics as the oracle, plus the bugs it no longer has.
local h = require("helpers")

describe("cloak patterns", function()
  local P
  before_each(function()
    h.reset()
    P = require("slop.modules.cloak.patterns")
  end)

  local function spans(rule_list, line, opts)
    local out = {}
    for _, s in ipairs(P.compute(P.normalize(rule_list), { line }, 0, opts)) do
      out[#out + 1] = { line:sub(s.col + 1, s.end_col), s.prefix }
    end
    return out
  end

  it("default rule keeps the '=' visible and masks the rest (greedy, incl. comments)", function()
    local r = { { file_pattern = ".env*", cloak_pattern = "=.+" } }
    assert.are.same({ { "value # c", "" } }, spans(r, "KEY=value # c"))
    assert.are.same({}, spans(r, "# just a comment"))
    assert.are.same({}, spans(r, "EMPTY="))
  end)

  it("normalises replace like cloak.nvim (README example)", function()
    local rules = {
      {
        file_pattern = ".env*",
        cloak_pattern = { "(a=).+", { "(b=).+" }, { "(c=).+", replace = "[inner] %1" } },
        replace = "[outer] %1",
      },
    }
    local n = P.normalize(rules)[1]
    assert.equal("[outer] %1", n.patterns[1].replace)
    assert.is_nil(n.patterns[2].replace, "inner table does not inherit")
    assert.equal("[inner] %1", n.patterns[3].replace)
    -- prefix differing from the original is drawn over the whole match
    assert.are.same({ { "a=1234567890ab", "[outer] a=" } }, spans(rules, "a=1234567890ab"))
    -- no replace -> legacy first char stays visible
    assert.are.same({ { "=1234567890ab", "" } }, spans(rules, "b=1234567890ab"))
    assert.are.same({ { "c=1234567890ab", "[inner] c=" } }, spans(rules, "c=1234567890ab"))
  end)

  it("a replace equal to the original keeps it as real text", function()
    local r = { { file_pattern = "*", cloak_pattern = "(token: ).+", replace = "%1" } }
    assert.are.same({ { "hunter2", "" } }, spans(r, "token: hunter2"))
  end)

  it("the legacy visible first character is a whole (multibyte) character", function()
    local r = { { file_pattern = "*", cloak_pattern = "：%S+" } }
    assert.are.same({ { "secret", "" } }, spans(r, "名前：secret # note"))
    r = { { file_pattern = "*", cloak_pattern = "é.+" } }
    assert.are.same({ { "tait", "" } }, spans(r, "x=était"))
  end)

  it("replace without capture groups is ignored (legacy first char)", function()
    local r = { { file_pattern = "*", cloak_pattern = "=.+", replace = "XX" } }
    assert.are.same({ { "abc", "" } }, spans(r, "K=abc"))
  end)

  it("replace may be a function or a table", function()
    local r = {
      {
        file_pattern = "*",
        cloak_pattern = "(k=).+",
        replace = function(c)
          return "<" .. c .. ">"
        end,
      },
    }
    assert.are.same({ { "k=12345678", "<k=>" } }, spans(r, "k=12345678"))
    r = { { file_pattern = "*", cloak_pattern = "(%w+=).+", replace = { ["k="] = "K:" } } }
    assert.are.same({ { "k=123", "K:" } }, spans(r, "k=123"))
  end)

  it("finds multiple matches per line", function()
    local r = { { file_pattern = "*", cloak_pattern = "=%w+" } }
    assert.are.same({ { "x1", "" }, { "y22", "" } }, spans(r, "A=x1 B=y22"))
  end)

  it("touching matches: the search goes on at the last char of a match, like cloak.nvim", function()
    -- `%d%d%d` matches 123, 345, 567, 789: each one's visible first char lies under the previous mask
    -- (going on after the match instead matched 123, 456, 789 and left 4 and 7 visible)
    local line = "pin 123456789"
    local masked = {}
    for _, sp in ipairs(P.compute(P.normalize({ { file_pattern = "*", cloak_pattern = "%d%d%d" } }), { line }, 0)) do
      for c = sp.col + 1, sp.end_col do
        masked[c] = true
      end
    end
    for c = 6, #line do
      assert.is_true(masked[c] == true, ("column %d (%s) not masked"):format(c, line:sub(c, c)))
    end
    assert.is_nil(masked[5], "the first char of the run stays visible")
  end)

  it("try_all_patterns: earliest start, tie -> longest; false -> list order", function()
    local r = { { file_pattern = "*", cloak_pattern = { "b=%w", "a=%w+", "a=%w+%s%w+" } } }
    assert.are.same({ { "=1 2", "" }, { "=3", "" } }, spans(r, "a=1 2 b=3"))
    assert.are.same(
      { { "=3", "" } },
      spans(r, "a=1 2 b=3", { try_all_patterns = false }),
      "first pattern in list order that matches anywhere"
    )
  end)

  it("terminates on single-char and empty matches (cloak.nvim infinite loop)", function()
    local r = { { file_pattern = "*", cloak_pattern = "=%S*" } }
    assert.are.same({ { "x", "" } }, spans(r, "A= B=x"))
    r = { { file_pattern = "*", cloak_pattern = "x*" } }
    assert.are.same({}, spans(r, "abc"))
    r = { { file_pattern = "*", cloak_pattern = "." } }
    assert.equal(0, #spans(r, "abc"), "1-char matches only keep the legacy visible char")
  end)

  it("stacked rules compose and overlapping spans merge", function()
    local rules = P.normalize({
      { file_pattern = "*.yaml", cloak_pattern = "(password: ).+", replace = "%1" },
      { file_pattern = "secrets/*", cloak_pattern = "(token: ).+", replace = "%1" },
      { file_pattern = "*.yaml", cloak_pattern = "(pass)word: .+", replace = "%1" },
    })
    local path = "/p/x/secrets/app.yaml"
    local applied = P.rules_for(rules, path)
    assert.equal(3, #applied)
    local s = P.compute(applied, { "password: a", "token: b" }, 3)
    assert.are.same({
      { row = 3, col = 4, end_col = 11, prefix = "" },
      { row = 4, col = 7, end_col = 8, prefix = "" },
    }, s)
  end)

  it("file patterns: no '/' -> basename, else full path; exclude wins", function()
    local rules = P.normalize({
      { file_pattern = ".env*", cloak_pattern = "=.+" },
      { file_pattern = "config/*.yaml", cloak_pattern = ":.+" },
    })
    assert.equal(1, #P.rules_for(rules, "/a/b/.env.local"))
    assert.equal(1, #P.rules_for(rules, "/a/.envrc"))
    assert.equal(0, #P.rules_for(rules, "/a/env"))
    assert.equal(1, #P.rules_for(rules, "/a/config/db.yaml"))
    assert.equal(0, #P.rules_for(rules, "/a/other/db.yaml"))
    assert.equal(0, #P.rules_for(rules, "/a/.env.example", { ".env.example" }))
    assert.equal(0, #P.rules_for(rules, ""))
  end)

  it("validate reports bad patterns with paths", function()
    local errs = P.validate({
      { file_pattern = ".env*", cloak_pattern = "=.+" },
      { file_pattern = 3, cloak_pattern = { "ok", "[unclosed" } },
      { file_pattern = "*", cloak_pattern = { { "(%" } } },
    }, "patterns")
    assert.equal(3, #errs)
    assert.matches("^patterns%[2%]%.file_pattern", errs[1])
    assert.matches("^patterns%[2%]%.cloak_pattern%[2%]: invalid Lua pattern", errs[2])
    assert.matches("^patterns%[3%]%.cloak_pattern%[1%]%[1%]", errs[3])
    assert.are.same({}, P.validate(P.builtin, "builtin"))
  end)

  it("validate catches pattern errors that only show up when the matcher reaches them", function()
    -- string.find("", pat) accepts all of these; matching "API_KEY=x" etc. throws
    local bad = {
      ["(password: .+"] = "unfinished capture",
      ["=.+%"] = "ends with '%%'",
      ["=[%w"] = "missing ']'",
      ["=%f"] = "missing '%[' after '%%f'",
      ["=%f[%w"] = "missing ']'",
      ["password: %b"] = "missing arguments to '%%b'",
      ["a%1(b)"] = "invalid capture index",
      ["x%0"] = "invalid capture index",
      ["a)"] = "invalid pattern capture",
      [("(.)"):rep(33)] = "too many captures",
    }
    for pat, err in pairs(bad) do
      local errs = P.validate({ { file_pattern = "*", cloak_pattern = pat } }, "patterns")
      assert.equal(1, #errs, pat)
      assert.matches("^patterns%[1%]%.cloak_pattern: invalid Lua pattern .*" .. err, errs[1])
    end
    local good = { "=.+", "(%w+)=%1", "[]]", "[^]]+", "[%]]", "%b()", "%f[%w]%w+", "()=", "%%", "^(%s*)%S.*" }
    for _, pat in ipairs(good) do
      assert.are.same({}, P.validate({ { file_pattern = "*", cloak_pattern = pat } }, "patterns"), pat)
    end
  end)

  it("compute fails closed when a pattern throws anyway: the whole line is a span, reported once", function()
    local msgs = {}
    local notify = vim.notify
    vim.notify = function(m)
      msgs[#msgs + 1] = m
    end
    local rules = P.normalize({ { file_pattern = "*", cloak_pattern = "(password: .+" } }, "mine")
    local s = P.compute(rules, { "user: me", "password: hunter2", "" }, 4)
    assert.are.same({ { row = 5, col = 0, end_col = 17, prefix = "" } }, s)
    P.compute(rules, { "password: again" }, 0)
    vim.wait(20)
    vim.notify = notify
    assert.equal(1, #msgs)
    assert.matches("mine%[1%]: pattern error %(unfinished capture%)", msgs[1])
  end)

  describe("builtin rules", function()
    local function apply(path, line)
      local rules = P.rules_for(P.normalize(P.builtin), path)
      local out = {}
      for _, s in ipairs(P.compute(rules, { line }, 0)) do
        out[#out + 1] = line:sub(s.col + 1, s.end_col)
      end
      return out
    end

    it("http-client env json string values", function()
      assert.are.same({ "abc123" }, apply("/p/http-client.private.env.json", '    "token": "abc123",'))
      assert.are.same({ "localhost" }, apply("/p/http-client.env.json", '"host": "localhost"'))
      assert.are.same({}, apply("/p/http-client.env.json", '  "dev": {'))
      -- an escaped quote does not end the masked value
      assert.are.same({ 'has\\"quote"' }, apply("/p/http-client.private.env.json", '  "password": "has\\"quote",'))
    end)

    it(".npmrc / .netrc / aws credentials", function()
      assert.are.same({ '"user:pass"' }, apply("/h/.yarnrc.yml", 'npmAuthIdent: "user:pass"'))
      assert.are.same({ "npm_XYZ" }, apply("/h/.npmrc", "//registry.npmjs.org/:_authToken=npm_XYZ"))
      assert.are.same({ "s3cr3t" }, apply("/h/.netrc", "machine x login me password s3cr3t"))
      assert.are.same({ "wJalr" }, apply("/h/.aws/credentials", "aws_secret_access_key = wJalr"))
      assert.are.same({}, apply("/h/notaws/credentials.txt", "aws_secret_access_key = wJalr"))
    end)

    it(".nvim/state files are masked entirely", function()
      assert.are.same(
        { "example.com\tFALSE\t/\tsid\tabc" },
        apply("/p/.nvim/state/rest/cookies.txt", "  example.com\tFALSE\t/\tsid\tabc")
      )
    end)

    it(".http Authorization / Cookie header values and token vars", function()
      assert.are.same({ "xyz.abc" }, apply("/p/api.http", "Authorization: Bearer xyz.abc"))
      assert.are.same({ "{{token}}" }, apply("/p/api.http", "Authorization: {{token}}"))
      assert.are.same({ "sid=1; a=2" }, apply("/p/api.rest", "Cookie: sid=1; a=2"))
      assert.are.same({ "k" }, apply("/p/api.http", "X-API-Key: k"))
      assert.are.same({ "abc" }, apply("/p/api.http", "@auth_token = abc"))
      assert.are.same({}, apply("/p/api.http", "GET https://example.com/auth"))
      assert.are.same({}, apply("/p/api.http", "Content-Type: application/json"))
    end)

    it(".http: secret-ish variables, case-insensitive headers, query/form values, JSON bodies", function()
      local cases = {
        ["@password = hunter2"] = "hunter2",
        ["@api_key = abc123"] = "abc123",
        ["@client_secret = s3cr3t"] = "s3cr3t",
        ["@apiKey=xyz"] = "xyz",
        ["AUTHORIZATION: Bearer abc.def"] = "abc.def",
        ["Proxy-Authorization: Basic dXNlcg=="] = "dXNlcg==",
        ["X-Auth-Token: abc123"] = "abc123",
        ["Api-Key: abc123"] = "abc123",
        ["GET https://x/y?api_key=abc&page=2 HTTP/1.1"] = "abc",
        ["user=me&password=hunter2"] = "hunter2",
        ['  "password": "hunter2",'] = 'hunter2"',
      }
      for line, want in pairs(cases) do
        assert.are.same({ want }, apply("/p/api.rest", line), line)
      end
      for _, line in ipairs({ "Host: example.com", "Accept: */*", "@baseUrl = https://example.com", "GET /users" }) do
        assert.are.same({}, apply("/p/api.http", line), line)
      end
    end)
  end)
end)

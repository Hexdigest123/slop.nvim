-- core.secrets v2 additions (owner: cloak): spans(), display providers, ensure() fast path.
local h = require("helpers")

describe("secrets v2", function()
  local secrets
  before_each(function()
    h.reset()
    vim.notify = function() end
    secrets = require("slop.core.secrets")
  end)

  local function finder(word, display)
    return {
      name = "find_" .. word,
      display = display,
      spans = function(_, lines, first_row)
        local out = {}
        for i, l in ipairs(lines) do
          local init = 1
          while true do
            local s, e = l:find(word, init, true)
            if not s then
              break
            end
            out[#out + 1] = { row = first_row + i - 1, col = s - 1, end_col = e }
            init = e + 1
          end
        end
        return out
      end,
    }
  end

  it("spans() unions and merges providers per row with absolute rows", function()
    secrets.register(finder("abc"))
    secrets.register(finder("bcd"))
    local spans = secrets.spans("/p/x.txt", { "xxabcdyy abc", "none", "bcd" }, 5)
    assert.are.same({
      { row = 5, col = 2, end_col = 6 },
      { row = 5, col = 9, end_col = 12 },
      { row = 7, col = 0, end_col = 3 },
    }, spans)
  end)

  it("spans() includes the built-in PEM rule unless display-only", function()
    secrets.register(finder("tok", true))
    local lines = { "-----BEGIN PRIVATE KEY-----", "MIIE", "-----END PRIVATE KEY-----", "tok" }
    assert.equal(2, #secrets.spans(nil, lines))
    local d = secrets.spans(nil, lines, 0, { display = true })
    assert.are.same({ { row = 3, col = 0, end_col = 3 } }, d)
  end)

  it("display-only spans skip providers without display = true", function()
    secrets.register(finder("tok"))
    assert.equal(0, #secrets.spans("/p/a", { "tok" }, 0, { display = true }))
    assert.equal(1, #secrets.spans("/p/a", { "tok" }, 0))
  end)

  it("match_path is not called for unnamed sources", function()
    local called = false
    local p = finder("tok")
    p.match_path = function()
      called = true
      return true
    end
    secrets.register(p)
    assert.equal(0, #secrets.spans(nil, { "tok" }))
    assert.is_false(called)
    assert.equal(1, #secrets.spans("/p/a", { "tok" }))
  end)

  it("loads providers once per config generation", function()
    local registry = require("slop.core.registry")
    local calls = 0
    local orig = registry.load_capability
    registry.load_capability = function(cap)
      calls = calls + 1
      return orig(cap)
    end
    secrets.is_blocked("/p/a.lua")
    secrets.is_blocked("/p/b.lua")
    secrets.redact_text("x", "/p/c.lua")
    assert.equal(1, calls)
    require("slop.config").setup({})
    secrets.is_blocked("/p/a.lua")
    assert.equal(2, calls)
  end)

  it("redact_diff applies multi-line rules per hunk (PEM body in a non-blocked file)", function()
    local diff = table.concat({
      "diff --git a/deploy/key.txt b/deploy/key.txt",
      "--- a/deploy/key.txt",
      "+++ b/deploy/key.txt",
      "@@ -1,2 +1,6 @@",
      " note",
      "-old",
      "+-----BEGIN OPENSSH PRIVATE KEY-----",
      "+MIIEsecretbody1",
      "+MIIEsecretbody2",
      "+-----END OPENSSH PRIVATE KEY-----",
      "\\ No newline at end of file",
    }, "\n")
    local out, n = secrets.redact_diff(diff)
    assert.falsy(out:find("MIIE", 1, true))
    assert.truthy(out:find("+-----BEGIN OPENSSH PRIVATE KEY-----\n+<redacted>\n+<redacted>\n", 1, true))
    assert.truthy(out:find(" note\n-old\n", 1, true))
    assert.truthy(out:find("\\ No newline at end of file", 1, true))
    assert.equal(2, n)
  end)

  it("is_cloaked catches a range inside a PEM body whose BEGIN/END lie outside it", function()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(buf, "/p/notes.md")
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "intro",
      "-----BEGIN RSA PRIVATE KEY-----",
      "MIIEaaaa",
      "MIIEbbbb",
      "-----END RSA PRIVATE KEY-----",
      "outro",
    })
    assert.is_true(secrets.is_cloaked(buf, { 3, 0, 3, 4 }))
    assert.is_true(secrets.is_cloaked(buf, { 2, 2, 3, 1 }))
    assert.is_false(secrets.is_cloaked(buf, { 0, 0, 0, 5 }))
    assert.is_false(secrets.is_cloaked(buf, { 5, 0, 5, 5 }))
  end)

  describe("with the cloak provider", function()
    it("a query before cloak is loaded still applies cloak rules (capability lazy-load)", function()
      local registry = require("slop.core.registry")
      assert.is_false(registry.is_loaded("cloak"))
      local out, n = secrets.redact_lines("/p/api.http", { "GET /x", "Authorization: Bearer abc.def" })
      assert.is_true(registry.is_loaded("cloak"))
      assert.are.same({ "GET /x", "Authorization: Bearer <redacted>" }, out)
      assert.equal(1, n)
    end)

    it("block = true rules and core globs block whole files", function()
      assert.is_true(secrets.is_blocked("/p/.nvim/state/rest/cookies.txt"))
      assert.is_true(secrets.is_blocked("/home/u/.netrc"))
      assert.is_true(secrets.is_blocked("/home/u/.aws/credentials"))
      assert.is_false(secrets.is_blocked("/p/api.http"))
      assert.is_false(secrets.is_blocked("/p/http-client.env.json"))
    end)

    it("redact_diff redacts cloak spans of non-blocked files", function()
      local diff = table.concat({
        "diff --git a/api.http b/api.http",
        "--- a/api.http",
        "+++ b/api.http",
        "@@ -1,2 +1,2 @@",
        " GET https://x",
        "-Authorization: Bearer old",
        "+Authorization: Bearer new",
        "diff --git a/.nvim/state/rest/cookies.txt b/.nvim/state/rest/cookies.txt",
        "@@ -1 +1 @@",
        "+x\tsid\tabc",
      }, "\n")
      local out = secrets.redact_diff(diff)
      assert.truthy(out:find("+Authorization: Bearer <redacted>", 1, true))
      assert.truthy(out:find("-Authorization: Bearer <redacted>", 1, true))
      assert.truthy(out:find("[slop: diff of .nvim/state/rest/cookies.txt omitted]", 1, true))
      assert.falsy(out:find("sid", 1, true))
    end)

    it("display toggles never disable redaction; is_cloaked follows text", function()
      require("slop").cloak.disable()
      local buf = vim.api.nvim_create_buf(false, true)
      vim.b[buf].slop_secret_path = "/p/api.http"
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "GET /x", "Cookie: sid=1" })
      assert.is_true(secrets.is_cloaked(buf))
      assert.is_true(secrets.is_cloaked(buf, { 1, 8, 1, 10 }))
      assert.is_false(secrets.is_cloaked(buf, { 0, 0, 0, 6 }))
      assert.is_false(secrets.is_cloaked(buf, { 1, 0, 1, 7 }), "header name is not secret")
      assert.equal("GET /x\nCookie: <redacted>", (secrets.redact_text("GET /x\nCookie: sid=1", buf)))
    end)

    it("user rules (cloak.patterns) and add_rules() feed redaction", function()
      require("slop").setup({
        cloak = { patterns = { { file_pattern = "*.yaml", cloak_pattern = "(password: ).+", replace = "%1" } } },
      })
      assert.are.same({ "password: <redacted>" }, (secrets.redact_lines("/p/a.yaml", { "password: x" })))
      assert.are.same({ "A=1" }, (secrets.redact_lines("/p/x.envish", { "A=1" })))
      require("slop").cloak.add_rules(
        "mine",
        { { file_pattern = "*.ini", cloak_pattern = "(key=).+", replace = "%1" } }
      )
      assert.are.same({ "key=<redacted>" }, (secrets.redact_lines("/p/a.ini", { "key=v" })))
      require("slop").cloak.remove_rules("mine")
      assert.are.same({ "key=v" }, (secrets.redact_lines("/p/a.ini", { "key=v" })))
    end)

    it("cloak disabled in config -> no cloak provider (core block list still applies)", function()
      require("slop").setup({ cloak = { enabled = false } })
      assert.are.same({ "Cookie: sid=1" }, (secrets.redact_lines("/p/api.http", { "Cookie: sid=1" })))
      assert.is_true(secrets.is_blocked("/p/.env"))
      assert.is_false(require("slop.core.registry").is_loaded("cloak"))
    end)
  end)
end)

local h = require("helpers")

describe("secrets", function()
  local secrets
  before_each(function()
    h.reset()
    vim.notify = function() end
    secrets = require("slop.core.secrets")
  end)

  it("blocks the built-in default globs with no provider registered", function()
    -- cloak is a lazily-loaded secrets provider; disable it to test the bare default path.
    require("slop.config").setup({ cloak = false })
    for _, p in ipairs({
      "/p/.env",
      "/p/.env.local",
      "/p/.env.example",
      "/p/certs/server.pem",
      "/p/id.key",
      "/p/a.p12",
      "/p/b.pfx",
      "/p/my_secret.txt",
      "/p/config/secrets.yaml",
      "/p/aws_credentials",
      "/p/credentials.json",
      "/p/my-private-key.txt",
    }) do
      assert.is_true(secrets.is_blocked(p), p)
    end
    for _, p in ipairs({ "/p/main.lua", "/p/env.lua", "/p/README.md", "/p/keyboard.c" }) do
      assert.is_false(secrets.is_blocked(p), p)
    end
    assert.equal(0, #secrets.providers())
  end)

  it("redact_text replaces blocked files entirely", function()
    local text, n = secrets.redact_text("API_KEY=abc\nX=1", "/p/.env")
    assert.equal("<redacted>", text)
    assert.equal(1, n)
    text, n = secrets.redact_text("local x = 1", "/p/main.lua")
    assert.equal("local x = 1", text)
    assert.equal(0, n)
  end)

  it("always redacts PEM private key bodies", function()
    local pem = table.concat(
      { "x", "-----BEGIN RSA PRIVATE KEY-----", "MIIEabc", "def", "-----END RSA PRIVATE KEY-----", "y" },
      "\n"
    )
    local text, n = secrets.redact_text(pem, "/p/notes.md")
    assert.equal(2, n)
    assert.falsy(text:find("MIIEabc", 1, true))
    assert.truthy(text:find("BEGIN RSA PRIVATE KEY", 1, true))
  end)

  it("honours config secrets.block and the effective-path buffer var", function()
    require("slop.config").setup({ secrets = { block = { "*.vault" } } })
    assert.is_true(secrets.is_blocked("/p/x.vault"))
    assert.is_false(secrets.is_blocked("/p/.env"), "user list replaces the default list")
    local buf = vim.api.nvim_create_buf(false, true)
    vim.b[buf].slop_secret_path = "/p/thing.vault"
    assert.is_true(secrets.is_blocked(buf))
    assert.is_true(secrets.is_cloaked(buf))
  end)

  it("applies provider spans and block globs", function()
    secrets.register({
      name = "test",
      block = { "*.private.env.json" },
      match_path = function(p)
        return p:match("%.ya?ml$") ~= nil
      end,
      spans = function(_, lines, first_row)
        local out = {}
        for i, l in ipairs(lines) do
          local s, e = l:find("token: (%S+)")
          if s then
            local vs = l:find("%S+$")
            out[#out + 1] = { row = first_row + i - 1, col = vs - 1, end_col = e }
          end
        end
        return out
      end,
    })
    assert.is_true(secrets.is_blocked("/p/dev.private.env.json"))
    local text, n = secrets.redact_text("name: x\ntoken: hunter2\n", "/p/c.yaml")
    assert.equal("name: x\ntoken: <redacted>\n", text)
    assert.equal(1, n)
    text = secrets.redact_text("token: hunter2", "/p/c.lua")
    assert.equal("token: hunter2", text, "provider does not match .lua")
    local lines = secrets.redact_lines("/p/c.yml", { "token: a", "ok" }, 10)
    assert.are.same({ "token: <redacted>", "ok" }, lines)

    local buf = vim.api.nvim_create_buf(false, true)
    vim.b[buf].slop_secret_path = "/p/c.yaml"
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "name: x", "token: hunter2" })
    assert.is_true(secrets.is_cloaked(buf))
    assert.is_true(secrets.is_cloaked(buf, { 1, 0, 1, 20 }))
    assert.is_false(secrets.is_cloaked(buf, { 0, 0, 0, 7 }))
    assert.is_false(secrets.is_cloaked(buf, { 1, 0, 1, 5 }))
    secrets.unregister("test")
    assert.is_false(secrets.is_cloaked(buf))
  end)

  it("redact_diff omits blocked files and redacts content lines", function()
    secrets.register({
      name = "t",
      spans = function(_, lines)
        local out = {}
        for i, l in ipairs(lines) do
          local s, e = l:find("SECRET%w*")
          if s then
            out[#out + 1] = { row = i - 1, col = s - 1, end_col = e }
          end
        end
        return out
      end,
    })
    local diff = table.concat({
      "diff --git a/.env b/.env",
      "index 1..2 100644",
      "--- a/.env",
      "+++ b/.env",
      "@@ -1 +1 @@",
      "-A=1",
      "+A=2",
      "diff --git a/main.lua b/main.lua",
      "--- a/main.lua",
      "+++ b/main.lua",
      "@@ -1,2 +1,2 @@",
      " local x = 1",
      "-local k = 'SECRETold'",
      "+local k = 'SECRETnew'",
      "--- comment-looking removed line SECRETx",
    }, "\n")
    local out, n = secrets.redact_diff(diff)
    assert.falsy(out:find("A=2", 1, true))
    assert.truthy(out:find("[slop: diff of .env omitted]", 1, true))
    assert.falsy(out:find("SECRET", 1, true))
    assert.truthy(out:find("+local k = '<redacted>'", 1, true))
    assert.truthy(out:find(" local x = 1", 1, true))
    assert.equal(4, n)
  end)

  it("filter_paths drops blocked paths", function()
    assert.are.same({ "/a/b.lua" }, secrets.filter_paths({ "/a/.env", "/a/b.lua", "/a/k.pem" }))
  end)

  it("loads secret providers (manifest provides = secrets) on first query", function()
    secrets.is_blocked("/p/x.lua")
    assert.is_true(require("slop.core.registry").is_loaded("cloak"))
  end)

  describe("redact_diff renames / copies", function()
    it("omits a section whose OLD path is blocked (its '-' lines are the old file's content)", function()
      local diff = table.concat({
        "diff --git a/config/secrets.yml b/config/settings.yml",
        "similarity index 60%",
        "rename from config/secrets.yml",
        "rename to config/settings.yml",
        "--- a/config/secrets.yml",
        "+++ b/config/settings.yml",
        "@@ -1,2 +1,2 @@",
        " production:",
        "-  stripe_key: sk_live_TOPSECRET_123",
        "+  stripe_key: <%= ENV['STRIPE_KEY'] %>",
        "diff --git a/a.txt b/.env.example",
        "copy from a.txt",
        "copy to .env.example",
        "diff --git a/.env b/env.txt",
        "@@ -1 +1 @@",
        "-API=old-secret",
        "+API=",
      }, "\n")
      local out = secrets.redact_diff(diff)
      assert.falsy(out:find("TOPSECRET", 1, true))
      assert.falsy(out:find("old-secret", 1, true))
      assert.truthy(out:find("[slop: diff of config/secrets.yml omitted]", 1, true))
      assert.truthy(out:find("[slop: diff of .env.example omitted]", 1, true))
      assert.truthy(out:find("[slop: diff of .env omitted]", 1, true))
    end)

    it("redacts the old side with the OLD path's provider rules", function()
      secrets.register({
        name = "yaml-only",
        match_path = function(p)
          return p:match("%.ya?ml$") ~= nil
        end,
        spans = function(_, lines)
          local out = {}
          for i, l in ipairs(lines) do
            local s = l:find("password: ", 1, true)
            if s then
              out[#out + 1] = { row = i - 1, col = s + 9, end_col = #l }
            end
          end
          return out
        end,
      })
      local out = secrets.redact_diff(table.concat({
        "diff --git a/db.yaml b/db.txt",
        "rename from db.yaml",
        "rename to db.txt",
        "--- a/db.yaml",
        "+++ b/db.txt",
        "@@ -1 +1 @@",
        "-password: hunter2",
        "+password: see vault",
      }, "\n"))
      assert.falsy(out:find("hunter2", 1, true))
      assert.truthy(out:find("+password: see vault", 1, true), "new side uses the new path's (no) rules")
      secrets.unregister("yaml-only")
    end)
  end)

  describe("private keys", function()
    local BODY = "MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQC7VJTUt9Us8cKj"
    local BODY2 = "MgorwmaSPBRpQyAAUqaHMVMy9x2RSdj8wXCvl3mq8f6hFuEJUBd6FT9PmQ8F4Gld"

    local function leaks(text, path)
      local red = secrets.redact_text(text, path or "/p/notes.txt")
      return red:find(BODY, 1, true) ~= nil or red:find(BODY2, 1, true) ~= nil or red:find("lQOYBGV", 1, true) ~= nil
    end

    it("finds markers anywhere in a line, one-line escaped keys and PGP blocks", function()
      assert.is_false(
        leaks(
          ('{\n  "private_key": "-----BEGIN PRIVATE KEY-----\\n%s\\n%s\\n-----END PRIVATE KEY-----\\n",\n}'):format(
            BODY,
            BODY2
          ),
          "/p/service.json"
        )
      )
      assert.is_false(
        leaks(
          ("const k = `-----BEGIN RSA PRIVATE KEY-----\n%s\n%s\n-----END RSA PRIVATE KEY-----`"):format(BODY, BODY2),
          "/p/tls_test.go"
        )
      )
      assert.is_false(
        leaks(
          ('KEY = ("-----BEGIN PRIVATE KEY-----\\n"\n  "%s\\n"\n  "%s\\n"\n  "-----END PRIVATE KEY-----\\n")'):format(
            BODY,
            BODY2
          ),
          "/p/fixtures.py"
        )
      )
      assert.is_false(leaks(table.concat({
        "-----BEGIN PGP PRIVATE KEY BLOCK-----",
        "Version: GnuPG v2",
        "",
        "lQOYBGVxyzABCAC7q1",
        "=abcd",
        "-----END PGP PRIVATE KEY BLOCK-----",
      }, "\n")))
      assert.is_false(
        leaks(('KEY="-----BEGIN OPENSSH PRIVATE KEY----- %s %s -----END OPENSSH PRIVATE KEY-----"'):format(BODY, BODY2))
      )
      -- the markers themselves stay (the AI still sees that a key was there)
      local red = secrets.redact_text(("-----BEGIN EC PRIVATE KEY-----\n%s\n-----END EC PRIVATE KEY-----"):format(BODY))
      assert.equal("-----BEGIN EC PRIVATE KEY-----\n<redacted>\n-----END EC PRIVATE KEY-----", red)
    end)

    it("redacts a window that starts inside a key (END without BEGIN, look-back for buffers)", function()
      local lines = { "x", "-----BEGIN RSA PRIVATE KEY-----", BODY, BODY2, BODY, "-----END RSA PRIVATE KEY-----", "y" }
      -- path source: the END marker below the window's key lines
      local out = secrets.redact_lines("/p/notes.md", vim.list_slice(lines, 4, 7), 3)
      assert.are.same({ "<redacted>", "<redacted>", "-----END RSA PRIVATE KEY-----", "y" }, out)
      -- buffer source: rows above the window are looked back, even without an END in the window
      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_name(buf, "/p/key-notes.md")
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
      assert.are.same({ "<redacted>", "<redacted>" }, (secrets.redact_lines(buf, { BODY2, BODY }, 3)))
      assert.are.same(
        { { row = 3, col = 0, end_col = #BODY2 }, { row = 4, col = 0, end_col = #BODY } },
        secrets.spans(buf, { BODY2, BODY }, 3)
      )
      -- without a buffer (no look-back possible) and without an END the window is left alone
      assert.are.same({ BODY2, BODY }, (secrets.redact_lines("/p/key-notes.md", { BODY2, BODY }, 3)))
    end)

    it("a mere mention of a marker in code does not redact what follows", function()
      local code = table.concat({
        "func isKey(s string) bool {",
        '  return strings.HasPrefix(s, "-----BEGIN PRIVATE KEY-----")',
        "}",
        "func other() int {",
        "  return 42",
        "}",
        'const endMark = "-----END PRIVATE KEY-----"',
      }, "\n")
      local red, n = secrets.redact_text(code, "/p/pem.go")
      assert.equal(code, red)
      assert.equal(0, n)
      local prose = "Keys start with -----BEGIN RSA PRIVATE KEY-----\nand you must never commit them to the repository"
      assert.equal(prose, (secrets.redact_text(prose)))
    end)
  end)

  describe("providers", function()
    it("a provider that throws (or returns invalid spans) fails closed and is reported once", function()
      local notes = {}
      vim.notify = function(msg)
        notes[#notes + 1] = msg
      end
      secrets.register({
        name = "broken",
        spans = function()
          error("malformed pattern (missing ']')")
        end,
      })
      local out, n = secrets.redact_lines("/p/a.txt", { "password=hunter2", "" })
      assert.are.same({ "<redacted>", "" }, out)
      assert.equal(1, n)
      secrets.redact_lines("/p/a.txt", { "again" })
      local reported = vim.tbl_filter(function(m)
        return m:find("broken", 1, true) ~= nil
      end, notes)
      assert.equal(1, #reported)
      assert.falsy(reported[1]:find("hunter2", 1, true))
      assert.is_true(secrets.is_cloaked((function()
        local b = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_buf_set_lines(b, 0, -1, false, { "anything" })
        return b
      end)()))
      secrets.register({
        name = "broken",
        spans = function()
          return { { row = 0, col = "x" } }
        end,
      })
      assert.are.same({ "<redacted>" }, (secrets.redact_lines("/p/a.txt", { "token" })))
      secrets.unregister("broken")
      assert.are.same({ "token" }, (secrets.redact_lines("/p/a.txt", { "token" })))
    end)
  end)

  describe("token detectors", function()
    before_each(function()
      require("slop.config").setup({ cloak = false })
    end)

    local function red(s)
      return (secrets.redact_text(s, "/p/main.lua"))
    end

    it("redact common token shapes (only the secret part)", function()
      local cases = {
        { "aws = AKIAIOSFODNN7EXAMPLE", "aws = <redacted>" },
        { "ASIAY34FZKBOKMUTVV7A,", "<redacted>," },
        { "t: ghp_0123456789abcdefghijklmnopqrstuvwxyz", "t: <redacted>" },
        { "gho_0123456789abcdefghijklmnopqrstuvwxyzAB", "<redacted>" },
        { "github_pat_11ABCDEFG0123456789_abcdefghijklmnopqrstuvwxyz", "<redacted>" },
        { "GITLAB=glpat-abcdefghij0123456789", "GITLAB=<redacted>" },
        { "slack xoxb-1234567890-abcdefghij", "slack <redacted>" },
        { 'k = "sk-proj-abcdefghijklmnopqrstuvwxyz0123456789"', 'k = "<redacted>"' },
        { "sk-ant-api03-abcdefghijklmnopqrstuvwxyz-ABC_def", "<redacted>" },
        { "sk-0123456789abcdefghijklmnopqrstuvwxyzABCDEF0123", "<redacted>" },
        { "sk_live_0123456789abcdefABCDEF / rk_test_0123456789abcdefABCDEF", "<redacted> / <redacted>" },
        { "key=AIzaSyA-1234567890abcdefghijklmnopqrstu", "key=<redacted>" },
        {
          "Bearer eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U.",
          "Bearer <redacted>.",
        },
        { "postgres://admin:hunter2@db.internal:5432/app", "postgres://admin:<redacted>@db.internal:5432/app" },
        { "redis://:s3cr3t@cache:6379/0", "redis://:<redacted>@cache:6379/0" },
      }
      for _, c in ipairs(cases) do
        assert.equal(c[2], red(c[1]), c[1])
      end
    end)

    it("leave identifiers, prose, hex hashes, UUIDs and URLs without passwords alone", function()
      for _, s in ipairs({
        "task-runner-integration-tests-and-more",
        "disk_live_backup_service_0123456789abcdef",
        "AKIA_CONSTANT AKIAIOSFODNN7EXAMPLEX xAKIAIOSFODNN7EXAMPLE",
        "my_sk-thing-abcdefghijklmnopqrstuvwxyz",
        "ghp_short eyJustAWord xoxo-kisses AIzaShort sk-learn sk_live_short glpat-short",
        "Ask the AKIA team about sk-learn and JWT eyJ tokens.",
        "4b825dc642cb6eb9a060e54bf8d69288fbee4904",
        "6ef19b41225c5369f1c104d45d8d85efa9b057b53b14b4b9b939dd74decc5321",
        "123e4567-e89b-12d3-a456-426614174000",
        "https://example.com:8080/path?x=1@y git@github.com:org/repo.git ssh://git@github.com/org/repo",
        "mailto:user@example.com http://user@host/ https://user:@host/",
        "local skeleton = require('sk-ui')",
      }) do
        assert.equal(s, red(s))
      end
    end)

    it("are AI-only (never display spans) and can be turned off with secrets.detectors = false", function()
      local tok = "aws = AKIAIOSFODNN7EXAMPLE"
      assert.equal(1, #secrets.spans("/p/main.lua", { tok }))
      assert.equal(0, #secrets.spans("/p/main.lua", { tok }, 0, { display = true }))
      local config = require("slop.config")
      local get = config.get
      config.get = function(ns)
        local v = get(ns)
        if ns == "secrets" then
          v = vim.tbl_extend("force", v, { detectors = false })
        end
        return v
      end
      local ok, err = pcall(function()
        assert.equal(tok, red(tok))
        -- private keys are not a "detector": they stay redacted
        assert.equal(
          "-----BEGIN PRIVATE KEY-----\n<redacted>\n-----END PRIVATE KEY-----",
          red(
            "-----BEGIN PRIVATE KEY-----\n"
              .. "MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQC7VJTUt9Us8cKj\n"
              .. "-----END PRIVATE KEY-----"
          )
        )
      end)
      config.get = get
      assert(ok, err)
    end)
  end)
end)

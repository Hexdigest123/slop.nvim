local h = require("helpers")

describe("secrets", function()
  local secrets
  before_each(function()
    h.reset()
    vim.notify = function() end
    secrets = require("slop.core.secrets")
  end)

  it("blocks the built-in default globs with no provider registered", function()
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
end)

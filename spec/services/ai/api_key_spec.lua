local h = require("helpers")

describe("ai api key resolution", function()
  local ai
  before_each(function()
    h.reset()
    vim.notify = function() end
    ai = require("slop.core.registry").service("ai")
    vim.uv.os_unsetenv("MISTRAL_API_KEY")
    vim.uv.os_unsetenv("MY_KEY")
  end)

  it("defaults to <SERVICE>_API_KEY", function()
    assert.are.same({ "env", "MISTRAL_API_KEY" }, { ai.api_key_source(ai.provider("codestral")) })
    local key, err = ai.api_key("codestral")
    assert.is_nil(key)
    assert.matches("MISTRAL_API_KEY is not set", err)
    vim.uv.os_setenv("MISTRAL_API_KEY", "k1")
    assert.equal("k1", ai.api_key("codestral"))
  end)

  it("api_key string names another env var; function returns the key; false = none", function()
    vim.uv.os_setenv("MY_KEY", "k2")
    assert.equal("k2", ai.api_key({ service = "mistral", api_key = "MY_KEY" }))
    assert.equal(
      "k3",
      ai.api_key({
        service = "x",
        api_key = function()
          return "k3"
        end,
      })
    )
    assert.is_nil((ai.api_key({ service = "ollama", api_key = false })))
    require("slop.config").setup({ ai = { providers = { codestral = { api_key = "MY_KEY" } } } })
    assert.equal("k2", ai.api_key("codestral"))
  end)

  it("an api_key function is called once and cached (password managers are slow), not on every request", function()
    local calls = 0
    local p = {
      service = "x",
      api_key = function()
        calls = calls + 1
        return "k" .. calls
      end,
    }
    assert.equal("k1", ai.api_key(p))
    assert.equal("k1", ai.api_key(p))
    assert.equal("k1", ai.api_key(p))
    assert.equal(1, calls)
    ai.key_ttl = 0 -- expired
    assert.equal("k2", ai.api_key(p))
    assert.equal(2, calls)
  end)

  it(
    "a provider or agent set to false (an invalid entry, reported as such) breaks neither providers() nor health()",
    function()
      require("slop.config").setup({ ai = { providers = { codestral = false }, agents = { vibe = false } } })
      local errs = table.concat(require("slop.config").errors("ai"), "\n")
      assert.matches("ai%.providers%.codestral", errs)
      assert.matches("ai%.agents%.vibe", errs)
      for _, kind in ipairs({ false, "chat" }) do
        local ok, list = pcall(ai.providers, kind or nil)
        assert(ok, list)
        assert.are.same({ "mistral_chat" }, list)
      end
      local out, orig = {}, vim.health
      vim.health = setmetatable({}, {
        __index = function(_, kind)
          return function(msg)
            out[#out + 1] = kind .. ": " .. tostring(msg)
          end
        end,
      })
      local hok, herr = pcall(ai.health)
      vim.health = orig
      assert(hok, herr)
      assert.matches("mistral_chat", table.concat(out, "\n"))
    end
  )

  it("a key pasted into api_key is never echoed (errors, health)", function()
    local pasted = { "sk-live-PASTED0123456789abcdef", "aB3dE5fG7hJ9kL1mN3pQ5rS7tU9vW1xY" }
    local _, err = ai.api_key({ service = "x", api_key = pasted[1] })
    assert.equal("api_key takes an environment variable NAME (or a function)", err)
    _, err = ai.api_key({ service = "x", api_key = pasted[2] }) -- looks like a name, but is not shown
    assert.is_nil(err:find(pasted[2], 1, true))
    assert.matches("not set", err)
    _, err = ai.api_key({ service = "x", api_key = "MY_KEY" })
    assert.equal("$MY_KEY is not set", err)

    require("slop.config").setup({
      ai = {
        providers = {
          a = { kind = "fim", url = "u", model = "m", api_key = pasted[1] },
          b = { kind = "fim", url = "u", model = "m", api_key = pasted[2] },
        },
      },
    })
    local out, orig = {}, vim.health
    vim.health = setmetatable({}, {
      __index = function(_, kind)
        return function(msg, advice)
          out[#out + 1] = kind .. ": " .. tostring(msg) .. " " .. vim.inspect(advice)
        end
      end,
    })
    local ok, herr = pcall(ai.health)
    vim.health = orig
    assert(ok, herr)
    local all = table.concat(out, "\n")
    for _, k in ipairs(pasted) do
      assert.is_nil(all:find(k, 1, true), all)
    end
    assert.matches("environment variable NAME", all)
  end)
end)

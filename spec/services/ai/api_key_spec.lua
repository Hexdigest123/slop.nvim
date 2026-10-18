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
end)

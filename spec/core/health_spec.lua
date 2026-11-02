local h = require("helpers")

describe(":checkhealth slop", function()
  it("runs without errors and covers core, modules and services", function()
    local out = h.nvim([[
vim.cmd("checkhealth slop")
io.stdout:write(table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n"))
]])
    assert.matches("slop: core", out)
    assert.matches("slop: modules", out)
    assert.matches("slop: term", out)
    assert.matches("slop: service ai", out)
    assert.matches("MISTRAL_API_KEY", out)
    assert.falsy(out:find("ERROR", 1, true), out)
  end)

  it("reports config errors and unknown options", function()
    local out = h.nvim([[
vim.notify = function() end
require("slop").setup({ ui = { picker = 1 }, term = { nope = true } })
vim.cmd("checkhealth slop")
io.stdout:write(table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n"))
]])
    assert.matches("ui%.picker", out)
    assert.matches("term%.nope", out)
  end)

  it("prints neither option values (a pasted key) nor logged messages", function()
    local out = h.nvim([[
vim.notify = function() end
require("slop").setup({ ai = { providers = { codestral = { api_key = "sk-FAKE-pasted-0000" } } } })
require("slop.core.log").error("request failed, token sk-FAKE-logged-0000")
vim.cmd("checkhealth slop")
io.stdout:write(table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n"))
]])
    assert.matches("api_key: expected env var name|function|false, got string", out)
    assert.matches("error%(s%) logged this session", out)
    assert.falsy(out:find("sk-FAKE-logged-0000", 1, true), "logged message")
    for line in out:gmatch("[^\n]+") do
      if line:find("config", 1, true) then
        assert.falsy(line:find("sk-FAKE-pasted-0000", 1, true), line)
      end
    end
    assert.falsy(out:match("slop: core(.-)slop: modules"):find("sk-FAKE", 1, true))
  end)

  it("checks the options of a module that a mistake leaves disabled", function()
    local out = h.nvim([[
vim.notify = function() end
require("slop").setup({ term = { enabled = "yes" } })
vim.cmd("checkhealth slop")
io.stdout:write(table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n"))
]])
    assert.matches("slop: term %(disabled%)", out)
    assert.matches("term%.enabled: expected boolean, got string", out)
  end)

  it("never prints API key values", function()
    local out = h.nvim([[
vim.uv.os_setenv("MISTRAL_API_KEY", "sk-very-secret-value")
vim.cmd("checkhealth slop")
io.stdout:write(table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n"))
]])
    assert.matches("MISTRAL_API_KEY %(set%)", out)
    assert.falsy(out:find("sk-very-secret-value", 1, true))
  end)
end)

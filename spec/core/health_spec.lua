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

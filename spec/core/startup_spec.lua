local h = require("helpers")

local REPORT = [[
local out = {}
for name in pairs(package.loaded) do
  if name == "slop" or name:match("^slop%.") then out[#out + 1] = name end
end
table.sort(out)
io.stdout:write("LOADED=" .. table.concat(out, ",") .. "\n")
io.stdout:write("CMD=" .. tostring(vim.api.nvim_get_commands({}).Slop ~= nil) .. "\n")
io.stdout:write("PLUG=" .. vim.fn.maparg("<Plug>(slop-term-toggle)", "n") .. "\n")
io.stdout:write("MAP=" .. vim.fn.maparg(" \\", "n") .. "\n")
io.stdout:write("HL=" .. vim.inspect(vim.api.nvim_get_hl(0, { name = "SlopBorder" })):gsub("%s+", " ") .. "\n")
]]

describe("startup cost", function()
  it("loads nothing but slop.manifest without setup()", function()
    local out = h.nvim("vim.g.mapleader = ' '\n" .. REPORT, { init = "vim.g.mapleader = ' '" })
    assert.matches("LOADED=slop%.manifest\n", out)
    assert.matches("CMD=true", out)
    assert.matches("PLUG=<Lua", out)
    assert.matches("MAP=<Plug>%(slop%-term%-toggle%)", out)
    assert.matches("FloatBorder", out)
  end)

  it("setup({}) before plugin/ (vim.pack order) loads only slop + slop.config + manifest", function()
    local out = h.nvim(
      REPORT,
      { init = "vim.g.mapleader = ' '; require('slop').setup({ term = { keymaps = { toggle = '<leader>T' } } })" }
    )
    assert.matches("LOADED=slop,slop%.config,slop%.manifest\n", out)
    assert.matches("MAP=\n", out) -- toggle moved to <leader>T
  end)

  it("lazy triggers: FileType http loads rest, InsertEnter loads complete", function()
    local out = h.nvim([[
vim.cmd("enew")
vim.bo.filetype = "http"
vim.cmd("startinsert") vim.cmd("doautocmd InsertEnter")
local reg = require("slop.core.registry")
io.stdout:write("REST=" .. tostring(reg.is_loaded("rest")) .. "\n")
io.stdout:write("COMPLETE=" .. tostring(reg.is_loaded("complete")) .. "\n")
io.stdout:write("TERM=" .. tostring(reg.is_loaded("term")) .. "\n")
]])
    assert.matches("REST=true", out)
    assert.matches("COMPLETE=true", out)
    assert.matches("TERM=false", out)
  end)
end)

-- Minimal repro config: nvim --clean -u scripts/minimal_init.lua
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.rtp:prepend(root)
vim.g.mapleader = " "
require("slop").setup({})

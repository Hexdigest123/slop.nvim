--- term: toggled float terminal (plus split/vsplit) and send-selection. Replaces toggleterm.
--- OWNER: term. STATUS: stub spec (defaults from plan §2.4); behaviour not implemented yet.
local function todo(what)
  return function()
    require("slop.core.log").notify("slop: term: " .. what .. " not implemented yet", vim.log.levels.WARN)
  end
end

---@type slop.ModuleSpec
return {
  name = "term",
  description = "Toggled float/split terminal at the project root, send selection",
  defaults = {
    enabled = true,
    layout = "float", -- "float" | "split" | "vsplit"
    float = {
      width = function()
        return vim.o.columns - 20
      end,
      height = function()
        return vim.o.lines - 10
      end,
      title = true,
    },
    shell = vim.o.shell,
    cwd = "root",
    start_insert = true,
    persist_mode = true,
    hide_on_leave = true,
    close_on_exit = true,
    keymaps = {
      toggle = "<leader>\\",
      send = "<leader>\\", -- visual mode
      normal_mode = "<esc><esc>", -- terminal mode, buffer-local
      split = "<leader>|-",
      vsplit = "<leader>||",
    },
  },
  setup = function(_) end,
  keymaps = {
    toggle = { mode = "n", desc = "toggle terminal", rhs = todo("toggle") },
    send = { mode = "x", desc = "send selection to terminal", rhs = todo("send") },
    split = { mode = "n", desc = "terminal in a split", rhs = todo("split") },
    vsplit = { mode = "n", desc = "terminal in a vsplit", rhs = todo("vsplit") },
    normal_mode = { mode = "t", buffer = true, desc = "terminal normal mode", rhs = "<C-\\><C-n>" },
  },
}

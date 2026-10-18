--- cloak: masks secrets on screen and feeds core.secrets so AI never sees them. Replaces cloak.nvim.
--- OWNER: cloak. STATUS: stub spec (defaults from plan §2.4); behaviour not implemented yet.
local function todo(what)
  return function()
    require("slop.core.log").notify("slop: cloak: " .. what .. " not implemented yet", vim.log.levels.WARN)
  end
end

---@type slop.ModuleSpec
return {
  name = "cloak",
  description = "Mask secrets on screen; feeds core.secrets redaction",
  defaults = {
    enabled = true,
    cloak_character = "*",
    highlight_group = "Comment",
    cloak_length = false, -- false = same length as the secret
    try_all_patterns = true,
    cloak_on_leave = false,
    render = "overlay", -- "overlay" | "conceal"
    patterns = {
      { file_pattern = ".env*", cloak_pattern = "=.+" },
    },
    keymaps = { toggle = "<leader>tp", preview_line = "<leader>tl" },
  },
  setup = function(_) end,
  keymaps = {
    toggle = { mode = "n", desc = "toggle cloak", rhs = todo("toggle") },
    preview_line = { mode = "n", desc = "reveal cloaked line", rhs = todo("preview_line") },
  },
}

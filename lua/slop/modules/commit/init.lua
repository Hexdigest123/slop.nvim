--- commit: AI commit-message ghost text in gitcommit buffers (git + fugitive).
--- OWNER: commit. STATUS: stub spec (defaults from plan §2.4); behaviour not implemented yet.
local function todo(what)
  return function()
    require("slop.core.log").notify("slop: commit: " .. what .. " not implemented yet", vim.log.levels.WARN)
  end
end

---@type slop.ModuleSpec
return {
  name = "commit",
  description = "AI commit message as ghost text in gitcommit buffers",
  services = { "ai" },
  defaults = {
    enabled = true,
    provider = "mistral_chat",
    style = "auto",
    keymaps = { regenerate = "<leader>ac" },
  },
  setup = function(_) end,
  keymaps = {
    regenerate = { mode = "n", ft = { "gitcommit" }, desc = "regenerate commit message", rhs = todo("regenerate") },
  },
}

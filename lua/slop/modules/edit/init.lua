--- edit: visual selection -> prompt -> ACP agent -> live progress -> inline diff accept/reject.
--- OWNER: edit. STATUS: stub spec (defaults from plan §2.4); behaviour not implemented yet.
local function todo(what)
  return function()
    require("slop.core.log").notify("slop: edit: " .. what .. " not implemented yet", vim.log.levels.WARN)
  end
end

---@type slop.ModuleSpec
return {
  name = "edit",
  description = "AI edits of a selection through an ACP agent, reviewed as an inline diff",
  services = { "ai" },
  open_keys = { "presets" },
  defaults = {
    enabled = true,
    agent = "vibe",
    apply = "diff",
    context = "scope",
    presets = {},
    rules_files = { ".nvim/rules.md", "AGENTS.md", "CLAUDE.md" },
    keymaps = {
      edit = "<leader>aa",
      preset = "<leader>ap",
      agent = "<leader>ag",
      cancel = "<leader>as",
      diff = {
        accept = "ga",
        reject = "gr",
        accept_all = "gA",
        reject_all = "gR",
        next = "]h",
        prev = "[h",
        refine = "<C-r>",
      },
    },
  },
  setup = function(_) end,
  keymaps = {
    edit = { mode = { "n", "x" }, desc = "AI edit", rhs = todo("edit") },
    preset = { mode = { "n", "x" }, desc = "AI edit preset", rhs = todo("preset") },
    agent = { mode = "n", desc = "select AI agent", rhs = todo("agent") },
    cancel = { mode = "n", desc = "cancel AI edit", rhs = todo("cancel") },
  },
}

--- complete: context-aware AI fill-in-the-middle as ghost text (or nvim-cmp). Replaces minuet-ai.
--- OWNER: complete. STATUS: stub spec (defaults from plan §2.4); behaviour not implemented yet.
local function todo(what)
  return function()
    require("slop.core.log").notify("slop: complete: " .. what .. " not implemented yet", vim.log.levels.WARN)
  end
end

local function nothing()
  return false -- fall through to the previous mapping / native key
end

---@type slop.ModuleSpec
return {
  name = "complete",
  description = "AI fill-in-the-middle completion as ghost text",
  services = { "ai" },
  defaults = {
    enabled = true,
    provider = "codestral",
    frontend = "virtualtext", -- "virtualtext" | "cmp" | "both"
    debounce = 250,
    timeout = 10000,
    max_tokens = 256,
    stop = { "\n\n" },
    candidates = 1,
    filetypes = { "*" },
    exclude = {
      filetypes = { "help", "gitrebase", "fzf", "TelescopePrompt", "oil", "slopterm", "slopprompt" },
      max_filesize = 512 * 1024,
      max_lines = 5000,
    },
    show_with_cmp_menu = true,
    context = { scope = true, neighbors = true, recent_edits = true, ring = true, budget = "auto" },
    keymaps = {
      accept = "<C-y>",
      accept_line = "<M-l>",
      accept_n_lines = "<M-n>",
      accept_word = "<M-w>",
      next = "<C-n>",
      prev = "<C-p>",
      dismiss = "<C-e>",
      toggle = "<leader>at",
    },
  },
  setup = function(_) end,
  keymaps = {
    toggle = { mode = "n", desc = "toggle AI completion", rhs = todo("toggle") },
    accept = { mode = "i", fallthrough = true, desc = "accept suggestion", rhs = nothing },
    accept_line = { mode = "i", fallthrough = true, desc = "accept suggestion line", rhs = nothing },
    accept_n_lines = { mode = "i", fallthrough = true, desc = "accept n suggestion lines", rhs = nothing },
    accept_word = { mode = "i", fallthrough = true, desc = "accept suggestion word", rhs = nothing },
    next = { mode = "i", fallthrough = true, desc = "next suggestion", rhs = nothing },
    prev = { mode = "i", fallthrough = true, desc = "previous suggestion", rhs = nothing },
    dismiss = { mode = "i", fallthrough = true, desc = "dismiss suggestion", rhs = nothing },
  },
}

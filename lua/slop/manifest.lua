-- Lazy-load triggers for built-in modules. This is the ONLY slop file required at startup,
-- so it must stay a plain data table: no require(), no function calls, no vim.* access.
--
-- A module directory without an entry here still works (`:Slop <name> ...`, `require("slop").<name>`);
-- an entry only adds startup triggers and default keymaps.

---@class slop.ManifestKey
---@field mode string|string[]   Mode(s) of the mapping.
---@field lhs string             Default lhs. MUST equal `spec.defaults.keymaps[<action>]` (contract-tested).
---@field desc string            Description, shown by which-key / :map.
---@field expr? boolean          The `<Plug>` mapping is an expr mapping (rhs returns keys).

---@class slop.ManifestEntry
---@field events? string[]       Autocmd events that load the module: "Event" or "Event pattern" (e.g. "User Foo").
---@field ft? string[]           Filetypes that load the module (FileType autocmd; already-open buffers too).
---@field cmd? boolean           Module has `:Slop <name> <sub>` subcommands.
---@field keys? table<string, slop.ManifestKey>  Global keymaps created at startup as `<Plug>(slop-<name>-<action>)`
---                                              plus the default lhs (unless the user maps it / sets it to false).
---@field provides? string[]     Capabilities (e.g. "secrets"); `registry.load_capability(cap)` loads providers.
---@field default_enabled? boolean  Default for `enabled` (default true). MUST equal `spec.defaults.enabled`.

---@type table<string, slop.ManifestEntry>
return {
  hello = {
    cmd = true,
    default_enabled = false,
    keys = {
      greet = { mode = "n", lhs = "<leader>sH", desc = "slop: hello greet" },
    },
  },

  term = {
    cmd = true,
    keys = {
      toggle = { mode = "n", lhs = "<leader>\\", desc = "slop: toggle terminal" },
      send = { mode = "x", lhs = "<leader>\\", desc = "slop: send selection to terminal" },
      split = { mode = "n", lhs = "<leader>|-", desc = "slop: terminal in a split" },
      vsplit = { mode = "n", lhs = "<leader>||", desc = "slop: terminal in a vsplit" },
    },
  },

  cloak = {
    events = { "BufReadPre", "BufNewFile", "FileType fzf", "User TelescopePreviewerLoaded" },
    provides = { "secrets" },
    cmd = true,
    keys = {
      toggle = { mode = "n", lhs = "<leader>tp", desc = "slop: toggle cloak" },
      preview_line = { mode = "n", lhs = "<leader>tl", desc = "slop: reveal cloaked line" },
    },
  },

  complete = {
    events = { "InsertEnter" },
    cmd = true,
    keys = {
      toggle = { mode = "n", lhs = "<leader>at", desc = "slop: toggle AI completion" },
    },
  },

  commit = {
    ft = { "gitcommit" },
    cmd = true,
  },

  rest = {
    ft = { "http" },
    cmd = true,
    keys = {
      run = { mode = "n", lhs = "<leader>rr", desc = "slop: run request" },
      pick = { mode = "n", lhs = "<leader>rp", desc = "slop: pick request" },
      last = { mode = "n", lhs = "<leader>rl", desc = "slop: rerun last request" },
      env = { mode = "n", lhs = "<leader>re", desc = "slop: select rest env" },
      gen = { mode = "n", lhs = "<leader>ra", desc = "slop: AI generate request" },
      fix = { mode = "n", lhs = "<leader>rx", desc = "slop: AI fix request" },
    },
  },

  edit = {
    cmd = true,
    keys = {
      edit = { mode = { "n", "x" }, lhs = "<leader>aa", desc = "slop: AI edit" },
      preset = { mode = { "n", "x" }, lhs = "<leader>ap", desc = "slop: AI edit preset" },
      agent = { mode = "n", lhs = "<leader>ag", desc = "slop: select AI agent" },
      cancel = { mode = "n", lhs = "<leader>as", desc = "slop: cancel AI edit" },
    },
  },
}

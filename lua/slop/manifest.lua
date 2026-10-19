-- Lazy-load triggers for built-in modules. This is the ONLY slop file required at startup,
-- so it must stay a plain data table: no require(), no function calls, no vim.* access.
--
-- A module directory without an entry here still works (`:Slop <name> ...`, `require("slop").<name>`);
-- an entry only adds startup triggers and default keymaps.

---@class slop.ManifestKey
---@field mode string|string[]   Mode(s) of the mapping.
---@field lhs string|false       Default lhs (false: only the <Plug> mapping). MUST equal `spec.defaults.keymaps[<action>]` (contract-tested).
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

  marks = {
    cmd = true,
    keys = {
      add = { mode = "n", lhs = "<leader>h", desc = "slop: mark file" },
      menu = { mode = "n", lhs = "<C-e>", desc = "slop: marks menu" },
      select_1 = { mode = "n", lhs = "<leader>1", desc = "slop: go to mark 1" },
      select_2 = { mode = "n", lhs = "<leader>2", desc = "slop: go to mark 2" },
      select_3 = { mode = "n", lhs = "<leader>3", desc = "slop: go to mark 3" },
      select_4 = { mode = "n", lhs = "<leader>4", desc = "slop: go to mark 4" },
      select_5 = { mode = "n", lhs = "<leader>5", desc = "slop: go to mark 5" },
      select_6 = { mode = "n", lhs = "<leader>6", desc = "slop: go to mark 6" },
      select_7 = { mode = "n", lhs = "<leader>7", desc = "slop: go to mark 7" },
      select_8 = { mode = "n", lhs = "<leader>8", desc = "slop: go to mark 8" },
      select_9 = { mode = "n", lhs = "<leader>9", desc = "slop: go to mark 9" },
      select_10 = { mode = "n", lhs = "<leader>0", desc = "slop: go to mark 10" },
      next = { mode = "n", lhs = false, desc = "slop: next mark" },
      prev = { mode = "n", lhs = false, desc = "slop: previous mark" },
    },
  },

  progress = {
    events = { "LspProgress", "Progress", "User SlopAiRequestStarted" },
    cmd = true,
  },

  doc = {
    cmd = true,
    keys = {
      generate = { mode = "n", lhs = "<leader>nd", desc = "slop: AI doc comment" },
      func = { mode = "n", lhs = "<leader>nf", desc = "slop: AI doc comment (function)" },
      class = { mode = "n", lhs = "<leader>nc", desc = "slop: AI doc comment (class)" },
      type = { mode = "n", lhs = "<leader>nt", desc = "slop: AI doc comment (type)" },
    },
  },
}

# slop.nvim

My fun plugin where I just add slop features instead of relying on unmaintained third-party plugins.

## Modules

| Module     | What it does                                                     | Help                 |
| ---------- | ---------------------------------------------------------------- | -------------------- |
| `complete` | AI ghost-text completion (or nvim-cmp source)                    | `:h slop-complete`   |
| `commit`   | AI commit message as ghost text in `git commit` / `:Git commit`  | `:h slop-commit`     |
| `edit`     | Select code, ask an ACP agent, review the inline diff            | `:h slop-edit`       |
| `rest`     | Run requests from any `.http` file in the project                | `:h slop-rest`       |
| `cloak`    | Mask secrets on screen and keep them away from the AI            | `:h slop-cloak`      |
| `term`     | Floating terminal                                                | `:h slop-term`       |

## Requirements

- Neovim 0.12+
- `curl` and `git`
- For AI features: an API key (default `MISTRAL_API_KEY`)
- For `edit`: an ACP agent on `$PATH` (`vibe-acp`, `opencode`, or `claude-agent-acp`)

## Install (lazy.nvim / LazyVim)

```lua
return { "hexdigest123/slop.nvim" }
```

That's it — every module is on with default settings, and nothing loads until you use it.

With options:

```lua
return {
  "hexdigest123/slop.nvim",
  opts = {
    -- API keys default to <SERVICE>_API_KEY; point a provider at another variable:
    ai = {
      providers = {
        codestral = { api_key = "MISTRAL_API_KEY_NVIM" },
        mistral_chat = { api_key = "MISTRAL_API_KEY_NVIM" },
      },
    },
    edit = { agent = "vibe" }, -- or "opencode" / "claude"
    complete = { frontend = "virtualtext" }, -- or "cmp" / "both"
    term = false, -- disable any module with `false`
  },
}
```

`api_key` can also be a function returning the key.

### nvim-cmp users

nvim-cmp owns `<C-y>`, `<C-n>`, `<C-p>` and `<C-e>` while its menu is active. To let slop's ghost text go first, wrap your cmp mappings:

```lua
local slop = require("slop").complete
mapping = {
  ["<C-y>"] = slop.cmp_map("accept", cmp.mapping.confirm({ select = true })),
  ["<C-n>"] = slop.cmp_map("next", cmp.mapping.select_next_item()),
  ["<C-p>"] = slop.cmp_map("prev", cmp.mapping.select_prev_item()),
  ["<C-e>"] = slop.cmp_map("dismiss", cmp.mapping.abort()),
}
```

### Local development

```lua
return { dir = "~/Projects/slop.nvim", opts = {} }
```

## Help

Everything is documented in Neovim's help:

| Command              | Shows                                                                 |
| -------------------- | --------------------------------------------------------------------- |
| `:h slop`            | Setup, every config option, commands, keymaps, events, project folder |
| `:h slop-<module>`   | One module: its keymaps, commands, options and examples               |
| `:checkhealth slop`  | Per module: config errors, API keys (set or not), agents on `$PATH`   |
| `:Slop modules`      | Which modules are enabled and loaded                                  |
| `:Slop log`          | slop's log (raise detail with `opts = { log = { level = "debug" } }`) |

Every keymap can be changed or turned off under the module's `keymaps` table, e.g.
`opts = { term = { keymaps = { toggle = "<C-\\>" } } }` or `toggle = false` (see `:h slop-keymaps`).

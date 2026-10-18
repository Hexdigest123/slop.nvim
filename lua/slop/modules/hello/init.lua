--- hello: a trivial module that exercises the whole module contract (used by contract tests and as a
--- template for new modules). Disabled by default: enable with `opts.hello = { enabled = true }`.
---
--- Contract tour:
---   defaults/schema  -> config.get("hello"), errors as "hello.<field>"
---   commands         -> :Slop hello greet [target]   (default subcommand, completes targets)
---   keymaps          -> <Plug>(slop-hello-greet), default lhs <leader>sH (manifest + defaults.keymaps)
---   highlights       -> SlopHelloGreeting
---   health           -> "slop: hello" section in :checkhealth slop
---   api              -> require("slop").hello.greet(target?) / .count()
---   events           -> User SlopHelloGreet { text, count }
local events = require("slop.core.events")

local state = { cfg = nil, count = 0, setups = 0 }

local api = {}

--- Greet `target` (default: cfg.target). Emits User SlopHelloGreet.
---@param target? string
---@return string text
function api.greet(target)
  local cfg = state.cfg or require("slop.config").get("hello")
  local text = ("%s, %s!"):format(cfg.greeting, target or cfg.target)
  state.count = state.count + 1
  if not cfg.silent then
    require("slop.core.log").notify(text, vim.log.levels.INFO, { scope = "hello" })
  end
  events.emit("hello", "Greet", { text = text, count = state.count })
  return text
end

--- Number of greetings so far.
---@return integer
function api.count()
  return state.count
end

--- How many times setup() ran (contract tests assert exactly once).
---@return integer
function api.setups()
  return state.setups
end

---@type slop.ModuleSpec
return {
  name = "hello",
  description = "Contract-test module: greets you",
  defaults = {
    enabled = false,
    greeting = "Hello",
    target = "world",
    silent = false,
    keymaps = { greet = "<leader>sH" },
  },
  schema = function(cfg, check)
    check("greeting", cfg.greeting, "string")
    check("target", cfg.target, "string")
    check("silent", cfg.silent, "boolean")
  end,
  setup = function(cfg)
    state.cfg = cfg
    state.setups = state.setups + 1
  end,
  commands = {
    greet = {
      desc = "greet [target]",
      default = true,
      impl = function(args)
        api.greet(args[1])
      end,
      complete = function(lead)
        return require("slop.core.util").complete_prefix({ "world", "neovim", "slop" }, lead)
      end,
    },
  },
  keymaps = {
    greet = {
      mode = "n",
      desc = "hello greet",
      rhs = function()
        api.greet()
      end,
    },
  },
  highlights = { SlopHelloGreeting = { link = "Title" } },
  health = function()
    vim.health.ok(("hello greets %d time(s) so far"):format(state.count))
  end,
  api = api,
}

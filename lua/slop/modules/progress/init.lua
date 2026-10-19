--- progress: LSP / native / AI progress in a small bottom-right window. Replaces fidget.nvim.
--- OWNER: progress. store.lua = task model + history, sources.lua = autocmds, view.lua = window (all lazy).
local function store()
  return require("slop.modules.progress.store")
end

local function view()
  return require("slop.modules.progress.view")
end

local function sources()
  return require("slop.modules.progress.sources")
end

local CLEAR = { "items", "history", "all" }
local au_config ---@type integer?

local api = {}

--- Current tasks (running and lingering), in display order.
---@return slop.progress.Item[]
function api.items()
  store().prune()
  return store().items()
end

--- Finished tasks, oldest first (ring buffer of `history_size`).
---@return slop.progress.Item[]
function api.history()
  return store().history()
end

--- Clear the window ("items", default), the history ("history") or both ("all").
---@param what? "items"|"history"|"all"
function api.clear(what)
  store().clear(what)
  view().render()
end

--- Show/hide the window; tasks are still tracked while hidden.
---@return boolean visible
function api.toggle()
  return view().toggle()
end

--- Open the history in a float.
function api.show_history()
  view().show_history()
end

local function configure(cfg)
  store().configure(cfg)
  view().configure(cfg, sources().sweep)
  sources().configure(cfg)
end

local function is_ms(v)
  return type(v) == "number" and v >= 0
end

---@type slop.ModuleSpec
return {
  name = "progress",
  description = "LSP, native and AI progress in a corner window (fidget replacement)",
  defaults = {
    enabled = true,
    sources = {
      lsp = true, -- LspProgress ($/progress)
      native = true, -- Progress autocmd: nvim_echo({ kind = "progress" }) from slop and other plugins
      ai = { chat = true, fim = false }, -- User SlopAiRequestStarted/Finished, per request kind
    },
    ignore = {}, -- group names to drop: LSP client names, Progress sources, "slop" (AI)
    lsp_mirror_sources = { "vim.lsp" }, -- Progress sources that only mirror LSP progress (dropped while lsp = true)
    dedupe_ms = 500, -- an AI request and a slop progress message this close together are one task
    linger = 2000, -- ms a finished task stays visible
    history_size = 100,
    max_items = 8, -- per group
    suppress_echo = true, -- hide Neovim's cmdline echo of progress messages ('messagesopt' progress:)
    spinner = false, -- false = config ui.spinner, or a core.ui.spinner style name
    interval = 100, -- ms per spinner frame
    icons = { success = "✓", failed = "✗", cancel = "⊘" },
    window = {
      border = "none",
      winblend = 100,
      zindex = 45,
      max_width = 0.5, -- (0, 1] fraction of the editor, > 1 cells
      x_padding = 1, -- columns from the right edge
      y_padding = 0, -- rows above the statusline
    },
  },
  schema = function(cfg, check)
    check("sources", cfg.sources, "table")
    local s = cfg.sources or {}
    check("sources.lsp", s.lsp, "boolean")
    check("sources.native", s.native, "boolean")
    check("sources.ai", s.ai, "table")
    check("sources.ai.chat", (s.ai or {}).chat, "boolean")
    check("sources.ai.fim", (s.ai or {}).fim, "boolean")
    check("ignore", cfg.ignore, vim.islist, false, "list of strings")
    check("lsp_mirror_sources", cfg.lsp_mirror_sources, vim.islist, false, "list of strings")
    check("dedupe_ms", cfg.dedupe_ms, is_ms, false, "number >= 0")
    check("linger", cfg.linger, is_ms, false, "number >= 0")
    check("history_size", cfg.history_size, is_ms, false, "number >= 0")
    check("max_items", cfg.max_items, function(v)
      return type(v) == "number" and v >= 1
    end, false, "number >= 1")
    check("suppress_echo", cfg.suppress_echo, "boolean")
    check("spinner", cfg.spinner, function(v)
      return v == false or type(v) == "string"
    end, false, "false or a spinner style name")
    check("interval", cfg.interval, function(v)
      return type(v) == "number" and v >= 10
    end, false, "number >= 10")
    check("icons", cfg.icons, "table")
    for _, k in ipairs({ "success", "failed", "cancel" }) do
      check("icons." .. k, (cfg.icons or {})[k], "string")
    end
    check("window", cfg.window, "table")
    local w = cfg.window or {}
    check("window.border", w.border, { "string", "table" })
    check("window.winblend", w.winblend, function(v)
      return type(v) == "number" and v >= 0 and v <= 100
    end, false, "number 0-100")
    check("window.zindex", w.zindex, "number")
    check("window.max_width", w.max_width, function(v)
      return type(v) == "number" and v > 0
    end, false, "positive number")
    check("window.x_padding", w.x_padding, is_ms, false, "number >= 0")
    check("window.y_padding", w.y_padding, is_ms, false, "number >= 0")
  end,
  setup = function(cfg)
    configure(cfg)
    sources().start(cfg, function(now)
      view().request(now)
    end, function()
      view().render()
    end)
    au_config = require("slop.core.events").on(nil, "ConfigChanged", function()
      if require("slop.core.registry").is_loaded("progress") then
        configure(require("slop.config").get("progress"))
        view().render()
      end
    end, { desc = "slop: progress reconfigure" })
  end,
  teardown = function()
    if au_config then
      require("slop.core.events").off(au_config)
      au_config = nil
    end
    sources().stop()
    view().stop()
    store().reset()
  end,
  commands = {
    history = {
      desc = "show finished tasks",
      default = true,
      impl = function()
        api.show_history()
      end,
    },
    clear = {
      desc = "clear [items|history|all]",
      impl = function(args)
        local what = args[1] or "items"
        if not vim.tbl_contains(CLEAR, what) then
          require("slop.core.log").notify(
            ("slop: progress: clear expects items|history|all, got %s"):format(what),
            vim.log.levels.WARN
          )
          return
        end
        api.clear(what)
      end,
      complete = function(lead, args)
        if #args > 1 then
          return {}
        end
        return require("slop.core.util").complete_prefix(CLEAR, lead)
      end,
    },
    toggle = {
      desc = "show/hide the progress window",
      impl = function()
        api.toggle()
      end,
    },
  },
  highlights = {
    SlopProgressNormal = { link = "Comment" },
    SlopProgressBorder = { link = "SlopBorder" },
    SlopProgressGroup = { link = "Title" },
    SlopProgressTitle = { link = "Question" },
    SlopProgressMessage = { link = "Comment" },
    SlopProgressPercent = { link = "Number" },
    SlopProgressSpinner = { link = "SlopSpinner" },
    SlopProgressDone = { link = "DiagnosticOk" },
    SlopProgressError = { link = "DiagnosticError" },
    SlopProgressCancel = { link = "DiagnosticWarn" },
  },
  health = function()
    local h = vim.health
    local cfg = require("slop.config").get("progress")
    local s = cfg.sources
    local on = {}
    for _, name in ipairs({ "lsp", "native" }) do
      if s[name] then
        on[#on + 1] = name
      end
    end
    for _, kind in ipairs({ "chat", "fim" }) do
      if s.ai[kind] then
        on[#on + 1] = "ai." .. kind
      end
    end
    h.ok(("sources: %s"):format(#on > 0 and table.concat(on, ", ") or "none"))
    if #cfg.ignore > 0 then
      h.info("ignored groups: " .. table.concat(cfg.ignore, ", "))
    end
    h.info(("'messagesopt' = %q (suppress_echo = %s)"):format(vim.o.messagesopt, tostring(cfg.suppress_echo)))
    if not require("slop.core.registry").is_loaded("progress") then
      h.info("not loaded yet (loads on the first LspProgress / Progress / AI request)")
      return
    end
    local running, total = store().count()
    h.info(
      ("%d task(s), %d running, %d in history; window %s"):format(
        total,
        running,
        #store().history(),
        view().visible() and "shown" or "hidden (:Slop progress toggle)"
      )
    )
  end,
  api = api,
}

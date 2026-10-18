--- complete: context-aware AI fill-in-the-middle as ghost text (or nvim-cmp). Replaces minuet-ai. OWNER: complete.
--- This file must stay cheap (it is required for :Slop completion / health without setup()); the engine lives in
--- engine.lua, postprocess.lua, cache.lua and cmp.lua beside it.

local function engine()
  return require("slop.modules.complete.engine")
end

local function log()
  return require("slop.core.log").scope("complete")
end

local api = {}

--- Is a complete suggestion visible in the current buffer?
---@return boolean
function api.is_visible()
  return engine().visible(0)
end

--- Accept the whole suggestion. false when none is visible.
---@return boolean
function api.accept()
  return engine().accept()
end

---@return boolean
function api.accept_word()
  return engine().accept_word()
end

---@return boolean
function api.accept_line()
  return engine().accept_line()
end

---@param n? integer                       default: a digit typed right after the key, else 1
---@return boolean
function api.accept_n_lines(n)
  return engine().accept_n_lines(n)
end

---@return boolean
function api.next()
  return engine().next()
end

---@return boolean
function api.prev()
  return engine().prev()
end

---@return boolean
function api.dismiss()
  return engine().dismiss()
end

--- Request a suggestion now (bypasses debounce, auto toggles and `condition`).
---@return boolean started
function api.trigger()
  return engine().trigger(0, { manual = true })
end

---@param scope? "global"|"buffer"
---@param value? boolean                   nil = toggle
---@return boolean enabled
local function set_enabled(scope, value)
  local e = engine()
  if scope == "buffer" then
    local buf = vim.api.nvim_get_current_buf()
    local cur = vim.b[buf].slop_complete ~= false
    local new = value
    if new == nil then
      new = not cur
    end
    vim.b[buf].slop_complete = new
    if not new then
      e.reset(buf)
    end
    log().notify(("auto-trigger %s for this buffer"):format(new and "on" or "off"), vim.log.levels.INFO)
    return new
  end
  local new = value
  if new == nil then
    new = not e.auto
  end
  e.auto = new
  if not new then
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      e.reset(b)
    end
  end
  log().notify(("auto-trigger %s"):format(new and "on" or "off"), vim.log.levels.INFO)
  return new
end

--- Toggle automatic suggestions (global, or for the current buffer).
---@param scope? "global"|"buffer"
---@return boolean enabled
function api.toggle(scope)
  return set_enabled(scope, nil)
end

---@param scope? "global"|"buffer"
function api.enable(scope)
  return set_enabled(scope, true)
end

---@param scope? "global"|"buffer"
function api.disable(scope)
  return set_enabled(scope, false)
end

--- Are automatic suggestions on (globally and for `buf`)?
---@param buf? integer
---@return boolean
function api.is_enabled(buf)
  buf = (buf == nil or buf == 0) and vim.api.nvim_get_current_buf() or buf
  return engine().auto and vim.b[buf].slop_complete ~= false
end

--- Statusline helper: { state = "idle"|"loading"|"shown", index?, total?, provider }.
---@param buf? integer
function api.status(buf)
  return engine().status(buf)
end

--- Candidates at the cursor (remainders after what was typed).
---@param buf? integer
---@return string[]
function api.items(buf)
  return engine().items(buf)
end

--- Use another provider at runtime (until the next config change).
---@param name string
function api.set_provider(name)
  local ai = require("slop.core.registry").service("ai")
  if not ai.provider(name) then
    log().notify("unknown provider " .. tostring(name), vim.log.levels.ERROR)
    return
  end
  local e = engine()
  local c = vim.deepcopy(require("slop.config").get("complete"))
  c.provider = name
  e.configure(c)
  e.clear_cache()
  log().notify("provider: " .. name, vim.log.levels.INFO)
end

--- nvim-cmp mapping helper: slop's action when a suggestion is visible, else `otherwise(fallback)` / fallback().
---   ["<C-y>"] = require("slop").complete.cmp_map("accept", cmp.mapping.confirm({ select = true }))
---@param action "accept"|"accept_word"|"accept_line"|"accept_n_lines"|"next"|"prev"|"dismiss"
---@param otherwise? fun(fallback: fun())
---@return fun(fallback: fun())
function api.cmp_map(action, otherwise)
  return function(fallback)
    if api[action] and api.is_visible() and api[action]() ~= false then
      return
    end
    if otherwise then
      otherwise(fallback)
    else
      fallback()
    end
  end
end

local function fallthrough(fn)
  return function()
    return engine()[fn]()
  end
end

local SCOPES = { "buffer", "global" }

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
    temperature = false, -- false = provider default; alternatives use 0.4, 0.6, ...
    stream = true,
    candidates = 1, -- fetched eagerly; more are fetched lazily on next/prev
    max_candidates = 3,
    multiline = "auto", -- true | false | "auto" (single line when text follows the cursor)
    mid_line = "closers", -- "closers" (copilot rule) | "always" | "never"
    max_lines = 20,
    cache = true,
    condition = false, -- false | fun(buf): boolean (auto requests only)
    filetypes = { "*" },
    exclude = {
      filetypes = {
        "help",
        "gitrebase",
        "fzf",
        "TelescopePrompt",
        "oil",
        "slopterm",
        "slopprompt",
        "DressingInput",
        "Trouble",
        "trouble",
        "dap-repl",
        "dapui_breakpoints",
        "dapui_console",
        "dapui_scopes",
        "dapui_stacks",
        "dapui_watches",
        "lazy",
        "mason",
        "prompt",
        "qf",
        "toggleterm",
      },
      buftypes = { "acwrite", "nofile", "prompt", "quickfix", "terminal", "help" },
      max_filesize = 512 * 1024,
      max_lines = 5000,
    },
    show_with_cmp_menu = true,
    context = {
      scope = true,
      neighbors = true,
      recent_edits = true,
      ring = true,
      diagnostics = true,
      budget = "auto",
    },
    keymaps = {
      accept = "<C-y>",
      accept_line = "<M-l>",
      accept_n_lines = "<M-n>",
      accept_word = "<M-w>",
      next = "<C-n>",
      prev = "<C-p>",
      dismiss = "<C-e>",
      trigger = "<M-\\>",
      toggle = "<leader>at",
    },
  },

  schema = function(cfg, check)
    local function one_of(list)
      return function(v)
        return vim.tbl_contains(list, v)
      end,
        table.concat(
          vim.tbl_map(function(x)
            return vim.inspect(x)
          end, list),
          "|"
        )
    end
    local function pos_int(v)
      return type(v) == "number" and v >= 0 and math.floor(v) == v
    end
    check("provider", cfg.provider, "string")
    local f, fmsg = one_of({ "virtualtext", "cmp", "both" })
    check("frontend", cfg.frontend, f, false, fmsg)
    for _, k in ipairs({ "debounce", "timeout", "max_tokens", "candidates", "max_candidates", "max_lines" }) do
      check(k, cfg[k], pos_int, false, "non-negative integer")
    end
    check("stop", cfg.stop, "table")
    check("temperature", cfg.temperature, function(v)
      return v == false or type(v) == "number"
    end, false, "false|number")
    check("stream", cfg.stream, "boolean")
    local m, mmsg = one_of({ true, false, "auto" })
    check("multiline", cfg.multiline, m, false, mmsg)
    local ml, mlmsg = one_of({ "closers", "always", "never" })
    check("mid_line", cfg.mid_line, ml, false, mlmsg)
    check("cache", cfg.cache, "boolean")
    check("condition", cfg.condition, function(v)
      return v == false or type(v) == "function"
    end, false, "false|function")
    check("filetypes", cfg.filetypes, "table")
    check("exclude", cfg.exclude, "table")
    if type(cfg.exclude) == "table" then
      check("exclude.filetypes", cfg.exclude.filetypes, "table")
      check("exclude.buftypes", cfg.exclude.buftypes, "table")
      check("exclude.max_filesize", cfg.exclude.max_filesize, "number")
      check("exclude.max_lines", cfg.exclude.max_lines, "number")
    end
    check("show_with_cmp_menu", cfg.show_with_cmp_menu, "boolean")
    check("context", cfg.context, "table")
    if type(cfg.context) == "table" then
      for _, k in ipairs({ "scope", "neighbors", "recent_edits", "ring", "diagnostics" }) do
        check("context." .. k, cfg.context[k], "boolean")
      end
      check("context.budget", cfg.context.budget, function(v)
        return v == "auto" or (type(v) == "number" and v > 0)
      end, false, "'auto'|positive number (characters)")
    end
  end,

  setup = function(cfg)
    local e = engine()
    e.configure(cfg)
    e.attach()
    require("slop.services.ai.context").track()
    if cfg.frontend ~= "virtualtext" then
      local cmp = require("slop.modules.complete.cmp")
      if not cmp.register() then
        vim.api.nvim_create_autocmd({ "InsertEnter", "User" }, {
          group = require("slop.core.util").augroup("complete"),
          desc = "slop: register the cmp source once nvim-cmp is loaded",
          callback = function()
            return cmp.register() -- true deletes the autocmd
          end,
        })
      end
    end
  end,

  teardown = function()
    engine().teardown()
    pcall(vim.api.nvim_del_augroup_by_name, "slop.complete")
  end,

  highlights = {
    SlopCompleteGhost = { link = "SlopGhost" },
    SlopCompleteCmpKind = { link = "CmpItemKind" },
  },

  keymaps = {
    toggle = {
      mode = "n",
      desc = "toggle AI completion",
      rhs = function()
        api.toggle()
      end,
    },
    trigger = {
      mode = "i",
      desc = "request AI suggestion",
      rhs = function()
        api.trigger()
      end,
    },
    accept = { mode = "i", fallthrough = true, desc = "accept suggestion", rhs = fallthrough("accept") },
    accept_line = { mode = "i", fallthrough = true, desc = "accept suggestion line", rhs = fallthrough("accept_line") },
    accept_n_lines = {
      mode = "i",
      fallthrough = true,
      desc = "accept n suggestion lines",
      rhs = function()
        return engine().accept_n_lines()
      end,
    },
    accept_word = { mode = "i", fallthrough = true, desc = "accept suggestion word", rhs = fallthrough("accept_word") },
    next = { mode = "i", fallthrough = true, desc = "next suggestion", rhs = fallthrough("next") },
    prev = { mode = "i", fallthrough = true, desc = "previous suggestion", rhs = fallthrough("prev") },
    dismiss = { mode = "i", fallthrough = true, desc = "dismiss suggestion", rhs = fallthrough("dismiss") },
  },

  commands = {
    status = {
      default = true,
      desc = "show completion status",
      impl = function()
        local st = api.status()
        local buf = vim.api.nvim_get_current_buf()
        local ok, why = engine().allowed(buf, false)
        local msg = ("provider %s · auto %s · %s%s"):format(
          st.provider,
          api.is_enabled() and "on" or "off",
          st.state,
          ok and "" or (" · inactive here: " .. tostring(why))
        )
        log().notify(msg, vim.log.levels.INFO)
      end,
    },
    toggle = {
      desc = "toggle automatic suggestions [buffer|global]",
      impl = function(args)
        api.toggle(args[1])
      end,
      complete = function(lead)
        return require("slop.core.util").complete_prefix(SCOPES, lead)
      end,
    },
    enable = {
      desc = "enable automatic suggestions [buffer|global]",
      impl = function(args)
        api.enable(args[1])
      end,
      complete = function(lead)
        return require("slop.core.util").complete_prefix(SCOPES, lead)
      end,
    },
    disable = {
      desc = "disable automatic suggestions [buffer|global]",
      impl = function(args)
        api.disable(args[1])
      end,
      complete = function(lead)
        return require("slop.core.util").complete_prefix(SCOPES, lead)
      end,
    },
    provider = {
      desc = "switch the completion provider",
      impl = function(args)
        if args[1] then
          api.set_provider(args[1])
        else
          log().notify("provider: " .. api.status().provider, vim.log.levels.INFO)
        end
      end,
      complete = function(lead)
        local ok, names = pcall(function()
          return require("slop.services.ai").providers()
        end)
        return require("slop.core.util").complete_prefix(ok and names or {}, lead)
      end,
    },
    cache = {
      desc = "clear the completion cache",
      impl = function()
        engine().clear_cache()
        log().notify("cache cleared", vim.log.levels.INFO)
      end,
    },
  },

  health = function()
    local h = vim.health
    local c = require("slop.config").get("complete")
    local ok_ai, ai = pcall(require, "slop.services.ai")
    local p = ok_ai and ai.provider(c.provider) or nil
    if not p then
      h.error(("provider `%s` is not defined in ai.providers"):format(c.provider))
    else
      local source, var = ai.api_key_source(p)
      local key = source == "env" and (
          os.getenv(var --[[@as string]]) or ""
        ) ~= ""
      local msg = ("provider `%s` (%s, %s, %s)"):format(c.provider, p.kind, p.service or "?", p.model)
      if source == "env" and not key then
        h.warn(msg .. (": $%s is NOT set"):format(var))
      else
        h.ok(msg .. (source == "env" and (": key from $%s (set)"):format(var) or (": key " .. source)))
      end
      if p.kind == "chat" then
        h.info("chat provider: completions use chat-FIM prompting (slower than a FIM endpoint)")
      end
    end
    if vim.fn.executable("curl") == 1 then
      h.ok("curl found")
    else
      h.error("curl not found in $PATH")
    end
    h.info(("frontend: %s"):format(c.frontend))
    if c.frontend ~= "virtualtext" then
      if package.loaded["cmp"] then
        h.ok(
          "nvim-cmp loaded"
            .. (require("slop.modules.complete.cmp").is_registered() and " (source `slop` registered)" or "")
        )
      else
        h.warn("frontend uses nvim-cmp but it is not loaded (yet)")
      end
    end
  end,

  api = api,
}

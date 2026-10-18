--- cloak: masks secrets on screen and feeds core.secrets so AI never sees them. Replaces cloak.nvim
--- (config keys are copy-paste compatible). See :h slop-cloak.txt.
---
--- init.lua stays cheap: the heavy parts (patterns, render, integrations) are required inside functions.

local state = {
  cfg = nil, ---@type table?
  rules = {}, ---@type slop.cloak.Rule[]
  extra = {}, ---@type table<string, table[]>  add_rules() sets (raw cloak.nvim-style rules)
  extra_order = {}, ---@type string[]
  path_cache = {}, ---@type table<string, slop.cloak.Rule[]>
}

local function render()
  return require("slop.modules.cloak.render")
end

local function patterns()
  return require("slop.modules.cloak.patterns")
end

local function log()
  return require("slop.core.log").scope("cloak")
end

--- Compile every rule set: user/cloak.nvim `patterns`, slop builtins, add_rules() sets.
local function compile()
  local cfg = assert(state.cfg)
  local p = patterns()
  local all = p.normalize(cfg.patterns, "patterns")
  if cfg.builtin_patterns ~= false then
    vim.list_extend(all, p.normalize(p.builtin, "builtin"))
  end
  for _, name in ipairs(state.extra_order) do
    vim.list_extend(all, p.normalize(state.extra[name], name))
  end
  state.rules = all
  state.path_cache = {}
end

--- Rules applying to `path` (cached per path).
---@param path string
---@return slop.cloak.Rule[]
local function rules_for(path)
  local c = state.path_cache[path]
  if not c then
    c = patterns().rules_for(state.rules, path, state.cfg and state.cfg.exclude)
    state.path_cache[path] = c
  end
  return c
end

local function register_provider()
  local secrets = require("slop.core.secrets")
  local block = {}
  for _, r in ipairs(state.rules) do
    if r.block then
      vim.list_extend(block, r.file_patterns)
    end
  end
  secrets.register({
    name = "cloak",
    block = block,
    match_path = function(path)
      return #rules_for(path) > 0
    end,
    spans = function(path, lines, first_row)
      return patterns().compute(rules_for(path), lines, first_row, state.cfg)
    end,
  })
end

local function rebuild()
  compile()
  register_provider()
  render().reconfigure(state.cfg)
end

-- API ------------------------------------------------------------------------------------------

local api = {}

local function ready()
  if not state.cfg then
    require("slop").load("cloak")
  end
  return state.cfg ~= nil
end

--- Toggle the display (never redaction). scope "buffer" = only the current buffer.
---@param scope? "global"|"buffer"
function api.toggle(scope)
  if not ready() then
    return
  end
  local r = render()
  r.set_enabled(not r.is_enabled(0), scope)
end

---@param scope? "global"|"buffer"
function api.enable(scope)
  if ready() then
    render().set_enabled(true, scope)
  end
end

---@param scope? "global"|"buffer"
function api.disable(scope)
  if ready() then
    render().set_enabled(false, scope)
  end
end

--- Display state of a buffer (default current).
---@param buf? integer
---@return boolean
function api.is_enabled(buf)
  return ready() and render().is_enabled(buf)
end

--- Reveal the cursor line (count = N lines) in this window until the cursor leaves it.
---@param count? integer
---@return boolean
function api.preview_line(count)
  return ready() and render().preview_line(count)
end

--- Cloak spans of a buffer (rows srow..erow, 0-based inclusive; default whole buffer).
---@param buf? integer
---@param srow? integer
---@param erow? integer
---@return slop.cloak.Span[]
function api.spans(buf, srow, erow)
  if not ready() then
    return {}
  end
  buf = (buf == nil or buf == 0) and vim.api.nvim_get_current_buf() or buf
  srow = srow or 0
  local lines = vim.api.nvim_buf_get_lines(buf, srow, erow and erow + 1 or -1, false)
  local path = require("slop.core.secrets").effective_path(buf)
  return patterns().compute(rules_for(path), lines, srow, state.cfg)
end

---@class slop.cloak.Status
---@field buf integer
---@field path string
---@field enabled boolean   display state
---@field global boolean
---@field cloaked boolean   a rule applies
---@field blocked boolean   never sent to AI
---@field rules string[]
---@field spans integer
---@field render string

--- Status of a buffer.
---@param buf? integer
---@return slop.cloak.Status
function api.status(buf)
  ready()
  buf = (buf == nil or buf == 0) and vim.api.nvim_get_current_buf() or buf
  local secrets = require("slop.core.secrets")
  local path = secrets.effective_path(buf)
  local names = {}
  for _, r in ipairs(state.cfg and rules_for(path) or {}) do
    names[#names + 1] = ("%s[%d] %s"):format(r.source, r.index, table.concat(r.file_patterns, ","))
  end
  return {
    buf = buf,
    path = path,
    enabled = state.cfg ~= nil and render().is_enabled(buf),
    global = render()._state.global,
    cloaked = #names > 0,
    blocked = secrets.is_blocked(path),
    rules = names,
    spans = #api.spans(buf),
    render = state.cfg and state.cfg.render or "overlay",
  }
end

--- Re-render (all buffers when nil).
---@param buf? integer
function api.refresh(buf)
  if ready() then
    render().invalidate(buf)
    render().refresh(buf)
  end
end

--- Give a scratch/preview buffer a (pseudo-)path so cloak rules and core.secrets apply to it.
---@param buf integer
---@param path string
function api.attach(buf, path)
  vim.b[buf].slop_secret_path = path
  api.refresh(buf)
end

--- Add a named set of extra cloak.nvim-style rules (screen + AI). Replaces a set with the same name.
---@param name string
---@param rules table[]
function api.add_rules(name, rules)
  local errs = patterns().validate(rules, name)
  if #errs > 0 then
    log().notify("invalid rules: " .. table.concat(errs, "; "), vim.log.levels.ERROR)
    return
  end
  if not state.extra[name] then
    state.extra_order[#state.extra_order + 1] = name
  end
  state.extra[name] = vim.deepcopy(rules)
  if state.cfg then
    rebuild()
  end
end

---@param name string
function api.remove_rules(name)
  if not state.extra[name] then
    return
  end
  state.extra[name] = nil
  state.extra_order = vim.tbl_filter(function(n)
    return n ~= name
  end, state.extra_order)
  if state.cfg then
    rebuild()
  end
end

-- Spec -----------------------------------------------------------------------------------------

local function scope_arg(args, cmd)
  if (args[1] == "buffer") or (cmd and cmd.bang) then
    return "buffer"
  end
  return "global"
end

local function complete_scope(lead, args)
  if #args > 1 then
    return {}
  end
  return require("slop.core.util").complete_prefix({ "buffer", "global" }, lead)
end

local function echo_status()
  local s = api.status()
  local msg = ("%s: %s, %s display (global %s), render=%s, %d span(s)%s\n  rules: %s"):format(
    s.path ~= "" and vim.fn.fnamemodify(s.path, ":~:.") or "[No Name]",
    s.cloaked and "cloaked" or "not cloaked",
    s.enabled and "on" or "off",
    s.global and "on" or "off",
    s.render,
    s.spans,
    s.blocked and ", blocked for AI" or "",
    #s.rules > 0 and table.concat(s.rules, " | ") or "none"
  )
  require("slop.core.log").notify(msg, vim.log.levels.INFO, { scope = "cloak" })
end

---@type slop.ModuleSpec
return {
  name = "cloak",
  description = "Mask secrets on screen; feeds core.secrets redaction",
  defaults = {
    enabled = true,
    cloak_character = "*",
    highlight_group = "SlopCloakMask", -- cloak.nvim default was "Comment" (SlopCloakMask links to it)
    cloak_length = false, -- false = same length as the secret; number = fixed mask length
    try_all_patterns = true,
    cloak_telescope = true,
    cloak_on_leave = false,
    patterns = {
      { file_pattern = ".env*", cloak_pattern = "=.+" },
    },
    -- slop additions
    render = "overlay", -- "overlay" | "conceal"
    nowrap = true, -- overlay: window-local 'nowrap' on cloaked buffers (restored when uncloaked)
    builtin_patterns = true, -- extra slop rules (http-client env json, .npmrc, .netrc, aws, .nvim/state, .http)
    exclude = {}, -- globs never cloaked, e.g. { ".env.example" }
    disable_completion = true, -- cmp / blink / native autocomplete / slop complete off in cloaked buffers
    fzf_lua = true, -- mask fzf-lua previews
    keymaps = { toggle = "<leader>tp", preview_line = "<leader>tl" },
  },
  schema = function(cfg, check)
    check("cloak_character", cfg.cloak_character, function(v)
      return type(v) == "string" and v ~= ""
    end, false, "non-empty string")
    check("highlight_group", cfg.highlight_group, "string")
    check("cloak_length", cfg.cloak_length, function(v)
      return v == false or v == nil or (tonumber(v) ~= nil and tonumber(v) >= 0)
    end, false, "false or a non-negative number")
    check("try_all_patterns", cfg.try_all_patterns, "boolean")
    check("cloak_telescope", cfg.cloak_telescope, "boolean")
    check("cloak_on_leave", cfg.cloak_on_leave, "boolean")
    check("render", cfg.render, function(v)
      return v == "overlay" or v == "conceal"
    end, false, "'overlay'|'conceal'")
    check("nowrap", cfg.nowrap, "boolean")
    check("builtin_patterns", cfg.builtin_patterns, "boolean")
    check("exclude", cfg.exclude, "table")
    check("disable_completion", cfg.disable_completion, "boolean")
    check("fzf_lua", cfg.fzf_lua, "boolean")
    local errs = require("slop.modules.cloak.patterns").validate(cfg.patterns, "patterns")
    if #errs > 0 then
      error("cloak." .. table.concat(errs, "\n  cloak."), 0)
    end
  end,
  setup = function(cfg)
    state.cfg = cfg
    compile()
    register_provider()
    render().start(cfg, rules_for)
    require("slop.modules.cloak.integrations").setup(cfg)
    vim.api.nvim_create_autocmd("User", {
      group = require("slop.core.util").augroup("cloak"),
      pattern = "SlopConfigChanged",
      desc = "slop: cloak live reconfig",
      callback = function()
        local config = require("slop.config")
        local new = config.get("cloak")
        if new.enabled and #config.errors("cloak") == 0 and state.cfg then
          state.cfg = new
          rebuild()
        end
      end,
    })
  end,
  teardown = function()
    require("slop.modules.cloak.integrations").teardown()
    render().stop()
    require("slop.core.secrets").unregister("cloak")
    pcall(vim.api.nvim_del_augroup_by_name, "slop.cloak")
    state.cfg = nil
  end,
  commands = {
    toggle = {
      desc = "toggle the cloak display [buffer|global]",
      default = true,
      impl = function(args, cmd)
        api.toggle(scope_arg(args, cmd))
      end,
      complete = complete_scope,
    },
    enable = {
      desc = "show masks [buffer|global]",
      impl = function(args, cmd)
        api.enable(scope_arg(args, cmd))
      end,
      complete = complete_scope,
    },
    disable = {
      desc = "reveal secrets on screen (AI redaction stays on) [buffer|global]",
      impl = function(args, cmd)
        api.disable(scope_arg(args, cmd))
      end,
      complete = complete_scope,
    },
    preview_line = {
      desc = "reveal the cursor line [count]",
      impl = function(args, cmd)
        local n = tonumber(args[1]) or (cmd and cmd.count and cmd.count > 0 and cmd.count) or 1
        api.preview_line(n)
      end,
    },
    status = {
      desc = "cloak state of the current buffer",
      impl = function()
        echo_status()
      end,
    },
  },
  keymaps = {
    toggle = {
      mode = "n",
      desc = "toggle cloak",
      rhs = function()
        api.toggle()
      end,
    },
    preview_line = {
      mode = "n",
      desc = "reveal cloaked line",
      rhs = function()
        api.preview_line(vim.v.count1)
      end,
    },
  },
  highlights = { SlopCloakMask = { link = "Comment" } },
  health = function()
    local config = require("slop.config")
    local cfg = config.get("cloak")
    local p = require("slop.modules.cloak.patterns")
    local errs = p.validate(cfg.patterns, "patterns")
    if #errs == 0 then
      local n = #cfg.patterns + (cfg.builtin_patterns and #p.builtin or 0)
      vim.health.ok(
        ("%d rule(s) compile (%d user/cloak.nvim, builtin_patterns=%s)"):format(
          n,
          #cfg.patterns,
          tostring(cfg.builtin_patterns)
        )
      )
    else
      for _, e in ipairs(errs) do
        vim.health.error(e)
      end
    end
    vim.health.info(
      ("render = %s%s"):format(
        cfg.render,
        cfg.render == "overlay"
            and (cfg.nowrap and " (window-local nowrap on cloaked buffers)" or " (nowrap=false: wrapped lines may leak)")
          or " (conceallevel=2, concealcursor=nvic on cloaked windows)"
      )
    )
    local s = require("slop.modules.cloak.integrations").status()
    if s.fzf_loaded then
      if not cfg.fzf_lua then
        vim.health.warn("fzf-lua installed but cloak.fzf_lua = false: previews show raw secrets")
      elseif s.fzf_patched then
        vim.health.ok("fzf-lua previewer patched (previews are masked)")
      elseif s.fzf_error then
        vim.health.warn(s.fzf_error)
      else
        vim.health.info("fzf-lua found; previewer is patched when the first picker opens")
      end
      vim.health.info("fzf-lua grep/live_grep RESULT lines are not masked; consider rg_opts --glob=!.env*")
    end
    if s.telescope then
      vim.health.info("telescope: previews masked via User TelescopePreviewerLoaded (needs telescope > 0.1.x)")
    end
    if s.cmp or s.blink then
      vim.health.info(
        ("completion in cloaked buffers: %s"):format(cfg.disable_completion and "disabled" or "NOT disabled")
      )
    end
    if vim.fn.exists(":CloakToggle") == 2 or package.loaded["cloak"] then
      vim.health.warn("cloak.nvim is also installed: remove it (double masks, duplicate commands)")
    end
    local names = vim.tbl_map(function(pr)
      return pr.name
    end, require("slop.core.secrets").providers())
    if require("slop.core.registry").is_loaded("cloak") then
      if vim.tbl_contains(names, "cloak") then
        vim.health.ok("core.secrets provider 'cloak' registered (AI redaction independent of the display)")
      else
        vim.health.error("cloak loaded but its core.secrets provider is missing")
      end
    else
      vim.health.info("cloak not loaded yet (loads on the first file read or secrets query)")
    end
    vim.health.info(
      "ACP agents may read secret files with their OWN tools; also deny them agent-side (e.g. Read(./.env*))"
    )
  end,
  api = api,
}

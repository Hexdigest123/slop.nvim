--- context: sticky scope headers at the top of the window. Replaces nvim-treesitter-context. See :h slop-context.txt.
---
--- init.lua stays cheap: scopes (treesitter) and render (floats, autocmds) are required inside functions.

local state = { cfg = nil } ---@type {cfg: table?}

local function render()
  return require("slop.modules.context.render")
end

local function ready()
  if not state.cfg then
    require("slop").load("context")
  end
  return state.cfg ~= nil
end

local function notify(msg, level)
  require("slop.core.log").notify(msg, level or vim.log.levels.INFO, { scope = "context" })
end

-- API ------------------------------------------------------------------------------------------

local api = {}

function api.enable()
  if ready() then
    render().set_enabled(true)
  end
end

function api.disable()
  if ready() then
    render().set_enabled(false)
  end
end

function api.toggle()
  if ready() then
    render().set_enabled(not render()._state.enabled)
  end
end

---@return boolean
function api.is_enabled()
  return state.cfg ~= nil and render()._state.enabled
end

--- Recompute and redraw the context of `win` (default current window).
---@param win? integer
function api.refresh(win)
  if ready() then
    render().update(win, true)
  end
end

--- What the context float of `win` shows: one entry per scope, outer first (0-based rows).
---@param win? integer
---@return {row: integer, col: integer, rows: integer}[]
function api.contexts(win)
  if not state.cfg then
    return {}
  end
  return vim.deepcopy(render().groups(win))
end

--- Jump to the start of the enclosing scope, `depth` levels up (default 1). Adds a jumplist entry.
---@param depth? integer
---@return boolean jumped
function api.go_to_context(depth)
  if not ready() then
    return false
  end
  depth = math.max(1, tonumber(depth) or 1)
  local win = vim.api.nvim_get_current_win()
  local all = require("slop.modules.context.scopes").enclosing(win, state.cfg)
  if not all then
    notify("no treesitter parser for this buffer", vim.log.levels.WARN)
    return false
  end
  local target = all[math.min(depth, #all)]
  if not target then
    return false
  end
  vim.cmd("normal! m'")
  vim.api.nvim_win_set_cursor(win, { target.row + 1, target.col })
  return true
end

-- Spec -----------------------------------------------------------------------------------------

local function positive_int(min)
  return function(v)
    return type(v) == "number" and v >= min and math.floor(v) == v
  end
end

---@type slop.ModuleSpec
return {
  name = "context",
  description = "Sticky scope headers (function/class/block context) at the top of the window",
  defaults = {
    enabled = true,
    mode = "cursor", -- "cursor" | "topline": which line's scopes are shown
    max_lines = 3, -- 0 = no limit (the window height still is)
    multiline_threshold = 20, -- max rows of one scope header (e.g. a long signature)
    trim_scope = "outer", -- "outer" | "inner": which scopes go first when there are more than max_lines
    line_numbers = true, -- cover the gutter with the context lines' numbers
    min_window_height = 0, -- no context in windows lower than this
    separator = false, -- false | one display cell, e.g. "─": drawn as a bottom border line
    zindex = 20,
    node_types = {}, -- { [lang] = { "node_type", ... } } replaces the built-in list of that language
    keymaps = { ["goto"] = false },
  },
  open_keys = { "node_types" },
  schema = function(cfg, check)
    check("mode", cfg.mode, function(v)
      return v == "cursor" or v == "topline"
    end, false, "'cursor'|'topline'")
    check("max_lines", cfg.max_lines, positive_int(0), false, "integer >= 0")
    check("multiline_threshold", cfg.multiline_threshold, positive_int(1), false, "integer >= 1")
    check("trim_scope", cfg.trim_scope, function(v)
      return v == "outer" or v == "inner"
    end, false, "'outer'|'inner'")
    check("line_numbers", cfg.line_numbers, "boolean")
    check("min_window_height", cfg.min_window_height, positive_int(0), false, "integer >= 0")
    check("separator", cfg.separator, function(v)
      return v == false or (type(v) == "string" and vim.fn.strdisplaywidth(v) == 1)
    end, false, "false or a single-cell string")
    check("zindex", cfg.zindex, positive_int(1), false, "integer >= 1")
    check("node_types", cfg.node_types, function(v)
      if type(v) ~= "table" then
        return false
      end
      for lang, list in pairs(v) do
        if type(lang) ~= "string" or type(list) ~= "table" or not vim.islist(list) then
          return false
        end
      end
      return true
    end, false, "table<lang, string[]>")
  end,
  setup = function(cfg)
    state.cfg = cfg
    render().start(cfg)
    vim.api.nvim_create_autocmd("User", {
      group = require("slop.core.util").augroup("context"),
      pattern = "SlopConfigChanged",
      desc = "slop: context live reconfig",
      callback = function()
        local config = require("slop.config")
        local new = config.get("context")
        if new.enabled and #config.errors("context") == 0 and state.cfg then
          state.cfg = new
          render().reconfigure(new)
        end
      end,
    })
  end,
  teardown = function()
    render().stop()
    state.cfg = nil
  end,
  commands = {
    toggle = {
      desc = "toggle the context float",
      default = true,
      impl = function()
        api.toggle()
      end,
    },
    enable = {
      desc = "show the context float",
      impl = function()
        api.enable()
      end,
    },
    disable = {
      desc = "hide the context float",
      impl = function()
        api.disable()
      end,
    },
    ["goto"] = {
      desc = "jump to the enclosing scope [depth]",
      impl = function(args, cmd)
        local n = tonumber(args[1]) or (cmd and cmd.count and cmd.count > 0 and cmd.count) or 1
        api.go_to_context(n)
      end,
    },
  },
  keymaps = {
    ["goto"] = {
      mode = "n",
      desc = "go to context",
      rhs = function()
        api.go_to_context(vim.v.count1)
      end,
    },
  },
  highlights = {
    SlopContext = { link = "NormalFloat" },
    SlopContextLineNumber = { link = "LineNr" },
    SlopContextBottom = { underline = true },
    SlopContextSeparator = { link = "FloatBorder" },
  },
  health = function()
    local cfg = require("slop.config").get("context")
    vim.health.info(
      ("mode = %s, max_lines = %d, trim_scope = %s, line_numbers = %s"):format(
        cfg.mode,
        cfg.max_lines,
        cfg.trim_scope,
        tostring(cfg.line_numbers)
      )
    )
    local types = require("slop.modules.context.scopes").types
    local langs = vim.tbl_keys(vim.tbl_extend("force", {}, types, cfg.node_types or {}))
    table.sort(langs)
    local have, missing = {}, {}
    for _, lang in ipairs(langs) do
      local ok, res = pcall(vim.treesitter.language.add, lang)
      if ok and res then
        have[#have + 1] = lang
      else
        missing[#missing + 1] = lang
      end
    end
    if #have > 0 then
      vim.health.ok("parsers with context node types: " .. table.concat(have, ", "))
    end
    if #missing > 0 then
      vim.health.info("no parser installed (no context there): " .. table.concat(missing, ", "))
    end
    -- filetypes of the open buffers
    local with, without = {}, {}
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      local ft = vim.bo[b].filetype
      if vim.api.nvim_buf_is_loaded(b) and vim.bo[b].buftype == "" and ft ~= "" and not with[ft] then
        local lang = vim.treesitter.language.get_lang(ft) or ft
        local ok, res = pcall(vim.treesitter.language.add, lang)
        if ok and res then
          with[ft] = lang
        else
          without[ft] = true
        end
      end
    end
    local w = vim.tbl_keys(with)
    table.sort(w)
    if #w > 0 then
      vim.health.ok("open filetypes with a parser: " .. table.concat(w, ", "))
    end
    local wo = vim.tbl_keys(without)
    table.sort(wo)
    if #wo > 0 then
      vim.health.info("open filetypes without a parser (no context): " .. table.concat(wo, ", "))
    end
    vim.health.info("highlights are copied from the buffer's treesitter highlighter (vim.treesitter.start())")
    if package.loaded["treesitter-context"] or vim.fn.exists(":TSContext") == 2 then
      vim.health.warn("nvim-treesitter-context is also installed: remove it (two context floats)")
    end
  end,
  api = api,
}

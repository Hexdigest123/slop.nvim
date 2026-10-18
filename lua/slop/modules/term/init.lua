--- term: toggled float terminal (plus split/vsplit) at the project root, send selection. Replaces toggleterm.
--- OWNER: term. Behaviour lives in modules/term/actions.lua (required lazily); the primitive in core/term.lua.
local function actions()
  return require("slop.modules.term.actions")
end

local LAYOUTS = { "float", "split", "vsplit" }

local function is_size(v)
  return type(v) == "function" or (type(v) == "number" and v > 0)
end

local api = {}

--- Toggle the terminal; `layout` forces float|split|vsplit (moves it when visible elsewhere).
---@param layout? slop.term.Layout
---@return slop.Term?
function api.toggle(layout)
  return actions().toggle(layout)
end

--- Show and focus the terminal.
---@param layout? slop.term.Layout
---@return slop.Term?
function api.show(layout)
  return actions().show(layout)
end

function api.hide()
  actions().hide()
end

--- Send text or lines (bracketed paste for multi-line, <CR> appended) and reveal the terminal.
---@param data string|string[]
---@param opts? slop.term.SendOpts
---@return boolean
function api.send(data, opts)
  return actions().send(data, opts)
end

--- Send the current/last visual selection.
---@return boolean
function api.send_selection()
  return actions().send_selection()
end

--- Run a command line (expandcmd) in the terminal.
---@param cmd string
---@return boolean
function api.exec(cmd)
  return actions().exec(cmd)
end

--- Kill the terminal (job stopped, buffer wiped).
function api.kill()
  actions().kill()
end

--- The module's terminal object (core.term slop.Term), if alive.
---@return slop.Term?
function api.term()
  return actions().current()
end

local function complete_layout(lead, args)
  if #args > 1 then
    return {}
  end
  return require("slop.core.util").complete_prefix(LAYOUTS, lead)
end

---@type slop.ModuleSpec
return {
  name = "term",
  description = "Toggled float/split terminal at the project root, send selection",
  defaults = {
    enabled = true,
    layout = "float", -- "float" | "split" | "vsplit"
    float = {
      width = function()
        return vim.o.columns - 20
      end,
      height = function()
        return vim.o.lines - 10
      end,
      min_width = 20,
      min_height = 5,
      title = true, -- true = " <shell name> ", string, or false
      title_pos = "center",
      border = false, -- false = config ui.border ("rounded")
      winblend = 0,
    },
    split = { size = 0.3 }, -- rows: (0,1] fraction of the editor, > 1 cells, or fun(columns, lines)
    vsplit = { size = 0.4 }, -- columns
    shell = vim.o.shell, -- string ("zsh -l" ok), string[] or fun(): string|string[]
    cwd = "root", -- "root" (core.project) | "cwd" | path | fun(): string
    start_insert = true,
    persist_mode = true,
    hide_on_leave = true, -- floats only
    close_on_exit = true, -- true | "success" | false
    keymaps = {
      toggle = "<leader>\\",
      send = "<leader>\\", -- visual mode
      normal_mode = "<esc><esc>", -- terminal mode, buffer-local
      split = "<leader>|-",
      vsplit = "<leader>||",
    },
  },
  schema = function(cfg, check)
    check("layout", cfg.layout, function(v)
      return vim.tbl_contains(LAYOUTS, v)
    end, false, "'float'|'split'|'vsplit'")
    check("float", cfg.float, "table")
    local f = cfg.float or {}
    check("float.width", f.width, is_size, false, "positive number or function")
    check("float.height", f.height, is_size, false, "positive number or function")
    check("float.min_width", f.min_width, "number")
    check("float.min_height", f.min_height, "number")
    check("float.title", f.title, { "boolean", "string" })
    check("float.title_pos", f.title_pos, function(v)
      return v == "left" or v == "center" or v == "right"
    end, false, "'left'|'center'|'right'")
    check("float.border", f.border, function(v)
      return v == false or type(v) == "string" or type(v) == "table"
    end, false, "false (= ui.border), border name or list")
    check("float.winblend", f.winblend, "number")
    check("split", cfg.split, "table")
    check("split.size", (cfg.split or {}).size, is_size, false, "positive number or function")
    check("vsplit", cfg.vsplit, "table")
    check("vsplit.size", (cfg.vsplit or {}).size, is_size, false, "positive number or function")
    check("shell", cfg.shell, { "string", "table", "function" })
    check("cwd", cfg.cwd, { "string", "function" })
    check("start_insert", cfg.start_insert, "boolean")
    check("persist_mode", cfg.persist_mode, "boolean")
    check("hide_on_leave", cfg.hide_on_leave, "boolean")
    check("close_on_exit", cfg.close_on_exit, function(v)
      return type(v) == "boolean" or v == "success"
    end, false, "boolean or 'success'")
  end,
  setup = function(_) end,
  commands = {
    toggle = {
      desc = "toggle [float|split|vsplit]",
      default = true,
      impl = function(args)
        api.toggle(args[1])
      end,
      complete = complete_layout,
    },
    send = {
      desc = "[range] send [text]: lines of the range, the text, or the current line",
      impl = function(args, cmd)
        if cmd and cmd.range and cmd.range > 0 then
          actions().send_lines(cmd.line1, cmd.line2)
        elseif #args > 0 then
          api.send(table.concat(args, " "))
        else
          local row = vim.api.nvim_win_get_cursor(0)[1]
          actions().send_lines(row, row)
        end
      end,
    },
    exec = {
      desc = "exec {cmd...}: run a command line in the terminal",
      impl = function(args)
        api.exec(table.concat(args, " "))
      end,
      complete = function(lead)
        return vim.fn.getcompletion(lead, "shellcmd")
      end,
    },
    kill = {
      desc = "kill the terminal job",
      impl = function()
        api.kill()
      end,
    },
  },
  keymaps = {
    toggle = {
      mode = "n",
      desc = "toggle terminal",
      rhs = function()
        api.toggle()
      end,
    },
    send = {
      mode = "x",
      desc = "send selection to terminal",
      rhs = function()
        api.send_selection()
      end,
    },
    split = {
      mode = "n",
      desc = "terminal in a split",
      rhs = function()
        api.toggle("split")
      end,
    },
    vsplit = {
      mode = "n",
      desc = "terminal in a vsplit",
      rhs = function()
        api.toggle("vsplit")
      end,
    },
    normal_mode = { mode = "t", buffer = true, desc = "terminal normal mode", rhs = "<C-\\><C-n>" },
  },
  highlights = {
    SlopTermNormal = { link = "Normal" },
    SlopTermBorder = { link = "SlopBorder" },
    SlopTermTitle = { link = "SlopTitle" },
  },
  health = function()
    local cfg = require("slop.config").get("term")
    local ok, cmd = pcall(function()
      return require("slop.modules.term.actions").shell_cmd(cfg.shell)
    end)
    if not ok or not cmd[1] then
      vim.health.error("term.shell could not be resolved: " .. tostring(cmd))
    elseif vim.fn.executable(cmd[1]) == 1 then
      vim.health.ok(("shell: %s"):format(table.concat(cmd, " ")))
    else
      vim.health.error(("shell %q is not executable"):format(cmd[1]))
    end
    local border = require("slop.core.ui.float").border(cfg.float.border or nil)
    vim.health.info(("layout: %s, border: %s"):format(cfg.layout, vim.inspect(border)))
    local core = package.loaded["slop.core.term"]
    local list = core and core.list({ hidden = true }) or {}
    if #list == 0 then
      vim.health.info("no terminals running")
    end
    for _, t in ipairs(list) do
      vim.health.info(
        ("terminal %d %s (%s) cwd=%s %s"):format(
          t.id,
          t.name,
          t.owner,
          t.cwd,
          t:is_running() and "running" or ("exited " .. tostring(t.exit_code))
        )
      )
    end
  end,
  api = api,
}

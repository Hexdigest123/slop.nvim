--- term module behaviour: one project-root shell terminal (float by default, split/vsplit on demand).
--- Required lazily by modules/term/init.lua. The terminal primitive lives in core/term.lua.
---@class slop.term.actions
local M = {}

local api = vim.api

M.layouts = { "float", "split", "vsplit" }

local state = {
  term = nil, ---@type slop.Term?
}

local function cfg()
  return require("slop.config").get("term")
end

local function core()
  return require("slop.core.term")
end

local function log()
  return require("slop.core.log").scope("term")
end

---@param layout any
---@return boolean
function M.valid_layout(layout)
  return vim.tbl_contains(M.layouts, layout)
end

--- Shell argv from config (string = 'shell'-style "prog args", list, or function).
---@param shell string|string[]|fun(): string|string[]
---@return string[]
function M.shell_cmd(shell)
  if type(shell) == "function" then
    shell = shell()
  end
  if type(shell) == "string" then
    if shell == "" then
      shell = vim.o.shell
    end
    return vim.split(vim.trim(shell), "%s+", { trimempty = true })
  end
  return vim.list_extend({}, shell or { vim.o.shell })
end

--- Working directory from config.
---@param cwd string|fun(): string
---@return string
function M.resolve_cwd(cwd)
  if type(cwd) == "function" then
    cwd = cwd()
  end
  if cwd == nil or cwd == "root" then
    return require("slop.core.project").root()
  elseif cwd == "cwd" then
    return vim.fn.getcwd()
  end
  return vim.fs.normalize(vim.fn.expand(cwd))
end

---@param c table term config
---@return slop.term.Spec
function M.term_spec(c)
  local f = c.float or {}
  local wo = {
    winhighlight = "Normal:SlopTermNormal,NormalFloat:SlopTermNormal,FloatBorder:SlopTermBorder,"
      .. "FloatTitle:SlopTermTitle",
  }
  if (f.winblend or 0) > 0 then
    wo.winblend = f.winblend
  end
  return {
    cmd = M.shell_cmd(c.shell),
    cwd = M.resolve_cwd(c.cwd),
    owner = "term",
    layout = c.layout,
    float = {
      width = f.width,
      height = f.height,
      min_width = f.min_width,
      min_height = f.min_height,
      title = f.title,
      title_pos = f.title_pos,
      border = f.border or nil,
    },
    split = c.split,
    vsplit = c.vsplit,
    wo = wo,
    start_insert = c.start_insert,
    persist_mode = c.persist_mode,
    hide_on_leave = c.hide_on_leave,
    close_on_exit = c.close_on_exit,
    on_open = function(t)
      require("slop.core.keymaps").apply_buf("term", t.buf)
    end,
  }
end

--- The module's terminal if it is alive.
---@return slop.Term?
function M.current()
  local t = state.term
  if t and core().get(t.id) == t and t.buf and api.nvim_buf_is_valid(t.buf) then
    return t
  end
  state.term = nil
  return nil
end

--- The module's terminal, spawned (hidden) when needed.
---@return slop.Term?
function M.ensure()
  local t = M.current()
  if t then
    return t
  end
  local spec = M.term_spec(cfg())
  t = core().spawn(spec)
  state.term = t
  return t
end

---@param layout? string
---@return boolean
local function check_layout(layout)
  if layout ~= nil and not M.valid_layout(layout) then
    log().notify(("unknown layout '%s' (float|split|vsplit)"):format(tostring(layout)), vim.log.levels.ERROR)
    return false
  end
  return true
end

--- Toggle the terminal. No layout: hide when visible, else show in config `layout`.
--- With a layout: show there (moving it if visible elsewhere), or hide when already shown there.
---@param layout? slop.term.Layout
---@return slop.Term?
function M.toggle(layout)
  if not check_layout(layout) then
    return nil
  end
  local t = M.ensure()
  if not t then
    return nil
  end
  if not t:is_visible() then
    return t:show({ layout = layout or cfg().layout })
  end
  return t:toggle(layout and { layout = layout } or nil)
end

--- Show (and focus) the terminal.
---@param layout? slop.term.Layout
---@return slop.Term?
function M.show(layout)
  if not check_layout(layout) then
    return nil
  end
  local t = M.ensure()
  return t and t:show({ layout = layout or cfg().layout })
end

function M.hide()
  local t = M.current()
  if t then
    t:hide()
  end
end

--- Reveal the terminal after sending: floats get focus, splits keep focus in the source window.
---@param t slop.Term
local function reveal(t)
  if t:is_visible() then
    return
  end
  local layout = cfg().layout
  t:show({ layout = layout, enter = layout == "float" })
end

--- Send text (string or lines) to the terminal and reveal it.
---@param data string|string[]
---@param opts? slop.term.SendOpts
---@return boolean
function M.send(data, opts)
  local t = M.ensure()
  if not t then
    return false
  end
  local ok = t:send(data, opts)
  if ok then
    reveal(t)
  end
  return ok
end

--- Text of the current (or last) visual selection, honouring char/line/block mode.
---@return string[]
function M.selection()
  local mode = vim.fn.mode()
  local s, e
  if mode:match("^[vV\22]") then
    s, e = vim.fn.getpos("v"), vim.fn.getpos(".")
  else
    s, e = vim.fn.getpos("'<"), vim.fn.getpos("'>")
    mode = vim.fn.visualmode()
  end
  if mode == "" then
    return {}
  end
  return vim.fn.getregion(s, e, { type = mode })
end

--- Send the visual selection (keymap `send`, mode x). Leaves visual mode.
---@return boolean
function M.send_selection()
  local lines = M.selection()
  if vim.fn.mode():match("^[vV\22]") then
    api.nvim_feedkeys(vim.keycode("<Esc>"), "nx", false)
  end
  if #lines == 0 then
    return false
  end
  return M.send(lines)
end

--- Send buffer lines line1..line2 (1-based, inclusive).
---@param line1 integer
---@param line2 integer
---@param buf? integer
---@return boolean
function M.send_lines(line1, line2, buf)
  local lines = api.nvim_buf_get_lines(buf or 0, line1 - 1, line2, false)
  return M.send(lines)
end

--- Run a command line in the terminal (expandcmd: `%` etc. work) and show it.
---@param cmd string
---@return boolean
function M.exec(cmd)
  if not cmd or vim.trim(cmd) == "" then
    log().notify("usage: :Slop term exec {cmd}", vim.log.levels.WARN)
    return false
  end
  local ok, expanded = pcall(vim.fn.expandcmd, cmd)
  return M.send(ok and expanded or cmd, { dedent = false })
end

--- Kill the terminal job and wipe its buffer.
function M.kill()
  local t = M.current()
  if t then
    t:kill()
  end
  state.term = nil
end

return M

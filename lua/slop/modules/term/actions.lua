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
    shell = vim.trim(shell ~= "" and shell or vim.o.shell)
    -- like core.term's default 'shell': a program path may contain spaces (maybe quoted), else "prog args"
    if vim.fn.executable(shell) == 1 then
      return { shell }
    end
    local quoted, rest = shell:match('^"([^"]+)"%s*(.*)$')
    local argv = vim.split(quoted and rest or shell, "%s+", { trimempty = true })
    if quoted then
      table.insert(argv, 1, quoted)
    end
    return argv
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

--- The module's terminal with a running shell: one whose job exited (kept by `close_on_exit`) is replaced by a
--- fresh one, unless `keep_shown` and it is visible here (its output stays readable until it is hidden).
---@param keep_shown? boolean
---@return slop.Term?
local function usable(keep_shown)
  local t = M.current()
  if t and not t:is_running() and not (keep_shown and t:is_visible()) then
    t:kill()
  end
  return M.ensure()
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
  local t = usable(true)
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
  local t = usable(true)
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
  local t = usable(false)
  if not t then
    return false
  end
  local ok = t:send(data, opts)
  if ok then
    reveal(t)
  end
  return ok
end

--- Leftmost display column of a position (its first cell), the position clamped to the end of its line.
---@param pos integer[]  getpos() result
---@return integer
local function first_cell(pos)
  local col = math.min(pos[3], vim.fn.col({ pos[2], "$" }))
  return vim.fn.virtcol({ pos[2], col, pos[4] }, true)[1]
end

--- What `y` gives for a blockwise selection made with `$` (getregion() only knows the corners' columns): every
--- line from display column `left` to its end. Like Vim, a character straddling the left edge becomes spaces and a
--- line that does not reach the edge becomes blanks as wide as the block.
---@param l1 integer
---@param l2 integer
---@param left integer
---@return string[]
local function block_to_eol(l1, l2, left)
  local right = 0
  for lnum = l1, l2 do
    right = math.max(right, vim.fn.virtcol({ lnum, "$" }))
  end
  local out = {}
  for lnum = l1, l2 do
    local stop = vim.fn.virtcol({ lnum, "$" })
    if stop < left then
      out[#out + 1] = (" "):rep(right - left + 1)
    elseif stop == left then
      out[#out + 1] = ""
    else
      local line = vim.fn.getline(lnum)
      local c = vim.fn.virtcol2col(0, lnum, left)
      local cells = vim.fn.virtcol({ lnum, c }, true)
      local pad = ""
      if cells[1] < left then
        pad = (" "):rep(cells[2] - left + 1)
        c = c + #vim.fn.strcharpart(line:sub(c), 0, 1)
      end
      out[#out + 1] = pad .. line:sub(c)
    end
  end
  return out
end

--- Text of the current (or last) visual selection, honouring char/line/block mode (and `$` in block mode).
---@return string[]
function M.selection()
  local mode = vim.fn.mode()
  local s, e, to_eol
  if mode:match("^[vV\22]") then
    s, e = vim.fn.getpos("v"), vim.fn.getpos(".")
    to_eol = vim.fn.getcurpos()[5] == vim.v.maxcol
  else
    s, e = vim.fn.getpos("'<"), vim.fn.getpos("'>")
    mode = vim.fn.visualmode()
    if mode == "\22" then
      -- only `gv` restores whether the block was made with `$` (its curswant); :normal leaves Visual mode active
      local view = vim.fn.winsaveview()
      vim.cmd("silent! noautocmd keepjumps normal! gv")
      to_eol = vim.fn.getcurpos()[5] == vim.v.maxcol
      vim.cmd("silent! noautocmd keepjumps normal! \27")
      vim.fn.winrestview(view)
    end
  end
  if mode == "" then
    return {}
  end
  if mode == "\22" and to_eol then
    return block_to_eol(math.min(s[2], e[2]), math.max(s[2], e[2]), math.min(first_cell(s), first_cell(e)))
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

local SPECIAL = {
  cword = true,
  cWORD = true,
  cexpr = true,
  cfile = true,
  afile = true,
  abuf = true,
  amatch = true,
  sfile = true,
  stack = true,
  script = true,
  slnum = true,
  sflnum = true,
  client = true,
}

--- Expand a command line like |:!| does: `%`, `#`, `#n` and `<cword>`-style items (with `:p` `:8` `:~` `:.` `:h`
--- `:t` `:r` `:e` `:S` modifiers) are replaced, `\%` `\#` `\<cword>` give the text itself, everything else stays as
--- typed (expandcmd() would also eat every backslash, e.g. in `grep '\<a\.b'`, and expand `$VAR` in single quotes).
---@param cmd string
---@return string? expanded  nil when an item has no value (e.g. `%` in an unnamed buffer)
function M.expand(cmd)
  local out, i = {}, 1
  while i <= #cmd do
    local c = cmd:sub(i, i)
    local stop
    if c == "\\" and (cmd:find("^[%%#]", i + 1) or SPECIAL[cmd:match("^<(%a+)>", i + 1)]) then
      out[#out + 1] = cmd:sub(i + 1, i + 1)
      i = i + 2
    else
      if c == "%" then
        stop = i
      elseif c == "#" then
        stop = select(2, cmd:find("^#%d*", i)) -- `#n`: buffer n
      elseif c == "<" then
        local _, e, word = cmd:find("^<(%a+)>", i)
        stop = SPECIAL[word] and e or nil
      end
      if stop then
        while cmd:find("^:[p8~.htreS]", stop + 1) do
          stop = stop + 2
        end
        local ok, value = pcall(vim.fn.expand, cmd:sub(i, stop)) -- E194/E499 when there is nothing to expand to
        if not ok or value == "" then
          return nil
        end
        out[#out + 1] = value
        i = stop + 1
      else
        out[#out + 1] = c
        i = i + 1
      end
    end
  end
  return table.concat(out)
end

--- Run a command line in the terminal (expanded like |:!|) and show it.
---@param cmd string
---@return boolean
function M.exec(cmd)
  if not cmd or vim.trim(cmd) == "" then
    log().notify("usage: :Slop term exec {cmd}", vim.log.levels.WARN)
    return false
  end
  return M.send(M.expand(cmd) or cmd, { dedent = false })
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

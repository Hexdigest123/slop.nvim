--- Named, reusable scratch buffers ("slop://<name>") and windows to show them in.
--- OWNER: rest.
---
---   local buf, win = scratch.open("rest/result", { layout = "vsplit", filetype = "json", winbar = "200 OK" })
---   scratch.set_lines(buf, lines)            -- handles 'modifiable'
---   scratch.set_winbar(buf, "%#Title#200%*") -- every window showing it, and windows that show it later
---@class slop.ui.scratch
local M = {}

local api = vim.api

---@class slop.scratch.BufOpts
---@field filetype? string
---@field modifiable? boolean             default false
---@field secret_path? string             sets vim.b.slop_secret_path (core.secrets / cloak effective path)
---@field bo? table<string, any>          extra buffer options

---@class slop.scratch.OpenOpts: slop.scratch.BufOpts
---@field layout? "vsplit"|"split"|"float"|"tab"|"current"  default "vsplit"
---@field enter? boolean                  focus the window (default false: focus stays in the source)
---@field size? integer|number            split size (cells, or (0, 1] fraction of the editor)
---@field float? slop.float.Opts          extra options for layout = "float"
---@field wo? table<string, any>          window-local options for the window
---@field winbar? string                  winbar text (statusline syntax)

local PREFIX = "slop://"
local bufs = {} ---@type table<string, integer>
local group ---@type integer?

local function augroup()
  if not group then
    group = api.nvim_create_augroup("slop.scratch", { clear = true })
    api.nvim_create_autocmd("BufWinEnter", {
      group = group,
      desc = "slop: scratch winbar",
      callback = function(ev)
        local text = vim.b[ev.buf].slop_winbar
        if text and M.name(ev.buf) then
          local win = api.nvim_get_current_win()
          if api.nvim_win_get_buf(win) == ev.buf then
            vim.wo[win][0].winbar = text
          end
        end
      end,
    })
  end
  return group
end

--- Name of a scratch buffer ("rest/result" for "slop://rest/result"), nil for other buffers.
---@param buf integer
---@return string?
function M.name(buf)
  if not (buf and api.nvim_buf_is_valid(buf)) then
    return nil
  end
  local n = vim.b[buf].slop_scratch
  return type(n) == "string" and n or nil
end

--- Existing scratch buffer by name (nil if none / wiped).
---@param name string
---@return integer?
function M.find(name)
  local b = bufs[name]
  if b and api.nvim_buf_is_valid(b) then
    return b
  end
  bufs[name] = nil
  local nr = vim.fn.bufnr("^" .. vim.fn.escape(PREFIX .. name, "\\/.*$^~[]") .. "$")
  if nr > 0 and M.name(nr) == name then
    bufs[name] = nr
    return nr
  end
  return nil
end

---@param buf integer
---@param opts slop.scratch.BufOpts
local function apply_buf_opts(buf, opts)
  if opts.filetype and vim.bo[buf].filetype ~= opts.filetype then
    vim.bo[buf].filetype = opts.filetype
  end
  if opts.modifiable ~= nil then
    vim.bo[buf].modifiable = opts.modifiable
  end
  if opts.secret_path ~= nil then
    vim.b[buf].slop_secret_path = opts.secret_path ~= "" and opts.secret_path or nil
  end
  for k, v in pairs(opts.bo or {}) do
    vim.bo[buf][k] = v
  end
end

--- Get (or create) the named scratch buffer: buftype=nofile, bufhidden=hide, noswapfile, unlisted.
---@param name string
---@param opts? slop.scratch.BufOpts
---@return integer buf
function M.get(name, opts)
  assert(type(name) == "string" and name ~= "", "slop: scratch.get needs a name")
  opts = opts or {}
  augroup()
  local buf = M.find(name)
  if not buf then
    buf = api.nvim_create_buf(false, true)
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].bufhidden = "hide"
    vim.bo[buf].swapfile = false
    vim.bo[buf].buflisted = false
    vim.bo[buf].undolevels = -1
    vim.b[buf].slop_scratch = name
    pcall(api.nvim_buf_set_name, buf, PREFIX .. name)
    vim.bo[buf].modifiable = opts.modifiable == true
    bufs[name] = buf
  end
  apply_buf_opts(buf, opts)
  return buf
end

--- First window in the current tabpage showing the scratch buffer (by name or buffer number).
---@param name_or_buf string|integer
---@return integer?
function M.win(name_or_buf)
  local buf = type(name_or_buf) == "number" and name_or_buf or M.find(name_or_buf --[[@as string]])
  if not (buf and api.nvim_buf_is_valid(buf)) then
    return nil
  end
  for _, w in ipairs(api.nvim_tabpage_list_wins(0)) do
    if api.nvim_win_get_buf(w) == buf then
      return w
    end
  end
  return nil
end

---@param size integer|number|nil
---@param total integer
---@param default number
---@return integer
local function cells(size, total, default)
  size = size or default
  if size <= 1 then
    return math.max(1, math.floor(total * size))
  end
  return math.floor(size)
end

---@param win integer
---@param opts slop.scratch.OpenOpts
local function apply_win_opts(win, buf, opts)
  for k, v in pairs(opts.wo or {}) do
    vim.wo[win][0][k] = v
  end
  local text = vim.b[buf].slop_winbar
  if text then
    vim.wo[win][0].winbar = text
  end
end

--- Show the named scratch buffer, reusing a window (in the current tabpage) that already shows it.
---@param name string
---@param opts? slop.scratch.OpenOpts
---@return integer buf, integer win
function M.open(name, opts)
  opts = opts or {}
  local buf = M.get(name, opts)
  if opts.winbar then
    vim.b[buf].slop_winbar = opts.winbar
  end
  local src = api.nvim_get_current_win()
  local win = M.win(buf)
  local layout = opts.layout or "vsplit"
  if not win then
    if layout == "float" then
      local fopts = vim.tbl_extend("force", { width = 0.8, height = 0.8, close_keys = { "q" } }, opts.float or {})
      fopts.buf = buf
      fopts.enter = opts.enter == true
      win = require("slop.core.ui.float").open(fopts).win
    elseif layout == "split" then
      win = api.nvim_open_win(buf, false, {
        split = "below",
        win = -1,
        height = cells(opts.size, vim.o.lines - vim.o.cmdheight, 0.3),
      })
    elseif layout == "tab" then
      vim.cmd("tab split")
      win = api.nvim_get_current_win()
      api.nvim_win_set_buf(win, buf)
    elseif layout == "current" then
      win = src
      api.nvim_win_set_buf(win, buf)
    else -- vsplit
      win = api.nvim_open_win(buf, false, {
        split = "right",
        win = -1,
        width = cells(opts.size, vim.o.columns, 0.5),
      })
    end
  end
  apply_win_opts(win, buf, opts)
  if opts.enter then
    api.nvim_set_current_win(win)
  elseif layout ~= "current" and api.nvim_win_is_valid(src) and api.nvim_get_current_win() ~= src then
    api.nvim_set_current_win(src)
  end
  return buf, win
end

--- Replace the buffer's lines (handles 'modifiable').
---@param buf integer
---@param lines string[]
function M.set_lines(buf, lines)
  if not api.nvim_buf_is_valid(buf) then
    return
  end
  local mod = vim.bo[buf].modifiable
  vim.bo[buf].modifiable = true
  local flat = {}
  for _, l in ipairs(lines) do
    for _, part in ipairs(vim.split(l, "\n", { plain = true })) do
      flat[#flat + 1] = part
    end
  end
  api.nvim_buf_set_lines(buf, 0, -1, false, flat)
  vim.bo[buf].modifiable = mod
  vim.bo[buf].modified = false
end

--- Set the winbar of every window showing `buf` (statusline syntax); remembered for windows opened later.
---@param buf integer
---@param text string
function M.set_winbar(buf, text)
  if not api.nvim_buf_is_valid(buf) then
    return
  end
  vim.b[buf].slop_winbar = text
  for _, w in ipairs(api.nvim_list_wins()) do
    if api.nvim_win_get_buf(w) == buf and api.nvim_win_get_config(w).relative == "" then
      vim.wo[w][0].winbar = text
    end
  end
end

--- Close every window showing the named buffer (the buffer is kept; the last window of the editor is
--- switched to another buffer instead).
---@param name string
function M.close(name)
  local buf = M.find(name)
  if not buf then
    return
  end
  for _, w in ipairs(api.nvim_list_wins()) do
    if api.nvim_win_is_valid(w) and api.nvim_win_get_buf(w) == buf then
      if not pcall(api.nvim_win_close, w, true) then
        local alt = vim.fn.bufnr("#")
        if alt > 0 and alt ~= buf and api.nvim_buf_is_valid(alt) then
          api.nvim_win_set_buf(w, alt)
        else
          api.nvim_win_set_buf(w, api.nvim_create_buf(true, false))
        end
      end
    end
  end
end

--- Close its windows and wipe the named buffer.
---@param name string
function M.delete(name)
  local buf = M.find(name)
  if not buf then
    return
  end
  M.close(name)
  bufs[name] = nil
  pcall(api.nvim_buf_delete, buf, { force = true })
end

return M

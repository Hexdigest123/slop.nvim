--- Edit UI: dimmed in-flight region, spinner/status virt_lines, result sinks (float, scratch).
---@class slop.edit.ui
local M = {}

local api = vim.api
local util = require("slop.core.util")

local function ns_region()
  return util.ns("edit.region")
end
local function ns_status()
  return util.ns("edit.status")
end
M.ns_region = ns_region

--- Region extmark: tracks edits, dims the text while the request runs.
---@param buf integer
---@param range slop.Range
---@return integer
function M.region_mark(buf, range)
  return util.region_mark(buf, ns_region(), range, {
    hl_group = "SlopEditRegion",
    priority = 150,
    invalidate = true,
  })
end

---@param buf integer
---@param id integer?
---@return slop.Range?
function M.region(buf, id)
  if not id then
    return nil
  end
  return util.mark_range(buf, ns_region(), id)
end

local function truncate(s, width)
  s = s:gsub("[\r\n\t]", " ")
  if api.nvim_strwidth(s) <= width then
    return s
  end
  return vim.fn.strcharpart(s, 0, math.max(1, width - 1)) .. "…"
end

local function win_width(buf)
  for _, w in ipairs(api.nvim_list_wins()) do
    if api.nvim_win_get_buf(w) == buf then
      return api.nvim_win_get_width(w)
    end
  end
  return vim.o.columns
end

--- Tail of the streamed answer: last non-empty line.
---@param text string
---@return string?
local function tail(text)
  if not text or text == "" then
    return nil
  end
  local last
  for line in text:gmatch("[^\n]+") do
    if line:find("%S") and not line:find("slop:replacement", 1, true) then
      last = line
    end
  end
  return last
end

---@class slop.edit.StatusView
---@field buf integer
---@field mark integer?
---@field status_id integer?
---@field agent string
---@field status string
---@field message string
---@field started integer
---@field cancel_key string|false

--- Draw / update the status virt_lines of a request (above the region; below it when the region starts at row 0).
---@param v slop.edit.StatusView
---@param frame string
function M.render_status(v, frame)
  if not util.buf_valid(v.buf) then
    return
  end
  local r = M.region(v.buf, v.mark)
  if not r then
    return
  end
  local width = win_width(v.buf) - 4
  local secs = math.floor((vim.uv.now() - v.started) / 1000)
  local head = ("%s · %s · %ds"):format(v.agent, v.status, secs)
  if v.cancel_key then
    head = head .. " · " .. v.cancel_key .. " cancel"
  end
  local lines = { { { frame .. " ", "SlopEditSpinner" }, { truncate(head, width), "SlopEditStatus" } } }
  local t = tail(v.message)
  if t then
    lines[2] = { { "  │ " .. truncate(vim.trim(t), width - 4), "SlopEditStatus" } }
  end
  local row, above = r[1], true
  if r[1] == 0 then
    row, above = r[3], false
  end
  local ok, id = pcall(api.nvim_buf_set_extmark, v.buf, ns_status(), row, 0, {
    id = v.status_id,
    virt_lines = lines,
    virt_lines_above = above,
  })
  if ok then
    v.status_id = id
  end
end

--- Remove the region mark and status lines of a request.
---@param v {buf: integer, mark: integer?, status_id: integer?}
function M.clear(v)
  if api.nvim_buf_is_valid(v.buf) then
    if v.mark then
      pcall(api.nvim_buf_del_extmark, v.buf, ns_region(), v.mark)
    end
    if v.status_id then
      pcall(api.nvim_buf_del_extmark, v.buf, ns_status(), v.status_id)
    end
  end
  v.mark, v.status_id = nil, nil
end

--- A short-lived error line at `row`.
---@param buf integer
---@param row integer
---@param msg string
function M.flash_error(buf, row, msg)
  if not util.buf_valid(buf) then
    return
  end
  row = math.max(0, math.min(row, api.nvim_buf_line_count(buf) - 1))
  local ok, id = pcall(api.nvim_buf_set_extmark, buf, ns_status(), row, 0, {
    virt_lines = { { { "✗ slop edit: " .. truncate(msg, win_width(buf) - 16), "SlopEditError" } } },
    virt_lines_above = row > 0,
  })
  if ok then
    vim.defer_fn(function()
      pcall(api.nvim_buf_del_extmark, buf, ns_status(), id)
    end, 5000)
  end
end

--- Markdown answer in a float (explain sink).
---@param title string
---@param text string
---@return slop.float.Handle?
function M.show_float(title, text)
  local lines = vim.split(vim.trim(text), "\n", { plain = true })
  local buf = api.nvim_create_buf(false, true)
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "markdown"
  vim.bo[buf].modifiable = false
  local float = require("slop.core.ui.float")
  local width = math.max(40, math.min(100, vim.o.columns - 10))
  local height = math.max(3, math.min(#lines + 1, math.floor(vim.o.lines * 0.7)))
  local ok, h = pcall(float.open, {
    buf = buf,
    title = title,
    width = width,
    height = function()
      return height
    end,
    close_keys = { "q", "<Esc>" },
    wo = { wrap = true, linebreak = true, conceallevel = 2 },
  })
  if not ok then
    require("slop.core.log").scope("edit").error("cannot open float: %s", h)
    return nil
  end
  return h
end

--- Lines in a named scratch buffer (core.ui.scratch), opened in a vsplit.
---@param name string
---@param lines string[]
---@param filetype? string
---@param opts? {modifiable?: boolean, secret_path?: string}
---@return integer? buf
function M.show_scratch(name, lines, filetype, opts)
  opts = opts or {}
  local ok, res = pcall(function()
    local scratch = require("slop.core.ui.scratch")
    local buf = scratch.open(name, {
      filetype = filetype,
      layout = "vsplit",
      enter = true,
      modifiable = opts.modifiable ~= false,
      secret_path = opts.secret_path,
    })
    scratch.set_lines(buf, lines)
    return buf
  end)
  if ok then
    return res
  end
  -- fallback when core.ui.scratch is unavailable
  vim.cmd("botright vnew")
  local buf = api.nvim_get_current_buf()
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false
  pcall(api.nvim_buf_set_name, buf, "slop://" .. name)
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  if filetype then
    vim.bo[buf].filetype = filetype
  end
  return buf
end

return M

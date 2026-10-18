--- Result view: one reused scratch buffer "slop://rest/result" holding only the (pretty-printed) body in its real
--- filetype; status, time and size in the winbar; `H` toggles the response headers (virtual lines above line 1).
---@class slop.rest.view
local M = {}

local api = vim.api

M.NAME = "rest/result"
M.MAX_FORMAT = 1024 * 1024

local current ---@type table?  last shown entry

--- Filetype for a Content-Type value.
---@param ctype? string
---@return string
function M.filetype(ctype)
  local t = (ctype or ""):lower():match("^%s*([^;]+)") or ""
  t = vim.trim(t)
  if t:match("json") then
    return "json"
  elseif t:match("xml") then
    return "xml"
  elseif t:match("html") then
    return "html"
  elseif t:match("javascript") or t:match("ecmascript") then
    return "javascript"
  elseif t:match("css") then
    return "css"
  elseif t:match("yaml") then
    return "yaml"
  elseif t:match("graphql") then
    return "graphql"
  end
  return "text"
end

---@param body string
---@param ctype? string
---@return boolean
function M.is_binary(body, ctype)
  local t = (ctype or ""):lower()
  if t:match("^image/") or t:match("octet%-stream") or t:match("^audio/") or t:match("^video/") or t:match("pdf") then
    return true
  end
  return body:sub(1, 1024):find("%z") ~= nil
end

---@param n number
---@return string
function M.human_size(n)
  n = n or 0
  if n < 1024 then
    return ("%d B"):format(n)
  elseif n < 1024 * 1024 then
    return ("%.1f KiB"):format(n / 1024)
  end
  return ("%.1f MiB"):format(n / 1024 / 1024)
end

---@param ms number
---@return string
function M.human_time(ms)
  if not ms then
    return "?"
  end
  if ms < 1000 then
    return ("%d ms"):format(math.floor(ms + 0.5))
  end
  return ("%.2f s"):format(ms / 1000)
end

--- Pure fallback pretty-printer for JSON (key order is not preserved by vim.json).
---@param body string
---@return string?
function M.json_pretty(body)
  local ok, data = pcall(vim.json.decode, body)
  if not ok then
    return nil
  end
  local eok, out = pcall(vim.json.encode, data, { indent = "  ", sort_keys = true })
  return eok and out or nil
end

--- Pretty-print `body` for `ft` asynchronously (jq / xmllint when available). cb(text) on the main loop.
---@param body string
---@param ft string
---@param enabled boolean
---@param cb fun(text: string)
function M.format(body, ft, enabled, cb)
  if not enabled or #body > M.MAX_FORMAT or body == "" then
    return cb(body)
  end
  local cmd
  if ft == "json" and vim.fn.executable("jq") == 1 then
    cmd = { "jq", "." }
  elseif ft == "xml" and vim.fn.executable("xmllint") == 1 then
    cmd = { "xmllint", "--format", "-" }
  end
  if not cmd then
    if ft == "json" then
      return cb(M.json_pretty(body) or body)
    end
    return cb(body)
  end
  local ok = pcall(vim.system, cmd, { stdin = body, text = true, timeout = 5000 }, function(r)
    vim.schedule(function()
      if r.code == 0 and r.stdout and r.stdout ~= "" then
        cb((r.stdout:gsub("\n$", "")))
      elseif ft == "json" then
        cb(M.json_pretty(body) or body)
      else
        cb(body)
      end
    end)
  end)
  if not ok then
    cb(ft == "json" and M.json_pretty(body) or body)
  end
end

local function esc(s)
  return (tostring(s or ""):gsub("%%", "%%%%"))
end

--- Short display form of a URL: path + query (host dropped).
---@param url string
---@return string
local function short_url(url)
  local path = (url or ""):match("^%a[%w+.-]*://[^/]+(/.*)$")
  return path or url or ""
end

--- Pure: winbar text for an entry { req, res?, err?, env?, running? }.
---@param e table
---@return string
function M.winbar(e)
  local req = e.req or {}
  local target = esc(
    ((e.resolved and e.resolved.method) or req.method or "")
      .. " "
      .. short_url((e.resolved and e.resolved.url) or req.url or "")
  )
  local parts
  if e.running then
    parts = { "%#SlopRestRunning# ⏳ " .. esc(e.running == true and "running" or e.running) .. " %*", target }
  elseif e.err then
    parts = { "%#SlopRestError# ✗ " .. esc(e.err) .. " %*", target }
  elseif e.res then
    local s = e.res.status or 0
    local hl = s >= 500 and "SlopRestError" or s >= 400 and "SlopRestWarn" or "SlopRestOk"
    local mark = s >= 400 and "✗" or "✓"
    parts = {
      ("%%#%s# %s %d %s %%*"):format(hl, mark, s, esc(e.res.reason or "")),
      target,
      M.human_time(e.res.time_ms),
      M.human_size(e.res.size),
    }
    if e.res.curl_error then
      parts[#parts + 1] = "%#SlopRestWarn#" .. esc(e.res.curl_error) .. "%*"
    end
  else
    parts = { target }
  end
  if e.env then
    parts[#parts + 1] = "[" .. esc(e.env) .. "]"
  end
  return table.concat(parts, " · ") .. "%=%#SlopDim#H headers%*"
end

local function cfg()
  return require("slop.config").get("rest")
end

---@return integer buf, integer win
local function open()
  local c = cfg()
  local scratch = require("slop.core.ui.scratch")
  local fresh = scratch.find(M.NAME) == nil
  local buf, win = scratch.open(M.NAME, {
    layout = c.result.layout,
    enter = c.result.focus == true,
    size = c.result.size,
  })
  if fresh then
    pcall(require("slop.core.keymaps").apply_buf, "rest", buf)
  end
  return buf, win
end

local function ns()
  return require("slop.core.util").ns("rest.result")
end

local function render_headers(buf)
  api.nvim_buf_clear_namespace(buf, ns(), 0, -1)
  local e = current
  local show = vim.b[buf].slop_rest_headers == true
  local n = 0
  if show and e and e.res then
    local vl = {
      {
        { ("HTTP/%s %d %s"):format(e.res.version or "?", e.res.status or 0, e.res.reason or ""), "SlopRestStatus" },
      },
    }
    for _, h in ipairs(e.res.headers or {}) do
      vl[#vl + 1] = { { h[1], "SlopRestHeaderName" }, { ": ", "SlopDim" }, { h[2], "SlopRestHeaderValue" } }
    end
    vl[#vl + 1] = { { "" } }
    api.nvim_buf_set_extmark(buf, ns(), 0, 0, { virt_lines = vl, virt_lines_above = true })
    n = #vl
  end
  for _, w in ipairs(api.nvim_list_wins()) do
    if api.nvim_win_get_buf(w) == buf then
      api.nvim_win_call(w, function()
        vim.fn.winrestview({ topline = 1, topfill = n })
      end)
    end
  end
end

--- Toggle the headers block of the result buffer.
function M.toggle_headers()
  local buf = require("slop.core.ui.scratch").find(M.NAME)
  if not buf then
    return
  end
  vim.b[buf].slop_rest_headers = not (vim.b[buf].slop_rest_headers == true)
  render_headers(buf)
end

--- Show "running" state for an entry.
---@param e table { req, resolved?, env?, running = true|string }
function M.running(e)
  current = e
  local buf = open()
  require("slop.core.ui.scratch").set_winbar(buf, M.winbar(e))
end

--- Show a finished entry: { req, resolved?, res?, err?, env? }.
---@param e table
---@param on_shown? fun(buf: integer)
function M.show(e, on_shown)
  current = e
  local scratch = require("slop.core.ui.scratch")
  local buf = open()
  scratch.set_winbar(buf, M.winbar(e))
  if e.err then
    scratch.get(M.NAME, { filetype = "text" })
    local lines = vim.split(e.err, "\n", { plain = true })
    vim.list_extend(lines, { "", "(" .. (e.req.method or "") .. " " .. (e.req.url or "") .. ")" })
    scratch.set_lines(buf, lines)
    render_headers(buf)
    if on_shown then
      on_shown(buf)
    end
    return
  end
  local res = e.res
  if M.is_binary(res.body, res.content_type) then
    scratch.get(M.NAME, { filetype = "text" })
    scratch.set_lines(buf, { ("(binary response: %s, %s)"):format(res.content_type or "?", M.human_size(#res.body)) })
    render_headers(buf)
    if on_shown then
      on_shown(buf)
    end
    return
  end
  local ft = M.filetype(res.content_type)
  local token = {}
  M._token = token
  M.format(res.body, ft, cfg().result.format, function(text)
    if M._token ~= token or not api.nvim_buf_is_valid(buf) then
      return
    end
    scratch.get(M.NAME, { filetype = ft })
    scratch.set_lines(buf, vim.split(text, "\n", { plain = true }))
    render_headers(buf)
    if on_shown then
      on_shown(buf)
    end
  end)
end

--- Entry currently shown (or nil).
---@return table?
function M.current()
  return current
end

function M.close()
  require("slop.core.ui.scratch").close(M.NAME)
end

return M

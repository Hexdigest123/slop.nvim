--- Secret redaction registry. OWNER: cloak (the skeleton implemented the built-in default path).
---
--- Every text that may reach an AI provider/agent MUST pass through this module:
---   * whole files matching a block glob are never sent (`is_blocked`) — redact_* return the placeholder
---   * spans reported by providers (cloak registers one) are replaced by `secrets.placeholder` ("<redacted>")
---   * built-in, always on: PEM private-key blocks are redacted in any text
---
--- Works with no provider registered: `secrets.block` (config) defaults to a conservative glob list
--- (".env*", "*.pem", "*.key", "*.p12", "*.pfx", "*secret*", "*credential*", "*private-key*").
---
--- Effective path contract: a buffer's path is `vim.b[buf].slop_secret_path` if set (scratch/preview
--- buffers showing a file's content set it), else its buffer name.
---
--- Display toggles (e.g. :Slop cloak toggle) never disable redaction.
--- Call from the main loop (not from luv callbacks): the first query lazily loads secret providers
--- (`registry.load_capability("secrets")`, i.e. cloak if enabled).
---@class slop.secrets
local M = {}

---@class slop.secrets.Span
---@field row integer      0-based row (relative to `first_row` passed to spans())
---@field col integer      0-based byte col
---@field end_col integer  0-based byte col, exclusive

---@class slop.secrets.Provider
---@field name string
---@field block? string[]                     extra file globs never sent to AI
---@field match_path? fun(path: string): boolean  provider applies to this path (default: all paths)
---@field spans? fun(path: string, lines: string[], first_row: integer): slop.secrets.Span[]  pure, text-based
---@field display? boolean                    also mask this provider's spans on screen (cloak renders them)

local providers = {} ---@type table<string, slop.secrets.Provider>
local order = {} ---@type string[]
local glob_cache = {} ---@type table<string, vim.lpeg.Pattern|false>
local ensuring = false
local ensured = false -- load_capability ran for the current config generation

local function cfg()
  return require("slop.config").get("secrets")
end

--- Load secret providers (cloak) once per config generation. A later `setup()` (User SlopConfigChanged)
--- may enable a provider, so the flag is reset then.
local function ensure()
  if ensured or ensuring or vim.in_fast_event() then
    return
  end
  ensuring = true
  pcall(function()
    require("slop.core.registry").load_capability("secrets")
  end)
  ensuring = false
  ensured = true
  pcall(vim.api.nvim_create_autocmd, "User", {
    group = vim.api.nvim_create_augroup("slop.secrets", { clear = true }),
    pattern = "SlopConfigChanged",
    once = true,
    desc = "slop: re-check secret providers after setup()",
    callback = function()
      ensured = false
    end,
  })
end

--- Placeholder the AI sees instead of a secret.
---@return string
function M.placeholder()
  return cfg().placeholder
end

--- Register (or replace, by name) a provider.
---@param provider slop.secrets.Provider
function M.register(provider)
  assert(type(provider) == "table" and type(provider.name) == "string", "slop: secrets.register needs {name=...}")
  if not providers[provider.name] then
    order[#order + 1] = provider.name
  end
  providers[provider.name] = provider
end

---@param name string
function M.unregister(name)
  providers[name] = nil
  order = vim.tbl_filter(function(n)
    return n ~= name
  end, order)
end

---@return slop.secrets.Provider[]
function M.providers()
  local out = {}
  for _, n in ipairs(order) do
    out[#out + 1] = providers[n]
  end
  return out
end

--- Effective path of a buffer (vim.b.slop_secret_path or the buffer name).
---@param buf integer
---@return string
function M.effective_path(buf)
  buf = buf == 0 and vim.api.nvim_get_current_buf() or buf
  local p = vim.b[buf].slop_secret_path
  if type(p) == "string" and p ~= "" then
    return p
  end
  return vim.api.nvim_buf_get_name(buf)
end

---@param src string|integer|nil
---@return string?
local function to_path(src)
  if type(src) == "number" then
    if not vim.api.nvim_buf_is_valid(src) and src ~= 0 then
      return nil
    end
    return M.effective_path(src)
  end
  return src
end

local function compile(glob)
  local c = glob_cache[glob]
  if c == nil then
    local ok, pat = pcall(vim.glob.to_lpeg, glob)
    c = ok and pat or false
    glob_cache[glob] = c
  end
  return c
end

--- Does `path` match `glob`? Globs without "/" match the basename; others match the full path
--- (also anywhere below a directory, i.e. as "**/<glob>").
---@param glob string
---@param path string
---@return boolean
function M.match_glob(glob, path)
  path = vim.fs.normalize(path)
  if not glob:find("/", 1, true) then
    local pat = compile(glob)
    return pat and pat:match(vim.fs.basename(path)) ~= nil or false
  end
  local pat = compile(glob)
  if pat and pat:match(path) then
    return true
  end
  local deep = compile("**/" .. glob:gsub("^%*%*/", ""))
  return deep and deep:match(path) ~= nil or false
end

--- Globs currently blocking files (config secrets.block + provider block lists).
---@return string[]
function M.block_globs()
  local out = vim.list_extend({}, cfg().block or {})
  for _, p in ipairs(M.providers()) do
    vim.list_extend(out, p.block or {})
  end
  return out
end

--- Must this file never be sent to AI at all? Accepts a path or a buffer number.
---@param src string|integer
---@return boolean
function M.is_blocked(src)
  ensure()
  local path = to_path(src)
  if not path or path == "" then
    return false
  end
  for _, g in ipairs(M.block_globs()) do
    if M.match_glob(g, path) then
      return true
    end
  end
  return false
end

--- Drop blocked paths from a list.
---@param paths string[]
---@return string[]
function M.filter_paths(paths)
  return vim.tbl_filter(function(p)
    return not M.is_blocked(p)
  end, paths)
end

local PEM_BEGIN = "^%s*%-%-%-%-%-BEGIN [%u%d ]*PRIVATE KEY%-%-%-%-%-"
local PEM_END = "^%s*%-%-%-%-%-END [%u%d ]*PRIVATE KEY%-%-%-%-%-"

--- All spans for `lines` (built-in PEM rule + providers), as { [row_index] = { {col, end_col}, ... } }.
---@param path string?
---@param lines string[]
---@param first_row integer
---@param display_only? boolean  only providers with display = true, no built-in rule
---@return table<integer, {[1]: integer, [2]: integer}[]>
local function collect(path, lines, first_row, display_only)
  local by_row = {}
  local function add(i, s, e)
    if e > s then
      by_row[i] = by_row[i] or {}
      table.insert(by_row[i], { s, e })
    end
  end
  local in_pem = false
  for i, l in ipairs(display_only and {} or lines) do
    if l:match(PEM_BEGIN) then
      in_pem = true
    elseif l:match(PEM_END) then
      in_pem = false
    elseif in_pem then
      add(i, 0, #l)
    end
  end
  for _, p in ipairs(M.providers()) do
    if
      p.spans
      and (not display_only or p.display)
      and (not p.match_path or (path and path ~= "" and p.match_path(path)))
    then
      local ok, spans = pcall(p.spans, path or "", lines, first_row)
      if ok and type(spans) == "table" then
        for _, s in ipairs(spans) do
          add(s.row - first_row + 1, s.col, s.end_col)
        end
      end
    end
  end
  return by_row
end

local function merge(spans)
  table.sort(spans, function(a, b)
    return a[1] < b[1]
  end)
  local out = {}
  for _, s in ipairs(spans) do
    local last = out[#out]
    if last and s[1] <= last[2] then
      last[2] = math.max(last[2], s[2])
    else
      out[#out + 1] = { s[1], s[2] }
    end
  end
  return out
end

--- All secret spans of `lines` (built-in PEM rule + every provider whose match_path accepts the source),
--- merged per row and sorted. Rows are absolute (`first_row` + index). Blocked sources are not special-cased.
---@param src string|integer|nil  path or buffer (effective path)
---@param lines string[]
---@param first_row? integer  0-based row of lines[1] (default 0)
---@param opts? {display?: boolean}  display = only providers with `display = true` (no PEM rule)
---@return slop.secrets.Span[]
function M.spans(src, lines, first_row, opts)
  ensure()
  first_row = first_row or 0
  local by_row = collect(to_path(src), lines, first_row, opts and opts.display)
  local rows = vim.tbl_keys(by_row)
  table.sort(rows)
  local out = {}
  for _, i in ipairs(rows) do
    for _, s in ipairs(merge(by_row[i])) do
      out[#out + 1] = { row = first_row + i - 1, col = s[1], end_col = s[2] }
    end
  end
  return out
end

--- Redact lines. Blocked source -> every line replaced by the placeholder (n = #lines).
---@param src string|integer|nil  path or buffer (effective path used for provider matching)
---@param lines string[]
---@param first_row? integer      0-based row of lines[1] in the source (default 0)
---@return string[] lines, integer n  number of redactions
function M.redact_lines(src, lines, first_row)
  ensure()
  local path = to_path(src)
  local ph = M.placeholder()
  if path and M.is_blocked(path) then
    return vim.tbl_map(function()
      return ph
    end, lines), #lines
  end
  local by_row = collect(path, lines, first_row or 0)
  local out, n = {}, 0
  for i, l in ipairs(lines) do
    local spans = by_row[i]
    if spans then
      local parts, pos = {}, 0
      for _, s in ipairs(merge(spans)) do
        local a, b = math.max(s[1], pos), math.min(s[2], #l)
        if b > a then
          parts[#parts + 1] = l:sub(pos + 1, a)
          parts[#parts + 1] = ph
          pos = b
          n = n + 1
        end
      end
      parts[#parts + 1] = l:sub(pos + 1)
      out[i] = table.concat(parts)
    else
      out[i] = l
    end
  end
  return out, n
end

--- Redact a text blob from `path` (diff hunks, @file contents, fs/read_text_file, prompts...).
--- Blocked path -> the whole text becomes the placeholder.
---@param text string
---@param path? string|integer  path or buffer; nil = only built-in + path-independent providers
---@return string text, integer n
function M.redact_text(text, path)
  ensure()
  local p = to_path(path)
  if p and p ~= "" and M.is_blocked(p) then
    return M.placeholder(), 1
  end
  local lines, n = M.redact_lines(p, vim.split(text, "\n", { plain = true }), 0)
  return table.concat(lines, "\n"), n
end

--- Redact a unified git diff: sections of blocked files are omitted entirely, other content lines are
--- redacted with that file's providers.
---@param diff string
---@return string diff, integer n
function M.redact_diff(diff)
  ensure()
  local out, n = {}, 0
  local path, skipping, in_hunk = nil, false, false
  for _, l in ipairs(vim.split(diff, "\n", { plain = true })) do
    local b = l:match("^diff %-%-git a/.- b/(.+)$")
    if b then
      path, in_hunk = b, false
      skipping = M.is_blocked(b)
      out[#out + 1] = l
      if skipping then
        out[#out + 1] = ("[slop: diff of %s omitted]"):format(b)
        n = n + 1
      end
    elseif not skipping then
      if l:match("^@@") then
        in_hunk = true
        out[#out + 1] = l
      elseif not in_hunk then
        local pb = l:match("^%+%+%+ b/(.+)$")
        if pb and pb ~= path then
          path = pb
          skipping = M.is_blocked(pb)
          if skipping then
            out[#out + 1] = ("[slop: diff of %s omitted]"):format(pb)
            n = n + 1
          end
        end
        if not skipping then
          out[#out + 1] = l
        end
      else
        local sign, body = l:match("^([+%- ])(.*)$")
        if sign then
          local red, k = M.redact_lines(path, { body }, 0)
          out[#out + 1] = sign .. red[1]
          n = n + k
        else
          out[#out + 1] = l
        end
      end
    end
  end
  return table.concat(out, "\n"), n
end

--- Is any part of `range` in `buf` secret? range = { srow, scol, erow, ecol } (0-based, ecol exclusive);
--- nil = whole buffer. Blocked buffers are always cloaked.
---@param buf integer
---@param range? slop.Range
---@return boolean
function M.is_cloaked(buf, range)
  ensure()
  buf = buf == 0 and vim.api.nvim_get_current_buf() or buf
  local path = M.effective_path(buf)
  if M.is_blocked(path) then
    return true
  end
  local srow, scol, erow, ecol = 0, 0, vim.api.nvim_buf_line_count(buf) - 1, math.huge
  if range then
    srow, scol, erow, ecol = range[1], range[2], range[3], range[4]
  end
  local lines = vim.api.nvim_buf_get_lines(buf, srow, erow + 1, false)
  local by_row = collect(path, lines, srow)
  for i, spans in pairs(by_row) do
    local row = srow + i - 1
    for _, s in ipairs(spans) do
      local lo = row == srow and scol or 0
      local hi = row == erow and ecol or math.huge
      if s[2] > lo and s[1] < hi then
        return true
      end
    end
  end
  return false
end

return M

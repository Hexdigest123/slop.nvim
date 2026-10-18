--- Context gathering for AI requests. OWNER: complete. Everything returned is already redacted via core.secrets.
---
--- FIM context layout (format ported from microsoft/vscode-copilot-chat completions-core, MIT, (c) Microsoft
--- Corporation: comment-prefixed context blocks in front of the prefix, budget split 35/15/35/15):
---
---   <comment> Path: src/app.lua                              -- header        \
---   <comment> Enclosing scope (signatures above the prefix)  -- scope          | stable (35%)
---   <comment> Consider the following lua diagnostics ...     -- diagnostics    |
---   <comment> Compare this snippet from other.lua: ...       -- neighbours    /  (best snippet last)
---   <comment> These are recently edited files. ...           -- recent edits  \  volatile (15%)
---   <comment> Compare this snippet from yanked.lua: ...      -- ring          /
---   ...prefix (cut on line boundaries from the top)           -- prefix (35% + every unused share)
---   suffix (rest of the line + following lines)               -- suffix (15% + unused prefix share)
---@class slop.ai.context
local M = {}

local api = vim.api

M.DEFAULT_BUDGET = 16000
M.shares = { prefix = 0.35, suffix = 0.15, stable = 0.35, volatile = 0.15 }
M.window = { before = 3000, after = 1000 } -- max raw lines read around the cursor

---@class slop.ai.Context
---@field prompt string                   assembled prefix side (header + context blocks + prefix)
---@field suffix string
---@field parts table<string, string>     header, scope, diagnostics, neighbors, edits, ring, prefix
---@field blocked? boolean                true when the buffer is blocked (caller must not send)
---@field meta table                      { budget, prefix_row (first row in the prompt), suffix_row (last row),
---                                         prefix_complete, suffix_complete, filetype, indent }

---@class slop.ai.ContextOpts
---@field header? boolean                 default true
---@field scope? boolean
---@field neighbors? boolean
---@field recent_edits? boolean
---@field ring? boolean
---@field diagnostics? boolean
---@field budget? integer|"auto"          characters (auto = 16000)

-- Pure helpers ----------------------------------------------------------------------------------

--- Keep whole lines from the END of `lines` within `max` chars (newlines count). The last line is always kept
--- (truncated from the left if it alone is too long).
---@param lines string[]
---@param max integer
---@return string[] kept, boolean complete
function M.take_tail(lines, max)
  local n = #lines
  if n == 0 then
    return {}, true
  end
  local total = #lines[n]
  if total > max then
    return { lines[n]:sub(-max) }, n == 1 and #lines[n] <= max
  end
  local first = n
  for i = n - 1, 1, -1 do
    local l = #lines[i] + 1
    if total + l > max then
      break
    end
    total = total + l
    first = i
  end
  return vim.list_slice(lines, first, n), first == 1
end

--- Keep whole lines from the START of `lines` within `max` chars. The first line is always kept (truncated).
---@param lines string[]
---@param max integer
---@return string[] kept, boolean complete
function M.take_head(lines, max)
  local n = #lines
  if n == 0 then
    return {}, true
  end
  local total = #lines[1]
  if total > max then
    return { lines[1]:sub(1, max) }, false
  end
  local last = 1
  for i = 2, n do
    local l = #lines[i] + 1
    if total + l > max then
      break
    end
    total = total + l
    last = i
  end
  return vim.list_slice(lines, 1, last), last == n
end

--- Prefix every line with the buffer's comment leader (commentstring; "# %s" fallback).
---@param lines string[]
---@param cs? string
---@return string[]
function M.comment(lines, cs)
  if type(cs) ~= "string" or not cs:find("%s", 1, true) then
    cs = "# %s"
  end
  local out = {}
  for i, l in ipairs(lines) do
    local c = cs:gsub("%%s", function()
      return l
    end)
    out[i] = (c:gsub("%s+$", ""))
  end
  return out
end

--- Split `total` into the four shares.
---@param total integer
---@return {prefix: integer, suffix: integer, stable: integer, volatile: integer}
function M.split_budget(total)
  local s = M.shares
  return {
    prefix = math.floor(total * s.prefix),
    suffix = math.floor(total * s.suffix),
    stable = math.floor(total * s.stable),
    volatile = math.floor(total * s.volatile),
  }
end

--- Pack text blocks (priority order) into `max` chars; returns the kept blocks in priority order.
---@param blocks string[]
---@param max integer
---@return string[] kept, integer used
function M.pack(blocks, max)
  local out, used = {}, 0
  for _, b in ipairs(blocks) do
    if b ~= "" and used + #b + 1 <= max then
      out[#out + 1] = b
      used = used + #b + 1
    end
  end
  return out, used
end

--- Apply redaction spans (core.secrets.spans format) to a list of lines.
---@param lines string[]
---@param spans slop.secrets.Span[]
---@param first_row integer
---@param placeholder string
---@return string[]
function M.apply_spans(lines, spans, first_row, placeholder)
  if #spans == 0 then
    return lines
  end
  local by_row = {}
  for _, s in ipairs(spans) do
    local r = s.row - first_row + 1
    by_row[r] = by_row[r] or {}
    table.insert(by_row[r], s)
  end
  local out = vim.list_slice(lines)
  for r, list in pairs(by_row) do
    local l = out[r]
    if l then
      table.sort(list, function(a, b)
        return a.col > b.col
      end)
      for _, s in ipairs(list) do
        l = l:sub(1, s.col) .. placeholder .. l:sub(s.end_col + 1)
      end
      out[r] = l
    end
  end
  return out
end

-- Path helpers ----------------------------------------------------------------------------------

local function relpath(path, buf)
  if path == "" then
    return path
  end
  local ok, root = pcall(function()
    return require("slop.core.project").root(buf)
  end)
  if ok and root then
    local okr, rel = pcall(require("slop.core.project").relpath, path, root)
    if okr and rel then
      return rel
    end
  end
  return vim.fn.fnamemodify(path, ":~:.")
end

--- "Indentation: 2 spaces" | "Indentation: tabs" hint for prompts.
---@param buf integer
---@return string
function M.indent_hint(buf)
  if not vim.bo[buf].expandtab then
    return "Indentation: tabs"
  end
  local sw = vim.bo[buf].shiftwidth
  if sw == 0 then
    sw = vim.bo[buf].tabstop
  end
  return ("Indentation: %d spaces"):format(sw)
end

-- Context blocks --------------------------------------------------------------------------------

local function header_block(rel, ft)
  if rel ~= "" then
    return { "Path: " .. rel }
  end
  if ft ~= "" then
    return { "Language: " .. ft }
  end
  return {}
end

local function scope_block(buf, row, col, cut_row)
  local ok, scopes = pcall(function()
    return require("slop.core.ts").scopes(buf, { row, col })
  end)
  if not ok or type(scopes) ~= "table" then
    return {}
  end
  local lines = {}
  for _, s in ipairs(scopes) do
    if s.range[1] < cut_row then
      vim.list_extend(lines, s.header)
    end
  end
  if #lines == 0 then
    return {}
  end
  lines = require("slop.core.secrets").redact_lines(buf, lines)
  table.insert(lines, 1, "Enclosing scope of the code below:")
  return lines
end

local function diagnostics_block(buf, row, rel, ft)
  local ok, diags = pcall(vim.diagnostic.get, buf, { severity = { min = vim.diagnostic.severity.WARN } })
  if not ok or #diags == 0 then
    return {}
  end
  table.sort(diags, function(a, b)
    return math.abs(a.lnum - row) < math.abs(b.lnum - row)
  end)
  local secrets = require("slop.core.secrets")
  local lines = { ("Consider the following %s diagnostics from %s:"):format(ft ~= "" and ft or "", rel) }
  for i = 1, math.min(5, #diags) do
    local d = diags[i]
    if math.abs(d.lnum - row) <= 30 then
      local msg = (d.message or ""):gsub("\n.*", "")
      lines[#lines + 1] = ("%d:%d - %s"):format(d.lnum + 1, d.col + 1, (secrets.redact_text(msg, buf)))
    end
  end
  return #lines > 1 and lines or {}
end

local function snippet_block(rel, lines)
  local out = { "Compare this snippet from " .. rel .. ":" }
  vim.list_extend(out, lines)
  return out
end

local function edits_blocks(buf)
  local ev = require("slop.services.ai.context.edits").events()
  local secrets = require("slop.core.secrets")
  local out = {}
  for i = #ev, 1, -1 do -- most recent first (priority)
    local e = ev[i]
    if api.nvim_buf_is_valid(e.buf) and not secrets.is_blocked(e.path) then
      local diff = secrets.redact_text(e.diff, e.path)
      local lines = { "File: " .. relpath(e.path, buf) }
      vim.list_extend(lines, vim.split(diff:gsub("\n$", ""), "\n", { plain = true }))
      out[#out + 1] = lines
    end
  end
  return out
end

local function ring_blocks(buf, win_first, win_last)
  local ring = require("slop.services.ai.context.edits").ring()
  local secrets = require("slop.core.secrets")
  local out = {}
  for i = #ring, 1, -1 do
    local c = ring[i]
    local overlaps = c.buf == buf and c.srow <= win_last and (c.srow + #c.lines) >= win_first
    if not overlaps and api.nvim_buf_is_valid(c.buf) and not secrets.is_blocked(c.path) then
      local lines = secrets.redact_lines(c.path, c.lines, c.srow)
      out[#out + 1] = snippet_block(relpath(c.path, buf), lines)
    end
  end
  return out
end

-- FIM --------------------------------------------------------------------------------------------

---@param budget? integer|"auto"
---@return integer
function M.resolve_budget(budget)
  if type(budget) == "number" and budget > 0 then
    return math.floor(budget)
  end
  return M.DEFAULT_BUDGET
end

--- Build FIM context for `buf` at (row, col) (0-based).
---@param buf integer
---@param row integer
---@param col integer
---@param opts? slop.ai.ContextOpts
---@return slop.ai.Context
function M.fim(buf, row, col, opts)
  opts = opts or {}
  buf = buf == 0 and api.nvim_get_current_buf() or buf
  local secrets = require("slop.core.secrets")
  local ft = vim.bo[buf].filetype
  local meta = { filetype = ft, indent = M.indent_hint(buf) }
  if secrets.is_blocked(buf) then
    return { prompt = "", suffix = "", parts = {}, blocked = true, meta = meta }
  end
  local B = M.resolve_budget(opts.budget)
  local share = M.split_budget(B)
  meta.budget = B

  -- raw window around the cursor, redacted with spans computed over the whole window
  local nlines = api.nvim_buf_line_count(buf)
  local first = math.max(0, row - M.window.before)
  local last = math.min(nlines - 1, row + M.window.after)
  local raw = api.nvim_buf_get_lines(buf, first, last + 1, false)
  local spans = secrets.spans(buf, raw, first)
  local cur = raw[row - first + 1] or ""
  col = math.min(col, #cur)
  local before_spans, after_spans = {}, {}
  local ph = secrets.placeholder()
  local other = {}
  for _, s in ipairs(spans) do
    if s.row == row then
      if s.end_col <= col then
        before_spans[#before_spans + 1] = s
      elseif s.col >= col then
        after_spans[#after_spans + 1] = { row = s.row, col = s.col - col, end_col = s.end_col - col }
      else -- crosses the cursor: redact the part before it
        before_spans[#before_spans + 1] = { row = s.row, col = s.col, end_col = col }
        after_spans[#after_spans + 1] = { row = s.row, col = 0, end_col = s.end_col - col }
      end
    else
      other[#other + 1] = s
    end
  end
  local red = M.apply_spans(raw, other, first, ph)
  local cur_before = M.apply_spans({ cur:sub(1, col) }, before_spans, row, ph)[1]
  local cur_after = M.apply_spans({ cur:sub(col + 1) }, after_spans, row, ph)[1]
  local prefix_lines = vim.list_slice(red, 1, row - first)
  prefix_lines[#prefix_lines + 1] = cur_before
  local suffix_lines = { cur_after }
  vim.list_extend(suffix_lines, vim.list_slice(red, row - first + 2))

  local name = api.nvim_buf_get_name(buf)
  local rel = relpath(name, buf)
  local cs = vim.bo[buf].commentstring

  -- suffix (15%)
  local suffix_take, suffix_done = M.take_head(suffix_lines, share.suffix)
  local suffix_used = #table.concat(suffix_take, "\n")

  -- stable context (35%): header > scope > diagnostics > neighbours
  local function block(lines)
    if #lines == 0 then
      return ""
    end
    return table.concat(M.comment(lines, cs), "\n")
  end
  local parts = {}
  local min_prefix = B - suffix_used - share.stable - share.volatile
  local est = M.take_tail(prefix_lines, math.max(min_prefix, share.prefix))
  local cut_row = row - #est + 1
  local stable = {}
  if opts.header ~= false then
    parts.header = block(header_block(rel, ft))
    stable[#stable + 1] = parts.header
  end
  if opts.scope ~= false then
    parts.scope = block(scope_block(buf, row, col, cut_row))
    stable[#stable + 1] = parts.scope
  end
  if opts.diagnostics ~= false then
    parts.diagnostics = block(diagnostics_block(buf, row, rel, ft))
    stable[#stable + 1] = parts.diagnostics
  end
  local neighbor_blocks = {}
  if opts.neighbors ~= false then
    local ref = table.concat(vim.list_slice(prefix_lines, math.max(1, #prefix_lines - 59)), "\n")
    local ok, snips = pcall(require("slop.services.ai.context.neighbors").snippets, buf, ref)
    if ok then
      -- priority: best first; output order: best last
      for i = #snips, 1, -1 do
        neighbor_blocks[#neighbor_blocks + 1] = block(snippet_block(relpath(snips[i].path, buf), snips[i].lines))
      end
    end
  end
  local kept_stable, stable_used = M.pack(vim.list_extend(vim.list_slice(stable), neighbor_blocks), share.stable)
  -- restore output order: stable blocks in their order, neighbours ascending (best last)
  local kept_set = {}
  for _, b in ipairs(kept_stable) do
    kept_set[b] = true
  end
  local out_blocks = {}
  for _, b in ipairs(stable) do
    if kept_set[b] then
      out_blocks[#out_blocks + 1] = b
    end
  end
  local kept_neighbors = {}
  for i = #neighbor_blocks, 1, -1 do
    if kept_set[neighbor_blocks[i]] then
      kept_neighbors[#kept_neighbors + 1] = neighbor_blocks[i]
      out_blocks[#out_blocks + 1] = neighbor_blocks[i]
    end
  end
  parts.neighbors = table.concat(kept_neighbors, "\n")

  -- volatile context (15%): recent edits (most recent first) > ring
  local volatile = {}
  local edit_kept = {}
  if opts.recent_edits ~= false then
    local eb = edits_blocks(buf)
    if #eb > 0 then
      local intro = "These are recently edited files. Do not suggest code that has been deleted."
      local outro = "End of recent edits"
      local budget = share.volatile - #intro - #outro - 4 * #(cs or "")
      local blocks = {}
      for _, lines in ipairs(eb) do
        blocks[#blocks + 1] = table.concat(lines, "\n")
      end
      local kept = M.pack(blocks, math.max(0, budget))
      if #kept > 0 then
        local lines = { intro }
        for i = #kept, 1, -1 do -- oldest first in the prompt
          vim.list_extend(lines, vim.split(kept[i], "\n", { plain = true }))
        end
        lines[#lines + 1] = outro
        edit_kept = { block(lines) }
      end
    end
  end
  parts.edits = edit_kept[1] or ""
  local volatile_used = parts.edits ~= "" and (#parts.edits + 1) or 0
  if parts.edits ~= "" then
    volatile[#volatile + 1] = parts.edits
  end
  if opts.ring ~= false then
    local rb = {}
    for _, lines in ipairs(ring_blocks(buf, first, last)) do
      rb[#rb + 1] = block(lines)
    end
    local kept, used = M.pack(rb, share.volatile - volatile_used)
    volatile_used = volatile_used + used
    local ring_out = {}
    for i = #kept, 1, -1 do
      ring_out[#ring_out + 1] = kept[i]
    end
    parts.ring = table.concat(ring_out, "\n")
    vim.list_extend(volatile, ring_out)
  end

  -- prefix: everything that is left
  local prefix_budget = B - suffix_used - stable_used - volatile_used
  local prefix_take, prefix_done = M.take_tail(prefix_lines, math.max(prefix_budget, share.prefix))
  local prefix = table.concat(prefix_take, "\n")
  if prefix_done and not suffix_done then
    local extra = prefix_budget - #prefix
    if extra > 0 then
      suffix_take, suffix_done = M.take_head(suffix_lines, suffix_used + extra)
    end
  end
  parts.prefix = prefix

  local ctx_blocks = vim.list_extend(out_blocks, volatile)
  local context = table.concat(
    vim.tbl_filter(function(b)
      return b ~= ""
    end, ctx_blocks),
    "\n"
  )
  meta.prefix_row = row - #prefix_take + 1
  meta.suffix_row = row + #suffix_take - 1
  meta.prefix_complete = prefix_done and first == 0
  meta.suffix_complete = suffix_done and last == nlines - 1
  return {
    prompt = (context ~= "" and (context .. "\n") or "") .. prefix,
    suffix = table.concat(suffix_take, "\n"),
    parts = parts,
    meta = meta,
  }
end

-- Files / rules (used by edit) -------------------------------------------------------------------

local SKIP_DIRS = {
  [".git"] = true,
  node_modules = true,
  vendor = true,
  target = true,
  dist = true,
  build = true,
  [".venv"] = true,
  venv = true,
  __pycache__ = true,
  [".cache"] = true,
}

local files_cache = {} ---@type table<string, {time: number, files: string[]}>
M.files_ttl = 30000
local files_au = false

local function files_autocmds()
  if files_au then
    return
  end
  files_au = true
  api.nvim_create_autocmd({ "BufNewFile", "BufFilePost", "BufDelete" }, {
    group = api.nvim_create_augroup("slop.ai.context.files", { clear = true }),
    desc = "slop: invalidate project file list",
    callback = function()
      files_cache = {}
    end,
  })
end

local function list_files(root)
  local res
  if vim.fn.executable("git") == 1 then
    local ok, obj = pcall(vim.system, {
      "git",
      "-C",
      root,
      "ls-files",
      "--cached",
      "--others",
      "--exclude-standard",
      "-z",
    }, { text = true })
    if ok then
      res = obj:wait(3000)
    end
  end
  local out = {}
  if res and res.code == 0 then
    for f in (res.stdout or ""):gmatch("[^%z]+") do
      out[#out + 1] = f
    end
    return out
  end
  for name, kind in
    vim.fs.dir(root, {
      depth = 20,
      skip = function(dir)
        return not SKIP_DIRS[vim.fs.basename(dir)]
      end,
    })
  do
    if kind == "file" then
      out[#out + 1] = name
      if #out >= 20000 then
        break
      end
    end
  end
  return out
end

--- Project files relative to `root` (git ls-files --cached --others --exclude-standard, else a directory walk),
--- secrets-filtered, cached per root (30 s; invalidated on file create/delete/rename). The first call per root
--- runs git synchronously (fast); later calls return the cache.
---@param root? string                    default core.project.root()
---@return string[]
function M.files(root)
  root = root or require("slop.core.project").root()
  files_autocmds()
  local c = files_cache[root]
  local now = vim.uv.now()
  if c and now - c.time < M.files_ttl then
    return c.files
  end
  local rel = list_files(root)
  local abs = {}
  for i, f in ipairs(rel) do
    abs[i] = vim.fs.joinpath(root, f)
  end
  local keep = {}
  for _, a in ipairs(require("slop.core.secrets").filter_paths(abs)) do
    keep[a] = true
  end
  local out = {}
  for i, f in ipairs(rel) do
    if keep[abs[i]] then
      out[#out + 1] = f
    end
  end
  table.sort(out)
  files_cache[root] = { time = now, files = out }
  return out
end

--- Invalidate the files cache (all roots or one).
---@param root? string
function M.invalidate_files(root)
  if root then
    files_cache[root] = nil
  else
    files_cache = {}
  end
end

---@class slop.ai.FileContent
---@field path string                     absolute
---@field rel string
---@field text string                     redacted
---@field filetype? string
---@field truncated? boolean

--- Content of a project file for prompts (live buffer first, else disk), redacted; blocked files are refused.
---@param path string                      absolute or relative to root
---@param opts? {root?: string, max_bytes?: integer}
---@return slop.ai.FileContent?, string? err
function M.file(path, opts)
  opts = opts or {}
  local root = opts.root or require("slop.core.project").root()
  local abs = vim.fs.normalize(path)
  if not abs:match("^/") and not abs:match("^%a:[/\\]") then
    abs = vim.fs.joinpath(root, abs)
  end
  abs = vim.fs.normalize(abs)
  local secrets = require("slop.core.secrets")
  if secrets.is_blocked(abs) then
    return nil, "blocked by secrets rules: " .. path
  end
  local max = opts.max_bytes or 100 * 1024
  local text
  local b = vim.fn.bufnr(abs)
  if b > 0 and api.nvim_buf_is_loaded(b) then
    text = table.concat(api.nvim_buf_get_lines(b, 0, -1, false), "\n")
  else
    local st = vim.uv.fs_stat(abs)
    if not st or st.type ~= "file" then
      return nil, "no such file: " .. path
    end
    local f = io.open(abs, "rb")
    if not f then
      return nil, "cannot read: " .. path
    end
    text = f:read(max + 1) or ""
    f:close()
  end
  if text:find("%z") then
    return nil, "binary file: " .. path
  end
  local truncated = #text > max
  if truncated then
    text = text:sub(1, max)
    text = text:gsub("[^\n]*$", "")
  end
  local rel = abs
  pcall(function()
    rel = require("slop.core.project").relpath(abs, root)
  end)
  return {
    path = abs,
    rel = rel,
    text = (secrets.redact_text(text, abs)),
    filetype = vim.filetype.match({ filename = abs }),
    truncated = truncated or nil,
  }
end

--- Rules files (e.g. ".nvim/rules.md", "AGENTS.md", "CLAUDE.md") that exist, redacted.
--- With opts.from (a directory inside root), every directory from root down to `from` is searched
--- (walk-up), root first, so the most specific file comes last.
---@param root? string
---@param names string[]
---@param opts? {from?: string, max_bytes?: integer}
---@return {path: string, rel: string, text: string}[]
function M.rules(root, names, opts)
  opts = opts or {}
  root = vim.fs.normalize(root or require("slop.core.project").root())
  local dirs = { root }
  if opts.from then
    local from = vim.fs.normalize(opts.from)
    if vim.startswith(from, root .. "/") then
      local chain = {}
      local d = from
      while d and d ~= root and #d > #root do
        table.insert(chain, 1, d)
        d = vim.fs.dirname(d)
      end
      vim.list_extend(dirs, chain)
    end
  end
  local out, seen = {}, {}
  for _, dir in ipairs(dirs) do
    for _, name in ipairs(names or {}) do
      local p = vim.fs.normalize(vim.fs.joinpath(dir, name))
      if not seen[p] and vim.uv.fs_stat(p) then
        seen[p] = true
        local fc = M.file(p, { root = root, max_bytes = opts.max_bytes })
        if fc then
          out[#out + 1] = { path = fc.path, rel = fc.rel, text = fc.text }
        end
      end
    end
  end
  return out
end

--- Start recent-edits / ring tracking (idempotent; complete calls this in setup).
function M.track()
  require("slop.services.ai.context.edits").attach()
end

return M

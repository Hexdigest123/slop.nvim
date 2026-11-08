--- Context for edit prompts: @file mentions, rules files, project files (completion), diagnostics.
--- Uses services.ai.context (files/file/rules) when available, else a small local fallback.
--- Everything returned is redacted; blocked files are never returned.
---@class slop.edit.context
local M = {}

local api = vim.api

local MAX_BYTES = 100 * 1024

local function ai_context()
  local ok, ctx = pcall(require, "slop.services.ai.context")
  return ok and type(ctx) == "table" and ctx or {}
end

local function project_root(buf)
  return require("slop.core.project").root(buf)
end

---@class slop.edit.FileText
---@field path string
---@field rel string
---@field text string
---@field filetype? string

--- The file a path resolves to through symlinks, when that is another name: secret globs and cloak rules match names,
--- so a link with an innocent name must be judged (and redacted) by its target too.
---@param abs string
---@return string?
local function link_target(abs)
  local real = vim.uv.fs_realpath(abs)
  return real and real ~= abs and real or nil
end

--- Content of a file for the prompt (live buffer first), redacted. nil + reason when blocked/missing.
---@param path string                      absolute or relative to root
---@param root string
---@return slop.edit.FileText?, string?
function M.file(path, root)
  local secrets = require("slop.core.secrets")
  local abs = vim.fs.normalize(path)
  if abs:sub(1, 1) ~= "/" and not abs:match("^%a:[/\\]") then
    abs = vim.fs.normalize(vim.fs.joinpath(root, abs))
  end
  local real = link_target(abs)
  if secrets.is_blocked(abs) or (real and secrets.is_blocked(real)) then
    return nil, "blocked by secrets rules: " .. path
  end
  local ctx = ai_context()
  if type(ctx.file) == "function" then
    local ok, fc, err = pcall(ctx.file, path, { root = root, max_bytes = MAX_BYTES })
    if ok then
      if fc and real then
        fc.text = (secrets.redact_text(fc.text, real))
      end
      return fc, err
    end
  end
  local text
  for _, b in ipairs(api.nvim_list_bufs()) do
    if api.nvim_buf_is_loaded(b) and vim.fs.normalize(api.nvim_buf_get_name(b)) == abs then
      text = table.concat(api.nvim_buf_get_lines(b, 0, -1, false), "\n")
      break
    end
  end
  if not text then
    local f = io.open(abs, "rb")
    if not f then
      return nil, "no such file: " .. path
    end
    text = f:read(MAX_BYTES) or ""
    f:close()
  end
  if text:find("%z") then
    return nil, "binary file: " .. path
  end
  local rel = abs
  if vim.startswith(abs, root .. "/") then
    rel = abs:sub(#root + 2)
  end
  text = secrets.redact_text(text, abs)
  if real then
    text = secrets.redact_text(text, real)
  end
  return {
    path = abs,
    rel = rel,
    text = text,
    filetype = vim.filetype.match({ filename = abs }),
  }
end

--- Rules files that exist under root, in order.
---@param root string
---@param names string[]
---@return slop.edit.FileText[]
function M.rules(root, names)
  local ctx = ai_context()
  if type(ctx.rules) == "function" then
    local ok, list = pcall(ctx.rules, root, names)
    if ok and type(list) == "table" then
      local secrets = require("slop.core.secrets")
      local out = {}
      for _, fc in ipairs(list) do
        local real = type(fc.path) == "string" and link_target(fc.path) or nil
        if not (real and secrets.is_blocked(real)) then
          if real then
            fc.text = (secrets.redact_text(fc.text, real))
          end
          out[#out + 1] = fc
        end
      end
      return out
    end
  end
  local out = {}
  for _, name in ipairs(names or {}) do
    local p = vim.fs.normalize(vim.fs.joinpath(root, name))
    if vim.uv.fs_stat(p) then
      local fc = M.file(p, root)
      if fc then
        out[#out + 1] = fc
      end
    end
  end
  return out
end

local file_cache = {} ---@type table<string, {time: integer, files: string[]}>

--- Project files relative to root (for @ completion).
---@param root string
---@return string[]
function M.files(root)
  local ctx = ai_context()
  if type(ctx.files) == "function" then
    local ok, list = pcall(ctx.files, root)
    if ok and type(list) == "table" then
      return list
    end
  end
  local c = file_cache[root]
  if c and vim.uv.now() - c.time < 30000 then
    return c.files
  end
  local out = {}
  local skip = { [".git"] = true, node_modules = true, vendor = true, target = true, dist = true, build = true }
  for name, kind in
    vim.fs.dir(root, {
      depth = 8,
      skip = function(dir)
        return not skip[vim.fs.basename(dir)]
      end,
    })
  do
    if kind == "file" then
      out[#out + 1] = name
      if #out >= 5000 then
        break
      end
    end
  end
  local secrets = require("slop.core.secrets")
  out = vim.tbl_filter(function(rel)
    return not secrets.is_blocked(vim.fs.joinpath(root, rel))
  end, out)
  table.sort(out)
  file_cache[root] = { time = vim.uv.now(), files = out }
  return out
end

--- "@path" mentions in an instruction (unique, in order). A trailing punctuation char is dropped.
---@param text string
---@return string[]
function M.mentions(text)
  local out, seen = {}, {}
  for path in (" " .. text):gmatch("%s@([^%s]+)") do
    path = path:gsub("[,;:%.%)%]]+$", "")
    if path ~= "" and not seen[path] then
      seen[path] = true
      out[#out + 1] = path
    end
  end
  return out
end

--- Diagnostics overlapping rows [srow, erow] as text lines ("line N: [ERROR] msg (source)"), redacted.
---@param buf integer
---@param srow integer
---@param erow integer
---@return string[]
function M.diagnostics(buf, srow, erow)
  local out = {}
  local names = { "ERROR", "WARN", "INFO", "HINT" }
  local diags = vim.diagnostic.get(buf)
  table.sort(diags, function(a, b)
    return a.lnum < b.lnum
  end)
  for _, d in ipairs(diags) do
    local last = d.end_lnum or d.lnum
    if last >= srow and d.lnum <= erow then
      out[#out + 1] = ("line %d: [%s] %s%s"):format(
        d.lnum + 1,
        names[d.severity] or "?",
        (d.message or ""):gsub("\n", " "),
        d.source and (" (" .. d.source .. ")") or ""
      )
    end
  end
  return require("slop.core.secrets").redact_lines(buf, out, 0)
end

--- Completion items for the prompt float: "#preset" and "@file".
---@param lead string
---@param presets table<string, slop.edit.Preset>
---@param root string
---@return table[]
function M.complete(lead, presets, root)
  local items = {}
  if lead:sub(1, 1) == "#" then
    local names = vim.tbl_keys(presets)
    table.sort(names)
    for _, n in ipairs(names) do
      if vim.startswith("#" .. n, lead) then
        items[#items + 1] = { word = "#" .. n, menu = presets[n].desc }
      end
    end
  elseif lead:sub(1, 1) == "@" then
    local q = lead:sub(2)
    local files = M.files(root)
    local matched
    if q == "" then
      matched = vim.list_slice(files, 1, 50)
    else
      matched = vim.list_slice(vim.fn.matchfuzzy(files, q), 1, 50)
    end
    for _, f in ipairs(matched) do
      items[#items + 1] = { word = "@" .. f, menu = "file" }
    end
  end
  return items
end

M.root = project_root

return M

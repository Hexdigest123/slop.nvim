--- doc: doc-comment styles, prompt building and answer parsing (pure apart from reading buffers).
---@class slop.doc.prompt
local M = {}

local api = vim.api

--- Built-in styles (name -> instructions). `styles[<ft>]` in the config is one of these names or free text.
---@type table<string, string>
M.STYLES = {
  luals = "LuaLS / EmmyLua annotations: `---` lines. A short summary line, then `---@param name type description` "
    .. "for every parameter (`name?` when optional) and `---@return type name? description` for return values. "
    .. "For a class/table use `---@class Name` and `---@field name type description`.",
  jsdoc = "JSDoc block `/** ... */` with ` * ` continuation lines: a summary, then `@param {Type} name description`, "
    .. "`@returns {Type} description` and `@throws` where relevant. In TypeScript omit the {Type} parts that the "
    .. "signature already states.",
  docstring = 'A Python docstring with triple double quotes ("""), PEP 257: a one-line summary, a blank line, then '
    .. "details; document Args, Returns and Raises (Google style) when there are any. Output ONLY the docstring: it "
    .. "is inserted as the first statement of the body.",
  godoc = "Go doc comment: `//` lines that start with the name of the item (`// Name does ...`), full sentences, "
    .. "no @tags.",
  rustdoc = "Rust doc comment: `///` lines in Markdown: a summary line, then details; `# Arguments`, `# Returns`, "
    .. "`# Errors`, `# Panics` and `# Examples` sections only where relevant.",
  javadoc = "Javadoc block `/** ... */` with ` * ` continuation lines: a summary sentence, then `@param name "
    .. "description`, `@return description` and `@throws Type description` where relevant.",
  kdoc = "KDoc block `/** ... */` with ` * ` continuation lines: a summary, then `@param name description`, "
    .. "`@return description` and `@throws Type description` where relevant; Markdown allowed.",
  doxygen = "Doxygen block `/** ... */` with ` * ` continuation lines: `@brief` summary, then `@param name "
    .. "description` (`@param[out]` for output pointers) and `@return description` where relevant.",
  phpdoc = "PHPDoc block `/** ... */` with ` * ` continuation lines: a summary, then `@param type $name description`, "
    .. "`@return type description` and `@throws Type description` where relevant.",
  shell = "A `#` comment block above the function: a summary, then `# Arguments:` (`#   $1 - description`), "
    .. "`# Outputs:` and `# Returns:` sections where relevant (Google shell style).",
  yard = "YARD: `#` comment lines: a summary, then `@param name [Type] description`, `@return [Type] description` "
    .. "and `@raise [Error] description` where relevant.",
}

--- Default style per filetype.
---@type table<string, string>
M.FILETYPES = {
  lua = "luals",
  javascript = "jsdoc",
  javascriptreact = "jsdoc",
  typescript = "jsdoc",
  typescriptreact = "jsdoc",
  vue = "jsdoc",
  svelte = "jsdoc",
  python = "docstring",
  go = "godoc",
  rust = "rustdoc",
  java = "javadoc",
  kotlin = "kdoc",
  c = "doxygen",
  cpp = "doxygen",
  objc = "doxygen",
  php = "phpdoc",
  sh = "shell",
  bash = "shell",
  zsh = "shell",
  ruby = "yard",
}

local KIND_LABEL = { func = "function", class = "class", type = "type" }

--- Style instructions for a filetype: cfg.styles[ft] (style name or free text) > built-in > commentstring.
---@param ft string
---@param styles? table<string, string>
---@param commentstring? string
---@return string
function M.style(ft, styles, commentstring)
  local s = (styles or {})[ft] or M.FILETYPES[ft]
  if s and M.STYLES[s] then
    return M.STYLES[s]
  end
  if s and s ~= "" then
    return s
  end
  local syn = require("slop.modules.doc.langs").syntax_for(ft, commentstring)
  if syn and syn.line[1] then
    return ("The language's line comments: lines starting with `%s `; a summary, then parameters and return value."):format(
      syn.line[1]
    )
  end
  if syn and syn.block then
    return ("A block comment `%s ... %s`; a summary, then parameters and return value."):format(
      syn.block[1],
      syn.block[2]
    )
  end
  return "The idiomatic documentation comment of this language."
end

--- System prompt.
---@param target slop.doc.Target
---@param style string
---@param instructions? string
---@return string
function M.system(target, style, instructions)
  local parts = {
    "You write documentation comments for source code.",
    "Output ONLY the doc comment"
      .. (target.docstring and " (the docstring)" or "")
      .. ": no code, no signature, no explanations. A single fenced block is fine; nothing outside it.",
    "Style: " .. style,
    "Rules:",
    "- Describe what the item does, its parameters, return values, errors and side effects where relevant.",
    "- Be concise and accurate; never invent behaviour the code does not show.",
    "- If an existing doc comment is given, return its complete updated replacement: keep what is still correct "
      .. "(and its wording), fix what is outdated, add what is missing.",
    "- `<redacted>` marks a hidden secret; never guess it.",
  }
  if instructions and vim.trim(instructions) ~= "" then
    parts[#parts + 1] = "Extra instructions: " .. vim.trim(instructions)
  end
  return table.concat(parts, "\n")
end

---@param lines string[]
---@param max integer
---@return string[] lines, boolean cut
local function budget(lines, max)
  local out, n = {}, 0
  for _, l in ipairs(lines) do
    n = n + #l + 1
    if n > max then
      return out, true
    end
    out[#out + 1] = l
  end
  return out, false
end

---@param lines string[]
---@param max integer
---@return string[]
local function budget_tail(lines, max)
  local out, n = {}, 0
  for i = #lines, 1, -1 do
    n = n + #lines[i] + 1
    if n > max then
      break
    end
    table.insert(out, 1, lines[i])
  end
  return out
end

---@class slop.doc.MessageOpts
---@field context_lines integer   lines of surrounding code (before + after) and of file head
---@field max_chars integer       budget for the item's code

--- User message: path, filetype, target, budgeted context, the item's code and its existing doc (all redacted).
---@param target slop.doc.Target
---@param opts slop.doc.MessageOpts
---@return string
function M.message(target, opts)
  local secrets = require("slop.core.secrets")
  local buf = target.buf
  local ft = vim.bo[buf].filetype
  local fence = ft ~= "" and ft or "text"
  local path = api.nvim_buf_get_name(buf)
  local root = require("slop.core.project").root(buf)
  local rel = path ~= "" and require("slop.core.project").relpath(path, root) or "[No Name]"
  local function get(s, e)
    return (secrets.redact_lines(buf, api.nvim_buf_get_lines(buf, s, e, false), s))
  end
  local function block(lines)
    return "```" .. fence .. "\n" .. table.concat(lines, "\n") .. "\n```"
  end
  local s, e = target.rows[1], target.rows[2]
  local lc = api.nvim_buf_line_count(buf)
  local parts = {
    ("File: %s (filetype %s)"):format(rel, ft ~= "" and ft or "none"),
    ("Document the %s%s (lines %d-%d)."):format(
      KIND_LABEL[target.kind] or target.kind,
      target.name and (" `" .. target.name .. "`") or "",
      s + 1,
      e + 1
    ),
  }
  local n = opts.context_lines
  local doc_s = math.min(target.range[1], s)
  if n > 0 then
    local ctx_chars = n * 120
    local head_e = math.min(math.floor(n / 2), doc_s)
    local before_s = math.max(head_e, doc_s - n)
    local ctx = {}
    if head_e > 0 then
      vim.list_extend(ctx, get(0, head_e))
      if before_s > head_e then
        ctx[#ctx + 1] = "…"
      end
    end
    vim.list_extend(ctx, budget_tail(get(before_s, doc_s), ctx_chars))
    local after = budget(get(e + 1, math.min(lc, e + 1 + math.floor(n / 2))), ctx_chars)
    if #ctx > 0 or #after > 0 then
      local body = vim.deepcopy(ctx)
      body[#body + 1] = "<<< the item to document is here >>>"
      vim.list_extend(body, after)
      parts[#parts + 1] = "Surrounding code (context only):\n" .. block(body)
    end
  end
  local code, cut = budget(get(s, e + 1), opts.max_chars)
  if cut then
    code[#code + 1] = "… (truncated)"
  end
  parts[#parts + 1] = "Code to document:\n" .. block(code)
  if #target.doc > 0 then
    parts[#parts + 1] = "Existing doc comment (update it):\n"
      .. block((secrets.redact_lines(buf, target.doc, target.range[1])))
  end
  return table.concat(parts, "\n\n")
end

-- Answer --------------------------------------------------------------------------------------------

local function trim_blank(lines)
  while #lines > 0 and not lines[#lines]:match("%S") do
    lines[#lines] = nil
  end
  while #lines > 0 and not lines[1]:match("%S") do
    table.remove(lines, 1)
  end
  return lines
end

--- Strip <think> blocks and take the first code fence (else the whole text).
---@param text string
---@return string[]
function M.unfence(text)
  text = (text or ""):gsub("\r", ""):gsub("<think>.-</think>", "")
  local lines = vim.split(text, "\n", { plain = true })
  for i, l in ipairs(lines) do
    -- fences only at the start of a line (doc comments may contain indented/prefixed ``` examples)
    if l:match("^%s*```") then
      local close = #lines + 1
      for j = i + 1, #lines do
        if lines[j]:match("^%s*```%s*$") then
          close = j
          break
        end
      end
      return trim_blank(vim.list_slice(lines, i + 1, close - 1))
    end
  end
  return trim_blank(lines)
end

local function starts(s, prefix)
  return prefix ~= "" and s:sub(1, #prefix) == prefix
end

--- Number of leading lines that form comments (line comments / block comments), 0 when none.
---@param lines string[]
---@param syntax slop.doc.Syntax
---@return integer n
local function comment_prefix(lines, syntax)
  local i, n = 1, 0
  while i <= #lines do
    local t = vim.trim(lines[i])
    if t == "" then
      break
    end
    local open, close = syntax.block and syntax.block[1], syntax.block and syntax.block[2]
    if open and starts(t, open) then
      local rest = t:sub(#open + 1)
      local j = i
      while true do
        local cpos = rest:find(close, 1, true)
        if cpos then
          if vim.trim(rest:sub(cpos + #close)) ~= "" then
            return n
          end
          break
        end
        j = j + 1
        if j > #lines then
          return n -- unterminated block
        end
        rest = lines[j]
      end
      i = j + 1
      n = i - 1
    else
      local is_line = false
      for _, leader in ipairs(syntax.line) do
        if starts(t, leader) then
          is_line = true
          break
        end
      end
      if not is_line then
        break
      end
      i = i + 1
      n = i - 1
    end
  end
  return n
end

local DELIMS = { '"""', "'''" }

--- Number of leading lines forming one Python docstring, 0 when none.
---@param lines string[]
---@return integer
local function docstring_prefix(lines)
  local t = vim.trim(lines[1] or "")
  local prefix = t:match("^[rRuUbBfF]*") or ""
  local body = t:sub(#prefix + 1)
  for _, d in ipairs(DELIMS) do
    if starts(body, d) then
      local rest = body:sub(#d + 1)
      local i = 1
      while true do
        local cpos = rest:find(d, 1, true)
        if cpos then
          if vim.trim(rest:sub(cpos + #d)) ~= "" then
            return 0
          end
          return i
        end
        i = i + 1
        if i > #lines then
          return 0
        end
        rest = lines[i]
      end
    end
  end
  return 0
end

--- Does `l` echo the item's code (its trimmed text equals a non-trivial line of the item)?
---@param l string
---@param code table<string, true>
---@return boolean
local function echoed(l, code)
  local t = vim.trim(l)
  return #t > 2 and code[t] == true
end

---@param lines string[]
---@return integer
local function min_indent(lines)
  local m
  for _, l in ipairs(lines) do
    if l:match("%S") then
      local w = #(l:match("^%s*"))
      m = m and math.min(m, w) or w
    end
  end
  return m or 0
end

--- Re-indent `lines` (common indentation removed) to `indent`. Python docstrings whose continuation lines are
--- indented deeper than the opening line (pasted from inside a body) are aligned on their own base.
---@param lines string[]
---@param indent string
---@param docstring? boolean
---@return string[]
function M.reindent(lines, indent, docstring)
  local base_first = min_indent(lines)
  local base_rest = base_first
  if docstring and #lines > 1 then
    local first = #(lines[1]:match("^%s*"))
    local rest = min_indent(vim.list_slice(lines, 2))
    local last = vim.trim(lines[#lines])
    if rest > first and (last == '"""' or last == "'''") then
      base_first, base_rest = first, rest
    end
  end
  local out = {}
  for i, l in ipairs(lines) do
    if l:match("%S") then
      local base = i == 1 and base_first or base_rest
      out[i] = indent .. l:sub(base + 1)
    else
      out[i] = ""
    end
  end
  return out
end

--- Parse a model answer into doc lines for `target`. Code fences, <think> blocks and echoed code are dropped; the
--- rest must be comment lines (python: one docstring), else an error is returned.
---@param text string
---@param target slop.doc.Target
---@param code string[]  the item's lines (to recognize echoes)
---@param syntax? slop.doc.Syntax
---@return string[]? lines, string? err
function M.parse(text, target, code, syntax)
  local lines = M.unfence(text)
  if #lines == 0 then
    return nil, "the AI answer is empty"
  end
  local known = {}
  for _, l in ipairs(code) do
    known[vim.trim(l)] = true
  end
  if target.docstring then
    -- an echoed `def ...:` header (and decorators) before the docstring
    while #lines > 0 and echoed(lines[1], known) do
      table.remove(lines, 1)
    end
    lines = trim_blank(lines)
    local n = docstring_prefix(lines)
    if n == 0 then
      return nil, "the AI answer is not a docstring"
    end
    local rest = trim_blank(vim.list_slice(lines, n + 1))
    if #rest > 0 and not echoed(rest[1], known) then
      return nil, "the AI answer contains code after the docstring"
    end
    return M.reindent(vim.list_slice(lines, 1, n), target.indent, true)
  end
  if not syntax then
    return nil, ("no comment syntax known for filetype '%s' (set 'commentstring')"):format(vim.bo[target.buf].filetype)
  end
  local n = comment_prefix(lines, syntax)
  if n == 0 then
    return nil, "the AI answer is not a comment"
  end
  local rest = trim_blank(vim.list_slice(lines, n + 1))
  if #rest > 0 and not echoed(rest[1], known) then
    return nil, "the AI answer contains code after the comment"
  end
  return M.reindent(vim.list_slice(lines, 1, n), target.indent)
end

return M

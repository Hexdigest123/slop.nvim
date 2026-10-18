--- Treesitter helpers (native vim.treesitter only; every call degrades to nil/false without a parser).
--- OWNER: complete.
---
--- Scope detection is node-type based and language agnostic: a node whose type names a function / method / class
--- like construct (see M.kinds) is a scope; its header is the source text from the node start up to its body.
---@class slop.ts
local M = {}

local api = vim.api

---@class slop.ts.Scope
---@field node TSNode
---@field kind "function"|"method"|"class"|"block"|string
---@field type string                    treesitter node type
---@field name? string
---@field range slop.Range               0-based {srow, scol, erow, ecol}
---@field header string[]                signature line(s) of the scope

--- Node-type classification: first match wins. Patterns are matched against the full node type.
---@type {[1]: string, [2]: string}[]
M.kinds = {
  { "^method", "method" },
  { "_method$", "method" },
  { "^constructor", "method" },
  { "^function", "function" },
  { "_function$", "function" },
  { "^func_literal$", "function" },
  { "^lambda", "function" },
  { "^arrow_function$", "function" },
  { "^closure_expression$", "function" },
  { "^anonymous_function", "function" },
  { "^local_function", "function" },
  { "^def$", "function" },
  { "^class", "class" },
  { "^struct", "class" },
  { "^interface", "class" },
  { "^impl_item$", "class" },
  { "^trait_item$", "class" },
  { "^enum_", "class" },
  { "^object_declaration$", "class" },
  { "^module$", "class" },
  { "^namespace", "class" },
  { "^type_declaration$", "class" },
}

-- node types that look like scopes but aren't (calls, parameters, names, bodies)
local NOT_SCOPE = { "call", "parameter", "argument", "name", "identifier", "body", "type_identifier", "signature" }

--- Body-ish child node types (header stops where the body starts).
local BODY = {
  block = true,
  body = true,
  compound_statement = true,
  statement_block = true,
  declaration_list = true,
  field_declaration_list = true,
  class_body = true,
  interface_body = true,
  enum_body = true,
  function_body = true,
  do_block = true,
  suite = true,
}

---@param buf integer
---@return integer
local function bufnr(buf)
  return (buf == nil or buf == 0) and api.nvim_get_current_buf() or buf
end

---@param t string
---@return string?
function M.classify(t)
  for _, bad in ipairs(NOT_SCOPE) do
    if t:find(bad, 1, true) and not t:match("_definition$") and not t:match("_declaration$") then
      return nil
    end
  end
  for _, k in ipairs(M.kinds) do
    if t:match(k[1]) then
      return k[2]
    end
  end
  return nil
end

--- Parser language of a buffer, if a parser is available.
---@param buf integer
---@return string? lang
function M.lang(buf)
  buf = bufnr(buf)
  if not api.nvim_buf_is_valid(buf) then
    return nil
  end
  local ok, parser = pcall(vim.treesitter.get_parser, buf, nil, { error = false })
  if ok and parser then
    return parser:lang()
  end
  return nil
end

---@param buf integer
---@return boolean
function M.has_parser(buf)
  return M.lang(buf) ~= nil
end

---@param buf integer
---@return vim.treesitter.LanguageTree?
local function parse(buf)
  local ok, parser = pcall(vim.treesitter.get_parser, buf, nil, { error = false })
  if not ok or not parser then
    return nil
  end
  local pok = pcall(parser.parse, parser, true)
  if not pok then
    return nil
  end
  return parser
end

---@param buf integer
---@param pos? {[1]: integer, [2]: integer}
---@return integer row, integer col
local function position(buf, pos)
  if pos then
    return pos[1], pos[2]
  end
  local win = api.nvim_get_current_win()
  if api.nvim_win_get_buf(win) == buf then
    local c = api.nvim_win_get_cursor(win)
    return c[1] - 1, c[2]
  end
  return 0, 0
end

---@param buf integer
---@param row integer
---@param col integer
---@return TSNode?
local function node_at(buf, row, col)
  local parser = parse(buf)
  if not parser then
    return nil
  end
  local ok, node = pcall(vim.treesitter.get_node, { bufnr = buf, pos = { row, col }, ignore_injections = false })
  if not ok then
    return nil
  end
  return node
end

local function node_name(node, buf)
  local ok, names = pcall(node.field, node, "name")
  local n = ok and names and names[1]
  if not n then
    for child in node:iter_children() do
      if child:named() and (child:type() == "identifier" or child:type():match("name$")) then
        n = child
        break
      end
    end
  end
  if n then
    local tok, text = pcall(vim.treesitter.get_node_text, n, buf)
    if tok and text and text ~= "" then
      return (text:gsub("\n.*", ""))
    end
  end
  return nil
end

local MAX_HEADER = 6

local function header(node, buf)
  local srow = node:range()
  local body
  local ok, b = pcall(node.field, node, "body")
  body = ok and b and b[1] or nil
  if not body then
    for child in node:iter_children() do
      if BODY[child:type()] then
        body = child
        break
      end
    end
  end
  local last = srow
  if body then
    local brow = body:range()
    last = math.max(srow, brow == srow and srow or brow - 1)
    -- a body starting on a later line whose first line is just "{" belongs to the header
    if brow > srow then
      local l = api.nvim_buf_get_lines(buf, brow, brow + 1, false)[1] or ""
      if l:match("^%s*[{:]%s*$") then
        last = brow
      end
    end
  end
  last = math.min(last, srow + MAX_HEADER - 1)
  return api.nvim_buf_get_lines(buf, srow, last + 1, false)
end

local function make_scope(node, kind, buf)
  local srow, scol, erow, ecol = node:range()
  return {
    node = node,
    kind = kind,
    type = node:type(),
    name = node_name(node, buf),
    range = { srow, scol, erow, ecol },
    header = header(node, buf),
  }
end

--- All enclosing scopes, outermost first.
---@param buf integer
---@param pos? {[1]: integer, [2]: integer}  0-based {row, col}; default cursor
---@param opts? {kinds?: string[]}
---@return slop.ts.Scope[]
function M.scopes(buf, pos, opts)
  buf = bufnr(buf)
  if not api.nvim_buf_is_valid(buf) then
    return {}
  end
  local row, col = position(buf, pos)
  local node = node_at(buf, row, col)
  local out = {}
  local want = opts and opts.kinds
  while node do
    local kind = M.classify(node:type())
    if kind and (not want or vim.tbl_contains(want, kind)) then
      table.insert(out, 1, make_scope(node, kind, buf))
    end
    node = node:parent()
  end
  return out
end

--- Smallest enclosing function/class-like scope at `pos` (0-based {row, col}; default cursor).
---@param buf integer
---@param pos? {[1]: integer, [2]: integer}
---@param opts? {kinds?: string[]}
---@return slop.ts.Scope?
function M.scope(buf, pos, opts)
  local all = M.scopes(buf, pos, opts)
  return all[#all]
end

-- Empty block detection ----------------------------------------------------------------------------

local OPENERS = {
  "{",
  "%(",
  "%[",
  ":",
  "%f[%w]then",
  "%f[%w]do",
  "%f[%w]else",
  "=>",
  "->",
  "%f[%w]begin",
  "%f[%w]function[%w_%.:%s]*%b()",
}

---@param line string
---@return boolean
function M.opens_block(line)
  line = line:gsub("%s+$", "")
  for _, o in ipairs(OPENERS) do
    if line:match(o .. "$") then
      return true
    end
  end
  return false
end

local function indent_of(line)
  return vim.fn.strdisplaywidth(line:match("^%s*") or "")
end

--- Is `pos` inside an empty block body (multi-line completion hint)?
--- True when the cursor sits on a blank line (or at the end of a line that opens a block) right after a block opener
--- and the next non-blank line is not indented deeper than the opener (i.e. the body is still empty):
---   `def f():⏎  █`, `function f()⏎  █⏎end`, `if (x) {█}`. Language agnostic (indentation based).
---@param buf integer
---@param pos? {[1]: integer, [2]: integer}
---@return boolean
function M.in_empty_block(buf, pos)
  buf = bufnr(buf)
  if not api.nvim_buf_is_valid(buf) then
    return false
  end
  local row, col = position(buf, pos)
  local lines = api.nvim_buf_get_lines(buf, 0, -1, false)
  local cur = lines[row + 1] or ""
  local before, after = cur:sub(1, col), cur:sub(col + 1)
  if after:match("%S") and not after:match("^%s*[%)%]}]+[;,]?%s*$") then
    return false
  end
  local blank = not before:match("%S")
  local opener
  if blank then
    local prow = row - 1
    while prow >= 0 and not lines[prow + 1]:match("%S") do
      prow = prow - 1
    end
    if prow < 0 then
      return false
    end
    opener = lines[prow + 1]
  else
    opener = before
    if after:match("%S") then
      return M.opens_block(before) -- `{█}`
    end
  end
  if not M.opens_block(opener) then
    return false
  end
  local nrow = row + 1
  while nrow < #lines and not lines[nrow + 1]:match("%S") do
    nrow = nrow + 1
  end
  local next_line = lines[nrow + 1]
  return next_line == nil or indent_of(next_line) <= indent_of(opener)
end

return M

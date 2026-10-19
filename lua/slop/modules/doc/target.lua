--- doc: find the documentable node at the cursor and its existing doc comment (treesitter).
---@class slop.doc.target
local M = {}

local api = vim.api

---@class slop.doc.Target
---@field buf integer
---@field kind slop.doc.Kind
---@field type string                       treesitter node type of the documented node
---@field lang string                       parser language
---@field name? string                      name of the item, when the grammar has one
---@field signature string                  first line of the item (trimmed)
---@field rows {[1]: integer, [2]: integer} 0-based rows of the item (attributes/decorators included), end inclusive
---@field range {[1]: integer, [2]: integer} 0-based rows [s, e) the doc replaces; s == e inserts
---@field indent string                     indentation of the doc lines
---@field doc string[]                      existing doc comment / docstring lines (empty: none)
---@field docstring boolean                 python: the doc is a docstring inside the body

local function line(buf, row)
  return api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ""
end

local function indent_of(s)
  return s:match("^%s*") or ""
end

local function is_comment(node)
  return node:type():find("comment", 1, true) ~= nil
end

--- Last row a node covers (an end at column 0 belongs to the previous row).
---@param node TSNode
---@return integer
local function last_row(node)
  local srow, _, erow, ecol = node:range()
  if ecol == 0 and erow > srow then
    return erow - 1
  end
  return erow
end

--- Node text name (field `name`), single line.
---@param node TSNode
---@param buf integer
---@return string?
local function name_of(node, buf)
  local n
  for _, f in ipairs({ "name", "key", "left" }) do
    local ok, names = pcall(node.field, node, f)
    n = n or (ok and names and names[1]) or nil
  end
  if not n and node:type() == "assignment_statement" then
    n = node:named_child(0) -- lua variable_list
  end
  if not n then
    local dok, decl = pcall(node.field, node, "declarator")
    n = dok and decl and decl[1] or nil
    -- C: declarator chain down to the identifier
    while n and n:type() ~= "identifier" and n:type() ~= "field_identifier" and n:type() ~= "type_identifier" do
      local iok, inner = pcall(n.field, n, "declarator")
      n = iok and inner and inner[1] or nil
    end
  end
  if not n then
    return nil
  end
  local tok, text = pcall(vim.treesitter.get_node_text, n, buf)
  if tok and text and text ~= "" then
    return (text:gsub("\n.*", ""))
  end
  return nil
end

--- Probe position: first non-blank column; on a comment directly above an item, the item below it.
---@param buf integer
---@param tree vim.treesitter.LanguageTree
---@param row integer
---@param col integer
---@return integer row, integer col
local function probe(buf, tree, row, col)
  local l = line(buf, row)
  col = math.max(col, #indent_of(l))
  if col >= #l and #l > 0 then
    col = #l - 1
  end
  local ok, node = pcall(tree.named_node_for_range, tree, { row, col, row, col }, { ignore_injections = true })
  if not ok or not node or not is_comment(node) then
    return row, col
  end
  local lang = require("slop.modules.doc.langs").langs[tree:lang()] or {}
  local attrs = lang.attrs or {}
  local cur = node
  local nxt = cur:next_named_sibling()
  while nxt and (is_comment(nxt) or attrs[nxt:type()]) and nxt:range() <= last_row(cur) + 1 do
    cur = nxt
    nxt = cur:next_named_sibling()
  end
  if nxt and nxt:range() == last_row(cur) + 1 then
    local srow, scol = nxt:range()
    return srow, scol
  end
  return row, col
end

--- Climb same-row wrappers (export, declarations) and any-row wrappers (decorators, templates).
---@param node TSNode
---@param lang slop.doc.Lang
---@return TSNode
local function anchor_of(node, lang)
  local anchor = node
  local wrap, any = lang.wrap or {}, lang.wrap_any or {}
  while true do
    local p = anchor:parent()
    if not p then
      break
    end
    local pt = p:type()
    if (wrap[pt] and p:range() == anchor:range()) or any[pt] then
      anchor = p
    else
      break
    end
  end
  return anchor
end

--- Does `node` count as an item of `kind` (nil: any) in `lang`? Returns its kind.
---@param node TSNode
---@param lang slop.doc.Lang?
---@param kind? slop.doc.Kind
---@return slop.doc.Kind?
local function match(node, lang, kind)
  local langs = require("slop.modules.doc.langs")
  local t = node:type()
  local k
  if not lang then
    k = langs.fallback_kind(t)
    if kind and k ~= kind then
      return nil
    end
    return k
  end
  if kind then
    k = vim.tbl_contains(lang[kind], t) and kind or nil
  else
    k = langs.kind_of(lang, t)
  end
  if not k then
    return nil
  end
  local check = lang.check and lang.check[t]
  if check then
    local ok, res = pcall(check, node)
    if not ok or not res then
      return nil
    end
  end
  return k
end

--- Python docstring: the body's leading string statement, or where a new one goes.
---@param node TSNode
---@param buf integer
---@return {[1]: integer, [2]: integer}? range, string indent, string[] doc, string? err
local function docstring(node, buf)
  local ok, b = pcall(node.field, node, "body")
  local body = ok and b and b[1] or nil
  if not body then
    return nil, "", {}, "definition without a body"
  end
  local brow = body:range()
  if brow <= node:range() then
    return nil, "", {}, "one-line definitions are not supported (put the body on its own line)"
  end
  local first
  for child in body:iter_children() do
    if child:named() and not is_comment(child) then
      first = child
      break
    end
  end
  local indent = indent_of(line(buf, brow))
  if first and first:type() == "expression_statement" then
    local s = first:named_child(0)
    if s and s:type() == "string" then
      local srow = first:range()
      local erow = last_row(first)
      return { srow, erow + 1 }, indent, api.nvim_buf_get_lines(buf, srow, erow + 1, false)
    end
  end
  return { brow, brow }, indent, {}
end

--- Comment lines directly above row `s` (contiguous comment siblings of `node`, each on its own line).
---@param node TSNode  the first node of the item (an attribute or the anchor)
---@param buf integer
---@param syntax? slop.doc.Syntax
---@return integer start  == s when there is no doc comment
local function doc_above(node, buf, syntax)
  local s = node:range()
  local skip = syntax and syntax.skip or {}
  local prev = node:prev_named_sibling()
  while prev and is_comment(prev) do
    local srow, scol, erow, ecol = prev:range()
    local attached = erow == s - 1 or (erow == s and ecol == 0 and erow > srow)
    local text = line(buf, srow)
    local own_line = scol == #indent_of(text)
    if not attached or not own_line then
      break
    end
    local trimmed = vim.trim(text)
    for _, pat in ipairs(skip) do
      if trimmed:match(pat) then
        return s
      end
    end
    s = srow
    prev = prev:prev_named_sibling()
  end
  return s
end

---@param node TSNode
---@return integer
local function span(node)
  local srow, _, erow = node:range()
  return erow - srow
end

--- Innermost documentable ancestor of the node at (row, col).
---@param tree vim.treesitter.LanguageTree
---@param row integer
---@param col integer
---@param lang? slop.doc.Lang
---@param kind? slop.doc.Kind
---@return TSNode? node, TSNode? anchor, slop.doc.Kind? kind
local function search(tree, row, col, lang, kind)
  local ok, node = pcall(tree.named_node_for_range, tree, { row, col, row, col }, { ignore_injections = true })
  if not ok then
    return nil
  end
  while node do
    local k = match(node, lang, kind)
    if k then
      local anchor = lang and anchor_of(node, lang) or node
      local anon = lang and lang.anon and lang.anon[node:type()]
      if not anon or (anchor ~= node and lang.decl and lang.decl[anchor:type()]) then
        return node, anchor, k
      end
    end
    node = node:parent()
  end
  return nil
end

--- Find the documentable item at `pos` (0-based {row, col}; default cursor) of `kind` (nil: innermost of any).
---@param buf? integer
---@param pos? {[1]: integer, [2]: integer}
---@param kind? slop.doc.Kind
---@return slop.doc.Target? target, string? err
function M.find(buf, pos, kind)
  buf = (buf == nil or buf == 0) and api.nvim_get_current_buf() or buf
  local ok, tree = pcall(vim.treesitter.get_parser, buf, nil, { error = false })
  if not ok or not tree then
    return nil, ("no treesitter parser for filetype '%s'"):format(vim.bo[buf].filetype)
  end
  if not pcall(tree.parse, tree) then
    return nil, "treesitter parse failed"
  end
  local langs = require("slop.modules.doc.langs")
  local lname = tree:lang()
  local lang = langs.langs[lname]
  local row, col
  if pos then
    row, col = pos[1], pos[2]
  elseif api.nvim_win_get_buf(0) == buf then
    local c = api.nvim_win_get_cursor(0)
    row, col = c[1] - 1, c[2]
  else
    row, col = 0, 0
  end
  row, col = probe(buf, tree, row, col)
  -- probe at the cursor column and at the end of the line (`local M = {}` with the cursor on `local`); both
  -- results contain the cursor row, the innermost one wins
  local best, best_node
  local eol = #(line(buf, row):gsub("%s+$", "")) - 1
  for _, c in ipairs({ col, math.max(eol, 0) }) do
    local node, anchor, k = search(tree, row, c, lang, kind)
    if node and (not best_node or span(anchor) < span(best_node[2])) then
      best, best_node = k, { node, anchor }
    end
  end
  if best_node then
    return M.build(buf, best_node[1], best_node[2], best, lname, lang)
  end
  local what = kind and ({ func = "function", class = "class", type = "type" })[kind] or "documentable item"
  return nil, ("no %s at the cursor"):format(what)
end

--- Target for a matched node.
---@param buf integer
---@param node TSNode
---@param anchor TSNode
---@param kind slop.doc.Kind
---@param lname string
---@param lang? slop.doc.Lang
---@return slop.doc.Target? target, string? err
function M.build(buf, node, anchor, kind, lname, lang)
  local first = anchor
  local attrs = lang and lang.attrs or {}
  local prev = first:prev_named_sibling()
  while prev and attrs[prev:type()] and last_row(prev) >= first:range() - 1 do
    first = prev
    prev = first:prev_named_sibling()
  end
  local srow = first:range()
  local erow = last_row(anchor)
  local name = name_of(node, buf)
  local p = node:parent()
  while not name and p and anchor:child_with_descendant(p) do
    name = name_of(p, buf)
    p = p:parent()
  end
  if not name and anchor ~= node then
    name = name_of(anchor, buf)
  end
  local target = {
    buf = buf,
    kind = kind,
    type = node:type(),
    lang = lname,
    name = name,
    signature = vim.trim(line(buf, anchor:range())),
    rows = { srow, erow },
    docstring = false,
    doc = {},
  }
  if lang and lang.docstring then
    local range, indent, doc, err = docstring(node, buf)
    if not range then
      return nil, err
    end
    target.docstring = true
    target.range, target.indent, target.doc = range, indent, doc
    return target
  end
  local syntax = require("slop.modules.doc.langs").syntax_for(vim.bo[buf].filetype, vim.bo[buf].commentstring)
  local ds = doc_above(first, buf, syntax)
  target.indent = indent_of(line(buf, srow))
  target.range = { ds, srow }
  target.doc = ds < srow and api.nvim_buf_get_lines(buf, ds, srow, false) or {}
  return target
end

return M

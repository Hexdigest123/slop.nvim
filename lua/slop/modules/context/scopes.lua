--- context: which scope header rows a window shows (pure treesitter, no rendering).
---
--- A context node is a node whose type is in the language's list (M.types, or the user's `node_types`), or, for
--- languages without a list, a core.ts scope kind (function/method/class) or a generic control-flow / literal type.
--- Its header is the node's start row up to the last row before its body.
local M = {}

local api = vim.api

---@class slop.context.Candidate
---@field row integer   0-based start row
---@field col integer   0-based start col (byte)
---@field last integer  last header row (inclusive)

---@class slop.context.Group
---@field row integer   first source row (0-based)
---@field col integer
---@field rows integer  number of rows shown

--- Context node types per treesitter language.
---@type table<string, string[]>
M.types = {
  lua = {
    "function_declaration",
    "function_definition",
    "if_statement",
    "elseif_statement",
    "else_statement",
    "for_statement",
    "while_statement",
    "repeat_statement",
    "do_statement",
    "table_constructor",
  },
  c = {
    "function_definition",
    "if_statement",
    "else_clause",
    "for_statement",
    "while_statement",
    "do_statement",
    "switch_statement",
    "case_statement",
    "struct_specifier",
    "union_specifier",
    "enum_specifier",
    "initializer_list",
    "preproc_if",
    "preproc_ifdef",
  },
  python = {
    "function_definition",
    "class_definition",
    "if_statement",
    "elif_clause",
    "else_clause",
    "for_statement",
    "while_statement",
    "with_statement",
    "try_statement",
    "except_clause",
    "finally_clause",
    "match_statement",
    "case_clause",
    "dictionary",
    "list",
  },
  javascript = {
    "function_declaration",
    "generator_function_declaration",
    "function_expression",
    "function",
    "arrow_function",
    "method_definition",
    "class_declaration",
    "class",
    "if_statement",
    "else_clause",
    "for_statement",
    "for_in_statement",
    "while_statement",
    "do_statement",
    "switch_statement",
    "switch_case",
    "switch_default",
    "try_statement",
    "catch_clause",
    "object",
    "jsx_element",
  },
  go = {
    "function_declaration",
    "method_declaration",
    "func_literal",
    "type_declaration",
    "if_statement",
    "for_statement",
    "expression_switch_statement",
    "type_switch_statement",
    "select_statement",
    "expression_case",
    "type_case",
    "communication_case",
    "default_case",
    "composite_literal",
  },
  rust = {
    "function_item",
    "impl_item",
    "trait_item",
    "struct_item",
    "enum_item",
    "union_item",
    "mod_item",
    "macro_definition",
    "if_expression",
    "else_clause",
    "match_expression",
    "match_arm",
    "for_expression",
    "while_expression",
    "loop_expression",
    "closure_expression",
    "struct_expression",
  },
  java = {
    "class_declaration",
    "interface_declaration",
    "enum_declaration",
    "record_declaration",
    "method_declaration",
    "constructor_declaration",
    "lambda_expression",
    "if_statement",
    "for_statement",
    "enhanced_for_statement",
    "while_statement",
    "do_statement",
    "switch_expression",
    "switch_block_statement_group",
    "try_statement",
    "catch_clause",
    "finally_clause",
  },
  ruby = {
    "class",
    "module",
    "method",
    "singleton_method",
    "if",
    "elsif",
    "else",
    "unless",
    "while",
    "until",
    "for",
    "case",
    "when",
    "begin",
    "do_block",
    "block",
    "hash",
  },
  bash = {
    "function_definition",
    "if_statement",
    "elif_clause",
    "else_clause",
    "for_statement",
    "c_style_for_statement",
    "while_statement",
    "case_statement",
    "case_item",
  },
  vim = {
    "function_definition",
    "if_statement",
    "elseif_statement",
    "else_statement",
    "for_loop",
    "while_loop",
    "try_statement",
  },
  markdown = { "section" },
  json = { "object", "array" },
  yaml = { "block_mapping_pair", "block_sequence_item" },
  toml = { "table", "table_array_element" },
  html = { "element" },
}
M.types.cpp = vim.list_extend(vim.deepcopy(M.types.c), {
  "class_specifier",
  "namespace_definition",
  "template_declaration",
  "lambda_expression",
  "for_range_loop",
  "try_statement",
  "catch_clause",
})
M.types.typescript = vim.list_extend(vim.deepcopy(M.types.javascript), {
  "interface_declaration",
  "enum_declaration",
  "internal_module",
  "abstract_class_declaration",
  "object_type",
})
M.types.tsx = M.types.typescript
M.types.jsonc = M.types.json

-- generic context types for languages without a list: <head>[_..._<tail>]
local CONTROL = {
  ["if"] = true,
  ["else"] = true,
  elif = true,
  ["elseif"] = true,
  elsif = true,
  ["for"] = true,
  foreach = true,
  ["while"] = true,
  ["do"] = true,
  loop = true,
  ["repeat"] = true,
  switch = true,
  case = true,
  match = true,
  try = true,
  catch = true,
  except = true,
  finally = true,
  with = true,
  unless = true,
  ["until"] = true,
  when = true,
  select = true,
}
local CONTROL_TAILS = { "_statement$", "_expression$", "_loop$", "_arm$", "_block$", "_case$", "_item$" }
-- `for_in_clause`, `for_numeric_clause` are parts of a header, `else_clause` is a branch
local CLAUSES =
  { ["else"] = true, elif = true, ["elseif"] = true, except = true, catch = true, case = true, finally = true }
local LITERALS = { object = true, dictionary = true, table_constructor = true, hash = true }

---@param t string
---@return boolean
function M.generic(t)
  if LITERALS[t] then
    return true
  end
  local head, rest = t:match("^(%l+)(.*)$")
  if head and CONTROL[head] then
    if rest == "" or (CLAUSES[head] and rest:match("_clause$")) then
      return true
    end
    for _, tail in ipairs(CONTROL_TAILS) do
      if rest:match(tail) then
        return true
      end
    end
  end
  return require("slop.core.ts").classify(t) ~= nil
end

local sets = setmetatable({}, { __mode = "k" }) ---@type table<string[], table<string, true>>

--- Is a node of type `t` in language `lang` a context node?
---@param lang string
---@param t string
---@param user? table<string, string[]>  config node_types (replaces the built-in list of that language)
---@return boolean
function M.is_context(lang, t, user)
  local list = (user and user[lang]) or M.types[lang]
  if not list then
    return M.generic(t)
  end
  local set = sets[list]
  if not set then
    set = {}
    for _, v in ipairs(list) do
      set[v] = true
    end
    sets[list] = set
  end
  return set[t] == true
end

-- Body detection: the header ends where the body starts.
local BODY_FIELDS = { body = true, consequence = true }
local BODY_TYPES = {
  block = true,
  body = true,
  compound_statement = true,
  statement_block = true,
  declaration_list = true,
  field_declaration_list = true,
  enumerator_list = true,
  class_body = true,
  interface_body = true,
  enum_body = true,
  function_body = true,
  body_statement = true,
  do_block = true,
  do_group = true,
  suite = true,
}

-- A header is a handful of children (keyword, name, parameters, ...) before the body. A node without a body (a
-- literal, a list) can have 100k children (a big JSON array, a data table): walking them all on every cursor move
-- took ~150 ms, so the search for the body stops after this many.
local MAX_HEADER_CHILDREN = 64

--- Last header row of `node`: the end row of the last child before its body (comments ignored); the start row when
--- the node has no body (literals, case labels, sections).
---@param node TSNode
---@return integer
function M.header_last(node)
  local srow = node:start()
  local last = srow
  local n = 0
  for child, field in node:iter_children() do
    local t = child:type()
    if (field and BODY_FIELDS[field]) or BODY_TYPES[t] or t:match("_body$") then
      return last
    end
    n = n + 1
    if n > MAX_HEADER_CHILDREN then
      break -- no body among the first children: a literal / list
    end
    if t ~= "comment" then
      local sr, _, er, ec = child:range()
      if ec == 0 and er > sr then
        er = er - 1
      end
      last = math.max(last, er)
    end
  end
  return srow
end

--- The buffer's parser, parsed (main tree + injections around `rows`). nil without a parser.
---@param buf integer
---@param rows? {[1]: integer, [2]: integer}|{[1]: integer, [2]: integer}[]  a row range or a sorted list of them
---@return vim.treesitter.LanguageTree?
function M.parser(buf, rows)
  local ok, parser = pcall(vim.treesitter.get_parser, buf, nil, { error = false })
  if not ok or not parser then
    return nil
  end
  if not pcall(parser.parse, parser, rows) then
    return nil
  end
  return parser
end

--- The rows to parse for `row`: what the buffer's treesitter highlighter parses on every redraw (w0-1 .. w$+1 of
--- each window of the tabpage showing `buf`, highlighter.lua `_on_start`), plus `row` if none of them shows it.
--- A partial LanguageTree:parse() drops the injected regions outside its range (0.12, see included_regions()): any
--- other range made the highlighter re-create and re-parse every injected tree in view after each edit.
---@param buf integer
---@param row integer
---@return {[1]: integer, [2]: integer}[]
local function parse_ranges(buf, row)
  local ranges, shown = {}, false
  for _, w in ipairs(api.nvim_tabpage_list_wins(0)) do
    if api.nvim_win_get_buf(w) == buf then
      local first, last = vim.fn.line("w0", w) - 1, vim.fn.line("w$", w) + 1
      ranges[#ranges + 1] = { first, last }
      shown = shown or (row >= first and row <= last)
    end
  end
  if not shown then
    ranges[#ranges + 1] = { row, row + 1 }
  end
  table.sort(ranges, function(a, b)
    return a[1] < b[1]
  end)
  return ranges
end

--- Every context node enclosing (row, col), in all language trees, outermost first, one per start row (the outermost
--- of a row wins; its header covers the longest header of that row). Multi-line nodes only.
---@param buf integer
---@param row integer
---@param col integer
---@param user? table<string, string[]>
---@return slop.context.Candidate[]? nil without a parser
function M.candidates(buf, row, col, user)
  local parser = M.parser(buf, parse_ranges(buf, row))
  if not parser then
    return nil
  end
  local found = {} ---@type {row: integer, col: integer, erow: integer, last: integer}[]
  parser:for_each_tree(function(tstree, ltree)
    if not tstree then
      return
    end
    local root = tstree:root()
    local rsr, _, rer = root:range()
    if row < rsr or row > rer then
      return
    end
    local lang = ltree:lang()
    local node = root:named_descendant_for_range(row, col, row, col)
    while node do
      local srow, scol, erow = node:range()
      if erow > srow and srow <= row and M.is_context(lang, node:type(), user) then
        found[#found + 1] = { row = srow, col = scol, erow = erow, last = M.header_last(node) }
      end
      node = node:parent()
    end
  end)
  table.sort(found, function(a, b)
    if a.row ~= b.row then
      return a.row < b.row
    end
    return a.erow > b.erow
  end)
  local out = {} ---@type slop.context.Candidate[]
  for _, f in ipairs(found) do
    local prev = out[#out]
    if prev and prev.row == f.row then
      prev.last = math.max(prev.last, f.last)
    else
      out[#out + 1] = { row = f.row, col = f.col, last = f.last }
    end
  end
  return out
end

--- Pick the groups whose start rows are hidden: scrolled above `top` or covered by the groups picked before them.
---@param cands slop.context.Candidate[]
---@param top integer  0-based topline
---@param limit integer  rows the context may cover (the pos row is never covered)
---@param cfg table  context config
---@param pos? fun(row: integer): integer  screen rows from the topline to `row`, negative above it (default
---  `row - top`; folds and wrapped lines make them differ)
---@return slop.context.Group[], integer height
function M.pick(cands, top, limit, cfg, pos)
  pos = pos or function(row)
    return row - top
  end
  local max = cfg.max_lines > 0 and math.min(cfg.max_lines, limit) or limit
  if max <= 0 then
    return {}, 0
  end
  local groups, h = {}, 0 ---@type slop.context.Group[], integer
  for _, c in ipairs(cands) do
    -- a start at or below screen row `max` (e.g. on the cursor row) is never covered: it would only push others out
    local p = pos(c.row)
    if p < h and p < max then
      local n = math.min(c.last - c.row + 1, cfg.multiline_threshold)
      groups[#groups + 1] = { row = c.row, col = c.col, rows = n }
      h = h + n
    end
  end
  while h > max and #groups > 1 do
    local g = table.remove(groups, cfg.trim_scope == "inner" and #groups or 1)
    h = h - g.rows
  end
  if h > max then
    groups[1].rows = max
    h = max
  end
  -- trimming removed rows that hid later starts: drop the groups whose start row is now visible below the float,
  -- else that line shows twice (one drawn exactly over its own row is harmless)
  local kept, kh = {}, 0 ---@type slop.context.Group[], integer
  for _, g in ipairs(groups) do
    if pos(g.row) <= kh then
      kept[#kept + 1] = g
      kh = kh + g.rows
    end
  end
  return kept, kh
end

---@param buf integer
---@param row integer
---@return integer
local function indent_col(buf, row)
  local line = api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ""
  return #(line:match("^%s*"))
end

--- The context of a window: groups (outer -> inner) and their total height. nil when the buffer has no parser.
---@param win integer
---@param cfg table  context config
---@param limit integer  max rows (window height minus what must stay visible)
---@return slop.context.Group[]?, integer
function M.compute(win, cfg, limit)
  local buf = api.nvim_win_get_buf(win)
  local top = vim.fn.line("w0", win) - 1
  local cursor = api.nvim_win_get_cursor(win)
  local crow, ccol = cursor[1] - 1, cursor[2]
  -- the float covers screen rows, not buffer rows: a closed fold is one row, a wrapped line several, and with
  -- 'smoothscroll' the topline may be partly scrolled off (skipcol)
  local view = api.nvim_win_call(win, vim.fn.winsaveview)
  local skip, fill = view.skipcol, view.topfill
  local function height(opts)
    opts.start_row = top
    -- start_vcol leaves out the virtual / diff filler lines above the topline: only `topfill` of them are shown
    opts.start_vcol = skip
    return api.nvim_win_text_height(win, opts)
  end
  ---@param row integer
  ---@return integer  screen row of `row`'s text (below its own filler lines), negative above the window
  local function pos(row)
    if row < top then
      return row - top
    end
    return fill + (row == top and 0 or height({ end_row = row, end_vcol = 0 }).all)
  end
  -- never cover the cursor line, neither with context rows nor with the separator line drawn below them
  if crow >= top then
    limit = math.min(limit, pos(crow) - (cfg.separator and 1 or 0))
  end
  if limit <= 0 then
    return require("slop.core.ts").has_parser(buf) and {} or nil, 0
  end
  if cfg.mode ~= "topline" then
    local cands = M.candidates(buf, crow, ccol, cfg.node_types)
    if not cands then
      return nil, 0
    end
    for _, c in ipairs(cands) do
      -- a multi-line header the cursor is in shows only the rows above the cursor
      if c.row < crow then
        c.last = math.min(c.last, crow - 1)
      end
    end
    return M.pick(cands, top, limit, cfg, pos)
  end
  -- topline: the context of the first row below the float; re-evaluated until the height is stable
  local h, groups = 0, {}
  for _ = 1, 4 do
    -- the buffer row on screen row h (the filler lines above the topline belong to it)
    local row = h < fill and top or height({ max_height = h - fill + 1 }).end_row
    local cands = M.candidates(buf, row, indent_col(buf, row), cfg.node_types)
    if not cands then
      return nil, 0
    end
    for _, c in ipairs(cands) do
      if c.row < row then
        c.last = math.min(c.last, row - 1)
      end
    end
    local nh
    groups, nh = M.pick(cands, top, limit, cfg, pos)
    if nh == h then
      break
    end
    h = nh
  end
  local total = 0
  for _, g in ipairs(groups) do
    total = total + g.rows
  end
  return groups, total
end

--- Enclosing context nodes of the cursor that start above the cursor row, innermost first (for go_to_context).
---@param win integer
---@param cfg table
---@return slop.context.Candidate[]?
function M.enclosing(win, cfg)
  local buf = api.nvim_win_get_buf(win)
  local cursor = api.nvim_win_get_cursor(win)
  local cands = M.candidates(buf, cursor[1] - 1, cursor[2], cfg.node_types)
  if not cands then
    return nil
  end
  local out = {}
  for i = #cands, 1, -1 do
    if cands[i].row < cursor[1] - 1 then
      out[#out + 1] = cands[i]
    end
  end
  return out
end

return M

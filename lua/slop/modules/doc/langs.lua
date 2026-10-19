--- doc: per-language tables (treesitter node types per kind, anchoring rules) and comment syntax.
---
--- Keys are treesitter parser languages (vim.treesitter.language.get_lang / core.ts.lang), not filetypes.
---@class slop.doc.langs
local M = {}

---@alias slop.doc.Kind "func"|"class"|"type"

---@class slop.doc.Lang
---@field func string[]                      node types documented as functions/methods
---@field class string[]                     classes, structs, impls, traits, modules
---@field type string[]                      types, interfaces, enums, typedefs, aliases
---@field anon? table<string, true>          documentable only when anchored at a `decl` node (a declaration value)
---@field decl? table<string, true>          anchors that make an anonymous node documentable
---@field wrap? table<string, true>          parents climbed to the anchor when they start on the node's row
---@field wrap_any? table<string, true>      parents climbed on any row (decorators, templates)
---@field attrs? table<string, true>         preceding sibling node types that belong to the item (#[derive])
---@field check? table<string, fun(node: TSNode): boolean>  extra test for a node type
---@field docstring? boolean                 the doc lives inside the body (python)

local function set(list)
  local out = {}
  for _, v in ipairs(list) do
    out[v] = true
  end
  return out
end

--- Does `node` have a child (field `body`, or a named child of one of `types`)?
---@param node TSNode
---@param types string[]
---@return boolean
local function has_child(node, types)
  local ok, b = pcall(node.field, node, "body")
  if ok and b and b[1] then
    return true
  end
  for child in node:iter_children() do
    if vim.tbl_contains(types, child:type()) then
      return true
    end
  end
  return false
end

--- C/C++ declaration whose declarator (through pointers/references) is a function: a prototype.
---@param node TSNode
---@return boolean
local function is_prototype(node)
  local ok, d = pcall(node.field, node, "declarator")
  local decl = ok and d and d[1] or nil
  while decl do
    local t = decl:type()
    if t == "function_declarator" then
      return true
    end
    if t ~= "pointer_declarator" and t ~= "reference_declarator" then
      return false
    end
    local fok, inner = pcall(decl.field, decl, "declarator")
    decl = fok and inner and inner[1] or nil
  end
  return false
end

local C_BODY = { "field_declaration_list", "enumerator_list" }
local function c_body(node)
  return has_child(node, C_BODY)
end

local JS_WRAP = set({
  "export_statement",
  "lexical_declaration",
  "variable_declaration",
  "variable_declarator",
  "pair",
  "field_definition",
  "public_field_definition",
  "assignment_expression",
  "expression_statement",
  "ambient_declaration",
})
local JS_ANON = set({ "arrow_function", "function_expression", "function", "class", "generator_function" })
local JS_DECL = set({
  "export_statement",
  "lexical_declaration",
  "variable_declaration",
  "pair",
  "field_definition",
  "public_field_definition",
  "expression_statement",
})

local js = {
  func = {
    "function_declaration",
    "generator_function_declaration",
    "method_definition",
    "function_expression",
    "function",
    "arrow_function",
    "generator_function",
  },
  class = { "class_declaration", "class" },
  type = {},
  anon = JS_ANON,
  decl = JS_DECL,
  wrap = JS_WRAP,
}

local ts = vim.tbl_extend("force", js, {
  func = vim.list_extend(vim.deepcopy(js.func), {
    "function_signature",
    "method_signature",
    "abstract_method_signature",
  }),
  class = { "class_declaration", "abstract_class_declaration", "class" },
  type = { "interface_declaration", "type_alias_declaration", "enum_declaration" },
})

local c = {
  func = { "function_definition", "declaration" },
  class = { "struct_specifier", "union_specifier" },
  type = { "enum_specifier", "type_definition" },
  wrap = set({ "type_definition", "declaration" }),
  check = {
    declaration = is_prototype,
    struct_specifier = c_body,
    union_specifier = c_body,
    enum_specifier = c_body,
  },
}

local cpp = vim.tbl_extend("force", c, {
  func = { "function_definition", "declaration", "field_declaration" },
  class = { "class_specifier", "struct_specifier", "union_specifier" },
  type = { "enum_specifier", "type_definition", "alias_declaration", "concept_definition" },
  wrap = set({ "type_definition", "declaration" }),
  wrap_any = set({ "template_declaration" }),
  check = vim.tbl_extend("force", c.check, {
    field_declaration = is_prototype,
    class_specifier = c_body,
  }),
})

---@type table<string, slop.doc.Lang>
M.langs = {
  lua = {
    func = { "function_declaration", "function_definition" },
    class = { "table_constructor" },
    type = {},
    anon = set({ "function_definition", "table_constructor" }),
    decl = set({ "assignment_statement", "variable_declaration", "field" }),
    wrap = set({ "expression_list", "assignment_statement", "variable_declaration", "field" }),
    check = {
      -- a table is a "class" only when assigned to a variable, not as a field value
      table_constructor = function(node)
        local p = node:parent()
        return p ~= nil and p:type() == "expression_list"
      end,
    },
  },
  python = {
    func = { "function_definition" },
    class = { "class_definition" },
    type = {},
    wrap_any = set({ "decorated_definition" }),
    docstring = true,
  },
  javascript = js,
  typescript = ts,
  tsx = ts,
  go = {
    func = { "function_declaration", "method_declaration", "method_elem", "method_spec" },
    class = { "type_spec" },
    type = { "type_spec", "type_alias" },
    wrap = set({ "type_declaration" }),
  },
  rust = {
    func = { "function_item", "function_signature_item" },
    class = { "struct_item", "impl_item", "trait_item", "union_item", "mod_item" },
    type = { "enum_item", "type_item" },
    attrs = set({ "attribute_item" }),
  },
  java = {
    func = { "method_declaration", "constructor_declaration", "compact_constructor_declaration" },
    class = { "class_declaration", "record_declaration" },
    type = { "interface_declaration", "enum_declaration", "annotation_type_declaration" },
  },
  kotlin = {
    func = { "function_declaration", "secondary_constructor" },
    class = { "class_declaration", "object_declaration" },
    type = { "type_alias" },
  },
  c = c,
  cpp = cpp,
  php = {
    func = { "function_definition", "method_declaration" },
    class = { "class_declaration", "trait_declaration" },
    type = { "interface_declaration", "enum_declaration" },
  },
  bash = {
    func = { "function_definition" },
    class = {},
    type = {},
  },
  ruby = {
    func = { "method", "singleton_method" },
    class = { "class", "module", "singleton_class" },
    type = {},
  },
}

--- Kind of a node type in a language table (nil: not documentable).
---@param lang slop.doc.Lang
---@param t string
---@return slop.doc.Kind?
function M.kind_of(lang, t)
  for _, kind in ipairs({ "func", "class", "type" }) do
    if vim.tbl_contains(lang[kind], t) then
      return kind
    end
  end
  return nil
end

--- core.ts fallback for languages without a table.
---@param t string
---@return slop.doc.Kind?
function M.fallback_kind(t)
  local k = require("slop.core.ts").classify(t)
  if k == "function" or k == "method" then
    return "func"
  elseif k == "class" then
    if t:match("interface") or t:match("enum") or t:match("type") or t:match("alias") then
      return "type"
    end
    return "class"
  end
  return nil
end

-- Comment syntax ------------------------------------------------------------------------------------

---@class slop.doc.Syntax
---@field line string[]                      line-comment leaders ("--", "//", "#")
---@field block? {[1]: string, [2]: string}  block delimiters
---@field docstring? boolean                 python: the answer is a docstring
---@field skip? string[]                     Lua patterns of comment lines that are never part of a doc (shebang)

local SLASH = { line = { "//" }, block = { "/*", "*/" } }
local HASH = { line = { "#" }, skip = { "^#!" } }

---@type table<string, slop.doc.Syntax>
M.syntax = {
  lua = { line = { "--" }, block = { "--[[", "]]" } },
  python = { line = { "#" }, docstring = true },
  javascript = SLASH,
  javascriptreact = SLASH,
  typescript = SLASH,
  typescriptreact = SLASH,
  go = SLASH,
  rust = { line = { "//" }, block = { "/*", "*/" }, skip = { "^//!" } },
  java = SLASH,
  kotlin = SLASH,
  c = SLASH,
  cpp = SLASH,
  objc = SLASH,
  cs = SLASH,
  swift = SLASH,
  scala = SLASH,
  dart = SLASH,
  zig = { line = { "//" } },
  php = { line = { "//", "#" }, block = { "/*", "*/" }, skip = { "^#!", "^#%[" } },
  sh = HASH,
  bash = HASH,
  zsh = HASH,
  fish = HASH,
  ruby = HASH,
  perl = HASH,
  elixir = HASH,
  r = HASH,
  yaml = HASH,
  toml = HASH,
  vim = { line = { '"' } },
  haskell = { line = { "--" }, block = { "{-", "-}" } },
  sql = { line = { "--" }, block = { "/*", "*/" } },
}

--- Comment syntax of a buffer: the table above by filetype, else derived from 'commentstring'.
---@param ft string
---@param commentstring? string
---@return slop.doc.Syntax?
function M.syntax_for(ft, commentstring)
  if M.syntax[ft] then
    return M.syntax[ft]
  end
  local cs = commentstring or ""
  local pre, post = cs:match("^%s*(.-)%s*%%s%s*(.-)%s*$")
  if not pre or pre == "" then
    return nil
  end
  if post ~= "" then
    return { line = {}, block = { pre, post } }
  end
  return { line = { pre } }
end

return M

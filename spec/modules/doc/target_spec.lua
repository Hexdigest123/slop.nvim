local h = require("helpers")

local LUA = {
  "---old doc", --  0
  "---@param a integer", --  1
  "local function foo(a, b)", --  2
  "  return a", --  3
  "end", --  4
  "local M = {}", --  5
  "M.bar = function(x) end", --  6
  "local t = { f = function() end, g = {} }", --  7
  "vim.schedule(function() end)", --  8
  "", --  9
  "-- detached", -- 10
  "", -- 11
  "function M.qux()", -- 12
  "  local inner = function() end", -- 13
  "  return inner", -- 14
  "end", -- 15
  "return M", -- 16
}

local C = {
  "/**", --  0
  " * Add.", --  1
  " */", --  2
  "static int add(int a, int b) { return a + b; }", --  3
  "int proto(int x);", --  4
  "typedef struct { int x; } Point;", --  5
  "struct node { int v; };", --  6
  "enum color { RED, GREEN };", --  7
  "typedef int myint;", --  8
  "void f(struct node *n);", --  9
  "int x = 1; /* trailing */", -- 10
  "int g(void) { return 0; }", -- 11
}

---@param lines string[]
---@param ft string
---@return integer
local function scratch(lines, ft)
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].filetype = ft
  vim.api.nvim_set_current_buf(buf)
  return buf
end

describe("doc target (lua)", function()
  local doc, buf
  before_each(function()
    h.reset()
    require("slop").setup({})
    doc = require("slop").doc
    buf = scratch(LUA, "lua")
  end)

  local function find(row, col, kind)
    return doc.find(buf, { row, col }, kind)
  end

  it("finds a local function and its attached doc comment", function()
    local t = assert(find(3, 4))
    assert.equal("func", t.kind)
    assert.equal("function_declaration", t.type)
    assert.equal("foo", t.name)
    assert.are.same({ 2, 4 }, t.rows)
    assert.are.same({ 0, 2 }, t.range)
    assert.are.same({ "---old doc", "---@param a integer" }, t.doc)
    assert.equal("", t.indent)
  end)

  it("a cursor on the doc comment targets the item below it", function()
    local t = assert(find(0, 0))
    assert.equal("foo", t.name)
    assert.are.same({ 0, 2 }, t.range)
  end)

  it("tables assigned to variables are classes (cursor anywhere on the line)", function()
    local t = assert(find(5, 0))
    assert.equal("class", t.kind)
    assert.equal("M", t.name)
    assert.are.same({ 5, 5 }, t.range)
    assert.are.same({}, t.doc)
  end)

  it("anonymous functions are documented through their declaration", function()
    local t = assert(find(6, 0))
    assert.equal("func", t.kind)
    assert.equal("M.bar", t.name)
    t = assert(find(7, 18))
    assert.equal("f", t.name)
    assert.equal("func", t.kind)
  end)

  it("anonymous functions passed as arguments are not documentable", function()
    local t, err = find(8, 20)
    assert.is_nil(t)
    assert.matches("no documentable item", err)
  end)

  it("a comment separated by a blank line is not the doc", function()
    local t = assert(find(14, 2))
    assert.equal("M.qux", t.name)
    assert.are.same({}, t.doc)
    assert.are.same({ 12, 12 }, t.range)
  end)

  it("innermost item wins; the indentation follows the item", function()
    local t = assert(find(13, 2))
    assert.equal("inner", t.name)
    assert.equal("  ", t.indent)
    assert.are.same({ 13, 13 }, t.rows)
  end)

  it("kind filters climb to the enclosing item of that kind", function()
    local t = assert(find(13, 20, "func"))
    assert.equal("inner", t.name)
    local c, err = find(3, 4, "class")
    assert.is_nil(c)
    assert.matches("no class", err)
    local ty, terr = find(3, 4, "type")
    assert.is_nil(ty)
    assert.matches("no type", terr)
  end)
end)

describe("doc target (c)", function()
  local doc, buf
  before_each(function()
    h.reset()
    require("slop").setup({})
    doc = require("slop").doc
    buf = scratch(C, "c")
  end)

  local function find(row, col, kind)
    return doc.find(buf, { row, col }, kind)
  end

  it("function with a block doc comment", function()
    local t = assert(find(3, 35))
    assert.equal("add", t.name)
    assert.are.same({ 0, 3 }, t.range)
    assert.are.same({ "/**", " * Add.", " */" }, t.doc)
    t = assert(find(1, 3)) -- inside the comment
    assert.equal("add", t.name)
  end)

  it("prototypes are functions, plain declarations are not", function()
    local t = assert(find(4, 0))
    assert.equal("func", t.kind)
    assert.equal("proto", t.name)
    assert.equal("func", assert(find(9, 10)).kind)
    assert.is_nil((find(10, 4)))
  end)

  it("structs are classes; typedefs and enums are types", function()
    local t = assert(find(5, 20))
    assert.equal("class", t.kind)
    assert.equal("struct_specifier", t.type)
    assert.are.same({ 5, 5 }, t.range)
    t = assert(find(5, 20, "type"))
    assert.equal("type_definition", t.type)
    assert.equal("Point", t.name)
    assert.equal("node", assert(find(6, 15)).name)
    assert.equal("type", assert(find(7, 15)).kind)
    assert.equal("myint", assert(find(8, 0)).name)
  end)

  it("a trailing comment on the previous line is not a doc", function()
    local t = assert(find(11, 0))
    assert.equal("g", t.name)
    assert.are.same({}, t.doc)
  end)
end)

describe("doc target (other)", function()
  before_each(function()
    h.reset()
    require("slop").setup({})
  end)

  it("no parser: an error", function()
    local buf = scratch({ "foo" }, "nosuchlang")
    local t, err = require("slop").doc.find(buf, { 0, 0 })
    assert.is_nil(t)
    assert.matches("no treesitter parser", err)
  end)

  it("languages without a table use the core.ts fallback", function()
    local langs = require("slop.modules.doc.langs")
    assert.equal("func", langs.fallback_kind("function_definition"))
    assert.equal("func", langs.fallback_kind("method_declaration"))
    assert.equal("class", langs.fallback_kind("class_definition"))
    assert.equal("type", langs.fallback_kind("interface_declaration"))
    assert.equal("type", langs.fallback_kind("enum_item"))
    assert.is_nil(langs.fallback_kind("call_expression"))
    -- vim script has no table: the fallback finds functions
    local buf = scratch({ "function! Foo()", "  echo 1", "endfunction" }, "vim")
    local t = require("slop").doc.find(buf, { 1, 2 })
    assert.not_nil(t)
    assert.equal("func", t.kind)
  end)

  it("syntax_for() falls back to 'commentstring'", function()
    local langs = require("slop.modules.doc.langs")
    assert.are.same({ "--" }, langs.syntax_for("lua").line)
    assert.are.same({ line = { ";" } }, langs.syntax_for("unknownft", "; %s"))
    assert.are.same({ line = {}, block = { "<!--", "-->" } }, langs.syntax_for("unknownft", "<!-- %s -->"))
    assert.is_nil(langs.syntax_for("unknownft", ""))
  end)
end)

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
    -- inside the comment's text (a comment_content node)
    assert.equal("foo", assert(find(0, 5)).name)
    assert.equal("foo", assert(find(1, 8)).name)
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

  it("a trailing ',' or ';' does not hide a function value from the end-of-line probe", function()
    buf = scratch({ "local M = {", "  f = function() end,", "}", "local h = function() end;" }, "lua")
    local t = assert(find(1, 2))
    assert.equal("func", t.kind)
    assert.equal("f", t.name)
    assert.are.same({ 1, 1 }, t.range)
    t = assert(find(3, 0))
    assert.equal("h", t.name)
  end)

  it("tool directives stay attached to the item: the doc goes above them", function()
    buf = scratch({
      "---Old.", --  0
      "---@diagnostic disable-next-line: unused-local", --  1
      "local function k(a) end", --  2
      "-- stylua: ignore", --  3
      "local function s() end", --  4
    }, "lua")
    local t = assert(find(2, 0))
    assert.are.same({ 0, 1 }, t.range)
    assert.are.same({ "---Old." }, t.doc)
    assert.are.same({ 1, 2 }, t.rows)
    t = assert(find(4, 0))
    assert.are.same({ 3, 3 }, t.range)
    assert.are.same({}, t.doc)
    t = assert(find(3, 3)) -- on the directive: the item below it
    assert.equal("s", t.name)
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

  it("a directive keeps its place above the item; a license header is never the doc", function()
    buf = scratch({
      "/** Old. */", --  0
      "// NOLINTNEXTLINE(readability-identifier-naming)", --  1
      "int Bad_Name(void) { return 0; }", --  2
      "/*", --  3
      " * Copyright (c) 2024 Example", --  4
      " * SPDX-License-Identifier: MIT", --  5
      " */", --  6
      "int main(void) { return 0; }", --  7
    }, "c")
    local t = assert(find(2, 4))
    assert.are.same({ 0, 1 }, t.range)
    assert.are.same({ "/** Old. */" }, t.doc)
    t = assert(find(7, 4))
    assert.are.same({ 7, 7 }, t.range)
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

  it("python: a body on the header's last line is a one-line definition", function()
    -- Nvim bundles no python parser: drive build() with the few node methods it uses
    local function node(t, range, fields)
      return {
        type = function()
          return t
        end,
        range = function()
          return unpack(range)
        end,
        field = function(_, name)
          return (fields or {})[name] or {}
        end,
        parent = function() end,
        prev_named_sibling = function() end,
        named_child = function() end,
        iter_children = function()
          return function() end
        end,
      }
    end
    local langs = require("slop.modules.doc.langs")
    local target = require("slop.modules.doc.target")
    local buf = scratch({ "def h(", "    a,", "): return a" }, "python")
    local def = node("function_definition", { 0, 0, 2, 11 }, { body = { node("block", { 2, 3, 2, 11 }) } })
    local t, err = target.build(buf, def, def, "func", "python", langs.langs.python)
    assert.is_nil(t)
    assert.matches("one%-line definitions", err)
    -- the body on its own line: the docstring goes at its start
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "def h(", "    a,", "):", "    return a" })
    def = node("function_definition", { 0, 0, 3, 12 }, { body = { node("block", { 3, 4, 3, 12 }) } })
    t = assert(target.build(buf, def, def, "func", "python", langs.langs.python))
    assert.are.same({ 3, 3 }, t.range)
    assert.equal("    ", t.indent)
  end)

  it("code embedded in another language: a markdown code block, the function around an injected string", function()
    local buf =
      scratch({ "# Title", "", "```lua", "---Old.", "local function f(a)", "  return a", "end", "```" }, "markdown")
    local t = assert(require("slop").doc.find(buf, { 5, 2 }))
    assert.equal("f", t.name)
    assert.equal("lua", t.lang)
    assert.equal("lua", t.filetype)
    assert.are.same({ 3, 4 }, t.range)
    assert.are.same({ "---Old." }, t.doc)
    assert.is_nil((require("slop").doc.find(buf, { 0, 0 })))
    -- a cursor in an injected string (vim.cmd -> vim) finds the Lua function around it
    buf = scratch({ "local function g()", "  vim.cmd('echo 1')", "end" }, "lua")
    t = assert(require("slop").doc.find(buf, { 1, 13 }))
    assert.equal("g", t.name)
    assert.equal("lua", t.filetype)
  end)

  it("typescript: decorators of a class member are its siblings, a decorated export starts at its decorator", function()
    -- Nvim bundles no typescript parser: use an installed one, else skip
    vim.opt.rtp:append(vim.fn.expand("~/.local/share/nvim/site"))
    -- language.add throws on Nvim 0.10 but returns nil, err since 0.11
    local ok, added = pcall(vim.treesitter.language.add, "typescript")
    if not (ok and added) then
      return pending("no typescript parser installed")
    end
    local buf = scratch({
      "/** Class doc. */", --  0
      "@Component({", --  1
      '  selector: "x",', --  2
      "})", --  3
      "export class Comp {", --  4
      "  /** Old. */", --  5
      '  @HostListener("click")', --  6
      "  @Other()", --  7
      "  onClick(): void {}", --  8
      "}", --  9
    }, "typescript")
    for _, pos in ipairs({ { 8, 2 }, { 6, 4 }, { 5, 4 } }) do
      local t = assert(require("slop").doc.find(buf, pos))
      assert.equal("onClick", t.name)
      assert.are.same({ 6, 8 }, t.rows)
      assert.are.same({ 5, 6 }, t.range)
    end
    for _, pos in ipairs({ { 4, 7 }, { 2, 2 }, { 0, 0 } }) do
      local t = assert(require("slop").doc.find(buf, pos))
      assert.equal("Comp", t.name)
      assert.are.same({ 1, 9 }, t.rows)
      assert.are.same({ 0, 1 }, t.range)
    end
  end)

  it("syntax_for() falls back to 'commentstring'", function()
    local langs = require("slop.modules.doc.langs")
    assert.are.same({ "--" }, langs.syntax_for("lua").line)
    assert.are.same({ line = { ";" } }, langs.syntax_for("unknownft", "; %s"))
    assert.are.same({ line = {}, block = { "<!--", "-->" } }, langs.syntax_for("unknownft", "<!-- %s -->"))
    assert.is_nil(langs.syntax_for("unknownft", ""))
  end)
end)

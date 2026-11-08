local h = require("helpers")

describe("core.ts", function()
  local ts
  local api = vim.api

  local function buf_with(lines, ft)
    local b = api.nvim_create_buf(true, false)
    api.nvim_buf_set_lines(b, 0, -1, false, lines)
    vim.bo[b].filetype = ft or ""
    return b
  end

  before_each(function()
    h.reset()
    ts = require("slop.core.ts")
  end)

  it("lang / has_parser", function()
    local b = buf_with({ "local x = 1" }, "lua")
    assert.equal("lua", ts.lang(b))
    assert.is_true(ts.has_parser(b))
    local n = buf_with({ "x" }, "")
    assert.is_nil(ts.lang(n))
    assert.is_false(ts.has_parser(n))
  end)

  it("classifies node types", function()
    assert.equal("function", ts.classify("function_declaration"))
    assert.equal("function", ts.classify("function_definition"))
    assert.equal("method", ts.classify("method_definition"))
    assert.equal("class", ts.classify("class_declaration"))
    assert.equal("function", ts.classify("arrow_function"))
    assert.is_nil(ts.classify("function_call"))
    assert.is_nil(ts.classify("parameters"))
    assert.is_nil(ts.classify("identifier"))
  end)

  it("finds enclosing lua scopes with names, ranges and headers", function()
    local b = buf_with({
      "local M = {}",
      "function M.outer(a, b)",
      "  local function inner(x)",
      "    return x + 1",
      "  end",
      "  return inner(a)",
      "end",
      "return M",
    }, "lua")
    local all = ts.scopes(b, { 3, 6 })
    assert.equal(2, #all)
    assert.equal("function", all[1].kind)
    assert.equal("M.outer", all[1].name)
    assert.are.same({ "function M.outer(a, b)" }, all[1].header)
    assert.are.same({ 1, 0, 6, 3 }, all[1].range)
    assert.equal("inner", all[2].name)
    assert.are.same({ "  local function inner(x)" }, all[2].header)
    local inner = ts.scope(b, { 3, 6 })
    assert.equal("inner", inner.name)
    assert.is_nil(ts.scope(b, { 0, 3 }))
    assert.are.same({}, ts.scopes(buf_with({ "x" }, "")))
  end)

  it("C: function definition header stops at the body", function()
    local b = buf_with({
      "static int",
      "add(int a,",
      "    int b)",
      "{",
      "  return a + b;",
      "}",
    }, "c")
    local s = ts.scope(b, { 4, 4 })
    assert.equal("function", s.kind)
    assert.are.same({ "static int", "add(int a,", "    int b)", "{" }, s.header)
  end)

  it("header parts and type references are not scopes", function()
    for _, t in ipairs({
      "function_declarator",
      "method_index_expression",
      "class_heritage",
      "function_type",
      "struct_field",
    }) do
      assert.is_nil(ts.classify(t), t)
    end
    -- cursor on a function's name / parameter list: the whole function, not its declarator
    local c = buf_with({ "static int", "add(int a,", "    int b)", "{", "  return a + b;", "}" }, "c")
    local s = ts.scope(c, { 1, 1 })
    assert.equal("function_definition", s.type)
    assert.are.same({ 0, 0, 5, 1 }, s.range)
    local l = buf_with({ "local M = {}", "function M:greet(name)", "  return 'hi ' .. name", "end" }, "lua")
    s = ts.scope(l, { 1, 12 })
    assert.equal("function_declaration", s.type)
    assert.are.same({ 1, 0, 3, 3 }, s.range)
    -- a struct type reference (no body) is not a class scope; the definition is
    local st = buf_with({ "struct point { int x; };", "int f(struct point *p) {", "  return p->x;", "}" }, "c")
    s = ts.scope(st, { 1, 14 })
    assert.equal("function_definition", s.type)
    assert.equal("struct_specifier", ts.scope(st, { 0, 16 }).type)
  end)

  it("scopes inside an injected language include the host language's scopes", function()
    local b = buf_with({
      "local M = {}",
      "function M.setup(opts)",
      '  vim.cmd("highlight link Foo Bar")',
      "end",
    }, "lua")
    local all = ts.scopes(b, { 2, 20 })
    assert.equal(1, #all)
    assert.equal("M.setup", all[1].name)
    local md = buf_with({ "# Title", "", "```lua", "local function f()", "  return 1", "end", "```" }, "markdown")
    assert.equal("f", ts.scope(md, { 4, 4 }).name)
  end)

  it("parses only the injections at the position", function()
    local lines = { "function M.a()", '  vim.cmd("echo 1")', "end" }
    for i = 1, 200 do
      lines[#lines + 1] = ("local x%d = %d"):format(i, i)
    end
    vim.list_extend(lines, { "function M.b()", '  vim.cmd("echo 2")', "end" })
    local b = buf_with(lines, "lua")
    assert.equal("M.a", ts.scope(b, { 1, 12 }).name)
    local trees = vim.treesitter.get_parser(b):children().vim:trees()
    assert.equal(1, vim.tbl_count(trees), "the far vim.cmd() injection was parsed too")
  end)

  it("the root node of a tree is never a scope (Python's root `module` looks like a Ruby module)", function()
    local b = buf_with({ "local x = 1", "function f()", "  return x", "end" }, "lua")
    -- the Lua root (`chunk`) classified like Python's `module` (kind "class" via "^module$")
    table.insert(ts.kinds, 1, { "^chunk$", "class" })
    local ok, err = pcall(function()
      assert.equal("class", ts.classify("chunk"))
      assert.is_nil(ts.scope(b, { 0, 3 }), "top level: no enclosing scope (not the whole file)")
      local all = ts.scopes(b, { 2, 4 })
      assert.equal(1, #all)
      assert.equal("f", all[1].name)
    end)
    table.remove(ts.kinds, 1)
    assert(ok, err)
    -- the real thing, when a Python parser is installed (language.add returns nil, err without one)
    local has_python, added = pcall(vim.treesitter.language.add, "python")
    if has_python and added then
      local py = buf_with({ "import os", "", "def f(a):", "    return a", "", "X = f(1)" }, "python")
      assert.is_nil(ts.scope(py, { 5, 0 }))
      assert.are.same(
        { "f" },
        vim.tbl_map(function(s)
          return s.name
        end, ts.scopes(py, { 3, 6 }))
      )
    end
  end)

  it("defaults to the cursor position of the current window", function()
    local b = buf_with({ "function f()", "  return 1", "end" }, "lua")
    api.nvim_set_current_buf(b)
    api.nvim_win_set_cursor(0, { 2, 3 })
    assert.equal("f", ts.scope(b).name)
  end)

  it("in_empty_block (table)", function()
    local cases = {
      { { "def f():", "    " }, { 1, 4 }, true },
      { { "def f():", "    ", "print(1)" }, { 1, 4 }, true },
      { { "def f():", "    ", "    return 1" }, { 1, 4 }, false },
      { { "function f()", "  ", "end" }, { 1, 2 }, true },
      { { "function f()", "  ", "  return 1", "end" }, { 1, 2 }, false },
      { { "if (x) {}" }, { 0, 8 }, true },
      { { "if (x) {", "  ", "}" }, { 1, 2 }, true },
      { { "local x = 1", "" }, { 1, 0 }, false },
      { { "foo(bar)", "" }, { 1, 0 }, false },
      { { "for i = 1, 3 do", "", "end" }, { 1, 0 }, true },
      { { "  x = {", "  " }, { 1, 2 }, true },
      { { "def f():", "    pass" }, { 1, 4 }, false },
    }
    for i, c in ipairs(cases) do
      local b = buf_with(c[1], "")
      assert.equal(c[3], ts.in_empty_block(b, c[2]), "case " .. i .. ": " .. table.concat(c[1], "\\n"))
    end
  end)
end)

-- context scopes: context node detection, header rows, candidate collection (injections too) and trimming.
local h = require("helpers")

local api = vim.api

describe("context scopes", function()
  local S
  before_each(function()
    h.reset()
    S = require("slop.modules.context.scopes")
  end)

  local function buf_with(lines, ft)
    local b = api.nvim_create_buf(true, false)
    api.nvim_buf_set_lines(b, 0, -1, false, lines)
    vim.bo[b].filetype = ft
    return b
  end

  local CFG = { max_lines = 3, multiline_threshold = 20, trim_scope = "outer" }
  local function cfg(o)
    return vim.tbl_extend("force", CFG, o or {})
  end

  local function rows(cands)
    return vim.tbl_map(function(c)
      return { c.row, c.last }
    end, cands)
  end

  it("classifies per language, with a generic fallback and user overrides", function()
    assert.is_true(S.is_context("lua", "function_declaration"))
    assert.is_true(S.is_context("lua", "table_constructor"))
    assert.is_false(S.is_context("lua", "function_call"))
    assert.is_false(S.is_context("lua", "block"))
    assert.is_true(S.is_context("c", "else_clause"))
    assert.is_true(S.is_context("cpp", "class_specifier"), "cpp extends c")
    assert.is_true(S.is_context("cpp", "if_statement"))
    assert.is_true(S.is_context("tsx", "interface_declaration"))
    -- unknown language: core.ts kinds + control flow + literals
    for _, t in ipairs({ "if_statement", "for_in_statement", "match_arm", "object", "function_definition", "class" }) do
      assert.is_true(S.is_context("zz", t), t)
    end
    for _, t in ipairs({ "identifier", "call_expression", "formal_parameters", "string", "for_numeric_clause" }) do
      assert.is_false(S.is_context("zz", t), t)
    end
    -- user list replaces the built-in one
    local user = { lua = { "if_statement" } }
    assert.is_true(S.is_context("lua", "if_statement", user))
    assert.is_false(S.is_context("lua", "function_declaration", user))
  end)

  it("header rows end before the body (lua multi-line signature, comments ignored)", function()
    local b = buf_with({
      "function M.f(a,", --0
      "  b)", --1
      "  -- comment", --2
      "  return a", --3
      "end", --4
      "if x then", --5
      "  y()", --6
      "end", --7
    }, "lua")
    local cands = assert(S.candidates(b, 3, 2))
    assert.are.same({ { 0, 1 } }, rows(cands))
    assert.are.same({ { 5, 5 } }, rows(assert(S.candidates(b, 6, 2))))
  end)

  it("C: body on the signature's last row counts, K&R brace does not; else-if shares a row", function()
    local b = buf_with({
      "int f(int a,", --0
      "      int b) {", --1
      "  if (a) {", --2
      "    a++;", --3
      "  } else if (b) {", --4
      "    b++;", --5
      "  }", --6
      "}", --7
      "int g(void)", --8
      "{", --9
      "  return 0;", --10
      "}", --11
    }, "c")
    assert.are.same({ { 0, 1 }, { 2, 2 }, { 4, 4 } }, rows(assert(S.candidates(b, 5, 4))))
    assert.are.same({ { 8, 8 } }, rows(assert(S.candidates(b, 10, 2))))
  end)

  it("walks injected trees (lua inside a markdown fence)", function()
    local b = buf_with({
      "# Title", --0
      "", --1
      "```lua", --2
      "local function f()", --3
      "  return 1", --4
      "end", --5
      "```", --6
    }, "markdown")
    local cands = assert(S.candidates(b, 4, 2))
    assert.are.same({ { 0, 0 }, { 3, 3 } }, rows(cands))
  end)

  it("returns nil without a parser", function()
    local b = buf_with({ "x", "y" }, "")
    assert.is_nil(S.candidates(b, 0, 0))
  end)

  it("pick: start rows above topline or under the float; trim outer / inner; threshold", function()
    local cands = {
      { row = 0, col = 0, last = 1 }, -- 2-row header
      { row = 5, col = 2, last = 5 },
      { row = 20, col = 4, last = 20 }, -- == top: covered once the outer ones show
      { row = 26, col = 6, last = 26 }, -- visible below the float
    }
    local g, ht = S.pick(cands, 20, 10, cfg({ max_lines = 0 }))
    assert.equal(4, ht)
    assert.are.same({ 0, 5, 20 }, { g[1].row, g[2].row, g[3].row })
    g, ht = S.pick(cands, 20, 10, cfg({ max_lines = 3 }))
    assert.equal(2, ht)
    assert.are.same({ 5, 20 }, { g[1].row, g[2].row }, "outer trimmed first")
    g, ht = S.pick(cands, 20, 10, cfg({ max_lines = 3, trim_scope = "inner" }))
    assert.equal(3, ht)
    assert.are.same({ 0, 5 }, { g[1].row, g[2].row })
    g, ht = S.pick(cands, 20, 10, cfg({ max_lines = 0, multiline_threshold = 1 }))
    assert.equal(3, ht)
    assert.equal(1, g[1].rows)
    -- one group taller than the limit is truncated
    g, ht = S.pick({ { row = 0, col = 0, last = 9 } }, 5, 10, cfg({ max_lines = 4 }))
    assert.equal(4, ht)
    assert.equal(4, g[1].rows)
    -- the limit (window / cursor) wins over max_lines
    _, ht = S.pick(cands, 20, 1, cfg({ max_lines = 0 }))
    assert.equal(1, ht)
    assert.are.same({}, (S.pick(cands, 20, 0, cfg())))
  end)

  it("pick: never the cursor row's scope, and not one that only the trimmed rows were hiding", function()
    local function rows_of(groups)
      return vim.tbl_map(function(g)
        return g.row
      end, groups)
    end
    -- function > for (on the topline 19) > if > if on the cursor row 21 (limit 2): the cursor row is never covered,
    -- so its scope must not push the covered `for` out
    local nested = {
      { row = 0, col = 0, last = 0 },
      { row = 19, col = 2, last = 19 },
      { row = 20, col = 4, last = 20 },
      { row = 21, col = 6, last = 21 },
    }
    local g, ht = S.pick(nested, 19, 2, cfg())
    assert.are.same({ 19, 20 }, rows_of(g))
    assert.equal(2, ht)
    -- a 3-row signature makes the `if` on 21 count as hidden; trimmed away (max_lines 3), 21 is visible again
    local sig = { { row = 0, col = 0, last = 2 }, { row = 19, col = 2, last = 19 }, { row = 21, col = 4, last = 21 } }
    g, ht = S.pick(sig, 19, 6, cfg())
    assert.are.same({ 19 }, rows_of(g))
    assert.equal(1, ht)
  end)

  it("pick: positions are screen rows (a closed fold over rows 20-39 is one row)", function()
    local function pos(row)
      if row <= 19 then
        return row - 19
      end
      return row <= 39 and 1 or row - 38
    end
    -- a 3-row header covers screen rows 0-2: the topline, the fold and row 40 -> the `for` on 40 is hidden
    local cands = { { row = 0, col = 0, last = 2 }, { row = 40, col = 2, last = 40 } }
    local g, ht = S.pick(cands, 19, 10, cfg({ max_lines = 0 }), pos)
    assert.are.same({ 0, 40 }, { g[1].row, g[2].row })
    assert.equal(4, ht)
    -- counted in buffer rows it would look visible (40 - 19 = 21 rows down) and its header would be lost
    g, ht = S.pick(cands, 19, 10, cfg({ max_lines = 0 }))
    assert.equal(1, #g)
    assert.equal(3, ht)
  end)
end)

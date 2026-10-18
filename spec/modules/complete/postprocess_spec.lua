local h = require("helpers")

describe("complete.postprocess", function()
  local pp
  before_each(function()
    h.reset()
    pp = require("slop.modules.complete.postprocess")
  end)

  local function ctx(o)
    return vim.tbl_extend("force", { before = "", after = "", next_lines = {}, expandtab = true, tabstop = 4 }, o or {})
  end

  it("valid_mid_line (copilot gate)", function()
    local cases = {
      { "", true },
      { ")", true },
      { "  ) ", true },
      { "]);", true },
      { '"', true },
      { "}:", true },
      { ") {", true },
      { "foo", false },
      { ", bar)", false },
      { "+ 1", false },
    }
    for _, c in ipairs(cases) do
      assert.equal(c[2], pp.valid_mid_line(c[1]), vim.inspect(c[1]))
    end
  end)

  it("process (table)", function()
    local cases = {
      -- name, text, ctx, expected
      { "plain", "x + 1", {}, "x + 1" },
      { "trailing ws", "x + 1  \n\n", {}, "x + 1" },
      { "blank", "  \n ", {}, "" },
      { "single line mode", "foo()\nbar()", { multiline = false }, "foo()" },
      { "rest of line ) dropped", "a, b)", { before = "f(", after = ")" }, "a, b" },
      { "rest of line on first line", "a)\n  more", { before = "f(", after = ")" }, "a\n  more" },
      { "rest of line kept when not at end", "a) + 1", { before = "f(", after = ")" }, "a) + 1" },
      { "space before rest", "x then", { before = "if ", after = " then" }, "x" },
      { "space kept", "x = 1", { before = "local ", after = "= 1" }, "x " },
      { "duplicate of next line", "return x", { next_lines = { "", "  return x" } }, "" },
      {
        "closing bracket dedupe",
        "  return 1\nend",
        { before = "  ", next_lines = { "end" } },
        "  return 1",
      },
      {
        "closing brace dedupe (multiple)",
        "x = 1;\n  }\n}",
        { before = "    ", next_lines = { "  }", "}" } },
        "x = 1;",
      },
      {
        "closer not in document is kept",
        "  return 1\nend",
        { before = "  ", next_lines = { "local y" } },
        "  return 1\nend",
      },
      {
        "block end: dedent cuts",
        "return 1\nend\n\nfunction g()\n  return 2\nend",
        { before = "  ", next_lines = {} },
        "return 1\nend",
      },
      {
        "block end: opened block ends at base level",
        "\n  return 1\nend\nprint(f())",
        { before = "function f()", next_lines = {} },
        "\n  return 1\nend",
      },
      { "max_lines", "a\nb\nc\nd", { max_lines = 2 }, "a\nb" },
      { "repetitive", string.rep("x = 1 ", 12), {}, "" },
      {
        "indent tabs -> spaces",
        "if x then\n\treturn\nend",
        { expandtab = true, tabstop = 4 },
        "if x then\n    return\nend",
      },
      {
        "indent spaces -> tabs",
        "if x then\n        y\nend",
        { expandtab = false, tabstop = 4 },
        "if x then\n\t\ty\nend",
      },
      { "chat: typed indentation stripped", "    return x", { before = "    ", chat = true }, "return x" },
      { "chat: repeated word stripped", "foo.bar()", { before = "local y = foo", chat = true }, ".bar()" },
    }
    for _, c in ipairs(cases) do
      assert.equal(c[4], pp.process(c[2], ctx(c[3])), c[1])
    end
  end)

  it("process_all dedupes after processing", function()
    assert.are.same({ "a", "b" }, pp.process_all({ "a ", "a", "", "b" }, ctx()))
  end)

  it("partial: single-line stops at the newline; multi-line stops at block end / max lines", function()
    assert.are.same({ "foo", false }, { pp.partial("foo", ctx({ multiline = false })) })
    assert.are.same({ "foo", true }, { pp.partial("foo\nba", ctx({ multiline = false })) })
    assert.are.same({ "a\nb", false }, { pp.partial("a\nb", ctx()) })
    local d, done = pp.partial("return 1\nend\nlocal z", ctx({ before = "  " }))
    assert.equal("return 1\nend", d)
    assert.is_true(done)
    d, done = pp.partial("1\n2\n3\n4\n", ctx({ max_lines = 2 }))
    assert.equal("1\n2", d)
    assert.is_true(done)
  end)

  it("is_repetitive / tokens", function()
    assert.are.same({ "a", ".", "b", "(", ")" }, pp.tokens("a.b ()"))
    assert.is_true(pp.is_repetitive(string.rep("ab ", 20)))
    assert.is_false(pp.is_repetitive("local function foo(a, b) return a + b end"))
  end)

  it("is_closer", function()
    for _, l in ipairs({ "}", "  end", ")", "  });", "fi", "</div>", "} else {" }) do
      assert.is_true(pp.is_closer(l), l)
    end
    for _, l in ipairs({ "x = 1", "endpoint()", "return" }) do
      assert.is_false(pp.is_closer(l), l)
    end
  end)
end)

describe("complete.cache", function()
  local Cache
  before_each(function()
    h.reset()
    Cache = require("slop.modules.complete.cache")
  end)

  it("serves typed-through and backspaced prefixes with equal suffix", function()
    local c = Cache.new(3)
    c:put("local x = ", "\nend", { "foo(1)", "bar" })
    assert.are.same({ "foo(1)", "bar" }, c:get("local x = ", "\nend"))
    assert.are.same({ "o(1)" }, c:get("local x = fo", "\nend"))
    assert.is_nil(c:get("local x = foo(1)", "\nend"))
    assert.is_nil(c:get("local x = fo", "\nother"))
    assert.is_nil(c:get("local y = ", "\nend"))
  end)

  it("LRU size and replace", function()
    local c = Cache.new(2)
    c:put("a", "", { "1" })
    c:put("b", "", { "2" })
    c:put("c", "", { "3" })
    assert.is_nil(c:get("a", ""))
    c:put("b", "", { "22" })
    assert.are.same({ "22" }, c:get("b", ""))
    assert.equal(2, #c.entries)
    c:put("z", "", {})
    assert.equal(2, #c.entries)
    c:clear()
    assert.is_nil(c:get("b", ""))
  end)
end)

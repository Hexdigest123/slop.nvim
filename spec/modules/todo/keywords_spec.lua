-- todo keywords: the shared matcher, keyword groups, filters, search regexes, colors.
local h = require("helpers")

describe("todo keywords", function()
  local K, kw
  before_each(function()
    h.reset()
    vim.notify = function() end
    K = require("slop.modules.todo.keywords")
    kw = K.compile({ keywords = K.defaults })
  end)

  local function m(line)
    return vim.tbl_map(function(x)
      return { x.col, x.end_col, x.keyword, x.author, x.message }
    end, K.match(line, kw.by_word))
  end

  it("needs a word boundary and ':' or '(author)'", function()
    assert.are.same({ { 3, 8, "TODO", nil, "fix it" } }, m("-- TODO: fix it"))
    assert.are.same({ { 3, 14, "FIX", "alice", "broken" } }, m("-- FIX(alice): broken"))
    assert.are.same({ { 3, 13, "FIX", "alice", "broken" } }, m("-- FIX(alice) broken"))
    assert.are.same({}, m("-- TODO fix it"))
    assert.are.same({}, m("-- TODO : spaced"))
    assert.are.same({}, m("-- MYTODO: x"))
    assert.are.same({}, m("-- TODOS: x"))
    assert.are.same({}, m("-- todo: lowercase"))
    assert.are.same({}, m("-- TODO(unclosed: x"))
    assert.are.same({ { 0, 5, "TODO", nil, "" } }, m("TODO:"))
  end)

  it("finds aliases and several todos on one line", function()
    local r = K.match("// FIXME: a  NOTE: b XXX: c", kw.by_word)
    assert.are.same(
      { "FIXME", "NOTE", "XXX" },
      vim.tbl_map(function(x)
        return x.keyword
      end, r)
    )
    assert.are.same(
      { "FIX", "NOTE", "WARN" },
      vim.tbl_map(function(x)
        return x.group.name
      end, r)
    )
    assert.equal("a  NOTE: b XXX: c", r[1].message)
  end)

  it("compiles the todo-comments default groups with highlight names", function()
    assert.are.same({ "FIX", "HACK", "NOTE", "PERF", "TEST", "TODO", "WARN" }, kw.order)
    for _, w in ipairs({ "FIX", "FIXME", "BUG", "FIXIT", "ISSUE" }) do
      assert.equal("FIX", kw.by_word[w].name, w)
    end
    for _, w in ipairs({ "WARNING", "XXX", "OPTIM", "PERFORMANCE", "OPTIMIZE", "INFO", "TESTING", "PASSED", "FAILED" }) do
      assert.not_nil(kw.by_word[w], w)
    end
    assert.equal("SlopTodoFix", kw.groups.FIX.hl)
    assert.equal("SlopTodoFixText", kw.groups.FIX.hl_text)
    assert.equal("SlopTodoMyKw", K.hl_name("MY_KW"))
    assert.are.same({ link = "DiagnosticError" }, K.highlights.SlopTodoFix)
    assert.are.same({ link = "DiagnosticInfo" }, K.highlights.SlopTodoTodo)
    assert.are.same({ link = "SlopTodoWarn" }, K.highlights.SlopTodoWarnText)
  end)

  it("user keywords: add groups, override aliases, `false` removes a group", function()
    local cfg = {
      keywords = vim.tbl_extend("force", vim.deepcopy(K.defaults), {
        HACK = false,
        TODO = { color = "#ff0000", alt = { "LATER" } },
        SAFETY = { icon = "S", color = "hint", signs = false },
      }),
    }
    local k = K.compile(cfg)
    assert.is_nil(k.groups.HACK)
    assert.is_nil(k.by_word.HACK)
    assert.equal("TODO", k.by_word.LATER.name)
    assert.is_false(k.groups.SAFETY.signs)
    assert.equal("", k.groups.TODO.icon)
    assert.are.same({}, K.validate(cfg.keywords))
  end)

  it("validates keywords", function()
    local errs = K.validate({ ["BAD-NAME"] = {}, X = 1, Y = { alt = { "a b" }, color = 3, signs = "no" } })
    local text = table.concat(errs, "\n")
    assert.matches("keywords.BAD%-NAME: keyword names", text)
    assert.matches("keywords.X: expected table or false", text)
    assert.matches("keywords.Y.alt%[1%]", text)
    assert.matches("keywords.Y.color: expected string", text)
    assert.matches("keywords.Y.signs: expected boolean", text)
  end)

  it("keyword filters: group name includes aliases, alias alone, unknown reported", function()
    assert.are.same({ "TODO", "FIX", "NOTE" }, K.parse_filter("TODO,FIX NOTE"))
    assert.are.same({ "TODO", "FIX", "NOTE" }, K.parse_filter({ "keywords=TODO,FIX", "NOTE" }))
    local words, unknown = K.select(kw, { "FIX", "XXX", "NOPE" })
    assert.are.same({ "BUG", "FIX", "FIXIT", "FIXME", "ISSUE", "XXX" }, vim.fn.sort(vim.tbl_keys(words)))
    assert.are.same({ "NOPE" }, unknown)
    assert.equal(kw.by_word, (K.select(kw, {})))
  end)

  it("search regexes match exactly what the Lua matcher matches", function()
    local rg, ere = K.patterns({ TODO = true, FIX = true, FIXME = true })
    assert.equal([[\b(FIXME|TODO|FIX)(:|\([^)]*\))]], rg)
    assert.equal([[(^|[^[:alnum:]_])(FIXME|TODO|FIX)(:|\([^)]*\))]], ere)
    local lines = { "x -- TODO: a", "FIX(bob) b", "-- TODO c", "MYTODO: d", "FIXME:e" }
    local tmp = h.tmpdir("todo-re") .. "/f.txt"
    h.write(tmp, table.concat(lines, "\n") .. "\n")
    local res = vim.system({ "grep", "-nE", ere, tmp }, { text = true }):wait()
    local got = {}
    for l in vim.gsplit(vim.trim(res.stdout), "\n") do
      got[#got + 1] = tonumber(l:match("^(%d+):"))
    end
    assert.are.same({ 1, 2, 5 }, got)
  end)

  it("color_def: color name (first existing group), highlight group, #hex", function()
    assert.are.same({ link = "DiagnosticError" }, K.color_def("error", K.colors))
    assert.are.same({ link = "ErrorMsg" }, K.color_def("ErrorMsg", K.colors))
    assert.are.same({ fg = "#123456" }, K.color_def("#123456", K.colors))
    assert.are.same({ fg = "#abcdef" }, K.color_def("mine", { mine = { "NoSuchGroup", "#abcdef" } }))
    assert.are.same({ link = "Identifier" }, K.color_def("NoSuchGroup", K.colors))
  end)
end)

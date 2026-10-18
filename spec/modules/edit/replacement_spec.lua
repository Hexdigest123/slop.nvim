local h = require("helpers")

describe("edit replacement protocol", function()
  local R
  before_each(function()
    h.reset()
    R = require("slop.modules.edit.replacement")
  end)

  describe("from_tag", function()
    it("takes the last complete block and trims one newline at each edge", function()
      local msg =
        "Sure.\n<slop:replacement>\nold\n</slop:replacement>\nBetter:\n<slop:replacement>\n  a\n  b\n</slop:replacement>"
      assert.equal("  a\n  b", R.from_tag(msg))
    end)

    it("unwraps a fence that wraps the whole block, keeps empty blocks", function()
      assert.equal("x = 1", R.from_tag("<slop:replacement>\n```lua\nx = 1\n```\n</slop:replacement>"))
      assert.equal("", R.from_tag("<slop:replacement>\n</slop:replacement>"))
      assert.equal("inline", R.from_tag("<slop:replacement>inline</slop:replacement>"))
    end)

    it("reports unterminated blocks", function()
      local t, err = R.from_tag("<slop:replacement>\nhalf")
      assert.is_nil(t)
      assert.equal("unterminated", err)
      assert.is_nil(R.from_tag("no tags"))
    end)
  end)

  it("from_fence takes the last fenced block", function()
    assert.equal("two", R.from_fence("```\none\n```\ntext\n```lua\ntwo\n```\n"))
    assert.is_nil(R.from_fence("nothing"))
  end)

  describe("from_diffs", function()
    local ctx =
      { path = "/p/a.lua", old_text = "local a = 1\nlocal b = 2", file_before = "-- head\n", file_after = "\n-- tail" }

    it("applies a fragment diff that occurs once in the region", function()
      local d = { { path = "/p/a.lua", oldText = "b = 2", newText = "b = 3" } }
      assert.equal("local a = 1\nlocal b = 3", R.from_diffs(d, ctx))
    end)

    it("cuts a whole-file diff down to the region", function()
      local d = { { path = "/p/a.lua", oldText = "whatever", newText = "-- head\nNEW\n-- tail" } }
      assert.equal("NEW", R.from_diffs(d, ctx))
    end)

    it("ignores other files and unmatched diffs", function()
      assert.is_nil(R.from_diffs({ { path = "/p/b.lua", oldText = "b = 2", newText = "x" } }, ctx))
      assert.is_nil(R.from_diffs({ { path = "/p/a.lua", oldText = "zzz", newText = "x" } }, ctx))
    end)
  end)

  it("extract falls back tag -> diff -> fence -> error", function()
    local ctx = { path = "/a", old_text = "x" }
    assert.same({ "1", "tag" }, { R.extract("<slop:replacement>1</slop:replacement>\n```\n2\n```", ctx) })
    assert.same({ "y", "diff" }, { R.extract("```\n2\n```", ctx, { { path = "/a", oldText = "x", newText = "y" } }) })
    assert.same({ "2", "fence" }, { R.extract("here:\n```\n2\n```", ctx) })
    local t, err = R.extract("I cannot", ctx)
    assert.is_nil(t)
    assert.matches("did not return", err)
    t, err = R.extract("<slop:replacement>\ncut off", ctx)
    assert.matches("truncated", err)
  end)

  describe("validate", function()
    it("normalises CRLF and the trailing newline of linewise regions", function()
      assert.same({ "a", "b" }, R.validate("a\r\nb\n", { old_text = "x", linewise = true }))
      assert.same({ "a", "" }, R.validate("a\n", { old_text = "x", linewise = false }))
      assert.same({}, R.validate("", { old_text = "x", linewise = true }))
    end)

    it("rejects nested tags and secret placeholders the original did not contain", function()
      assert.is_nil((R.validate("<slop:replacement>", { old_text = "", linewise = true })))
      local _, err = R.validate("token = <redacted>", { old_text = "token = x", linewise = true })
      assert.matches("placeholder", err)
      assert.same({ "a <redacted>" }, R.validate("a <redacted>", { old_text = "a <redacted>", linewise = true }))
    end)

    it("restores a dropped base indentation", function()
      local old = "    if x then\n      y()\n    end"
      assert.same(
        { "    if x then", "      z()", "", "    end" },
        R.validate("if x then\n  z()\n\nend", { old_text = old, linewise = true })
      )
      assert.same({ "  kept" }, R.validate("  kept", { old_text = "    a", linewise = true }))
    end)
  end)

  describe("presets", function()
    it("merges user presets, removes false ones and parses #name", function()
      local P = require("slop.modules.edit.presets")
      local all = P.all({ explain = false, mine = { prompt = "Do it", desc = "mine" }, fix = { agent = "claude" } })
      assert.is_nil(all.explain)
      assert.equal("Do it", all.mine.prompt)
      assert.equal("claude", all.fix.agent)
      assert.is_true(all.fix.diagnostics)
      assert.equal("float", P.all().explain.sink)
      assert.equal("scratch", P.all().tests.sink)
      assert.same({ "mine", "extra words" }, { P.parse("#mine extra words", all) })
      assert.same({ nil, "#nope x" }, { P.parse("#nope x", all) })
      assert.truthy(vim.tbl_contains(P.names(), "optimize"))
    end)
  end)

  describe("prompt", function()
    it("contains the protocol, region, context, rules, diagnostics and files", function()
      local P = require("slop.modules.edit.prompt")
      local blocks, text = P.build({
        sink = "diff",
        path = "/r/a.lua",
        rel = "a.lua",
        filetype = "lua",
        srow = 3,
        erow = 4,
        region = { "x = 1", "y = 2" },
        before = { "-- before" },
        after = { "-- after" },
        instruction = "rename",
        rules = { { rel = "AGENTS.md", text = "use tabs" } },
        files = { { path = "/r/b.lua", rel = "b.lua", text = "B" } },
        diagnostics = { "line 4: [ERROR] boom" },
      })
      assert.equal(1, #blocks)
      for _, needle in ipairs({
        "<slop:replacement>",
        "lines 4-5",
        "<region>\nx = 1\ny = 2\n</region>",
        "<before>\n-- before\n</before>",
        '<project_rules path="AGENTS.md">\nuse tabs',
        '<file path="b.lua">\nB\n</file>',
        "line 4: [ERROR] boom",
        "Instruction: rename",
        "Do NOT edit, create, delete or move files",
      }) do
        assert.truthy(text:find(needle, 1, true), needle)
      end
      local eblocks = P.build({
        sink = "float",
        path = "/r/a.lua",
        rel = "a.lua",
        filetype = "lua",
        srow = 0,
        erow = 0,
        scol = 2,
        ecol = 5,
        region = { "abc" },
        before = {},
        after = {},
        instruction = "why?",
        files = { { path = "/r/b.lua", rel = "b.lua", text = "B" } },
        embedded = true,
      })
      assert.equal(2, #eblocks)
      assert.equal("resource", eblocks[2].type)
      assert.matches("Markdown", eblocks[1].text)
      assert.matches("byte column 3", eblocks[1].text)
      assert.equal(
        "Explain it\n\nAdditional instructions from the user: briefly",
        P.instruction({ prompt = "Explain it" }, " briefly ")
      )
    end)
  end)
end)

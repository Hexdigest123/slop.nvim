local h = require("helpers")

describe("doc prompt", function()
  local prompt, langs
  before_each(function()
    h.reset()
    require("slop").setup({})
    prompt = require("slop.modules.doc.prompt")
    langs = require("slop.modules.doc.langs")
  end)

  local function target(extra)
    return vim.tbl_extend("force", { buf = 0, indent = "  ", docstring = false, kind = "func", doc = {} }, extra or {})
  end

  local LUA_CODE = { "  local function add(a, b)", "    return a + b", "  end" }

  describe("parse", function()
    it("strips fences, keeps comment lines and re-indents", function()
      local text = "Here it is:\n```lua\n---Add two numbers.\n---@param a integer\n---@return integer\n```\nDone."
      local lines = prompt.parse(text, target(), LUA_CODE, langs.syntax.lua)
      assert.are.same({ "  ---Add two numbers.", "  ---@param a integer", "  ---@return integer" }, lines)
    end)

    it("drops <think> blocks and an unterminated fence", function()
      local text = "<think>let me see\n```lua\nlocal x\n```</think>```lua\n--- Sum.\n"
      assert.are.same({ "  --- Sum." }, prompt.parse(text, target(), LUA_CODE, langs.syntax.lua))
    end)

    it("drops echoed code after the comment", function()
      local text = "---Add.\nlocal function add(a, b)\n  return a + b\nend"
      assert.are.same({ "  ---Add." }, prompt.parse(text, target(), LUA_CODE, langs.syntax.lua))
    end)

    it("rejects code that is not an echo", function()
      local lines, err = prompt.parse("---Add.\nprint('hi')", target(), LUA_CODE, langs.syntax.lua)
      assert.is_nil(lines)
      assert.matches("code after the comment", err)
      lines, err = prompt.parse("local x = 1", target(), LUA_CODE, langs.syntax.lua)
      assert.is_nil(lines)
      assert.matches("not a comment", err)
      lines, err = prompt.parse("\n\n", target(), LUA_CODE, langs.syntax.lua)
      assert.is_nil(lines)
      assert.matches("empty", err)
    end)

    it("block comments keep their inner alignment", function()
      local text = "```c\n/**\n * @brief Add.\n * @return sum\n */\nint add(int a, int b);\n```"
      local code = { "int add(int a, int b) { return a + b; }" }
      local lines = prompt.parse(text, target({ indent = "\t" }), code, langs.syntax.c)
      assert.are.same({ "\t/**", "\t * @brief Add.", "\t * @return sum", "\t */" }, lines)
    end)

    it("a doc comment may contain ``` examples (rustdoc)", function()
      local text = "```rust\n/// Adds.\n///\n/// ```\n/// assert_eq!(add(1, 2), 3);\n/// ```\n```"
      local lines =
        prompt.parse(text, target({ indent = "" }), { "fn add(a: i32, b: i32) -> i32 {" }, langs.syntax.rust)
      assert.are.same({ "/// Adds.", "///", "/// ```", "/// assert_eq!(add(1, 2), 3);", "/// ```" }, lines)
    end)

    it("rejects an unterminated or trailing-code block comment", function()
      assert.is_nil((prompt.parse("/** Add.\n * more", target(), {}, langs.syntax.c)))
      assert.is_nil((prompt.parse("/** Add. */ int x;", target(), {}, langs.syntax.c)))
    end)

    it("commentstring fallback syntax", function()
      local syn = langs.syntax_for("unknownft", "; %s")
      assert.are.same({ "  ; Does a thing." }, prompt.parse("; Does a thing.", target(), {}, syn))
      assert.is_nil((prompt.parse("// nope", target(), {}, syn)))
    end)

    it("python docstrings: echoed header dropped, aligned to the body", function()
      local code = { "def add(a, b):", "    return a + b" }
      local t = target({ docstring = true, indent = "    " })
      local text = '```python\ndef add(a, b):\n    """Add a and b.\n\n    Returns:\n        The sum.\n    """\n'
        .. "    return a + b\n```"
      assert.are.same(
        { '    """Add a and b.', "", "    Returns:", "        The sum.", '    """' },
        prompt.parse(text, t, code)
      )
      assert.are.same({ '    """Add."""' }, prompt.parse('"""Add."""', t, code))
      assert.are.same({ "    r'''Add \\d.'''" }, prompt.parse("r'''Add \\d.'''", t, code))
    end)

    it("python: non-docstring answers are rejected", function()
      local t = target({ docstring = true, indent = "    " })
      local lines, err = prompt.parse("# Add a and b", t, {})
      assert.is_nil(lines)
      assert.matches("not a docstring", err)
      lines, err = prompt.parse('"""Add."""\nx = 1', t, {})
      assert.is_nil(lines)
      assert.matches("code after the docstring", err)
    end)
  end)

  describe("style", function()
    it("built-in per filetype, overridable by name or free text", function()
      assert.equal(prompt.STYLES.luals, prompt.style("lua", {}))
      assert.equal(prompt.STYLES.jsdoc, prompt.style("typescript", {}))
      assert.equal(prompt.STYLES.docstring, prompt.style("python", {}))
      assert.equal(prompt.STYLES.doxygen, prompt.style("lua", { lua = "doxygen" }))
      assert.equal("Plain prose only.", prompt.style("go", { go = "Plain prose only." }))
      assert.matches("`; `", prompt.style("unknownft", {}, "; %s"))
      assert.matches("<!%-%-", prompt.style("unknownft", {}, "<!-- %s -->"))
    end)

    it("every filetype default names an existing style", function()
      for ft, s in pairs(prompt.FILETYPES) do
        assert.not_nil(prompt.STYLES[s], ft)
      end
    end)

    it("system prompt carries the style and extra instructions", function()
      local sys = prompt.system(target(), "STYLE-X", "Write in French.")
      assert.matches("ONLY the doc comment", sys)
      assert.matches("STYLE%-X", sys)
      assert.matches("Extra instructions: Write in French%.", sys)
      assert.matches("existing doc comment", sys)
      assert.falsy(prompt.system(target(), "S", "  "):find("Extra instructions", 1, true))
      assert.matches("docstring", prompt.system(target({ docstring = true }), "S"))
    end)
  end)

  describe("message", function()
    it("includes path, kind, context, code and the existing doc, redacted and budgeted", function()
      local root = h.tmpdir("docmsg")
      vim.fn.mkdir(root .. "/.git", "p")
      local lines = { "local secret = require('x')" }
      for i = 1, 50 do
        lines[#lines + 1] = ("local v%d = %d"):format(i, i)
      end
      vim.list_extend(lines, {
        "---Old doc.",
        "local function f()",
        "  return 'tok'",
        "end",
        "local after = 1",
      })
      local buf = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
      vim.api.nvim_buf_set_name(buf, root .. "/lua/m.lua")
      vim.bo[buf].filetype = "lua"
      vim.api.nvim_set_current_buf(buf)
      require("slop.core.secrets").register({
        name = "test",
        spans = function(_, ls, first)
          local out = {}
          for i, l in ipairs(ls) do
            local s, e = l:find("tok", 1, true)
            if s then
              out[#out + 1] = { row = first + i - 1, col = s - 1, end_col = e }
            end
          end
          return out
        end,
      })
      local t = assert(require("slop").doc.find(buf, { 52, 0 }))
      local msg = prompt.message(t, { context_lines = 10, max_chars = 16000 })
      assert.matches("File: lua/m%.lua %(filetype lua%)", msg)
      assert.matches("Document the function `f` %(lines 53%-55%)", msg)
      assert.matches("local secret = require", msg) -- file head
      assert.matches("local v50 = 50", msg) -- lines before
      assert.falsy(msg:find("local v20 = 20", 1, true)) -- outside the context window
      assert.matches("local after = 1", msg)
      assert.matches("Existing doc comment %(update it%):\n```lua\n%-%-%-Old doc%.\n```", msg)
      assert.falsy(msg:find("tok", 1, true))
      assert.matches("<redacted>", msg)

      local short = prompt.message(t, { context_lines = 0, max_chars = 500 })
      assert.falsy(short:find("Surrounding code", 1, true))
      assert.matches("Code to document", short)
    end)
  end)
end)

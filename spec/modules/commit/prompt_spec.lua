local h = require("helpers")

local function section(path, added, removed)
  local l = { ("diff --git a/%s b/%s"):format(path, path), "--- a/" .. path, "+++ b/" .. path, "@@ -1 +1 @@" }
  for i = 1, removed or 0 do
    l[#l + 1] = "-old line " .. i
  end
  for i = 1, added or 0 do
    l[#l + 1] = "+new line number " .. i
  end
  return table.concat(l, "\n") .. "\n"
end

describe("commit.prompt", function()
  local prompt
  before_each(function()
    h.reset()
    prompt = require("slop.modules.commit.prompt")
  end)

  describe("build", function()
    local ctx = {
      repo = "slop.nvim",
      branch = "feat/JIRA-7-commit",
      user_commits = { "feat(term): float toggle" },
      repo_commits = { "fix(core/http): cancel on timeout", "feat(term): float toggle" },
      diff = section("a.lua", 1, 1),
      style = "conventional",
      textwidth = 72,
      conventions = "Scopes are module names.",
      instructions = "Mention tests.",
    }

    it("ports the VS Code prompt: system rules + tagged user message", function()
      local msgs = prompt.build(ctx)
      assert.equal(2, #msgs)
      assert.equal("system", msgs[1].role)
      assert.matches("best git commit message", msgs[1].content)
      assert.matches("```text codeblock", msgs[1].content)
      local u = msgs[2].content
      assert.equal("user", msgs[2].role)
      assert.matches(
        "<repository%-context>\n# REPOSITORY DETAILS:\nRepository name: slop%.nvim\nBranch name: feat/JIRA%-7%-commit",
        u
      )
      assert.matches(
        "<user%-commits>\n# RECENT USER COMMITS %(For reference only, do not copy!%):\n%- feat%(term%): float toggle",
        u
      )
      assert.matches("# RECENT REPOSITORY COMMITS", u)
      assert.matches("<changes>\n<code%-changes>\n# CODE CHANGES:\n```diff\ndiff %-%-git a/a%.lua b/a%.lua", u)
      assert.matches("<reminder>\nNow generate a commit message", u)
      assert.matches("<custom%-instructions>", u)
      assert.matches("Conventional Commits", u)
      assert.matches("Wrap body lines at 72", u)
      assert.matches("Scopes are module names%.", u)
      assert.matches("Mention tests%.", u)
      assert.falsy(u:find("ORIGINAL CODE", 1, true))
    end)

    it("omits empty blocks and adds amend / changed-files blocks when relevant", function()
      local u = prompt.build({ repo = "r", diff = section("x", 1), files = {}, user_commits = {} })[2].content
      assert.falsy(u:find("<user-commits>", 1, true))
      assert.falsy(u:find("<recent-commits>", 1, true))
      assert.falsy(u:find("Branch name", 1, true))
      assert.falsy(u:find("<amended-commit>", 1, true))
      assert.matches("Follow the conventions of the RECENT REPOSITORY COMMITS", u)
      u = prompt.build({
        repo = "r",
        diff = "d",
        previous = { "feat: old message" },
        cut = true,
        files = { { path = "big.txt", added = 900, removed = 3, note = "truncated" } },
      })[2].content
      assert.matches("<amended%-commit>\n# MESSAGE OF THE COMMIT BEING AMENDED.-feat: old message", u)
      assert.matches("%- big%.txt %(%+900 %-3%) %[truncated%]", u)
    end)

    it("uses a longer fence when the diff itself contains ```", function()
      local u = prompt.build({ repo = "r", diff = section("README.md", 0) .. "+```lua\n" })[2].content
      assert.matches("````diff\n", u)
    end)
  end)

  describe("parse_reply", function()
    it("extracts the ```text block and ignores prose around it", function()
      local lines = prompt.parse_reply("Here you go:\n\n```text\nfeat: add x\n\nWhy it matters.\n```\nHope it helps")
      assert.same({ "feat: add x", "", "Why it matters." }, lines)
    end)

    it("falls back to any fenced block, then the raw reply", function()
      assert.same({ "fix: y" }, prompt.parse_reply("```\nfix: y\n```"))
      assert.same({ "fix: raw", "", "body" }, prompt.parse_reply("\nfix: raw\n\n\n\nbody\n"))
    end)

    it("drops comment lines (git would strip them) with the given comment char", function()
      assert.same({ "feat: a", "", "b" }, prompt.parse_reply("```text\nfeat: a\n# note\n\nb\n```"))
      assert.same({ "#123 fixed", "", "b" }, prompt.parse_reply("#123 fixed\n; c\n\nb", { comment_char = ";" }))
    end)

    it("tolerates partial streams", function()
      assert.same({}, prompt.parse_reply("``", { partial = true }))
      assert.same({}, prompt.parse_reply("```tex", { partial = true }))
      assert.same({ "feat: par" }, prompt.parse_reply("```text\nfeat: par", { partial = true }))
      assert.same({ "feat: x", "", "bo" }, prompt.parse_reply("```text\nfeat: x\n\nbo\n``", { partial = true }))
    end)

    it("wraps the body (not the subject) at textwidth with hanging bullets", function()
      local long = ("word "):rep(20)
      local lines = prompt.parse_reply(
        "```text\nfeat: " .. long .. "\n\n" .. long .. "\n- " .. long .. "\nSigned-off-by: " .. long .. "\n```",
        { wrap = true, textwidth = 30 }
      )
      assert.equal("feat: " .. vim.trim(long), lines[1])
      for i = 3, #lines - 1 do
        assert.truthy(#lines[i] <= 30, lines[i])
      end
      local bullet
      for i, l in ipairs(lines) do
        if vim.startswith(l, "- ") then
          bullet = i
        end
      end
      assert.matches("^  word", lines[bullet + 1])
      assert.matches("^Signed%-off%-by: ", lines[#lines])
    end)
  end)

  describe("sanitize_diff / budget_diff", function()
    it("drops sections with unreadable headers and leading noise", function()
      local d, n = prompt.sanitize_diff('noise\ndiff --git "a/x\\ty" "b/x\\ty"\n+secret\n' .. section("ok.txt", 1))
      assert.equal(1, n)
      assert.falsy(d:find("secret", 1, true))
      assert.falsy(d:find("noise", 1, true))
      assert.matches("unreadable path omitted", d)
      assert.matches("diff %-%-git a/ok%.txt", d)
    end)

    it("keeps small diffs untouched", function()
      local diff = section("a.txt", 2, 1) .. section("b.txt", 1)
      local out, files, cut = prompt.budget_diff(diff, { max_chars = 10000, summarize = {} })
      assert.equal(diff, out)
      assert.is_false(cut)
      assert.same({ path = "a.txt", added = 2, removed = 1 }, files[1])
    end)

    it("summarises lock files and shares the budget per file", function()
      local diff = section("small.txt", 2) .. section("huge.txt", 400) .. section("package-lock.json", 300)
      local out, files, cut = prompt.budget_diff(diff, { max_chars = 2000, summarize = { "package-lock.json" } })
      assert.is_true(cut)
      assert.truthy(#out <= 2000, #out)
      assert.truthy(out:find(section("small.txt", 2), 1, true), "small file kept whole")
      assert.matches("diff truncated: %+400 %-0 lines", out)
      assert.matches("package%-lock%.json\n%[slop: diff omitted %(generated or lock file%): %+300 %-0 lines%]", out)
      assert.equal("truncated", files[2].note)
      assert.equal("summarized", files[3].note)
    end)

    it("summarises files whose share is too small to be useful", function()
      local diff = ""
      for i = 1, 30 do
        diff = diff .. section("f" .. i .. ".txt", 50)
      end
      local out, files = prompt.budget_diff(diff, { max_chars = 3000, summarize = {} })
      assert.truthy(#out <= 3000 + 200, #out)
      assert.equal("omitted", files[1].note)
      assert.matches("too large", out)
    end)
  end)

  describe("redact_hunks", function()
    it("applies multi-line rules (PEM blocks) across a hunk's lines", function()
      local diff = table.concat({
        "diff --git a/k.txt b/k.txt",
        "--- /dev/null",
        "+++ b/k.txt",
        "@@ -0,0 +1,4 @@",
        "+-----BEGIN RSA PRIVATE KEY-----",
        "+MIIEsecretbody",
        "+-----END RSA PRIVATE KEY-----",
        "+after",
        "\\ No newline at end of file",
      }, "\n")
      local out, n = prompt.redact_hunks(diff)
      assert.equal(1, n)
      assert.falsy(out:find("MIIEsecretbody", 1, true))
      assert.matches("\n%+<redacted>\n", out)
      assert.matches("\n%+after\n", out)
      assert.matches("No newline at end of file$", out)
      assert.matches("^diff %-%-git a/k%.txt b/k%.txt\n%-%-%- /dev/null\n%+%+%+ b/k%.txt\n@@", out)
    end)
  end)

  describe("redaction (core.secrets) on the commit path", function()
    it("blocked files are omitted and provider spans redacted before budgeting", function()
      local secrets = require("slop.core.secrets")
      secrets.register({
        name = "commit_spec",
        spans = function(_, lines, first)
          local out = {}
          for i, l in ipairs(lines) do
            local s, e = l:find("tok_%w+")
            if s then
              out[#out + 1] = { row = first + i - 1, col = s - 1, end_col = e }
            end
          end
          return out
        end,
      })
      local diff = section(".env", 1)
        .. "diff --git a/cfg.lua b/cfg.lua\n--- a/cfg.lua\n+++ b/cfg.lua\n@@ -0,0 +1 @@\n+local key = 'tok_abc123'\n"
      local red = secrets.redact_diff(prompt.sanitize_diff(diff))
      local out = prompt.budget_diff(red, { max_chars = 10000, summarize = {} })
      assert.falsy(out:find("new line number", 1, true), ".env content never sent")
      assert.matches("%[slop: diff of %.env omitted%]", out)
      assert.falsy(out:find("tok_abc123", 1, true))
      assert.matches("<redacted>", out)
    end)
  end)
end)

local h = require("helpers")

vim.env.GIT_CONFIG_GLOBAL = "/dev/null" -- isolate from the user's git config (hooks, templates, verbose)
vim.env.GIT_CONFIG_NOSYSTEM = "1"

local function sh(dir, args, env)
  local cmd = { "git" }
  vim.list_extend(cmd, args)
  local res = vim.system(cmd, { cwd = dir, env = env, text = true }):wait(10000)
  assert(res.code == 0, table.concat(args, " ") .. ": " .. tostring(res.stderr))
  return res.stdout
end

local function repo()
  local dir = h.tmpdir("repo")
  sh(dir, { "init", "-q", "-b", "main" })
  sh(dir, { "config", "user.email", "me@example.com" })
  sh(dir, { "config", "user.name", "Me" })
  sh(dir, { "config", "commit.gpgsign", "false" })
  h.write(dir .. "/a.txt", "one\n")
  sh(dir, { "add", "a.txt" })
  sh(dir, { "commit", "-q", "-m", "feat(core): first commit" })
  return dir
end

local TEMPLATE = {
  "",
  "# Please enter the commit message for your changes. Lines starting",
  "# with '#' will be ignored, and an empty message aborts the commit.",
  "#",
  "# On branch main",
}

--- Fake services.ai.chat: records requests; the test drives the stream.
local function fake_ai()
  local ai = require("slop.services.ai")
  local calls = {}
  ai.chat = function(req)
    local call = { req = req, cancelled = false, text = "" }
    call.handle = {
      cancel = function()
        call.cancelled = true
      end,
      is_active = function()
        return not call.cancelled
      end,
    }
    function call.chunk(delta)
      call.text = call.text .. delta
      req.on_chunk(delta, call.text)
    end
    function call.done(text, err)
      req.on_done(text or call.text, err)
    end
    calls[#calls + 1] = call
    return call.handle
  end
  return calls
end

local function wait(fn, msg)
  assert(vim.wait(5000, fn, 5), msg or "timed out")
end

local function lines(buf)
  return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
end

describe("commit module", function()
  local dir, calls, commit, ghost

  local function open(content)
    local path = dir .. "/.git/COMMIT_EDITMSG"
    h.write(path, table.concat(content or TEMPLATE, "\n") .. "\n")
    vim.cmd.edit(path)
    local buf = vim.api.nvim_get_current_buf()
    vim.bo[buf].filetype = "gitcommit"
    return buf
  end

  before_each(function()
    h.reset()
    vim.env.GIT_INDEX_FILE = nil
    pcall(vim.cmd, "silent! %bwipeout!")
    dir = repo()
    vim.cmd.cd(dir)
    require("slop").setup({})
    calls = fake_ai()
    commit = assert(require("slop.core.registry").load("commit"))
    ghost = require("slop.core.ui.ghost")
  end)

  it("generates on FileType gitcommit and streams ghost text at line 1", function()
    h.write(dir .. "/a.txt", "one\ntwo\n")
    sh(dir, { "add", "a.txt" })
    h.write(dir .. "/unstaged.txt", "not staged\n")
    local buf = open()
    wait(function()
      return #calls == 1
    end, "ai.chat was not called")
    local req = calls[1].req
    assert.equal("mistral_chat", req.provider)
    assert.is_true(req.stream)
    assert.equal(0.3, req.temperature)
    local user = req.messages[2].content
    assert.matches("Repository name: " .. vim.pesc(vim.fs.basename(dir)), user)
    assert.matches("Branch name: main", user)
    assert.matches("%- feat%(core%): first commit", user)
    assert.matches("%+two", user)
    assert.falsy(user:find("unstaged.txt", 1, true))
    assert.equal("streaming", commit.state(buf).status)

    calls[1].chunk("```text\nfeat: add")
    local g = ghost.get(buf)
    assert.not_nil(g)
    assert.equal(0, g.row)
    assert.equal(0, g.col)
    assert.same({ "feat: add" }, g.lines)
    calls[1].chunk(" two\n\nAdd the second line.\n```")
    calls[1].done()
    local st = commit.state(buf)
    assert.equal("done", st.status)
    assert.equal("index", st.source)
    assert.same({ { "feat: add two", "", "Add the second line." } }, st.variants)
    assert.same({ "feat: add two", "", "Add the second line." }, ghost.get(buf).lines)
    assert.equal("", lines(buf)[1], "nothing inserted before accept")

    local accepted
    require("slop.core.events").on("commit", "Accepted", function(data)
      accepted = data
    end)
    assert.is_true(commit.accept(buf))
    local l = lines(buf)
    assert.same({ "feat: add two", "", "Add the second line." }, { l[1], l[2], l[3] })
    assert.equal(TEMPLATE[2], l[4])
    assert.is_false(ghost.is_visible(buf))
    wait(function()
      return accepted ~= nil
    end)
    assert.equal(buf, accepted.buf)
    assert.equal("accepted", commit.state(buf).status)
  end)

  it("does nothing automatically when the message area is not empty", function()
    sh(dir, { "commit", "-q", "--allow-empty", "-m", "chore: other" })
    local buf = open({ "fix: already written", "", "# comment" })
    vim.wait(200)
    assert.equal(0, #calls)
    assert.equal("idle", commit.state(buf).status)
  end)

  it("redacts secrets in the diff before it reaches ai.chat", function()
    h.write(dir .. "/.env", "API_KEY=supersecretvalue\n")
    h.write(dir .. "/key.txt", "-----BEGIN RSA PRIVATE KEY-----\nMIIEsecretbody\n-----END RSA PRIVATE KEY-----\n")
    h.write(dir .. "/ok.txt", "fine\n")
    sh(dir, { "add", "-f", ".env", "key.txt", "ok.txt" })
    open()
    wait(function()
      return #calls == 1
    end)
    local user = calls[1].req.messages[2].content
    assert.falsy(user:find("supersecretvalue", 1, true))
    assert.falsy(user:find("MIIEsecretbody", 1, true))
    assert.matches("%[slop: diff of %.env omitted%]", user)
    assert.matches("%+<redacted>", user)
    assert.matches("%+fine", user)
  end)

  it("discards a stale result when the user typed a message meanwhile", function()
    h.write(dir .. "/a.txt", "x\n")
    sh(dir, { "add", "a.txt" })
    local buf = open()
    wait(function()
      return #calls == 1
    end)
    calls[1].chunk("```text\nfeat: partial")
    assert.is_true(commit.is_visible(buf))
    vim.api.nvim_buf_set_lines(buf, 0, 1, false, { "my own message" })
    vim.api.nvim_exec_autocmds("TextChanged", { buffer = buf })
    assert.is_true(calls[1].cancelled)
    assert.is_false(ghost.is_visible(buf))
    calls[1].done("```text\nfeat: late\n```")
    assert.is_false(ghost.is_visible(buf))
    assert.equal("my own message", lines(buf)[1])
    assert.equal("stale", commit.state(buf).status)
  end)

  it("regenerates variants with a rising temperature and cycles them with next/prev", function()
    h.write(dir .. "/a.txt", "y\n")
    sh(dir, { "add", "a.txt" })
    local buf = open()
    wait(function()
      return #calls == 1
    end)
    calls[1].done("```text\nfeat: one\n```")
    assert.is_true(commit.regenerate(buf))
    assert.equal(2, #calls, "regenerate reuses the gathered context")
    assert.equal(0.6, calls[2].req.temperature)
    calls[2].done("```text\nfeat: two\n```")
    assert.same({ "feat: two" }, ghost.get(buf).lines)
    assert.same({ 2, 2 }, ghost.get(buf).counter)
    assert.is_true(commit.prev(buf))
    assert.same({ "feat: one" }, ghost.get(buf).lines)
    assert.is_true(commit.prev(buf))
    assert.same({ "feat: two" }, ghost.get(buf).lines, "prev wraps")
    assert.is_true(commit.next(buf))
    assert.equal(3, #calls, "next past the last variant asks for a new one")
    assert.truthy(math.abs(calls[3].req.temperature - 0.9) < 1e-9)
    calls[3].done("```text\nfeat: three\n```")
    assert.equal(3, #commit.state(buf).variants)

    -- regenerate with a typed message replaces it (one undo step)
    assert.is_true(commit.accept(buf))
    assert.equal("feat: three", lines(buf)[1])
    assert.is_true(commit.regenerate(buf))
    assert.equal("", lines(buf)[1])
    assert.equal(TEMPLATE[2], lines(buf)[2])
    assert.equal(4, #calls)
  end)

  it("binds buffer-local accept/dismiss keys that fall through without a suggestion", function()
    h.write(dir .. "/a.txt", "z\n")
    sh(dir, { "add", "a.txt" })
    local buf = open()
    wait(function()
      return #calls == 1
    end)
    for _, lhs in ipairs({ "<C-y>", "<C-e>", "<C-n>", "<C-p>", " ac" }) do
      local m = vim.fn.maparg(lhs, "n", false, true)
      assert.equal(1, m.buffer, lhs .. " is buffer-local")
    end
    assert.equal(1, vim.fn.maparg("<C-y>", "i", false, true).buffer)
    calls[1].done("```text\nfix: zed\n```")
    h.feed("<C-e>")
    assert.is_false(ghost.is_visible(buf))
    assert.equal("dismissed", commit.state(buf).status)
    h.feed("<C-y>") -- falls through (native scroll), nothing inserted
    assert.equal("", lines(buf)[1])
    commit.next(buf) -- nothing visible -> false, no request
    assert.equal(1, #calls)
    h.feed(" ac")
    assert.equal(2, #calls)
    calls[2].done("```text\nfix: again\n```")
    h.feed("<C-y>")
    assert.equal("fix: again", lines(buf)[1])
  end)

  it("reads the diff from the verbose scissors section when present", function()
    local content = vim.list_extend(vim.deepcopy(TEMPLATE), {
      "# ------------------------ >8 ------------------------",
      "# Do not modify or remove the line above.",
      "# Everything below it will be ignored.",
      "diff --git a/verbose.txt b/verbose.txt",
      "new file mode 100644",
      "--- /dev/null",
      "+++ b/verbose.txt",
      "@@ -0,0 +1 @@",
      "+from the scissors section",
    })
    local buf = open(content)
    wait(function()
      return #calls == 1
    end)
    assert.equal("verbose", commit.state(buf).source)
    assert.matches("%+from the scissors section", calls[1].req.messages[2].content)
  end)

  it("honours GIT_INDEX_FILE exported by `git commit -a/<paths>`", function()
    local idx = h.tmpdir("idx") .. "/index"
    vim.uv.fs_copyfile(dir .. "/.git/index", idx)
    h.write(dir .. "/temp.txt", "temporary index\n")
    sh(dir, { "add", "temp.txt" }, { GIT_INDEX_FILE = idx })
    vim.env.GIT_INDEX_FILE = idx
    open()
    wait(function()
      return #calls == 1
    end)
    vim.env.GIT_INDEX_FILE = nil
    assert.matches("%+temporary index", calls[1].req.messages[2].content)
  end)

  it("detects an amend (message == HEAD's) and sends the amended commit's diff", function()
    local buf = open({ "feat(core): first commit", "", "# Please enter the commit message" })
    vim.wait(100)
    assert.equal(0, #calls)
    assert.is_true(commit.regenerate(buf))
    wait(function()
      return #calls == 1
    end)
    local st = commit.state(buf)
    assert.is_true(st.amend)
    assert.equal("amend", st.source)
    local user = calls[1].req.messages[2].content
    assert.matches("%+one", user, "diff against the amended commit's parent")
    assert.matches("<amended%-commit>.-feat%(core%): first commit", user)
  end)

  it("includes <root>/.nvim/commit.md and config instructions", function()
    h.write(dir .. "/.nvim/commit.md", "Always use the scope `core`.\n")
    require("slop").setup({ commit = { instructions = "Keep it short.", style = "plain" } })
    h.write(dir .. "/a.txt", "w\n")
    sh(dir, { "add", "a.txt" })
    open()
    wait(function()
      return #calls == 1
    end)
    local user = calls[1].req.messages[2].content
    assert.matches("Always use the scope `core`%.", user)
    assert.matches("Keep it short%.", user)
    assert.matches("Do not use Conventional Commits prefixes", user)
  end)

  it("reports provider errors without leaving a ghost behind", function()
    h.write(dir .. "/a.txt", "e\n")
    sh(dir, { "add", "a.txt" })
    local buf = open()
    wait(function()
      return #calls == 1
    end)
    calls[1].done(nil, { kind = "config", message = "$MISTRAL_API_KEY is not set" })
    local st = commit.state(buf)
    assert.equal("error", st.status)
    assert.matches("MISTRAL_API_KEY", st.error)
    assert.is_false(ghost.is_visible(buf))
    local found = false
    for _, e in ipairs(require("slop.core.log").entries({ scope = "commit" })) do
      found = found or e.msg:find("MISTRAL_API_KEY", 1, true) ~= nil
    end
    assert.is_true(found)
  end)

  it("tells the user when nothing is staged (explicit request)", function()
    local buf = open()
    vim.wait(300)
    assert.equal(0, #calls)
    assert.is_true(commit.generate(buf, { explicit = true }))
    wait(function()
      return commit.state(buf).status == "idle"
    end)
    assert.equal(0, #calls)
    local found = false
    for _, e in ipairs(require("slop.core.log").entries({ scope = "commit" })) do
      found = found or e.msg:find("no staged changes", 1, true) ~= nil
    end
    assert.is_true(found)
  end)

  it("does not attach to non-gitcommit buffers", function()
    vim.cmd.enew()
    assert.is_false(commit.generate(0))
    assert.is_nil(commit.state(0))
  end)
end)

local h = require("helpers")

--- Run git synchronously (tests only).
local function sh(dir, args, env)
  local cmd = { "git", "-c", "core.quotepath=off" }
  vim.list_extend(cmd, args)
  local res = vim.system(cmd, { cwd = dir, env = env, text = true }):wait(10000)
  assert(res.code == 0, table.concat(args, " ") .. ": " .. tostring(res.stderr))
  return res.stdout
end

local function repo(name)
  local dir = h.tmpdir(name or "repo")
  sh(dir, { "init", "-q", "-b", "main" })
  sh(dir, { "config", "user.email", "me@example.com" })
  sh(dir, { "config", "user.name", "Me" })
  sh(dir, { "config", "commit.gpgsign", "false" })
  return dir
end

local function commit(dir, file, text, msg, author)
  h.write(dir .. "/" .. file, text)
  sh(dir, { "add", file })
  local args = { "commit", "-q", "-m", msg }
  if author then
    vim.list_extend(args, { "--author", author })
  end
  sh(dir, args)
end

--- Call an async git.* function and wait for its callback.
local function await(fn, ...)
  local out, done = nil, false
  local args = { ... }
  args[#args + 1] = function(...)
    out = { ... }
    done = true
  end
  fn(unpack(args))
  assert(
    vim.wait(10000, function()
      return done
    end, 5),
    "callback never ran"
  )
  return unpack(out)
end

describe("core.git", function()
  local git
  before_each(function()
    h.reset()
    vim.env.GIT_INDEX_FILE = nil
    git = require("slop.core.git")
  end)

  describe("root / git_dir", function()
    it("finds the work tree from a file, a COMMIT_EDITMSG path and a directory", function()
      local dir = repo()
      h.write(dir .. "/src/a.lua", "x")
      assert.equal(dir, git.root(dir .. "/src/a.lua"))
      assert.equal(dir, git.root(dir .. "/.git/COMMIT_EDITMSG"))
      assert.equal(dir .. "/.git", git.git_dir(dir .. "/.git/COMMIT_EDITMSG"))
      assert.equal(dir .. "/.git", git.git_dir(dir .. "/src/a.lua"))
      assert.equal(dir, git.root(dir .. "/src"))
    end)

    it("handles buffers, b:git_dir (fugitive) and fugitive:// names", function()
      local dir = repo()
      local other = h.tmpdir("plain")
      vim.cmd.cd(other)
      h.write(dir .. "/.git/COMMIT_EDITMSG", "\n# comment\n")
      vim.cmd.edit(dir .. "/.git/COMMIT_EDITMSG")
      assert.equal(dir, git.root(0))
      assert.equal(dir, git.root())
      local scratch = vim.api.nvim_create_buf(false, true)
      vim.b[scratch].git_dir = dir .. "/.git"
      assert.equal(dir, git.root(scratch))
      assert.equal(dir, git.root("fugitive://" .. dir .. "/.git//0/src/a.lua"))
    end)

    it("maps a linked worktree's COMMIT_EDITMSG to that worktree", function()
      local dir = repo()
      commit(dir, "a.txt", "a\n", "init")
      local wt = h.tmpdir("wt") .. "/tree"
      sh(dir, { "worktree", "add", "-q", wt })
      local gd = vim.fs.normalize(vim.trim(sh(wt, { "rev-parse", "--absolute-git-dir" })))
      assert.equal(wt, git.root(gd .. "/COMMIT_EDITMSG"))
      assert.equal(gd, git.git_dir(wt .. "/a.txt"))
      assert.equal(wt, git.root(wt .. "/a.txt"))
    end)

    it("returns nil outside a repository", function()
      local other = h.tmpdir("plain")
      vim.cmd.cd(other)
      assert.is_nil(git.root(other .. "/x.txt"))
    end)
  end)

  describe("staged_diff", function()
    local dir
    before_each(function()
      dir = repo()
      commit(dir, "a.txt", "one\n", "feat: first")
    end)

    it("returns only staged changes, with a/ b/ prefixes even with odd diff config", function()
      sh(dir, { "config", "diff.mnemonicPrefix", "true" })
      sh(dir, { "config", "diff.noprefix", "true" })
      h.write(dir .. "/a.txt", "one\ntwo\n")
      sh(dir, { "add", "a.txt" })
      h.write(dir .. "/b.txt", "unstaged\n")
      local diff, err = await(git.staged_diff, { cwd = dir })
      assert.is_nil(err)
      assert.matches("diff %-%-git a/a%.txt b/a%.txt", diff)
      assert.matches("\n%+two\n", diff)
      assert.falsy(diff:find("b.txt", 1, true))
    end)

    it("is empty when nothing is staged and falls back to the work tree on request", function()
      h.write(dir .. "/a.txt", "one\nchanged\n")
      assert.equal("", (await(git.staged_diff, { cwd = dir })))
      local diff = await(git.staged_diff, { cwd = dir, worktree = true })
      assert.matches("%+changed", diff)
    end)

    it("honours GIT_INDEX_FILE (opts.env and the inherited environment)", function()
      local idx = h.tmpdir("idx") .. "/index"
      vim.uv.fs_copyfile(dir .. "/.git/index", idx)
      h.write(dir .. "/c.txt", "temp index\n")
      sh(dir, { "add", "c.txt" }, { GIT_INDEX_FILE = idx })
      assert.equal("", (await(git.staged_diff, { cwd = dir })))
      local diff = await(git.staged_diff, { cwd = dir, env = { GIT_INDEX_FILE = idx } })
      assert.matches("b/c%.txt", diff)
      vim.env.GIT_INDEX_FILE = idx
      diff = await(git.staged_diff, { cwd = dir })
      vim.env.GIT_INDEX_FILE = nil
      assert.matches("%+temp index", diff)
    end)

    it("amend diffs the index against the amended commit's parent", function()
      commit(dir, "b.txt", "bee\n", "feat: second")
      h.write(dir .. "/a.txt", "one\nmore\n")
      sh(dir, { "add", "a.txt" })
      local diff = await(git.staged_diff, { cwd = dir, amend = true })
      assert.matches("b/b%.txt", diff, "includes the amended commit's own changes")
      assert.matches("%+more", diff, "and what is staged now")
      local plain = await(git.staged_diff, { cwd = dir })
      assert.falsy(plain:find("b.txt", 1, true))
    end)

    it("amend of a root commit diffs against the empty tree", function()
      local diff = await(git.staged_diff, { cwd = dir, amend = true })
      assert.matches("new file mode", diff)
      assert.matches("%+one", diff)
    end)

    it("works on an unborn branch", function()
      local fresh = repo("fresh")
      h.write(fresh .. "/n.txt", "new\n")
      sh(fresh, { "add", "n.txt" })
      local diff = await(git.staged_diff, { cwd = fresh })
      assert.matches("%+new", diff)
    end)

    it("reports git errors", function()
      local other = h.tmpdir("plain")
      local diff, err = await(git.staged_diff, { cwd = other })
      assert.is_nil(diff)
      assert.matches("git diff failed", err)
    end)
  end)

  describe("branch / log / config", function()
    it("branch: name, unborn and detached", function()
      local dir = repo()
      assert.equal("main", (await(git.branch, { cwd = dir })))
      commit(dir, "a.txt", "a\n", "init")
      sh(dir, { "checkout", "-q", "-b", "feat/JIRA-1-thing" })
      assert.equal("feat/JIRA-1-thing", (await(git.branch, { cwd = dir })))
      sh(dir, { "checkout", "-q", "--detach" })
      local b, err = await(git.branch, { cwd = dir })
      assert.is_nil(b)
      assert.is_nil(err)
    end)

    it("log returns subjects newest first and {} for an unborn HEAD", function()
      local dir = repo()
      assert.same({}, (await(git.log, { cwd = dir })))
      commit(dir, "a.txt", "1\n", "feat: one\n\nbody")
      commit(dir, "a.txt", "2\n", "fix: two")
      commit(dir, "a.txt", "3\n", "docs: three")
      assert.same({ "docs: three", "fix: two" }, (await(git.log, { cwd = dir, n = 2 })))
      assert.same({}, (await(git.log, { cwd = dir, n = 0 })))
    end)

    it("recent_commits splits the user's own subjects from the repository's", function()
      local dir = repo()
      commit(dir, "a.txt", "1\n", "chore: theirs", "Other <other@example.com>")
      commit(dir, "a.txt", "2\n", "feat: mine")
      commit(dir, "a.txt", "3\n", "fix: theirs again", "Other <other@example.com>")
      local rc = await(git.recent_commits, { cwd = dir, n = 5 })
      assert.same({ "feat: mine" }, rc.user)
      assert.same({ "fix: theirs again", "feat: mine", "chore: theirs" }, rc.repo)
    end)

    it("config_get returns values and nil when unset", function()
      local dir = repo()
      assert.equal("me@example.com", (await(git.config_get, "user.email", { cwd = dir })))
      local v, err = await(git.config_get, "slop.nothing", { cwd = dir })
      assert.is_nil(v)
      assert.is_nil(err)
    end)

    it("head_message returns HEAD's full message", function()
      local dir = repo()
      assert.is_nil((await(git.head_message, { cwd = dir })))
      commit(dir, "a.txt", "1\n", "feat: one\n\nbody line")
      assert.equal("feat: one\n\nbody line", vim.trim(await(git.head_message, { cwd = dir })))
    end)

    it("run() passes stdin and calls back on the main loop", function()
      local dir = repo()
      local res = await(git.run, { "hash-object", "--stdin" }, { cwd = dir, stdin = "hello\n" })
      assert.equal(0, res.code)
      assert.equal("ce013625030ba8dba906f756967f9e9ca394464a", vim.trim(res.stdout))
      local fast
      git.run({ "--version" }, { cwd = dir }, function()
        fast = vim.in_fast_event()
      end)
      vim.wait(5000, function()
        return fast ~= nil
      end)
      assert.is_false(fast)
    end)
  end)

  describe("parent_amend", function()
    it("detects a `git commit --amend` ancestor process", function()
      if not vim.uv.fs_stat("/proc/self") then
        return
      end
      local p = vim.system({ "bash", "-c", "exec -a git sh -c 'sleep 5; :' x commit --amend" })
      vim.wait(100)
      assert.is_true(git.parent_amend(p.pid))
      p:kill(9)
      local q = vim.system({ "bash", "-c", "exec -a git sh -c 'sleep 5; :' x commit -v" })
      vim.wait(100)
      assert.is_false(git.parent_amend(q.pid))
      q:kill(9)
      assert.is_false(git.parent_amend())
    end)
  end)

  describe("parse_commit_buffer", function()
    local SC = "# ------------------------ >8 ------------------------"

    it("treats a template with only comments as empty", function()
      local r = git.parse_commit_buffer({
        "",
        "# Please enter the commit message for your changes. Lines starting",
        "# with '#' will be ignored.",
        "#",
        "# On branch main",
      })
      assert.is_true(r.empty)
      assert.same({}, r.message)
      assert.equal("#", r.comment_char)
      assert.equal(2, r.first_comment)
      assert.is_nil(r.scissors)
      assert.is_nil(r.diff)
    end)

    it("returns the message without comments and blank edges", function()
      local r = git.parse_commit_buffer({ "", "feat: x  ", "", "body", "", "# comment", "" })
      assert.is_false(r.empty)
      assert.same({ "feat: x", "", "body" }, r.message)
    end)

    it("extracts the verbose diff below the scissors (commit -v)", function()
      local r = git.parse_commit_buffer({
        "",
        "# Please enter the commit message",
        SC,
        "# Do not modify or remove the line above.",
        "# Everything below it will be ignored.",
        "diff --git a/a.txt b/a.txt",
        "index 5626abf..814f4a4 100644",
        "--- a/a.txt",
        "+++ b/a.txt",
        "@@ -1 +1,2 @@",
        " one",
        "+# not a comment inside the diff",
        "",
      })
      assert.is_true(r.empty)
      assert.equal(3, r.scissors)
      assert.equal(
        "diff --git a/a.txt b/a.txt\nindex 5626abf..814f4a4 100644\n--- a/a.txt\n+++ b/a.txt\n@@ -1 +1,2 @@\n one\n+# not a comment inside the diff\n",
        r.diff
      )
    end)

    it("keeps only the staged part of commit -vv and normalises mnemonic prefixes", function()
      local r = git.parse_commit_buffer({
        "fix: thing",
        SC,
        "# Do not modify or remove the line above.",
        "# Changes to be committed:",
        "diff --git c/a.txt i/a.txt",
        "--- c/a.txt",
        "+++ i/a.txt",
        "@@ -1 +1 @@",
        "--- c/not-a-header",
        "+new",
        "# --------------------------------------------------",
        "# Changes not staged for commit:",
        "diff --git i/b.txt w/b.txt",
        "+unstaged",
      })
      assert.same({ "fix: thing" }, r.message)
      assert.equal(
        "diff --git a/a.txt b/a.txt\n--- a/a.txt\n+++ b/a.txt\n@@ -1 +1 @@\n--- c/not-a-header\n+new\n",
        r.diff
      )
    end)

    it("refuses diffs whose headers it cannot read (diff.noprefix)", function()
      local r = git.parse_commit_buffer({ "", SC, "diff --git a.txt a.txt", "--- a.txt", "+++ a.txt" })
      assert.is_nil(r.diff)
      assert.matches("unrecognised diff header", r.diff_error)
    end)

    it("honours another comment char (from the scissors line or opts)", function()
      local lines =
        { "", "; Please enter", "; ------------------------ >8 ------------------------", "diff --git a/x b/x" }
      local r = git.parse_commit_buffer(lines)
      assert.equal(";", r.comment_char)
      assert.is_true(r.empty)
      assert.equal(3, r.scissors)
      r = git.parse_commit_buffer({ "# a real line", "; comment" }, { comment_char = ";" })
      assert.same({ "# a real line" }, r.message)
    end)
  end)

  describe("split_diff", function()
    it("splits sections and counts changes", function()
      local diff = table.concat({
        "diff --git a/a.txt b/a.txt",
        "--- a/a.txt",
        "+++ b/a.txt",
        "@@ -1,2 +1,2 @@",
        "-old",
        "+new",
        "+more",
        " ctx",
        "diff --git a/old.txt b/new.txt",
        "similarity index 90%",
        "rename from old.txt",
        "rename to new.txt",
        "diff --git a/img.png b/img.png",
        "Binary files a/img.png and b/img.png differ",
        "",
      }, "\n")
      local files = git.split_diff(diff)
      assert.equal(3, #files)
      assert.equal("a.txt", files[1].path)
      assert.equal(2, files[1].added)
      assert.equal(1, files[1].removed)
      assert.equal("new.txt", files[2].path)
      assert.equal("old.txt", files[2].old_path)
      assert.is_true(files[3].binary)
      assert.equal(diff, files[1].text .. files[2].text .. files[3].text)
    end)
  end)
end)

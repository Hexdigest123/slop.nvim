-- End to end: a real `git commit` launches a headless nvim as $GIT_EDITOR; slop lazy-loads on FileType gitcommit,
-- gathers the diff (here only visible through git's GIT_INDEX_FILE, because of `-a`), "streams" a stubbed
-- ai.chat reply as ghost text, and the buffer-local <C-y> accepts it before :wq.
local h = require("helpers")

vim.env.GIT_CONFIG_GLOBAL = "/dev/null"
vim.env.GIT_CONFIG_NOSYSTEM = "1"

local function sh(dir, args)
  local cmd = { "git" }
  vim.list_extend(cmd, args)
  local res = vim.system(cmd, { cwd = dir, text = true }):wait(10000)
  assert(res.code == 0, table.concat(args, " ") .. ": " .. tostring(res.stderr))
  return res.stdout
end

local INIT = [[
vim.opt.rtp:prepend(%q)
vim.g.mapleader = " "
local out = %q
local reply = %q
local ai = require("slop.services.ai")
ai.chat = function(req)
  local f = assert(io.open(out .. "/prompt.txt", "w"))
  f:write(req.messages[2].content)
  f:close()
  vim.defer_fn(function()
    req.on_chunk("```text\nfeat: e2e", "```text\nfeat: e2e")
    req.on_done(reply)
  end, 20)
  return { cancel = function() end, is_active = function() return false end }
end
require("slop").setup({ commit = { style = "conventional", unstaged_fallback = false } })
vim.api.nvim_create_autocmd("User", {
  pattern = "SlopCommitGenerated",
  callback = function()
    vim.schedule(function()
      vim.api.nvim_feedkeys(vim.keycode("<C-y>"), "mx", false)
      vim.cmd("wq")
    end)
  end,
})
vim.defer_fn(function() vim.cmd("cquit") end, 8000)
]]

describe("commit e2e", function()
  it("git commit -a -> ghost text -> <C-y> -> committed message", function()
    local dir = h.tmpdir("e2e")
    sh(dir, { "init", "-q", "-b", "main" })
    sh(dir, { "config", "user.email", "me@example.com" })
    sh(dir, { "config", "user.name", "Me" })
    h.write(dir .. "/a.txt", "one\n")
    sh(dir, { "add", "a.txt" })
    sh(dir, { "commit", "-q", "-m", "feat(core): first" })
    h.write(dir .. "/a.txt", "one\nonly via commit -a\n") -- NOT staged: only GIT_INDEX_FILE shows it

    local out = h.tmpdir("out")
    local init = out .. "/init.lua"
    h.write(init, INIT:format(h.root, out, "```text\nfeat: e2e message\n\nBody line.\n```"))
    local editor = ("%s --headless --clean -u %s"):format(vim.v.progpath, init)
    local res = vim
      .system({ "git", "commit", "-a" }, {
        cwd = dir,
        env = { GIT_EDITOR = editor },
        text = true,
        timeout = 20000,
      })
      :wait(25000)
    assert.equal(0, res.code, (res.stderr or "") .. (res.stdout or ""))
    assert.equal("feat: e2e message\n\nBody line.", vim.trim(sh(dir, { "log", "-1", "--format=%B" })))
    local prompt = assert(h.read(out .. "/prompt.txt"))
    assert.matches("%+only via commit %-a", prompt)
    assert.matches("Branch name: main", prompt)
    assert.matches("%- feat%(core%): first", prompt)
    assert.matches("Conventional Commits", prompt)
  end)
end)

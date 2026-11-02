-- End-to-end specs in a REAL terminal UI: a child Neovim (with slop) runs inside a :terminal of this headless test
-- process, is driven over its RPC socket, and the assertions read what libvterm actually drew. Headless specs never
-- draw the grid (folds, inccommand previews, float borders and statuslines, hit-enter prompts), so the regressions
-- below can only be seen here.
local h = require("helpers")
local api = vim.api

local Tui = {}
Tui.__index = Tui

local KEYS = { "MISTRAL_API_KEY", "OPENAI_API_KEY", "ANTHROPIC_API_KEY", "GEMINI_API_KEY", "CODESTRAL_API_KEY" }

---@param ms integer
---@param cond fun(): boolean
local function wait(ms, cond)
  return vim.wait(ms, cond, 20)
end

--- Start a child Neovim TUI in a fresh terminal buffer (80 columns x the window height).
---@param cwd string
function Tui.start(cwd)
  vim.cmd("enew")
  local buf = api.nvim_get_current_buf()
  local sock = vim.fn.tempname() .. ".sock"
  local env = { TERM = "xterm-256color" }
  for _, k in ipairs(KEYS) do
    env[k] = "" -- no AI request can be authenticated from these specs
  end
  local cmd = { vim.v.progpath, "--clean", "--listen", sock, "--cmd", "set rtp^=" .. h.root }
  local job = vim.fn.jobstart(cmd, { term = true, cwd = cwd, env = env })
  assert(job > 0, "could not start the child nvim")
  local self = setmetatable({ buf = buf, job = job, win = api.nvim_get_current_win() }, Tui)
  assert(
    wait(10000, function()
      if not vim.uv.fs_stat(sock) then
        return false
      end
      local ok, chan = pcall(vim.fn.sockconnect, "pipe", sock, { rpc = true })
      if ok and chan > 0 then
        self.chan = chan
        return true
      end
      return false
    end),
    "child nvim did not listen on " .. sock
  )
  assert(
    wait(10000, function()
      local ok, entered = pcall(vim.rpcrequest, self.chan, "nvim_get_vvar", "vim_did_enter")
      return ok and entered == 1
    end),
    "child nvim did not finish starting"
  )
  -- the TUI process talks to an embedded server: remember its pid so stop() never leaves it behind
  self.pid = vim.rpcrequest(self.chan, "nvim_exec_lua", "return vim.fn.getpid()", {})
  return self
end

---@return string
function Tui:screen()
  local rows = api.nvim_win_get_height(self.win)
  return table.concat(api.nvim_buf_get_lines(self.buf, -rows - 1, -1, false), "\n")
end

--- Fail (with the screen) instead of hanging when the child waits at a prompt: requests would queue behind it.
function Tui:assert_not_blocked()
  local mode = vim.rpcrequest(self.chan, "nvim_get_mode") -- a fast request, answered even at a prompt
  assert(not mode.blocking, ("child is blocked in mode %q:\n%s"):format(mode.mode, self:screen()))
end

---@param code string
function Tui:lua(code, ...)
  self:assert_not_blocked()
  return vim.rpcrequest(self.chan, "nvim_exec_lua", code, { ... })
end

--- Fire and forget: for actions that might end at a prompt (a request would never return).
---@param code string
function Tui:notify_lua(code)
  vim.rpcnotify(self.chan, "nvim_exec_lua", code, {})
end

---@param keys string
function Tui:keys(keys)
  vim.rpcrequest(self.chan, "nvim_input", keys)
end

--- Wait until `pred(screen)` holds; returns ok and the last screen.
---@param pred fun(screen: string): boolean
---@param ms? integer
function Tui:wait_screen(pred, ms)
  local s = ""
  local ok = wait(ms or 5000, function()
    s = self:screen()
    return pred(s)
  end)
  return ok, s
end

function Tui:stop()
  pcall(vim.rpcrequest, self.chan, "nvim_input", "<Esc><Esc>") -- leave a "-- More --"/hit-enter prompt
  pcall(vim.rpcnotify, self.chan, "nvim_command", "qa!")
  wait(3000, function()
    return vim.fn.jobwait({ self.job }, 0)[1] ~= -1
  end)
  pcall(vim.fn.jobstop, self.job)
  pcall(vim.fn.chanclose, self.chan)
  if self.pid and vim.uv.kill(self.pid, 0) == 0 then
    vim.uv.kill(self.pid, "sigkill")
  end
  pcall(api.nvim_buf_delete, self.buf, { force = true })
end

--- Run `fn(tui)` against a child started in `cwd`; the child is always stopped.
---@param cwd string
---@param fn fun(t: table)
local function with_tui(cwd, fn)
  local t = Tui.start(cwd)
  local ok, err = pcall(fn, t)
  t:stop()
  if not ok then
    error(err, 0)
  end
end

-- AI modules stay off: nothing here may reach a provider.
local SETUP = [[require("slop").setup({ complete = false, commit = false, edit = false, doc = false, rest = false })]]

---@param s string
---@param needle string
local function count(s, needle)
  return select(2, s:gsub(vim.pesc(needle), ""))
end

describe("tui", function()
  it("cloak masks secrets in closed folds and in diff-mode folds", function()
    local dir = h.tmpdir("tui-fold")
    local lines = {}
    for i = 1, 14 do
      lines[i] = ("KEY%02d=topsecret%02d"):format(i, i)
    end
    h.write(dir .. "/.env.a", table.concat(lines, "\n") .. "\n")
    lines[14] = "KEY14=CHANGED"
    h.write(dir .. "/.env.b", table.concat(lines, "\n") .. "\n")
    with_tui(dir, function(t)
      t:lua(SETUP .. [[; vim.cmd("edit .env.a")]])
      local ok, s = t:wait_screen(function(screen)
        return screen:find("KEY01=%*") ~= nil
      end)
      assert(ok, "no masks drawn:\n" .. s)
      t:keys("2Gzfjj")
      ok, s = t:wait_screen(function(screen)
        return not screen:find("KEY03=", 1, true) -- lines 2-4 are folded
      end)
      assert(ok, "no closed fold:\n" .. s)
      assert(not s:find("topsecret", 1, true), "secret visible in a closed fold:\n" .. s)
      t:keys("zE:diffsplit .env.b<CR>")
      ok, s = t:wait_screen(function(screen)
        -- both windows in diff mode: the unchanged lines 1-7 are one closed fold in each
        return count(screen, ".env.") >= 2 and not screen:find("KEY02=", 1, true)
      end)
      assert(ok, "no diff folds:\n" .. s)
      assert(not s:find("topsecret", 1, true), "secret visible in a diff fold:\n" .. s)
    end)
  end)

  for _, inccommand in ipairs({ "split", "nosplit" }) do
    it(("cloak keeps secrets hidden while a :substitute is typed ('inccommand' = %s)"):format(inccommand), function()
      local dir = h.tmpdir("tui-inccmd")
      h.write(dir .. "/.env", "# secrets\nAPI_KEY=sk-live-1234567890abcdef\nDB_PASSWORD=hunter2\n")
      with_tui(dir, function(t)
        t:lua(("vim.o.inccommand = %q; "):format(inccommand) .. SETUP .. [[; vim.cmd("edit .env")]])
        local ok, s = t:wait_screen(function(screen)
          return screen:find("API_KEY=%*") ~= nil
        end)
        assert(ok, "no masks drawn:\n" .. s)
        -- the live preview turns `KEY=value` into `KEY: value`, which the `=.+` rule no longer matches
        t:keys(":%s/=/: /")
        ok, s = t:wait_screen(function(screen)
          return screen:find(":%s/=/: /", 1, true) ~= nil
        end)
        assert(ok, "command line not shown:\n" .. s)
        vim.wait(300, function()
          return false
        end) -- time for a live preview to draw
        s = t:screen()
        assert(not s:find("1234567890abcdef", 1, true), "secret visible while typing :substitute:\n" .. s)
        assert(not s:find("hunter2", 1, true), "secret visible while typing :substitute:\n" .. s)
        t:keys("<Esc>")
      end)
    end)
  end

  it("progress window shows LSP progress whose fields are JSON null (vim.NIL) without errors", function()
    local dir = h.tmpdir("tui-progress")
    h.write(dir .. "/a.lua", "local a = 1\n")
    with_tui(dir, function(t)
      t:lua(SETUP .. [[; vim.cmd("edit a.lua")]])
      -- what 0.12's LSP client delivers for {"title": "Indexing", "message": null, "percentage": null}
      t:notify_lua([[
        local function fire(kind, value)
          value.kind = kind
          vim.api.nvim_exec_autocmds("LspProgress", {
            pattern = kind,
            data = { client_id = 4242, params = { token = "tui", value = value } },
          })
        end
        fire("begin", { title = "Indexing", message = vim.NIL, percentage = vim.NIL, cancellable = vim.NIL })
        fire("report", { title = vim.NIL, message = vim.NIL, percentage = 40 })
      ]])
      local ok, s = t:wait_screen(function(screen)
        return screen:find("Indexing", 1, true) ~= nil
      end)
      assert(ok, "progress item not shown:\n" .. s)
      t:assert_not_blocked()
      assert(not s:find("Error", 1, true) and not s:find("userdata", 1, true), "error on screen:\n" .. s)
      t:notify_lua([[
        vim.api.nvim_exec_autocmds("LspProgress", {
          pattern = "end",
          data = { client_id = 4242, params = { token = "tui", value = { kind = "end", message = vim.NIL } } },
        })
      ]])
      vim.wait(300, function()
        return false
      end)
      t:assert_not_blocked()
      s = t:screen()
      assert(not s:find("Error", 1, true) and not s:find("userdata", 1, true), "error on screen:\n" .. s)
    end)
  end)

  it("context headers are borderless floats without a statusline ('winborder', local 'statusline')", function()
    local dir = h.tmpdir("tui-context")
    local src = { "local M = {}", "", "function M.outer(a)", "  if a then", "    for i = 1, 10 do" }
    for i = 1, 40 do
      src[#src + 1] = ("      print('line %d', i)"):format(i)
    end
    vim.list_extend(src, { "    end", "  end", "end", "", "return M" })
    h.write(dir .. "/sample.lua", table.concat(src, "\n") .. "\n")
    with_tui(dir, function(t)
      t:lua([[vim.o.winborder = "rounded"; vim.o.number = true; ]] .. SETUP .. [[; vim.cmd("edit sample.lua")]])
      t:lua([[vim.wo.statusline = "%f LOCALSTL"]])
      t:keys("30Gzt5j")
      local ok, s = t:wait_screen(function(screen)
        return (screen:match("^[^\n]*") or ""):find("function M.outer(a)", 1, true) ~= nil
      end)
      assert(ok, "no context header at the top:\n" .. s)
      assert.truthy(s:find("if a then", 1, true) and s:find("for i = 1, 10 do", 1, true), "incomplete header:\n" .. s)
      for _, ch in ipairs({ "╭", "╮", "╰", "╯", "│" }) do
        assert(not s:find(ch, 1, true), "border drawn around the context float:\n" .. s)
      end
      assert.equal(1, count(s, "LOCALSTL"), "a statusline was drawn inside the context float:\n" .. s)
    end)
  end)
end)

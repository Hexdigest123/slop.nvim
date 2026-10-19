local h = require("helpers")

local SRC = {
  "local M = {}", -- 0
  "", -- 1
  "---Old doc.", -- 2
  "function M.add(a, b)", -- 3
  "  return a + b", -- 4
  "end", -- 5
  "", -- 6
  "function M.sub(a, b)", -- 7
  "  local token = 'sk-live-123'", -- 8
  "  return a - b", -- 9
  "end", -- 10
  "return M", -- 11
}

describe("doc module", function()
  local root, chat_reqs, answer, diff_calls, notes, cancelled, hold

  before_each(function()
    h.reset()
    notes = {}
    vim.notify = function(msg, level)
      notes[#notes + 1] = { msg = msg, level = level }
    end
    vim.cmd("silent! tabonly | silent! only | enew!")
    root = h.tmpdir("docroot")
    vim.fn.mkdir(root .. "/.git", "p")
    vim.cmd.cd(root)
    h.source_plugin()
    require("slop").setup({})
    chat_reqs, diff_calls, cancelled, hold = {}, {}, 0, false
    answer = { "```lua", "---Adds numbers.", "---@param a number", "```" }
    local registry = require("slop.core.registry")
    registry.service = function(name)
      assert.equal("ai", name)
      return {
        chat = function(req)
          chat_reqs[#chat_reqs + 1] = req
          if not hold then
            vim.schedule(function()
              if type(answer) == "table" and answer.kind then
                req.on_done(nil, answer)
              else
                req.on_done(table.concat(answer, "\n"), nil)
              end
            end)
          end
          return {
            cancel = function()
              cancelled = cancelled + 1
            end,
          }
        end,
      }
    end
    package.loaded["slop.core.ui.diff"] = {
      show = function(buf, range, lines, opts)
        diff_calls[#diff_calls + 1] = { buf = buf, range = range, lines = lines, opts = opts }
        return {}
      end,
    }
  end)

  local function open(name, lines)
    h.write(root .. "/" .. name, table.concat(lines or SRC, "\n") .. "\n")
    vim.cmd.edit(root .. "/" .. name)
    vim.bo.filetype = "lua"
    return vim.api.nvim_get_current_buf()
  end

  local function wait_diff(n)
    assert.is_true(vim.wait(2000, function()
      return #diff_calls >= (n or 1)
    end, 10))
  end

  local function noted(pat)
    return vim.iter(notes):any(function(n)
      return n.msg:find(pat) ~= nil
    end)
  end

  it("updates an existing doc comment: the diff range covers it", function()
    local buf = open("m.lua")
    vim.api.nvim_win_set_cursor(0, { 5, 2 })
    assert.is_true(require("slop").doc.generate())
    wait_diff()
    local req = chat_reqs[1]
    assert.equal("mistral_chat", req.provider)
    assert.is_false(req.stream)
    assert.equal(1024, req.max_tokens)
    assert.equal(30000, req.timeout)
    assert.matches("LuaLS", req.system)
    local msg = req.messages[1].content
    assert.matches("Document the function `M%.add`", msg)
    assert.matches("Existing doc comment", msg)
    assert.matches("%-%-%-Old doc%.", msg)
    local d = diff_calls[1]
    assert.equal(buf, d.buf)
    assert.are.same({ 2, 3 }, d.range)
    assert.are.same({ "---Adds numbers.", "---@param a number" }, d.lines)
    assert.matches("M%.add", d.opts.title)
    assert.is_false(require("slop").doc.is_running(buf))
  end)

  it("inserts above an undocumented function, redacting secrets", function()
    open("m.lua")
    require("slop.core.secrets").register({
      name = "test",
      spans = function(_, ls, first)
        local out = {}
        for i, l in ipairs(ls) do
          local s, e = l:find("sk%-live%-%d+")
          if s then
            out[#out + 1] = { row = first + i - 1, col = s - 1, end_col = e }
          end
        end
        return out
      end,
    })
    vim.api.nvim_win_set_cursor(0, { 9, 4 })
    require("slop").doc.generate("func")
    wait_diff()
    local msg = chat_reqs[1].messages[1].content
    assert.matches("M%.sub", msg)
    assert.falsy(msg:find("sk-live-123", 1, true))
    assert.matches("<redacted>", msg)
    assert.falsy(msg:find("Existing doc comment", 1, true))
    assert.are.same({ 7, 7 }, diff_calls[1].range)
  end)

  it("re-indents to the item", function()
    open("n.lua", { "local function outer()", "  local inner = function()", "  end", "end" })
    answer = { "--- Inner.", "--- More." }
    vim.api.nvim_win_set_cursor(0, { 2, 2 })
    require("slop").doc.generate()
    wait_diff()
    assert.are.same({ "  --- Inner.", "  --- More." }, diff_calls[1].lines)
    assert.are.same({ 1, 1 }, diff_calls[1].range)
  end)

  it("refuses blocked files", function()
    open(".env.lua")
    vim.api.nvim_win_set_cursor(0, { 5, 2 })
    assert.is_false(require("slop").doc.generate())
    vim.wait(50)
    assert.equal(0, #chat_reqs)
    assert.is_true(noted("blocked"))
  end)

  it("non-comment answers are an error, nothing is inserted", function()
    open("m.lua")
    answer = { "function M.add(a, b)", "  return a + b", "end" }
    vim.api.nvim_win_set_cursor(0, { 5, 2 })
    require("slop").doc.generate()
    assert.is_true(vim.wait(2000, function()
      return noted("not a comment")
    end, 10))
    assert.equal(0, #diff_calls)
  end)

  it("AI errors are reported", function()
    open("m.lua")
    answer = { kind = "http", message = "HTTP 401" }
    vim.api.nvim_win_set_cursor(0, { 5, 2 })
    require("slop").doc.generate()
    assert.is_true(vim.wait(2000, function()
      return noted("HTTP 401")
    end, 10))
    assert.equal(0, #diff_calls)
  end)

  it("nothing at the cursor: a notification, no request", function()
    open("m.lua")
    vim.api.nvim_win_set_cursor(0, { 12, 0 })
    assert.is_false(require("slop").doc.generate("func"))
    assert.equal(0, #chat_reqs)
    assert.is_true(noted("no function at the cursor"))
  end)

  it("cancel: the handle is cancelled, a late answer is ignored", function()
    local buf = open("m.lua")
    hold = true
    vim.api.nvim_win_set_cursor(0, { 5, 2 })
    require("slop").doc.generate()
    local doc = require("slop").doc
    assert.is_true(doc.is_running(buf))
    -- the spinner line is drawn above the doc range
    assert.is_true(vim.wait(1000, function()
      local marks = vim.api.nvim_buf_get_extmarks(buf, -1, 0, -1, { details = true })
      return vim.iter(marks):any(function(m)
        return m[4].virt_lines ~= nil and m[2] == 2
      end)
    end, 10))
    vim.cmd("Slop doc cancel")
    assert.equal(1, cancelled)
    assert.is_false(doc.is_running(buf))
    chat_reqs[1].on_done("---late", nil)
    vim.wait(50)
    assert.equal(0, #diff_calls)
    local marks = vim.api.nvim_buf_get_extmarks(buf, require("slop.core.util").ns("doc"), 0, -1, {})
    assert.equal(0, #marks)
  end)

  it("a new request in the same buffer replaces the running one", function()
    open("m.lua")
    hold = true
    vim.api.nvim_win_set_cursor(0, { 5, 2 })
    require("slop").doc.generate()
    vim.api.nvim_win_set_cursor(0, { 9, 2 })
    require("slop").doc.generate()
    assert.equal(1, cancelled)
    assert.equal(2, #chat_reqs)
  end)

  it("an edited doc range discards the answer", function()
    local buf = open("m.lua")
    hold = true
    vim.api.nvim_win_set_cursor(0, { 5, 2 })
    require("slop").doc.generate()
    vim.api.nvim_buf_set_lines(buf, 2, 3, false, { "---Edited meanwhile." })
    chat_reqs[1].on_done("---New.", nil)
    vim.wait(50)
    assert.equal(0, #diff_calls)
    assert.is_true(noted("changed while waiting"))
  end)

  it("lines added above while waiting move the target", function()
    local buf = open("m.lua")
    hold = true
    vim.api.nvim_win_set_cursor(0, { 9, 2 })
    require("slop").doc.generate()
    vim.api.nvim_buf_set_lines(buf, 0, 0, false, { "-- new", "-- lines" })
    chat_reqs[1].on_done("---New.", nil)
    wait_diff()
    assert.are.same({ 9, 9 }, diff_calls[1].range)
  end)

  it("styles and instructions come from the config", function()
    require("slop").setup({ doc = { styles = { lua = "doxygen" }, instructions = "Use British spelling." } })
    open("m.lua")
    vim.api.nvim_win_set_cursor(0, { 5, 2 })
    require("slop").doc.generate()
    wait_diff()
    assert.matches("Doxygen", chat_reqs[1].system)
    assert.matches("British spelling", chat_reqs[1].system)
  end)

  it("commands and keymaps", function()
    open("m.lua")
    vim.api.nvim_win_set_cursor(0, { 5, 2 })
    vim.cmd("Slop doc class")
    assert.equal(0, #chat_reqs) -- no class around M.add
    assert.is_true(noted("no class at the cursor"))
    vim.cmd("Slop doc func")
    wait_diff()
    assert.equal(1, #chat_reqs)
    for name, lhs in pairs({ generate = "<leader>nd", func = "<leader>nf", class = "<leader>nc", type = "<leader>nt" }) do
      assert.matches("slop", vim.fn.maparg(lhs, "n", false, true).desc or "", name)
    end
    local names = require("slop.core.commands").complete("", "Slop doc ", 0)
    for _, sub in ipairs({ "generate", "func", "class", "type", "cancel" }) do
      assert.truthy(vim.tbl_contains(names, sub), sub)
    end
  end)

  it("works end to end with the real inline diff", function()
    package.loaded["slop.core.ui.diff"] = nil
    local buf = open("m.lua")
    vim.api.nvim_win_set_cursor(0, { 9, 2 })
    require("slop").doc.generate()
    assert.is_true(vim.wait(2000, function()
      return vim.api.nvim_buf_get_lines(buf, 7, 8, false)[1] == "---Adds numbers."
    end, 10))
    assert.are.same(
      { "---Adds numbers.", "---@param a number", "function M.sub(a, b)" },
      vim.api.nvim_buf_get_lines(buf, 7, 10, false)
    )
    require("slop.core.ui.diff").list(buf)[1]:reject_all()
    assert.equal("function M.sub(a, b)", vim.api.nvim_buf_get_lines(buf, 7, 8, false)[1])
  end)
end)

describe("doc health", function()
  local saved
  before_each(function()
    h.reset()
    require("slop").setup({})
    saved = vim.health
  end)
  after_each(function()
    vim.health = saved
    vim.env.MISTRAL_API_KEY = nil
  end)

  local function run()
    local out = {}
    local function rec(kind)
      return function(msg)
        out[#out + 1] = kind .. ": " .. msg
      end
    end
    vim.health = { ok = rec("ok"), warn = rec("warn"), error = rec("error"), info = rec("info"), start = rec("start") }
    require("slop.core.registry").spec("doc").health()
    return table.concat(out, "\n")
  end

  it("reports the key variable name, never its value", function()
    vim.env.MISTRAL_API_KEY = nil
    local text = run()
    assert.matches("warn: provider `mistral_chat`: %$MISTRAL_API_KEY is NOT set", text)
    vim.env.MISTRAL_API_KEY = "super-secret-value"
    text = run()
    assert.matches("ok: provider `mistral_chat`", text)
    assert.matches("MISTRAL_API_KEY is set", text)
    assert.falsy(text:find("super-secret-value", 1, true))
    assert.matches("generate <leader>nd", text)
  end)

  it("unknown provider is an error", function()
    require("slop").setup({ doc = { provider = "nope" } })
    assert.matches("error: provider `nope` is not configured", run())
  end)
end)

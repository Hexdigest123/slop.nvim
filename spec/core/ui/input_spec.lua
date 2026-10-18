local h = require("helpers")

local api = vim.api

describe("core.ui.input", function()
  local input, src
  before_each(function()
    h.reset()
    vim.cmd("silent! %bwipeout!")
    vim.cmd.cd(h.tmpdir("input"))
    input = require("slop.core.ui.input")
    src = api.nvim_get_current_win()
    vim.cmd.stopinsert()
  end)

  it("opens a bordered float in insert mode and submits with <C-s>", function()
    local got
    local hd = input.open({
      title = "Edit",
      on_submit = function(t)
        got = t
      end,
    })
    assert.equal(hd.win, api.nvim_get_current_win())
    local cfg = api.nvim_win_get_config(hd.win)
    assert.equal("editor", cfg.relative)
    assert.truthy(cfg.border and #cfg.border > 0)
    assert.equal("slopprompt", vim.bo[hd.buf].filetype)
    hd:set_text({ "make it", "faster" })
    h.feed("<C-s>")
    assert.equal("make it\nfaster", got)
    assert.is_false(api.nvim_win_is_valid(hd.win))
    assert.equal(src, api.nvim_get_current_win())
  end)

  it("<CR> in normal mode submits, <Esc>/q cancel, empty cancels", function()
    local events = {}
    local function open()
      return input.open({
        default = "x",
        on_submit = function(t)
          events[#events + 1] = "submit:" .. t
        end,
        on_cancel = function()
          events[#events + 1] = "cancel"
        end,
      })
    end
    open()
    vim.cmd.stopinsert()
    h.feed("<CR>")
    open()
    h.feed("<Esc>")
    h.feed("<Esc>")
    open()
    h.feed("<Esc>q")
    local hd = open()
    hd:set_text("   ")
    h.feed("<C-s>")
    assert.same({ "submit:x", "cancel", "cancel", "cancel" }, events)
  end)

  it("leaving the window cancels exactly once", function()
    local n = 0
    local hd = input.open({
      on_submit = function() end,
      on_cancel = function()
        n = n + 1
      end,
    })
    api.nvim_set_current_win(src)
    vim.wait(100, function()
      return n > 0
    end)
    assert.equal(1, n)
    assert.is_false(api.nvim_win_is_valid(hd.win))
    hd:close()
    assert.equal(1, n)
  end)

  it("anchors below a buffer region", function()
    local buf = api.nvim_get_current_buf()
    api.nvim_buf_set_lines(buf, 0, -1, false, { "a", "b", "c", "d" })
    local hd = input.open({ anchor = { buf = buf, row = 1, end_row = 2 }, on_submit = function() end })
    local cfg = api.nvim_win_get_config(hd.win)
    assert.equal("win", cfg.relative)
    assert.equal(src, cfg.win)
    hd:close()
  end)

  it("grows with its content", function()
    local hd = input.open({ on_submit = function() end })
    assert.equal(1, api.nvim_win_get_height(hd.win))
    api.nvim_buf_set_lines(hd.buf, 0, -1, false, { "1", "2", "3", "4" })
    api.nvim_exec_autocmds("TextChanged", { buffer = hd.buf })
    assert.equal(4, api.nvim_win_get_height(hd.win))
    hd:close()
  end)

  it("keeps a per-key history, persisted per project, navigable with <Up>/<Down>", function()
    for _, t in ipairs({ "first", "second" }) do
      local hd = input.open({ history = "test", on_submit = function() end })
      hd:set_text(t)
      h.feed("<C-s>")
    end
    assert.same({ "second", "first" }, input.history("test"))
    local path = require("slop.core.project").dir("state", "ui", "input_history.json")
    assert.truthy(vim.uv.fs_stat(path))
    local hd = input.open({ history = "test", on_submit = function() end })
    vim.cmd.stopinsert()
    h.feed("<Up>")
    assert.equal("second", hd:text())
    h.feed("<Up>")
    assert.equal("first", hd:text())
    h.feed("<Down><Down>")
    assert.equal("", hd:text())
    hd:close()
  end)

  it("completes trigger tokens via the hook and completefunc", function()
    local calls = {}
    local hd = input.open({
      on_submit = function() end,
      complete = function(lead, line)
        calls[#calls + 1] = { lead, line }
        return { "#explain", "#fix" }
      end,
    })
    assert.equal("v:lua.require'slop.core.ui.input'._completefunc", vim.bo[hd.buf].completefunc)
    api.nvim_buf_set_lines(hd.buf, 0, -1, false, { "#e" })
    api.nvim_win_set_cursor(hd.win, { 1, 2 })
    api.nvim_exec_autocmds("TextChangedI", { buffer = hd.buf })
    assert.same({ { "#e", "#e" } }, calls)
    api.nvim_buf_set_lines(hd.buf, 0, -1, false, { "do @fi" })
    api.nvim_win_set_cursor(hd.win, { 1, 6 })
    assert.equal(3, input._completefunc(1, ""))
    assert.same({ "#explain", "#fix" }, input._completefunc(0, "@fi"))
    api.nvim_exec_autocmds("TextChanged", { buffer = hd.buf })
    local marks = api.nvim_buf_get_extmarks(hd.buf, require("slop.core.util").ns("input"), 0, -1, {})
    assert.equal(1, #marks)
    hd:close()
  end)
end)

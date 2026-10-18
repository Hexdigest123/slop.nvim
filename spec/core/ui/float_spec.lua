local h = require("helpers")

describe("core.ui.float", function()
  local float, api

  before_each(function()
    h.reset()
    vim.notify = function() end
    pcall(vim.cmd, "silent! only")
    vim.o.columns, vim.o.lines, vim.o.cmdheight = 120, 40, 1
    float = require("slop.core.ui.float")
    api = vim.api
  end)

  after_each(function()
    float.close_all()
  end)

  it("resolve_size: fraction, cells, function", function()
    assert.equal(60, float.resolve_size(0.5, 120))
    assert.equal(30, float.resolve_size(30, 120))
    assert.equal(
      100,
      float.resolve_size(function(c)
        return c - 20
      end, 0)
    )
  end)

  it("border defaults to config ui.border and is never 'none'", function()
    assert.equal("rounded", float.border())
    assert.equal("single", float.border("single"))
    assert.equal("rounded", float.border("none"))
    require("slop").setup({ ui = { border = "double" } })
    assert.equal("double", float.border())
  end)

  it("opens a centered, bordered, titled float with Slop highlights", function()
    local f = float.open({ width = 0.5, height = 10, title = "Hi", footer = "foot" })
    assert.is_true(f:is_valid())
    assert.equal(f.win, api.nvim_get_current_win())
    local c = api.nvim_win_get_config(f.win)
    assert.equal("editor", c.relative)
    assert.equal(60, c.width)
    assert.equal(10, c.height)
    assert.equal(29, c.col) -- (120 - 60 - 2) / 2
    assert.equal(13, c.row) -- (39 - 10 - 2) / 2
    assert.equal(" Hi ", c.title[1][1])
    assert.equal("center", c.title_pos)
    assert.equal(" foot ", c.footer[1][1])
    assert.equal("╭", c.border[1])
    assert.matches("FloatBorder:SlopBorder", vim.wo[f.win].winhighlight)
    assert.equal("wipe", vim.bo[f.buf].bufhidden)
  end)

  it("clamps to the editor and min sizes", function()
    local c = float.config({ width = 500, height = 500 })
    assert.equal(118, c.width)
    assert.equal(37, c.height)
    c = float.config({ width = 2, height = 2, min_width = 20, min_height = 5 })
    assert.equal(20, c.width)
    assert.equal(5, c.height)
  end)

  it("cursor, win and region relative configs", function()
    local c = float.config({ relative = "cursor", width = 10, height = 2 })
    assert.equal("cursor", c.relative)
    assert.equal(1, c.row)
    api.nvim_buf_set_lines(0, 0, -1, false, { "a", "b", "c", "d" })
    c = float.config({ relative = "region", region = { 1, 2, 2, 1 }, width = 10, height = 2 })
    assert.equal("win", c.relative)
    assert.are.same({ 2, 0 }, c.bufpos)
    assert.equal("NW", c.anchor)
    assert.equal(2, c.col)
    local f = float.open({ relative = "region", region = { 1, 0, 2, 1 }, width = 10, height = 2, enter = false })
    assert.is_true(f:is_valid())
    assert.equal("win", api.nvim_win_get_config(f.win).relative)
  end)

  it("close() fires on_close once and wipes its own buffer", function()
    local n = 0
    local f = float.open({
      on_close = function()
        n = n + 1
      end,
    })
    local buf = f.buf
    f:close()
    f:close()
    assert.equal(1, n)
    assert.is_false(f:is_valid())
    assert.is_false(api.nvim_buf_is_valid(buf))
  end)

  it("on_close also fires when the window is closed externally; caller buffers survive", function()
    local buf = api.nvim_create_buf(false, true)
    local n = 0
    local f = float.open({
      buf = buf,
      on_close = function()
        n = n + 1
      end,
    })
    api.nvim_win_close(f.win, true)
    assert.equal(1, n)
    assert.is_true(api.nvim_buf_is_valid(buf))
    assert.is_nil(float.get(f.win))
  end)

  it("close_keys close the float", function()
    local f = float.open({ close_keys = { "q" } })
    h.feed("q")
    assert.is_false(f:is_valid())
  end)

  it("close_on_leave closes it when focus leaves", function()
    local prev = api.nvim_get_current_win()
    local f = float.open({ close_on_leave = true })
    api.nvim_set_current_win(prev)
    vim.wait(100, function()
      return not f:is_valid()
    end)
    assert.is_false(f:is_valid())
  end)

  it("re-layouts on VimResized (functions re-evaluated)", function()
    local f = float.open({
      width = function(c)
        return c - 20
      end,
      height = function(_, l)
        return l - 10
      end,
    })
    assert.equal(100, api.nvim_win_get_width(f.win))
    assert.equal(30, api.nvim_win_get_height(f.win))
    vim.o.columns, vim.o.lines = 100, 30
    vim.api.nvim_exec_autocmds("VimResized", {})
    assert.equal(80, api.nvim_win_get_width(f.win))
    assert.equal(20, api.nvim_win_get_height(f.win))
    local c = api.nvim_win_get_config(f.win)
    assert.equal(9, c.col)
  end)

  it("update() changes title/footer; get/list/is_float/close", function()
    local f = float.open({ title = "a" })
    f:update({ title = "b", footer = "x" })
    local c = api.nvim_win_get_config(f.win)
    assert.equal(" b ", c.title[1][1])
    assert.equal(" x ", c.footer[1][1])
    assert.equal(f, float.get(f.win))
    assert.equal(1, #float.list())
    assert.is_true(float.is_float(f.win))
    float.close(f.win)
    assert.equal(0, #float.list())
    assert.is_false(float.is_float(api.nvim_get_current_win()))
  end)
end)

local h = require("helpers")

describe("core.ui.spinner", function()
  local spinner
  before_each(function()
    h.reset()
    spinner = require("slop.core.ui.spinner")
  end)

  it("knows styles and falls back to dots", function()
    assert.equal(10, #spinner.frames())
    assert.same({ "-", "\\", "|", "/" }, spinner.frames("line"))
    assert.same(spinner.frames("dots"), spinner.frames("nope"))
    assert.truthy(vim.tbl_contains(spinner.styles(), "arc"))
  end)

  it("uses config ui.spinner by default", function()
    require("slop").setup({ ui = { spinner = "circle" } })
    assert.same({ "◐", "◓", "◑", "◒" }, spinner.frames())
  end)

  it("ticks on the main loop and stops", function()
    local ticks = {}
    local s = spinner.new({
      style = "line",
      interval = 5,
      on_tick = function(f)
        assert.is_false(vim.in_fast_event())
        ticks[#ticks + 1] = f
      end,
    })
    assert.is_false(s:is_running())
    s:start()
    assert.is_true(s:is_running())
    vim.wait(500, function()
      return #ticks >= 5
    end)
    s:stop()
    local n = #ticks
    assert.is_true(n >= 5)
    assert.same({ "-", "\\", "|", "/", "-" }, vim.list_slice(ticks, 1, 5))
    vim.wait(30)
    assert.equal(n, #ticks)
    assert.is_false(s:is_running())
    assert.equal(ticks[n], s:frame())
  end)

  it("emits native progress and reacts to cancel requests", function()
    local seen = {}
    vim.api.nvim_create_autocmd("Progress", {
      pattern = "slop",
      callback = function(ev)
        seen[#seen + 1] = vim.deepcopy(ev.data)
      end,
    })
    local cancelled = false
    local p = spinner.progress({
      title = "edit",
      message = "starting",
      on_cancel = function()
        cancelled = true
      end,
    })
    assert.matches("^slop%.slop%.%d+$", p.id)
    p:update("reading", 40)
    assert.equal("running", seen[#seen].status)
    assert.same({ "reading" }, seen[#seen].text)
    vim.api.nvim_exec_autocmds("Progress", { pattern = "slop", data = { id = p.id, status = "cancel" } })
    assert.is_true(cancelled)
    p:finish("failed", "boom")
    assert.is_true(p:is_done())
    local last
    for _, d in ipairs(seen) do
      if d.id == p.id and d.status ~= "cancel" then
        last = d
      end
    end
    assert.equal("failed", last.status)
    p:update("ignored")
    assert.equal("failed", seen[#seen].status)
  end)
end)

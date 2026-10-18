local h = require("helpers")

describe("core.ui.scratch", function()
  local scratch
  local api = vim.api
  before_each(function()
    h.reset()
    vim.notify = function() end
    vim.cmd("silent! tabonly | silent! only | enew")
    require("slop").setup({})
    scratch = require("slop.core.ui.scratch")
  end)

  it("get() creates a nofile buffer once and reuses it by name", function()
    local buf = scratch.get("test/one", { filetype = "json" })
    assert.equal("slop://test/one", api.nvim_buf_get_name(buf))
    assert.equal("nofile", vim.bo[buf].buftype)
    assert.equal("hide", vim.bo[buf].bufhidden)
    assert.is_false(vim.bo[buf].swapfile)
    assert.is_false(vim.bo[buf].buflisted)
    assert.is_false(vim.bo[buf].modifiable)
    assert.equal("json", vim.bo[buf].filetype)
    assert.equal(buf, scratch.get("test/one"))
    assert.equal(buf, scratch.find("test/one"))
    assert.equal("test/one", scratch.name(buf))
    assert.is_nil(scratch.find("test/none"))
    assert.not_equal(buf, scratch.get("test/two"))
  end)

  it("does not re-fire FileType when the filetype is unchanged", function()
    local n = 0
    api.nvim_create_autocmd("FileType", {
      pattern = "json",
      callback = function()
        n = n + 1
      end,
    })
    scratch.get("ft", { filetype = "json" })
    scratch.get("ft", { filetype = "json" })
    assert.equal(1, n)
  end)

  it("secret_path sets vim.b.slop_secret_path", function()
    local buf = scratch.get("sec", { secret_path = "/x/.env" })
    assert.equal("/x/.env", vim.b[buf].slop_secret_path)
  end)

  it("set_lines() works on non-modifiable buffers and splits embedded newlines", function()
    local buf = scratch.get("lines")
    scratch.set_lines(buf, { "a", "b\nc" })
    assert.are.same({ "a", "b", "c" }, api.nvim_buf_get_lines(buf, 0, -1, false))
    assert.is_false(vim.bo[buf].modifiable)
    assert.is_false(vim.bo[buf].modified)
  end)

  it("open() vsplit keeps focus, then reuses the same window", function()
    local src = api.nvim_get_current_win()
    local buf, win = scratch.open("res", { layout = "vsplit", wo = { wrap = false } })
    assert.equal(src, api.nvim_get_current_win())
    assert.equal(2, #api.nvim_tabpage_list_wins(0))
    assert.equal(buf, api.nvim_win_get_buf(win))
    assert.is_false(vim.wo[win].wrap)
    -- right of the source window
    assert.is_true(api.nvim_win_get_position(win)[2] > api.nvim_win_get_position(src)[2])
    local buf2, win2 = scratch.open("res", { layout = "split" })
    assert.equal(buf, buf2)
    assert.equal(win, win2)
    assert.equal(2, #api.nvim_tabpage_list_wins(0))
    assert.equal(win, scratch.win("res"))
  end)

  it("open() split / enter / current / tab layouts", function()
    local src = api.nvim_get_current_win()
    local _, win = scratch.open("s1", { layout = "split", enter = true, size = 7 })
    assert.equal(win, api.nvim_get_current_win())
    assert.equal(7, api.nvim_win_get_height(win))
    api.nvim_set_current_win(src)
    local b2, w2 = scratch.open("s2", { layout = "current" })
    assert.equal(src, w2)
    assert.equal(b2, api.nvim_win_get_buf(src))
    local tabs = #api.nvim_list_tabpages()
    scratch.open("s3", { layout = "tab", enter = true })
    assert.equal(tabs + 1, #api.nvim_list_tabpages())
  end)

  it("open() float uses core.ui.float with the buffer", function()
    local opened
    package.loaded["slop.core.ui.float"] = {
      open = function(o)
        opened = o
        local win = api.nvim_open_win(o.buf, o.enter, {
          relative = "editor",
          row = 1,
          col = 1,
          width = 10,
          height = 3,
          border = "rounded",
        })
        return { win = win, buf = o.buf }
      end,
    }
    local buf, win = scratch.open("fl", { layout = "float", float = { title = "T" } })
    assert.equal(buf, opened.buf)
    assert.equal("T", opened.title)
    assert.is_false(opened.enter)
    assert.equal("editor", api.nvim_win_get_config(win).relative)
  end)

  it("winbar is set on showing windows and re-applied to new windows", function()
    local buf, win = scratch.open("wb", { winbar = "first" })
    assert.equal("first", vim.wo[win].winbar)
    scratch.set_winbar(buf, "second")
    assert.equal("second", vim.wo[win].winbar)
    scratch.close("wb")
    assert.is_nil(scratch.win("wb"))
    assert.truthy(api.nvim_buf_is_valid(buf))
    vim.cmd("vsplit")
    api.nvim_win_set_buf(0, buf)
    assert.equal("second", vim.wo[0].winbar)
  end)

  it("close() never closes the last window; delete() wipes", function()
    local buf = scratch.open("only", { layout = "current" })
    scratch.close("only")
    assert.equal(1, #api.nvim_list_wins())
    assert.not_equal(buf, api.nvim_get_current_buf())
    scratch.delete("only")
    assert.is_false(api.nvim_buf_is_valid(buf))
    assert.is_nil(scratch.find("only"))
  end)
end)

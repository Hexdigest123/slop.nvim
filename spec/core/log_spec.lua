local h = require("helpers")

describe("log", function()
  local log, notes
  before_each(function()
    h.reset()
    notes = {}
    vim.notify = function(msg, level)
      notes[#notes + 1] = { msg = msg, level = level }
    end
    log = require("slop.core.log")
  end)

  it("notifies at/above log.level with the slop: prefix", function()
    log.info("quiet")
    log.warn("loud %d", 1)
    log.scope("term").error("boom %s", "x")
    assert.equal(2, #notes)
    assert.equal("slop: loud 1", notes[1].msg)
    assert.equal("slop: term: boom x", notes[2].msg)
    assert.equal(vim.log.levels.ERROR, notes[2].level)
  end)

  it("records entries in a bounded ring buffer", function()
    require("slop.config").setup({ log = { max_entries = 3, level = "error" } })
    for i = 1, 5 do
      log.info("m%d", i)
    end
    log.debug("not recorded")
    local msgs = vim.tbl_map(function(e)
      return e.msg
    end, log.entries())
    assert.are.same({ "m3", "m4", "m5" }, msgs)
    log.clear()
    assert.are.same({}, log.entries())
  end)

  it("notify() always shows and formats tables", function()
    require("slop.config").setup({ log = { level = "off" } })
    log.notify("hi")
    assert.equal("slop: hi", notes[1].msg)
    log.error("never shown")
    assert.equal(1, #notes)
    log.info("t %s", { a = 1 })
    assert.matches("a = 1", log.entries()[#log.entries()].msg)
  end)

  it("open() shows the log in a scratch buffer", function()
    log.warn("visible")
    local buf = log.open()
    assert.equal("sloplog", vim.bo[buf].filetype)
    assert.matches("visible", table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n"))
  end)

  it("open() after :bdelete of the log gives a scratch buffer again (no E37 on :qa)", function()
    log.warn("first")
    local buf = log.open()
    vim.cmd("bdelete " .. buf)
    log.warn("second")
    buf = log.open()
    assert.equal("nofile", vim.bo[buf].buftype)
    assert.equal("sloplog", vim.bo[buf].filetype)
    assert.is_false(vim.bo[buf].modified)
    assert.is_false(vim.bo[buf].swapfile)
    assert.equal("<Cmd>close<CR>", vim.fn.maparg("q", "n"))
    assert.matches("second", table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n"))
    assert.equal(1, #vim.tbl_filter(function(b)
      return vim.api.nvim_buf_get_name(b) == "slop://log"
    end, vim.api.nvim_list_bufs()))
  end)

  it("survives log.max_entries = 0 (validation error reported, logging keeps working)", function()
    assert.truthy(pcall(require("slop.config").setup, { log = { max_entries = 0 } }))
    assert.matches("log%.max_entries", notes[#notes].msg)
    log.warn("still works")
    assert.equal("slop: still works", notes[#notes].msg)
    require("slop.config").setup({})
    log.warn("after fix")
    assert.equal("after fix", log.entries()[#log.entries()].msg)
  end)

  it("keeps the newest entries in order when max_entries changes", function()
    require("slop.config").setup({ log = { max_entries = 5, level = "error" } })
    for i = 1, 7 do
      log.info("a%d", i)
    end
    require("slop.config").setup({ log = { max_entries = 3, level = "error" } })
    log.info("b")
    local function msgs()
      return vim.tbl_map(function(e)
        return e.msg
      end, log.entries())
    end
    assert.are.same({ "a6", "a7", "b" }, msgs())
    require("slop.config").setup({ log = { max_entries = 10, level = "error" } })
    log.info("c")
    assert.are.same({ "a6", "a7", "b", "c" }, msgs())
  end)
end)

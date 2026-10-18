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
end)

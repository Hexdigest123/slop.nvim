local h = require("helpers")

describe("progress store", function()
  local store, t

  before_each(function()
    h.reset()
    store = require("slop.modules.progress.store")
    t = 1000
    store.now = function()
      return t
    end
    store.configure({ linger = 100, history_size = 3 })
  end)

  it("flattens multi-line text to one line (the window has one line per item)", function()
    local item = store.update("m", { origin = "lsp", group = "clangd", title = "a\nb", message = "one\r\n  two\n" })
    assert.equal("a b", item.title)
    assert.equal("one two", item.message)
    store.finish("m", "failed", { message = "boom\nstack" })
    assert.equal("boom stack", store.history()[1].message)
  end)

  it("creates, updates and finishes items; success forces 100%", function()
    local item, created = store.update("a", { origin = "lsp", group = "lua_ls", title = "Index", percent = 10 })
    assert.is_true(created)
    assert.equal("running", item.status)
    local _, again = store.update("a", { message = "3/9", percent = 30 })
    assert.is_false(again)
    t = 1250
    local done = assert(store.finish("a", "success", { message = "done" }))
    assert.equal("success", done.status)
    assert.equal(250, done.ms)
    assert.equal(100, done.percent)
    assert.equal("done", store.history()[1].message)
    -- finishing twice does not duplicate the history entry
    store.finish("a", "failed")
    assert.equal(1, #store.history())
    assert.equal("success", store.get("a").status)
  end)

  it("finish of an unknown key needs an origin", function()
    assert.is_nil(store.finish("nope", "success"))
    assert.not_nil(store.finish("once", "success", { origin = "native", group = "vim.pack" }))
    assert.equal(1, #store.items())
  end)

  it("finished items linger, then prune drops them", function()
    store.update("a", { origin = "native", group = "g" })
    store.finish("a", "success")
    t = t + 99
    assert.is_false(store.prune())
    t = t + 1
    assert.is_true(store.prune())
    assert.equal(0, #store.items())
  end)

  it("revives a finished key and orders by group (first seen), then start", function()
    store.update("b1", { origin = "native", group = "B" })
    store.update("a1", { origin = "native", group = "A" })
    store.update("b2", { origin = "native", group = "B" })
    store.finish("b1", "success")
    store.update("b1", { message = "again" })
    assert.equal("running", store.get("b1").status)
    assert.is_nil(store.get("b1").finished)
    local keys = vim.tbl_map(function(i)
      return i.key
    end, store.items())
    assert.are.same({ "b1", "b2", "a1" }, keys)
  end)

  it("history is a ring of history_size; clear items/history/all", function()
    for i = 1, 5 do
      store.finish("k" .. i, "success", { origin = "native", group = "g" })
    end
    local hist = store.history()
    assert.equal(3, #hist)
    assert.equal("k3", hist[1].key)
    assert.equal("k5", hist[3].key)
    store.clear()
    assert.equal(0, #store.items())
    assert.equal(3, #store.history())
    store.clear("history")
    assert.equal(0, #store.history())
    store.update("x", { origin = "native", group = "g" })
    store.finish("x", "success")
    store.clear("all")
    assert.equal(0, #store.items())
    assert.equal(0, #store.history())
  end)

  it("items() and history() return copies", function()
    store.update("a", { origin = "native", group = "g", message = "m" })
    store.items()[1].message = "changed"
    assert.equal("m", store.get("a").message)
  end)
end)

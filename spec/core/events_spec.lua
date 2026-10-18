local h = require("helpers")

describe("events", function()
  local events
  before_each(function()
    h.reset()
    events = require("slop.core.events")
  end)

  it("builds User Slop<Module><Event> patterns", function()
    assert.equal("SlopTermOpen", events.pattern("term", "Open"))
    assert.equal("SlopMyModDidThing", events.pattern("my_mod", "did_thing"))
    assert.equal("SlopConfigChanged", events.pattern(nil, "ConfigChanged"))
  end)

  it("emit/on pass data; once; off", function()
    local got, n = nil, 0
    events.on("term", "Open", function(data)
      got = data
    end)
    local once = events.on("term", "Open", function()
      n = n + 1
    end, { once = true })
    assert.truthy(once)
    events.emit("term", "Open", { id = 3 })
    events.emit("term", "Open", { id = 4 })
    assert.are.same({ id = 4 }, got)
    assert.equal(1, n)
    local id = events.on("x", "Y", function()
      n = n + 100
    end)
    events.off(id)
    events.emit("x", "Y")
    assert.equal(1, n)
  end)

  it("plain autocmds see the same event", function()
    local seen
    vim.api.nvim_create_autocmd("User", {
      pattern = "SlopRestDone",
      callback = function(a)
        seen = a.data.status
      end,
    })
    events.emit("rest", "Done", { status = 200 })
    assert.equal(200, seen)
  end)

  it("emit is safe from fast contexts", function()
    local seen = false
    events.on("t", "Fast", function()
      seen = true
    end)
    local timer = vim.uv.new_timer()
    timer:start(1, 0, function()
      events.emit("t", "Fast")
      timer:close()
    end)
    assert.truthy(vim.wait(1000, function()
      return seen
    end))
  end)
end)

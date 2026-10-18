local h = require("helpers")

describe("hello module (full contract)", function()
  before_each(function()
    h.reset()
    vim.notify = function() end
    h.source_plugin()
    require("slop").setup({ hello = { enabled = true, greeting = "Hi", silent = true } })
  end)

  it("is not loaded until used", function()
    assert.is_false(require("slop.core.registry").is_loaded("hello"))
  end)

  it("api via require('slop').hello, setup exactly once, event emitted", function()
    local ev
    require("slop.core.events").on("hello", "Greet", function(d)
      ev = d
    end)
    local hello = require("slop").hello
    assert.equal("Hi, slop!", hello.greet("slop"))
    assert.are.same({ text = "Hi, slop!", count = 1 }, ev)
    assert.equal("Hi, world!", require("slop").hello.greet())
    assert.equal(1, hello.setups())
  end)

  it("command, keymap and highlight", function()
    vim.cmd("Slop hello greet x")
    h.feed(" sH")
    local hello = require("slop").hello
    assert.equal(2, hello.count())
    assert.equal("Title", vim.api.nvim_get_hl(0, { name = "SlopHelloGreeting" }).link)
  end)

  it("health section", function()
    local health = require("slop.core.registry").spec("hello").health
    assert.truthy(health)
  end)
end)

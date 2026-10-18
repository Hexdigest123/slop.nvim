-- core.secrets v2 additions (owner: cloak): spans(), display providers, ensure() fast path.
local h = require("helpers")

describe("secrets v2", function()
  local secrets
  before_each(function()
    h.reset()
    vim.notify = function() end
    secrets = require("slop.core.secrets")
  end)

  local function finder(word, display)
    return {
      name = "find_" .. word,
      display = display,
      spans = function(_, lines, first_row)
        local out = {}
        for i, l in ipairs(lines) do
          local init = 1
          while true do
            local s, e = l:find(word, init, true)
            if not s then
              break
            end
            out[#out + 1] = { row = first_row + i - 1, col = s - 1, end_col = e }
            init = e + 1
          end
        end
        return out
      end,
    }
  end

  it("spans() unions and merges providers per row with absolute rows", function()
    secrets.register(finder("abc"))
    secrets.register(finder("bcd"))
    local spans = secrets.spans("/p/x.txt", { "xxabcdyy abc", "none", "bcd" }, 5)
    assert.are.same({
      { row = 5, col = 2, end_col = 6 },
      { row = 5, col = 9, end_col = 12 },
      { row = 7, col = 0, end_col = 3 },
    }, spans)
  end)

  it("spans() includes the built-in PEM rule unless display-only", function()
    secrets.register(finder("tok", true))
    local lines = { "-----BEGIN PRIVATE KEY-----", "MIIE", "-----END PRIVATE KEY-----", "tok" }
    assert.equal(2, #secrets.spans(nil, lines))
    local d = secrets.spans(nil, lines, 0, { display = true })
    assert.are.same({ { row = 3, col = 0, end_col = 3 } }, d)
  end)

  it("display-only spans skip providers without display = true", function()
    secrets.register(finder("tok"))
    assert.equal(0, #secrets.spans("/p/a", { "tok" }, 0, { display = true }))
    assert.equal(1, #secrets.spans("/p/a", { "tok" }, 0))
  end)

  it("match_path is not called for unnamed sources", function()
    local called = false
    local p = finder("tok")
    p.match_path = function()
      called = true
      return true
    end
    secrets.register(p)
    assert.equal(0, #secrets.spans(nil, { "tok" }))
    assert.is_false(called)
    assert.equal(1, #secrets.spans("/p/a", { "tok" }))
  end)

  it("loads providers once per config generation", function()
    local registry = require("slop.core.registry")
    local calls = 0
    local orig = registry.load_capability
    registry.load_capability = function(cap)
      calls = calls + 1
      return orig(cap)
    end
    secrets.is_blocked("/p/a.lua")
    secrets.is_blocked("/p/b.lua")
    secrets.redact_text("x", "/p/c.lua")
    assert.equal(1, calls)
    require("slop.config").setup({})
    secrets.is_blocked("/p/a.lua")
    assert.equal(2, calls)
  end)
end)

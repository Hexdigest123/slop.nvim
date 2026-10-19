local h = require("helpers")

-- services.ai emits User SlopAiRequestStarted / SlopAiRequestFinished around every HTTP request.
describe("services.ai request events", function()
  local ai, calls, seen

  local function fake_http()
    calls = {}
    package.loaded["slop.core.http"] = {
      request = function(req)
        calls[#calls + 1] = req
        return {
          id = #calls,
          cancel = function() end,
          is_active = function()
            return true
          end,
        }
      end,
    }
  end

  local function respond(i, body, err)
    calls[i].on_done(body and {
      json = function()
        return body
      end,
    } or nil, err)
  end

  before_each(function()
    h.reset()
    vim.notify = function() end
    vim.uv.os_setenv("SLOP_TEST_KEY", "k")
    fake_http()
    require("slop.config").setup({
      ai = {
        providers = {
          oa = { kind = "chat", service = "openai", url = "http://x", model = "gpt-x", api_key = "SLOP_TEST_KEY" },
          cs = { kind = "fim", service = "mistral", url = "http://x", model = "codestral", api_key = "SLOP_TEST_KEY" },
        },
      },
    })
    ai = require("slop.core.registry").service("ai")
    seen = {}
    for _, ev in ipairs({ "RequestStarted", "RequestFinished" }) do
      require("slop.core.events").on("ai", ev, function(data)
        seen[#seen + 1] = { ev = ev, data = data }
      end)
    end
  end)

  it("chat: started then finished with ms, provider, model and source", function()
    local got
    ai.chat({
      provider = "oa",
      source = "commit",
      messages = { { role = "user", content = "q" } },
      on_done = function(text)
        got = text
      end,
    })
    assert.equal(1, #seen)
    assert.equal("RequestStarted", seen[1].ev)
    local s = seen[1].data
    assert.equal("chat", s.kind)
    assert.equal("oa", s.provider)
    assert.equal("gpt-x", s.model)
    assert.equal("commit", s.source)
    assert.equal("number", type(s.id))
    respond(1, { choices = { { message = { content = "hi" } } } })
    assert.equal("hi", got)
    assert.equal(2, #seen)
    local f = seen[2].data
    assert.equal("RequestFinished", seen[2].ev)
    assert.equal(s.id, f.id)
    assert.equal("number", type(f.ms))
    assert.is_nil(f.error)
  end)

  it("fim: error and cancel are reported; ids are distinct", function()
    ai.complete_fim({ provider = "cs", prompt = "a", suffix = "b", on_done = function() end })
    ai.complete_fim({ provider = "cs", prompt = "a", suffix = "b", on_done = function() end })
    assert.equal("fim", seen[1].data.kind)
    assert.not_equal(seen[1].data.id, seen[2].data.id)
    respond(1, nil, { kind = "http", message = "HTTP 500" })
    respond(2, nil, { kind = "cancelled", message = "request cancelled" })
    assert.matches("HTTP 500", seen[3].data.error)
    assert.equal("cancelled", seen[4].data.error)
  end)

  it("source defaults to the calling slop module; config errors emit nothing", function()
    local f = assert(
      loadstring(
        "return function(ai) ai.chat({ provider = 'oa', messages = {}, on_done = function() end }) end",
        "@/x/lua/slop/modules/rest/ai.lua"
      )
    )()
    f(ai)
    assert.equal("rest", seen[1].data.source)
    ai.chat({ provider = "nope", messages = {}, on_done = function() end })
    assert.equal(1, #seen)
  end)
end)

local h = require("helpers")
local mock = require("services.ai.mock_server")

describe("services.ai providers", function()
  local ai, srv
  local api_key = "TEST_KEY_VAR"

  local function setup(providers)
    require("slop.config").setup({ ai = { providers = providers } })
    ai = require("slop.core.registry").service("ai")
  end

  local function wait_done(fn)
    local out = {}
    fn(function(a, b)
      out.n = (out.n or 0) + 1
      out.value, out.err = a, b
    end, out)
    assert.is_true(
      mock.wait(function()
        return out.n ~= nil
      end, 6000),
      "no on_done"
    )
    vim.wait(20)
    assert.equal(1, out.n)
    return out
  end

  before_each(function()
    h.reset()
    vim.notify = function() end
    vim.uv.os_setenv(api_key, "sekret")
  end)
  after_each(function()
    if srv then
      srv.stop()
      srv = nil
    end
  end)

  it("codestral FIM (mistral): body, auth, non-streamed parse", function()
    srv = mock.start(function(_, res)
      res.json(200, { choices = { { message = { content = "x + 1" } } } })
    end)
    setup({
      cs = {
        kind = "fim",
        service = "mistral",
        url = srv.url .. "/v1/fim/completions",
        model = "codestral-latest",
        api_key = api_key,
      },
    })
    local out = wait_done(function(done)
      ai.complete_fim({
        provider = "cs",
        prompt = "a = ",
        suffix = "\n",
        max_tokens = 64,
        stop = { "\n\n" },
        stream = false,
        on_done = done,
      })
    end)
    assert.is_nil(out.err)
    assert.are.same({ "x + 1" }, out.value)
    local req = srv.requests[1]
    assert.equal("/v1/fim/completions", req.path)
    assert.equal("Bearer sekret", req.headers.authorization)
    local body = vim.json.decode(req.body)
    assert.equal("codestral-latest", body.model)
    assert.equal("a = ", body.prompt)
    assert.equal("\n", body.suffix)
    assert.equal(64, body.max_tokens)
    assert.are.same({ "\n\n" }, body.stop)
    assert.is_false(body.stream)
  end)

  it("codestral FIM streams deltas (SSE) incrementally", function()
    srv = mock.start(function(_, res)
      res.stream(200, {
        mock.sse({ choices = { { delta = { content = "foo" } } } }),
        mock.sse({ choices = { { delta = { content = "(bar)" }, finish_reason = "stop" } } }),
        mock.sse("[DONE]"),
      })
    end)
    setup({ cs = { kind = "fim", service = "mistral", url = srv.url, model = "m", api_key = api_key } })
    local deltas = {}
    local out = wait_done(function(done)
      ai.complete_fim({
        provider = "cs",
        prompt = "p",
        suffix = "s",
        on_chunk = function(d, all)
          deltas[#deltas + 1] = { d, all }
        end,
        on_done = done,
      })
    end)
    assert.is_nil(out.err)
    assert.are.same({ "foo(bar)" }, out.value)
    assert.are.same({ { "foo", "foo" }, { "(bar)", "foo(bar)" } }, deltas)
    assert.is_true(vim.json.decode(srv.requests[1].body).stream)
  end)

  it("openai-compatible FIM (ollama/deepseek): choices[].text, n, keyless, params, headers, transform", function()
    srv = mock.start(function(_, res)
      res.json(200, { choices = { { text = "one" }, { text = "two" } } })
    end)
    setup({
      local_fim = {
        kind = "fim",
        service = "ollama",
        url = srv.url .. "/v1/completions",
        model = "qwen2.5-coder",
        api_key = false,
        params = { top_p = 0.9, options = { num_ctx = 4096 } },
        headers = { ["X-Extra"] = "1" },
        transform = function(r, info)
          r.body.transformed = info.kind
          return r
        end,
      },
    })
    local out = wait_done(function(done)
      ai.complete_fim({ provider = "local_fim", prompt = "p", suffix = "s", n = 2, stream = false, on_done = done })
    end)
    assert.are.same({ "one", "two" }, out.value)
    local req = srv.requests[1]
    assert.is_nil(req.headers.authorization)
    assert.equal("1", req.headers["x-extra"])
    local body = vim.json.decode(req.body)
    assert.equal(2, body.n)
    assert.equal(0.9, body.top_p)
    assert.equal(4096, body.options.num_ctx)
    assert.equal("fim", body.transformed)
  end)

  it("fim_template puts special tokens in the prompt and omits suffix (llama.cpp /v1/completions)", function()
    srv = mock.start(function(_, res)
      res.json(200, { choices = { { text = "mid" } } })
    end)
    setup({
      q = { kind = "fim", service = "ollama", url = srv.url, model = "x", api_key = false, fim_template = "qwen" },
    })
    wait_done(function(done)
      ai.complete_fim({ provider = "q", prompt = "P", suffix = "S", stream = false, on_done = done })
    end)
    local body = vim.json.decode(srv.requests[1].body)
    assert.equal("<|fim_prefix|>P<|fim_suffix|>S<|fim_middle|>", body.prompt)
    assert.is_nil(body.suffix)
  end)

  it("llama.cpp /infill dialect (stream)", function()
    srv = mock.start(function(_, res)
      res.stream(200, { mock.sse({ content = "ab" }), mock.sse({ content = "c", stop = true }) })
    end)
    setup({ l = { kind = "fim", service = "llamacpp", url = srv.url .. "/infill", model = "x", api_key = false } })
    local out = wait_done(function(done)
      ai.complete_fim({ provider = "l", prompt = "P", suffix = "S", max_tokens = 9, on_done = done })
    end)
    assert.are.same({ "abc" }, out.value)
    local body = vim.json.decode(srv.requests[1].body)
    assert.equal("P", body.input_prefix)
    assert.equal("S", body.input_suffix)
    assert.equal(9, body.n_predict)
  end)

  it("openai chat: system message, streamed text", function()
    srv = mock.start(function(_, res)
      res.stream(200, {
        mock.sse({ choices = { { delta = { role = "assistant" } } } }),
        mock.sse({ choices = { { delta = { content = "Hel" } } } }),
        mock.sse({ choices = { { delta = { content = "lo" } } } }),
        mock.sse("[DONE]"),
      })
    end)
    setup({ oa = { kind = "chat", service = "openai", url = srv.url, model = "gpt", api_key = api_key } })
    local chunks = {}
    local out = wait_done(function(done)
      ai.chat({
        provider = "oa",
        system = "be brief",
        messages = { { role = "user", content = "hi" } },
        temperature = 0.2,
        on_chunk = function(d)
          chunks[#chunks + 1] = d
        end,
        on_done = done,
      })
    end)
    assert.equal("Hello", out.value)
    assert.are.same({ "Hel", "lo" }, chunks)
    local body = vim.json.decode(srv.requests[1].body)
    assert.are.same({ { role = "system", content = "be brief" }, { role = "user", content = "hi" } }, body.messages)
    assert.equal(0.2, body.temperature)
    assert.is_true(body.stream)
  end)

  it("mistral chat non-streamed (default without on_chunk)", function()
    srv = mock.start(function(_, res)
      res.json(200, { choices = { { message = { content = "feat: x" } } } })
    end)
    setup({ mc = { kind = "chat", service = "mistral", url = srv.url, model = "m", api_key = api_key } })
    local out = wait_done(function(done)
      ai.chat({ provider = "mc", messages = { { role = "user", content = "diff" } }, on_done = done })
    end)
    assert.equal("feat: x", out.value)
    assert.is_false(vim.json.decode(srv.requests[1].body).stream)
  end)

  it("anthropic: headers, top-level system, max_tokens, SSE events", function()
    srv = mock.start(function(_, res)
      res.stream(200, {
        'event: message_start\ndata: {"type":"message_start"}\n\n',
        'event: content_block_delta\ndata: {"type":"content_block_delta","delta":{"type":"text_delta","text":"Hi"}}\n\n',
        'event: content_block_delta\ndata: {"type":"content_block_delta","delta":{"type":"text_delta","text":"!"}}\n\n',
        'event: message_stop\ndata: {"type":"message_stop"}\n\n',
      })
    end)
    setup({
      cl = {
        kind = "chat",
        service = "anthropic",
        url = srv.url .. "/v1/messages",
        model = "claude",
        api_key = api_key,
      },
    })
    local out = wait_done(function(done)
      ai.chat({
        provider = "cl",
        stream = true,
        messages = { { role = "system", content = "sys" }, { role = "user", content = "q" } },
        on_done = done,
      })
    end)
    assert.equal("Hi!", out.value)
    local req = srv.requests[1]
    assert.equal("sekret", req.headers["x-api-key"])
    assert.equal("2023-06-01", req.headers["anthropic-version"])
    local body = vim.json.decode(req.body)
    assert.equal("sys", body.system)
    assert.are.same({ { role = "user", content = "q" } }, body.messages)
    assert.equal(1024, body.max_tokens)
  end)

  it("anthropic non-streamed content blocks", function()
    srv = mock.start(function(_, res)
      res.json(200, { content = { { type = "text", text = "a" }, { type = "text", text = "b" } } })
    end)
    setup({ cl = { kind = "chat", service = "anthropic", url = srv.url, model = "c", api_key = api_key } })
    local out = wait_done(function(done)
      ai.chat({ provider = "cl", messages = { { role = "user", content = "q" } }, on_done = done })
    end)
    assert.equal("ab", out.value)
  end)

  it("gemini: url, key header, roles, systemInstruction, streamed", function()
    srv = mock.start(function(_, res)
      res.stream(200, {
        mock.sse({ candidates = { { content = { parts = { { text = "G" } }, role = "model" } } } }),
        mock.sse({ candidates = { { content = { parts = { { text = "o" } } }, finishReason = "STOP" } } }),
      })
    end)
    setup({
      gm = {
        kind = "chat",
        service = "gemini",
        url = srv.url .. "/v1beta/models",
        model = "gemini-x",
        api_key = api_key,
      },
    })
    local out = wait_done(function(done)
      ai.chat({
        provider = "gm",
        stream = true,
        system = "S",
        max_tokens = 50,
        messages = {
          { role = "user", content = "u" },
          { role = "assistant", content = "a" },
          { role = "user", content = "v" },
        },
        on_done = done,
      })
    end)
    assert.equal("Go", out.value)
    local req = srv.requests[1]
    assert.equal("/v1beta/models/gemini-x:streamGenerateContent", req.path)
    assert.equal("alt=sse", req.query)
    assert.equal("sekret", req.headers["x-goog-api-key"])
    local body = vim.json.decode(req.body)
    assert.equal("S", body.systemInstruction.parts[1].text)
    assert.are.same(
      { "user", "model", "user" },
      vim.tbl_map(function(c)
        return c.role
      end, body.contents)
    )
    assert.equal(50, body.generationConfig.maxOutputTokens)
  end)

  it("chat-FIM: a chat provider serves complete_fim with <END>-separated alternatives", function()
    srv = mock.start(function(_, res)
      res.stream(200, {
        mock.sse({ choices = { { delta = { content = "radius ** 2\n<E" } } } }),
        mock.sse({ choices = { { delta = { content = "ND>\nr * r" } } } }),
        mock.sse("[DONE]"),
      })
    end)
    setup({ oc = { kind = "chat", service = "openrouter", url = srv.url, model = "m", api_key = api_key } })
    local shown = {}
    local out = wait_done(function(done)
      ai.complete_fim({
        provider = "oc",
        prompt = "return math.pi * ",
        suffix = "\n",
        n = 2,
        filetype = "python",
        on_chunk = function(_, text)
          shown[#shown + 1] = text
        end,
        on_done = done,
      })
    end)
    assert.are.same({ "radius ** 2", "r * r" }, out.value)
    assert.are.same({ "radius ** 2" }, shown)
    local body = vim.json.decode(srv.requests[1].body)
    assert.equal("system", body.messages[1].role)
    assert.matches("up to 2 different alternatives", body.messages[1].content)
    local last = body.messages[#body.messages].content
    assert.matches("Language: python", last)
    assert.matches("return math%.pi %* </before_cursor>", last)
  end)

  it("errors: unknown provider, missing key (never throws), HTTP error message enrichment", function()
    srv = mock.start(function(_, res)
      res.json(401, { message = "Unauthorized: bad key" })
    end)
    vim.uv.os_unsetenv("MISTRAL_API_KEY")
    setup({
      cs = { kind = "fim", service = "mistral", url = srv.url, model = "m", api_key = api_key },
      nokey = { kind = "fim", service = "mistral", url = srv.url, model = "m" },
    })
    local out = wait_done(function(done)
      ai.complete_fim({ provider = "nope", prompt = "", suffix = "", on_done = done })
    end)
    assert.equal("config", out.err.kind)
    out = wait_done(function(done)
      ai.complete_fim({ provider = "nokey", prompt = "", suffix = "", on_done = done })
    end)
    assert.equal("config", out.err.kind)
    assert.matches("MISTRAL_API_KEY is not set", out.err.message)
    assert.equal(0, #srv.requests)
    out = wait_done(function(done)
      ai.complete_fim({ provider = "cs", prompt = "", suffix = "", on_done = done })
    end)
    assert.equal("http", out.err.kind)
    assert.equal(401, out.err.code)
    assert.matches("HTTP 401: Unauthorized: bad key", out.err.message)
  end)

  it("cancel via the returned handle", function()
    srv = mock.start(function(_, res)
      res.hang()
    end)
    setup({ cs = { kind = "fim", service = "mistral", url = srv.url, model = "m", api_key = api_key } })
    local out = wait_done(function(done)
      local handle = ai.complete_fim({ provider = "cs", prompt = "", suffix = "", on_done = done })
      vim.defer_fn(function()
        handle:cancel()
      end, 50)
    end)
    assert.equal("cancelled", out.err.kind)
  end)

  it("schema validates the new provider fields", function()
    require("slop.config").setup({
      ai = { providers = { x = { kind = "fim", url = "u", model = "m", fim_template = "nope", params = 1 } } },
    })
    local errs = table.concat(require("slop.config").errors("ai"), "\n")
    assert.matches("ai%.providers%.x%.fim_template", errs)
    assert.matches("ai%.providers%.x%.params", errs)
  end)

  it("providers() lists names, optionally by kind", function()
    setup({})
    assert.are.same({ "codestral", "mistral_chat" }, ai.providers())
    assert.are.same({ "codestral" }, ai.providers("fim"))
  end)

  it("chat_fim.parse handles fences and separators", function()
    local cf = require("slop.services.ai.chat_fim")
    assert.are.same({ "a", "b\nc" }, cf.parse("```lua\na\n```\n<END>\nb\nc\n"))
    assert.are.same({}, cf.parse("  \n"))
    assert.equal("x", cf.first_partial("x\n<EN"))
  end)
  it("reasoning models: content chunks keep only the text (non-streamed and streamed)", function()
    local oa = require("slop.services.ai.providers.openai")
    local body = {
      choices = {
        {
          message = {
            role = "assistant",
            content = {
              { type = "thinking", thinking = { { type = "text", text = "hmm" } }, closed = true },
              { type = "text", text = "feat: " },
              { type = "text", text = "add x" },
            },
          },
        },
      },
    }
    assert.equal("feat: add x", oa.parse_chat(body))
    assert.equal("", oa.parse_chat({ choices = { { message = { content = { { type = "thinking" } } } } } }))
    local think = vim.json.encode({
      choices = { { delta = { content = { { type = "thinking", thinking = { { type = "text", text = "x" } } } } } } },
    })
    assert.is_nil((oa.delta({ data = think })))
    local text = vim.json.encode({ choices = { { delta = { content = { { type = "text", text = "OK" } } } } } })
    assert.equal("OK", (oa.delta({ data = text })))
    assert.equal("OK", (oa.delta({ data = vim.json.encode({ choices = { { delta = { content = "OK" } } } }) })))
  end)
end)

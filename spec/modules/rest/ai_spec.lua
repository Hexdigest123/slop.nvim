local h = require("helpers")

local ANSWER = "Here you go:\n```http\n### List users\n# @name listUsers\nGET {{baseUrl}}/users\n```\nBye"

describe("rest ai (pure helpers)", function()
  local ai
  before_each(function()
    h.reset()
    require("slop").setup({})
    ai = require("slop.modules.rest.ai")
  end)

  it("sensitive() names", function()
    for _, n in ipairs({ "Authorization", "Cookie", "Set-Cookie", "X-Api-Key", "apiKey", "access_token", "password" }) do
      assert.is_true(ai.sensitive(n), n)
    end
    for _, n in ipairs({ "Content-Type", "Accept", "baseUrl", "keyboard" }) do
      assert.is_false(ai.sensitive(n), n)
    end
  end)

  it("mask_headers() keeps {{var}}-only values", function()
    assert.are.same(
      { "Authorization: <redacted>", "Authorization: Bearer {{token}}", "Accept: */*" },
      ai.mask_headers({
        { "Authorization", "Bearer abc" },
        { "Authorization", "Bearer {{token}}" },
        { "Accept", "*/*" },
      })
    )
  end)

  it("mask_text() masks JSON fields, header lines and file vars", function()
    local text = table.concat({
      "@token = abc123",
      "@ref = {{login.response.body.$.token}}",
      "@baseUrl = http://h",
      "Cookie: sid=zzz",
      "X-Api-Key: {{API_KEY}}",
      '{"password": "hunter2", "name": "ann", "accessToken": "{{t}}"}',
    }, "\n")
    local out = ai.mask_text(text)
    assert.falsy(out:find("abc123", 1, true))
    assert.falsy(out:find("zzz", 1, true))
    assert.falsy(out:find("hunter2", 1, true))
    assert.truthy(out:find("@ref = {{login.response.body.$.token}}", 1, true))
    assert.truthy(out:find("@baseUrl = http://h", 1, true))
    assert.truthy(out:find("X-Api-Key: {{API_KEY}}", 1, true))
    assert.truthy(out:find('"name": "ann"', 1, true))
    assert.truthy(out:find('"accessToken": "{{t}}"', 1, true))
  end)

  it("sensitive(): short words only as a whole part of the name", function()
    for _, n in ipairs({ "X-Auth", "db_pass", "userPwd", "pw", "card-pin", "otp", "jwt", "client_secret", "Bearer" }) do
      assert.is_true(ai.sensitive(n), n)
    end
    for _, n in ipairs({ "author", "passenger", "spinner", "keyboard", "options" }) do
      assert.is_false(ai.sensitive(n), n)
    end
  end)

  it("mask_text() masks query strings, form bodies, X-Auth, pass/pwd/jwt keys, escaped quotes", function()
    local text = table.concat({
      "POST https://api.x/oauth/token?client_id=web&api_key=QUERY-SECRET",
      "X-Auth: hdr-secret",
      "",
      "grant_type=password&username=ann&password=FORM-SECRET",
      "access_token=RESPONSE-SECRET&scope=repo&token_type=bearer",
      '{"pass": "p1", "pwd": "p2", "jwt": "p3", "password": "esc\\"TAIL-SECRET", "name": "ann"}',
      "GET /a?token={{token}}",
    }, "\n")
    local out = ai.mask_text(text)
    for _, s in ipairs({ "QUERY-SECRET", "hdr-secret", "FORM-SECRET", "RESPONSE-SECRET", "p1", "p2", "p3", "TAIL" }) do
      assert.falsy(out:find(s, 1, true), s .. " leaked:\n" .. out)
    end
    assert.truthy(out:find("client_id=web&api_key=<redacted>", 1, true))
    assert.truthy(out:find("grant_type=password&username=ann&password=<redacted>", 1, true))
    assert.truthy(out:find('"password": "<redacted>", "name": "ann"', 1, true))
    assert.truthy(out:find("GET /a?token={{token}}", 1, true))
  end)

  local hints = {
    { "/r/src/routes/api/users/+server.ts", "/api/users" },
    { "/r/src/routes/(app)/api/items/[id]/+server.js", "/api/items/{id}" },
    { "/r/app/api/orders/route.ts", "/api/orders" },
    { "/r/pages/api/hello.ts", "/api/hello" },
    { "/r/pages/api/things/index.ts", "/api/things" },
  }
  for _, c in ipairs(hints) do
    it("route_hint(" .. c[1] .. ")", function()
      assert.matches(vim.pesc(c[2]), ai.route_hint(c[1]))
    end)
  end
  it("route_hint() is nil for other files", function()
    assert.is_nil(ai.route_hint("/r/lib/x.ts"))
  end)

  it("extract() takes the first http fence (or the whole text)", function()
    assert.are.same({ "### List users", "# @name listUsers", "GET {{baseUrl}}/users" }, ai.extract(ANSWER))
    assert.are.same({ "GET /a" }, ai.extract("```\nGET /a\n```"))
    assert.are.same({ "GET /x" }, ai.extract("<slop:http>\nGET /x\n</slop:http>"))
    assert.are.same({ "GET /plain" }, ai.extract("\nGET /plain\n\n"))
  end)
end)

describe("rest ai gen/fix", function()
  local root, chat_reqs, answer, diff_calls, notes

  before_each(function()
    h.reset()
    notes = {}
    vim.notify = function(msg, level)
      notes[#notes + 1] = { msg = msg, level = level }
    end
    vim.cmd("silent! tabonly | silent! only | enew!")
    root = h.tmpdir("airoot")
    vim.fn.mkdir(root .. "/.git", "p")
    vim.cmd.cd(root)
    h.source_plugin()
    require("slop").setup({})
    chat_reqs, diff_calls, answer = {}, {}, ANSWER
    local registry = require("slop.core.registry")
    registry.service = function(name)
      assert.equal("ai", name)
      return {
        chat = function(req)
          chat_reqs[#chat_reqs + 1] = req
          vim.schedule(function()
            req.on_done(answer, nil)
          end)
          return { cancel = function() end }
        end,
      }
    end
    package.loaded["slop.core.ui.diff"] = {
      show = function(buf, range, lines, opts)
        diff_calls[#diff_calls + 1] = { buf = buf, range = range, lines = lines, opts = opts }
        return {}
      end,
      list = function()
        return {}
      end,
    }
    require("slop").rest.status() -- load the module
  end)

  local function wait_diff(n)
    assert.is_true(vim.wait(3000, function()
      return #diff_calls >= (n or 1)
    end, 10))
  end

  it("gen (description) appends to the current .http buffer, context redacted", function()
    h.write(root .. "/.env", "SECRET_VALUE=supersecret\n")
    h.write(root .. "/http-client.env.json", vim.json.encode({ dev = { apiKey = "envsecret", baseUrl = "http://e" } }))
    h.write(
      root .. "/api.http",
      "@baseUrl = http://localhost:3000\n@token = abc123\n\n### Me\n# @name me\nGET {{baseUrl}}/me\n"
        .. "Authorization: Bearer literalsecret\nX-S: {{SECRET_VALUE}}\n"
    )
    vim.cmd.edit(root .. "/api.http")
    local buf = vim.api.nvim_get_current_buf()
    require("slop").rest.gen({ mode = "desc", text = "list users" })
    wait_diff()
    local msg = chat_reqs[1].messages[1].content
    assert.equal("user", chat_reqs[1].messages[1].role)
    assert.matches("list users", msg)
    assert.matches("baseUrl", msg)
    assert.matches("apiKey", msg) -- env var NAMES are sent
    for _, secret in ipairs({ "abc123", "supersecret", "envsecret" }) do
      assert.falsy(msg:find(secret, 1, true), secret .. " leaked")
    end
    assert.matches("syntax", chat_reqs[1].system)
    local d = diff_calls[1]
    assert.equal(buf, d.buf)
    local n = vim.api.nvim_buf_line_count(buf)
    assert.are.same({ n, n }, d.range)
    assert.are.same({ "", "### List users", "# @name listUsers", "GET {{baseUrl}}/users" }, d.lines)
  end)

  it("gen (code) uses the handler under the cursor, the route hint, and targets <root>/requests.http", function()
    local path = root .. "/src/routes/api/users/+server.ts"
    h.write(path, "export async function GET() {\n  return json(await db.users())\n}\n")
    vim.cmd.edit(path)
    require("slop").rest.gen()
    wait_diff()
    local msg = chat_reqs[1].messages[1].content
    assert.matches("/api/users", msg)
    assert.matches("db%.users", msg)
    local d = diff_calls[1]
    assert.equal(root .. "/requests.http", vim.api.nvim_buf_get_name(d.buf))
    assert.equal("http", vim.bo[d.buf].filetype)
    assert.are.same({ 0, 1 }, d.range)
    assert.equal(d.buf, vim.api.nvim_get_current_buf())
  end)

  it("gen refuses blocked files", function()
    h.write(root .. "/.env.local", "A=1\n")
    vim.cmd.edit(root .. "/.env.local")
    vim.bo.filetype = "sh"
    require("slop").rest.gen({ mode = "code" })
    vim.wait(100)
    assert.equal(0, #chat_reqs)
    assert.truthy(vim.iter(notes):any(function(n)
      return n.msg:find("blocked", 1, true) ~= nil
    end))
  end)

  it("gen (openapi) sends the spec text", function()
    h.write(root .. "/openapi.yaml", "openapi: 3.0.0\npaths:\n  /pets:\n    get: {}\n")
    vim.cmd.edit(root .. "/openapi.yaml")
    require("slop").rest.gen()
    wait_diff()
    assert.matches("OpenAPI specification", chat_reqs[1].messages[1].content)
    assert.matches("/pets", chat_reqs[1].messages[1].content)
  end)

  it("invalid AI output is shown raw, no diff", function()
    answer = "I cannot do that."
    h.write(root .. "/x.http", "GET http://x/\n")
    vim.cmd.edit(root .. "/x.http")
    require("slop").rest.gen({ mode = "desc", text = "x" })
    assert.is_true(vim.wait(2000, function()
      return require("slop.core.ui.scratch").find("rest/ai-output") ~= nil
    end))
    assert.equal(0, #diff_calls)
    local b = require("slop.core.ui.scratch").find("rest/ai-output")
    assert.are.same({ "I cannot do that." }, vim.api.nvim_buf_get_lines(b, 0, -1, false))
  end)

  it("fix replaces the failed request block, response context masked", function()
    local f = root .. "/f.http"
    h.write(f, '@b = http://x\n\n### Create\n# @name create\nPOST {{b}}/items\n\n{"a": 1,}\n\n### Other\nGET /o\n')
    local parsed = require("slop.modules.rest.discover").parse(f)
    local req = parsed.requests[1]
    local S = require("slop.modules.rest.api")._state
    S.failed[root] = {
      req = req,
      res = {
        status = 400,
        reason = "Bad Request",
        headers = { { "Set-Cookie", "sid=secretcookie" }, { "Content-Type", "application/json" } },
        body = '{"error": "invalid json", "password": "hunter2"}',
      },
    }
    answer = '```http\n### Create\n# @name create\nPOST {{b}}/items\nContent-Type: application/json\n\n{"a": 1}\n```'
    require("slop").rest.fix()
    wait_diff()
    local msg = chat_reqs[1].messages[1].content
    assert.matches("400 Bad Request", msg)
    assert.matches("invalid json", msg)
    assert.matches('{"a": 1,}', msg, 1)
    assert.falsy(msg:find("secretcookie", 1, true))
    assert.falsy(msg:find("hunter2", 1, true))
    local d = diff_calls[1]
    assert.equal(f, vim.api.nvim_buf_get_name(d.buf))
    assert.are.same({ 2, 7 }, d.range)
    assert.equal("Content-Type: application/json", d.lines[4])
  end)

  local FIX_FILE = '@b = http://x\n\n### Create\n# @name create\nPOST {{b}}/items\n\n{"a": 1,}\n\n### Other\nGET /o\n'
  local FIX_ANSWER = '```http\n### Create\n# @name create\nPOST {{b}}/items\n\n{"a": 1}\n```'

  local function fail_create(f)
    h.write(f, FIX_FILE)
    local req = require("slop.modules.rest.discover").parse(f).requests[1]
    require("slop.modules.rest.api")._state.failed[root] = { req = req, err = "HTTP 400" }
    answer = FIX_ANSWER
  end

  it("fix keeps targeting the block when lines are added above it while the AI answers", function()
    local f = root .. "/moved.http"
    fail_create(f)
    require("slop").rest.fix()
    -- the answer arrives asynchronously; meanwhile the user edits above the block
    local buf = vim.fn.bufadd(f)
    vim.api.nvim_buf_set_lines(buf, 0, 0, false, { "@extra = 1", "" })
    wait_diff()
    assert.are.same({ 4, 9 }, diff_calls[1].range)
    assert.equal("### Create", vim.api.nvim_buf_get_lines(buf, 4, 5, false)[1])
  end)

  it("fix shows the answer raw when the block was deleted while the AI answered", function()
    local f = root .. "/gone.http"
    fail_create(f)
    require("slop").rest.fix()
    vim.api.nvim_buf_set_lines(vim.fn.bufadd(f), 2, 8, false, {})
    assert.is_true(vim.wait(2000, function()
      return vim.iter(notes):any(function(n)
        return n.msg:find("the request block was deleted", 1, true) ~= nil
      end)
    end, 10))
    assert.equal(0, #diff_calls)
    assert.truthy(require("slop.core.ui.scratch").find("rest/ai-output"))
  end)

  it("fix with untitled requests fixes the one under the cursor, not the last failed one", function()
    local f = root .. "/untitled.http"
    h.write(f, "###\nGET http://x/nope\n\n###\nDELETE http://x/other\n")
    vim.cmd.edit(f)
    local first = require("slop.modules.rest.api").request_at_cursor(0)
    require("slop.modules.rest.api")._state.failed[root] = { req = first, err = "HTTP 404" }
    vim.api.nvim_win_set_cursor(0, { 5, 0 })
    answer = "```http\n###\nDELETE http://x/other/fixed\n```"
    require("slop").rest.fix()
    wait_diff()
    local msg = chat_reqs[1].messages[1].content
    assert.matches("DELETE http://x/other", msg)
    assert.falsy(msg:find("/nope", 1, true))
    assert.are.same({ 3, 5 }, diff_calls[1].range)
  end)

  it("gen detects a minified OpenAPI JSON file and caps every context at MAX_CONTEXT", function()
    local ai = require("slop.modules.rest.ai")
    local paths = {}
    for i = 1, 3000 do
      paths[i] = ('"/items/%d":{"get":{"summary":"Get item %d"}}'):format(i, i)
    end
    h.write(root .. "/openapi.json", '{"openapi":"3.1.0","paths":{' .. table.concat(paths, ",") .. "}}\n")
    vim.cmd.edit(root .. "/openapi.json")
    assert.is_true(ai.is_openapi(0))
    require("slop").rest.gen()
    wait_diff()
    local msg = chat_reqs[1].messages[1].content
    assert.matches("OpenAPI specification", msg)
    assert.truthy(#msg < ai.MAX_CONTEXT + 4096, #msg)
    -- a minified bundle in code mode: the ±50 lines window is a single huge line
    h.write(root .. "/bundle.js", "function GET(){" .. string.rep("x();", 50000) .. "}\n")
    vim.cmd.edit(root .. "/bundle.js")
    assert.is_false(ai.is_openapi(0))
    require("slop").rest.gen({ mode = "code" })
    wait_diff(2)
    msg = chat_reqs[2].messages[1].content
    assert.matches("truncated", msg)
    assert.truthy(#msg < ai.MAX_CONTEXT + 4096, #msg)
  end)

  it("fix without any failure warns", function()
    require("slop").rest.fix()
    assert.truthy(vim.iter(notes):any(function(n)
      return n.msg:find("no failed request", 1, true) ~= nil
    end))
  end)

  it("acp backend collects agent message chunks", function()
    require("slop").setup({ rest = { ai = { backend = "acp", agent = "fake" } } })
    local prompted
    package.loaded["slop.services.ai.acp"] = {
      text = function(t)
        return { type = "text", text = t }
      end,
      block_text = function(b)
        return b.text
      end,
      client = function(o)
        assert.equal("fake", o.agent)
        return {
          new_session = function(_, _, cb)
            cb({
              prompt = function(_, blocks, handlers)
                prompted = blocks[1].text
                vim.schedule(function()
                  handlers.on_update({
                    sessionUpdate = "agent_message_chunk",
                    content = { type = "text", text = "```http\n" },
                  })
                  handlers.on_update({
                    sessionUpdate = "agent_message_chunk",
                    content = { type = "text", text = "GET /from-agent\n```" },
                  })
                  handlers.on_done("end_turn")
                end)
              end,
              close = function() end,
            })
          end,
        }
      end,
    }
    h.write(root .. "/y.http", "GET http://y/\n")
    vim.cmd.edit(root .. "/y.http")
    require("slop").rest.gen({ mode = "desc", text = "agent please" })
    wait_diff()
    assert.equal(0, #chat_reqs)
    assert.matches("agent please", prompted)
    assert.are.same({ "", "GET /from-agent" }, diff_calls[1].lines)
  end)
end)

describe("rest ai with the real core.ui.diff", function()
  it("previews the generated request in the buffer", function()
    h.reset()
    vim.notify = function() end
    local root = h.tmpdir("realdiff")
    vim.fn.mkdir(root .. "/.git", "p")
    vim.cmd.cd(root)
    h.source_plugin()
    require("slop").setup({})
    require("slop.core.registry").service = function()
      return {
        chat = function(req)
          vim.schedule(function()
            req.on_done(ANSWER)
          end)
        end,
      }
    end
    local ok_diff = pcall(require("slop.core.ui.diff").compute, { "a" }, { "b" })
    if not ok_diff then
      return -- diff not implemented in this tree
    end
    h.write(root .. "/z.http", "GET http://z/\n")
    vim.cmd.edit(root .. "/z.http")
    require("slop").rest.gen({ mode = "desc", text = "x" })
    assert.is_true(vim.wait(3000, function()
      return #require("slop.core.ui.diff").list(0) > 0
    end))
    local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    assert.are.same({ "GET http://z/", "", "### List users", "# @name listUsers", "GET {{baseUrl}}/users" }, lines)
    require("slop.core.ui.diff").list(0)[1]:reject_all()
    assert.are.same({ "GET http://z/" }, vim.api.nvim_buf_get_lines(0, 0, -1, false))
  end)
end)

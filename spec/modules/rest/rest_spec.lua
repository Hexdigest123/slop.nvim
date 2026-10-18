local h = require("helpers")

local function wait_for(fn, ms)
  assert.is_true(vim.wait(ms or 10000, fn, 10), "timed out")
end

describe("rest module", function()
  local mock, srv, root, rest, notes

  local function http_file(rel, text)
    h.write(root .. "/" .. rel, text)
    return root .. "/" .. rel
  end

  local function result_buf()
    return require("slop.core.ui.scratch").find("rest/result")
  end

  local function run_and_wait(fn)
    local n = #srv.requests
    local done = false
    local sub = require("slop.core.events").on("rest", "Response", function()
      done = true
    end)
    fn()
    wait_for(function()
      return done and #srv.requests > n
    end)
    require("slop.core.events").off(sub)
    -- wait for the view (async pretty-print)
    vim.wait(300, function()
      local b = result_buf()
      return b and vim.api.nvim_buf_get_lines(b, 0, 1, false)[1] ~= ""
    end)
  end

  before_each(function()
    h.reset()
    notes = {}
    vim.notify = function(msg, level)
      notes[#notes + 1] = { msg = msg, level = level }
    end
    vim.cmd("silent! tabonly | silent! only | enew!")
    root = h.tmpdir("restroot")
    vim.fn.mkdir(root .. "/.git", "p")
    vim.cmd.cd(root)
    mock = require("services.ai.mock_server")
    srv = mock.start(function(req, res)
      if req.path == "/login" then
        res.send(200, vim.json.encode({ token = "tok-" .. (req.body:match('"user":%s*"(%w+)"') or "?") }), {
          ["Content-Type"] = "application/json",
          ["Set-Cookie"] = "sid=s1; Path=/",
        })
      elseif req.path == "/me" then
        res.send(200, vim.json.encode({ auth = req.headers.authorization or "none", cookie = req.headers.cookie }), {
          ["Content-Type"] = "application/json; charset=utf-8",
        })
      elseif req.path == "/fail" then
        res.send(500, "boom", { ["Content-Type"] = "text/plain" })
      else
        res.send(404, "nope")
      end
    end)
    h.source_plugin()
    require("slop").setup({})
    rest = require("slop").rest
  end)

  after_each(function()
    srv:stop()
  end)

  it("discovers .http/.rest files, skips node_modules, ignores .gitignore", function()
    h.write(root .. "/.gitignore", "requests.http\n")
    http_file("requests.http", "### a\nGET http://x/a")
    http_file("api/users.rest", "### b\nGET http://x/b")
    http_file("node_modules/pkg/x.http", "### c\nGET http://x/c")
    http_file("deep/a/b/c/d.http", "### d\nGET http://x/d")
    local titles = vim.tbl_map(function(r)
      return r.title
    end, rest.requests(root))
    table.sort(titles)
    assert.are.same({ "a", "b", "d" }, titles)
  end)

  it("discovery cache is invalidated on write", function()
    local f = http_file("one.http", "### a\nGET http://x/a")
    assert.equal(1, #rest.requests(root))
    http_file("two.http", "### b\nGET http://x/b")
    assert.equal(1, #rest.requests(root)) -- cached
    vim.cmd.edit(f)
    vim.cmd("silent write")
    assert.equal(2, #rest.requests(root))
  end)

  it("runs the request under the cursor with <CR>, shows a pretty JSON body and winbar", function()
    local f = http_file(
      "api.http",
      ("@base = %s\n\n### Login\n# @name login\nPOST {{base}}/login\nContent-Type: application/json\n\n"):format(
        srv.url
      ) .. '{"user": "ann"}\n'
    )
    vim.cmd.edit(f)
    assert.equal("http", vim.bo.filetype)
    vim.api.nvim_win_set_cursor(0, { 5, 0 })
    local src = vim.api.nvim_get_current_win()
    run_and_wait(function()
      h.feed("<CR>")
    end)
    assert.equal('{"user": "ann"}', srv.requests[1].body)
    local buf = assert(result_buf())
    assert.equal("json", vim.bo[buf].filetype)
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    assert.are.same({ "{", '  "token": "tok-ann"', "}" }, lines)
    local win = require("slop.core.ui.scratch").win(buf)
    assert.not_nil(win)
    assert.equal(src, vim.api.nvim_get_current_win()) -- focus stays in the source
    assert.matches("200 OK", vim.wo[win].winbar)
    assert.matches("POST /login", vim.wo[win].winbar)
    -- H toggles the headers block
    vim.api.nvim_set_current_win(win)
    h.feed("H")
    local marks = vim.api.nvim_buf_get_extmarks(buf, -1, 0, -1, { details = true })
    assert.equal(1, #marks)
    local vl = marks[1][4].virt_lines
    assert.matches("^HTTP/1.1 200", vl[1][1][1])
    h.feed("H")
    assert.equal(0, #vim.api.nvim_buf_get_extmarks(buf, -1, 0, -1, {}))
    -- the result window is reused
    vim.api.nvim_set_current_win(src)
    run_and_wait(function()
      rest.run_cursor()
    end)
    assert.equal(2, #vim.api.nvim_tabpage_list_wins(0))
  end)

  it("chains: runs the missing dependency first, then uses its response and the cookie jar", function()
    local f = http_file(
      "chain.http",
      table.concat({
        "@base = " .. srv.url,
        "@token = {{login.response.body.$.token}}",
        "### Login",
        "# @name login",
        "POST {{base}}/login",
        "",
        '{"user": "bob"}',
        "",
        "### Me",
        "# @name me",
        "GET {{base}}/me",
        "Authorization: Bearer {{token}}",
      }, "\n")
    )
    vim.cmd.edit(f)
    vim.api.nvim_win_set_cursor(0, { 11, 0 })
    run_and_wait(function()
      rest.run_cursor()
    end)
    wait_for(function()
      return #srv.requests == 2
    end)
    assert.equal("/login", srv.requests[1].path)
    assert.equal("/me", srv.requests[2].path)
    wait_for(function()
      return table.concat(vim.api.nvim_buf_get_lines(result_buf(), 0, -1, false), "\n"):find("auth") ~= nil
    end)
    local body = vim.json.decode(table.concat(vim.api.nvim_buf_get_lines(result_buf(), 0, -1, false), "\n"))
    assert.equal("Bearer tok-bob", body.auth)
    assert.equal("sid=s1", body.cookie)
    -- jar lives in the project state dir, which is gitignored
    assert.truthy(vim.uv.fs_stat(root .. "/.nvim/state/rest/cookies.txt"))
    assert.matches("state/", h.read(root .. "/.nvim/.gitignore"))
    -- second run: login response is in memory, only /me is sent
    run_and_wait(function()
      rest.run_cursor()
    end)
    assert.equal(3, #srv.requests)
    assert.equal("/me", srv.requests[3].path)
  end)

  it("blocks sending on unresolved variables with an error naming them (and a diagnostic)", function()
    local f = http_file("bad.http", "### Bad\nGET {{nowhere}}/x?{{alsoMissing}}")
    vim.cmd.edit(f)
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    rest.run_cursor()
    vim.wait(200)
    assert.equal(0, #srv.requests)
    local found = false
    for _, n in ipairs(notes) do
      if n.msg:find("unresolved variables: {{nowhere}}, {{alsoMissing}}", 1, true) then
        found = true
        assert.equal(vim.log.levels.ERROR, n.level)
      end
    end
    assert.is_true(found)
    local diags = vim.diagnostic.get(0, { severity = vim.diagnostic.severity.ERROR })
    assert.equal(1, #diags)
    assert.equal(1, diags[1].lnum)
  end)

  it("reports dependency cycles without sending", function()
    local f =
      http_file("cyc.http", "# @name a\n# @depends b\nGET http://x/a\n###\n# @name b\n# @depends a\nGET http://x/b")
    vim.cmd.edit(f)
    vim.api.nvim_win_set_cursor(0, { 3, 0 })
    rest.run_cursor()
    vim.wait(100)
    assert.equal(0, #srv.requests)
    assert.truthy(vim.iter(notes):any(function(n)
      return n.msg:find("dependency cycle: a -> b -> a", 1, true) ~= nil
    end))
  end)

  it("@prompt asks via vim.ui.input (prompt beats file vars), cancel aborts", function()
    local f = http_file(
      "prompt.http",
      ('@who = file\n# @prompt who Who are you\nPOST %s/login\n\n{"user": "{{who}}"}'):format(srv.url)
    )
    local asked
    vim.ui.input = function(o, cb)
      asked = o
      cb("carl")
    end
    vim.cmd.edit(f)
    vim.api.nvim_win_set_cursor(0, { 3, 0 })
    run_and_wait(function()
      rest.run_cursor()
    end)
    assert.equal("Who are you: ", asked.prompt)
    assert.equal('{"user": "carl"}', srv.requests[1].body)
    vim.ui.input = function(o, cb)
      asked = o
      cb(nil)
    end
    rest.run_cursor()
    vim.wait(100)
    assert.equal("carl", asked.default) -- last answer offered
    assert.equal(1, #srv.requests)
  end)

  it("uses the selected env (persisted) and .env values", function()
    h.write(
      root .. "/http-client.env.json",
      vim.json.encode({ dev = { base = srv.url }, prod = { base = "http://127.0.0.1:1" } })
    )
    h.write(root .. "/.env", "USERNAME_X=dora\n")
    local f = http_file("env.http", 'POST {{base}}/login\n\n{"user": "{{USERNAME_X}}"}')
    assert.equal("dev", rest.current_env()) -- default when it exists
    rest.env("prod")
    assert.equal("prod", rest.current_env())
    local hist = vim.json.decode(h.read(root .. "/.nvim/state/rest/history.json"))
    assert.equal("prod", hist.env)
    rest.env("dev")
    vim.cmd.edit(f)
    run_and_wait(function()
      rest.run_cursor()
    end)
    assert.equal('{"user": "dora"}', srv.requests[1].body)
    local win = require("slop.core.ui.scratch").win("rest/result")
    assert.matches("%[dev%]", vim.wo[win].winbar)
  end)

  it("<leader>rl re-reads the file and reruns the last request", function()
    local f = http_file("last.http", ('### L\n# @name l\nPOST %s/login\n\n{"user": "v1"}'):format(srv.url))
    vim.cmd.edit(f)
    run_and_wait(function()
      rest.run_cursor()
    end)
    vim.cmd("bwipe!")
    h.write(f, ('### L\n# @name l\nPOST %s/login\n\n{"user": "v2"}'):format(srv.url))
    run_and_wait(function()
      h.feed(" rl")
    end)
    assert.equal('{"user": "v2"}', srv.requests[2].body)
    local hist = vim.json.decode(h.read(root .. "/.nvim/state/rest/history.json"))
    assert.equal("last.http", hist.last.file)
    assert.equal("l", hist.last.name)
    assert.equal("last.http#l", hist.recent[1])
  end)

  it("picker lists every request, recent first, with preview; selecting runs it", function()
    http_file("a.http", ("### First\nPOST %s/login\n\n{}\n### Second\nGET %s/me"):format(srv.url, srv.url))
    http_file("sub/b.http", ("### Third\nGET %s/fail"):format(srv.url))
    local captured
    package.loaded["slop.core.ui.picker"] = {
      pick = function(items, opts)
        captured = { items = items, opts = opts }
      end,
    }
    rest.pick()
    local labels = vim.tbl_map(function(it)
      return it.title
    end, captured.items)
    assert.are.same({ "First", "Second", "Third" }, labels)
    local text = table.concat(vim.tbl_map(function(c)
      return c[1]
    end, captured.opts.format(captured.items[3])))
    assert.matches("^sub/b%.http › Third", text)
    assert.matches("GET", text)
    local pv = captured.opts.preview(captured.items[2])
    assert.equal("http", pv.filetype)
    assert.are.same({ "### Second", "GET " .. srv.url .. "/me" }, pv.lines)
    run_and_wait(function()
      captured.opts.on_select(captured.items[3])
    end)
    assert.equal("/fail", srv.requests[1].path)
    local win = require("slop.core.ui.scratch").win("rest/result")
    assert.matches("500", vim.wo[win].winbar)
    -- reopen: the run request is now first
    rest.pick()
    assert.equal("Third", captured.items[1].title)
    -- <C-e> action jumps to the request
    local second = vim.iter(captured.items):find(function(it)
      return it.title == "Second"
    end)
    captured.opts.on_select(second, "edit")
    assert.equal(root .. "/a.http", vim.api.nvim_buf_get_name(0))
    assert.equal(6, vim.api.nvim_win_get_cursor(0)[1])
  end)

  it("<leader>rr outside http buffers opens the picker; keymaps never use <leader>rn", function()
    local called = false
    package.loaded["slop.core.ui.picker"] = {
      pick = function()
        called = true
      end,
    }
    http_file("x.http", "GET http://x/")
    h.feed(" rr")
    assert.is_true(called)
    assert.equal("", vim.fn.maparg("<leader>rn", "n"))
  end)

  it("connection errors are shown in the view", function()
    local f = http_file("down.http", "# @timeout 3s\nGET http://127.0.0.1:1/x")
    vim.cmd.edit(f)
    local entry
    require("slop.modules.rest.api").run(require("slop.modules.rest.api").request_at_cursor(0), {
      on_done = function(e)
        entry = e
      end,
    })
    wait_for(function()
      return entry ~= nil
    end)
    assert.matches("onnect", entry.err)
    local win = require("slop.core.ui.scratch").win("rest/result")
    assert.matches("✗", vim.wo[win].winbar)
  end)

  it("commands: :Slop rest run <name>, env completion, cookies clear", function()
    http_file("n.http", ('### N\n# @name named\nPOST %s/login\n\n{"user": "n"}'):format(srv.url))
    run_and_wait(function()
      vim.cmd("Slop rest run named")
    end)
    assert.equal("/login", srv.requests[1].path)
    local spec = require("slop.core.registry").spec("rest")
    assert.are.same({ "named" }, spec.commands.run.complete("na", {}))
    assert.truthy(vim.uv.fs_stat(root .. "/.nvim/state/rest/cookies.txt"))
    vim.cmd("Slop rest cookies clear")
    assert.falsy(vim.uv.fs_stat(root .. "/.nvim/state/rest/cookies.txt"))
  end)

  it("lints parser warnings as diagnostics", function()
    local f = http_file("lint.http", "POST http://x/a\n\n{}\n> {% client.global.set('a', 1) %}")
    vim.cmd.edit(f)
    local d = vim.diagnostic.get(0)
    assert.equal(1, #d)
    assert.matches("script blocks", d[1].message)
  end)
end)

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
      elseif req.path == "/auth" then
        if req.body:find('"pw": "right"', 1, true) then
          res.json(200, { token = "tok-right" })
        else
          res.json(401, { error = "bad password" })
        end
      elseif req.path == "/hang" then
        res.hang()
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
    -- (ignore floats: the progress module shows the request in one)
    local splits = vim.tbl_filter(function(w)
      return vim.api.nvim_win_get_config(w).relative == ""
    end, vim.api.nvim_tabpage_list_wins(0))
    assert.equal(2, #splits)
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
    -- the file the lines come from: cloak masks the preview like that file (Authorization: values)
    assert.equal(captured.items[2].req.file, pv.path)
    assert.matches("a%.http$", pv.path)
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

  it("picker columns stay aligned with wide (CJK) titles", function()
    http_file("w.http", ("### %s\nGET http://x/a\n### short\nGET http://x/b"):format(string.rep("漢字", 30)))
    local captured
    package.loaded["slop.core.ui.picker"] = {
      pick = function(items, opts)
        captured = { items = items, opts = opts }
      end,
    }
    rest.pick()
    local widths = vim.tbl_map(function(it)
      local chunks = captured.opts.format(it)
      return vim.fn.strdisplaywidth(chunks[1][1] .. chunks[2][1] .. chunks[3][1])
    end, captured.items)
    assert.equal(widths[1], widths[2])
    local title = captured.opts.format(captured.items[1])[3][1]
    assert.equal(48, vim.fn.strdisplaywidth(title))
    assert.matches("…%s*$", title)
  end)

  it("works with the real builtin picker (filter + <CR> runs)", function()
    require("slop").setup({ ui = { picker = "builtin" } })
    http_file("p.http", ("### Alpha\nGET %s/me\n### Beta login\nPOST %s/login\n\n{}"):format(srv.url, srv.url))
    rest.pick()
    local prompt = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_lines(prompt, 0, -1, false, { "beta" })
    vim.api.nvim_exec_autocmds("TextChangedI", { buf = prompt })
    run_and_wait(function()
      h.feed("<CR>")
    end)
    assert.equal("/login", srv.requests[1].path)
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

  it(":Slop rest run <name> in a non-http buffer does not run request-like lines of that buffer", function()
    http_file("n.http", ('### Login\nPOST %s/login\n\n{"user": "real"}'):format(srv.url))
    -- API docs in Markdown: same heading, a request-like line below it
    h.write(root .. "/README.md", ("### Login\nGET %s/me\n"):format(srv.url))
    vim.cmd.edit(root .. "/README.md")
    run_and_wait(function()
      vim.cmd("Slop rest run Login")
    end)
    assert.equal("/login", srv.requests[1].path)
  end)

  it(":Slop rest run <name> prefers the current http file, wherever its cursor is", function()
    http_file("a_other.http", ("### x\n# @name dup\nGET %s/fail"):format(srv.url))
    local f = http_file("b_mine.http", ("@v = 1\n\n### x\n# @name dup\nGET %s/me"):format(srv.url))
    vim.cmd.edit(f)
    vim.api.nvim_win_set_cursor(0, { 1, 0 }) -- on the file variables, outside every request block
    run_and_wait(function()
      vim.cmd("Slop rest run dup")
    end)
    assert.equal("/me", srv.requests[1].path)
  end)

  it("<CR> in a block without a request line runs nothing (not the request above it)", function()
    local f = http_file("draft.http", ("### Delete\nDELETE %s/me\n\n### Draft\n# TODO\n"):format(srv.url))
    vim.cmd.edit(f)
    vim.api.nvim_win_set_cursor(0, { 5, 0 })
    h.feed("<CR>")
    vim.wait(100)
    assert.equal(0, #srv.requests)
    assert.truthy(vim.iter(notes):any(function(n)
      return n.msg:find("no request under the cursor", 1, true) ~= nil
    end))
  end)

  it("lints parser warnings as diagnostics", function()
    local f = http_file("lint.http", "POST http://x/a\n\n{}\n> {% client.global.set('a', 1) %}")
    vim.cmd.edit(f)
    local d = vim.diagnostic.get(0)
    assert.equal(1, #d)
    assert.matches("script blocks", d[1].message)
  end)

  it("<CR> runs the request under the cursor of the CURRENT window (buffer shown twice)", function()
    local f = http_file("two.http", ("### one\nGET %s/me?one\n\n### two\nGET %s/me?two"):format(srv.url, srv.url))
    vim.cmd.edit(f)
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    vim.cmd("belowright split")
    vim.api.nvim_win_set_cursor(0, { 5, 0 })
    assert.not_equal(vim.api.nvim_get_current_win(), vim.fn.bufwinid(0)) -- the first window is the other one
    run_and_wait(function()
      h.feed("<CR>")
    end)
    assert.equal("two", srv.requests[1].query)
  end)

  it("a dependency answering >= 400 stops the run, and runs again the next time", function()
    local f = http_file(
      "dep.http",
      table.concat({
        "@pw = wrong",
        "### Auth",
        "# @name auth",
        ("POST %s/auth"):format(srv.url),
        "",
        '{"pw": "{{pw}}"}',
        "",
        "### Me",
        "# @name me",
        ("GET %s/me"):format(srv.url),
        "Authorization: Bearer {{auth.response.body.$.token}}",
      }, "\n")
    )
    vim.cmd.edit(f)
    vim.api.nvim_win_set_cursor(0, { 10, 0 })
    local api = require("slop.modules.rest.api")
    local entry
    local function run()
      entry = nil
      api.run(api.request_at_cursor(0), {
        on_done = function(e)
          entry = e
        end,
      })
      wait_for(function()
        return entry ~= nil
      end)
    end
    run()
    assert.equal("dependency 'auth' failed: HTTP 401 Unauthorized", entry.err)
    assert.equal(401, entry.res.status) -- the dependency's response is what the view shows
    assert.equal(1, #srv.requests)
    -- the password is fixed: the failed response must not count as "auth already ran"
    vim.api.nvim_buf_set_lines(0, 0, 1, false, { "@pw = right" })
    run()
    assert.is_nil(entry.err)
    assert.are.same({ "/auth", "/auth", "/me" }, {
      srv.requests[1].path,
      srv.requests[2].path,
      srv.requests[3].path,
    })
    assert.equal("Bearer tok-right", vim.json.decode(entry.res.body).auth)
  end)

  it("an unwritable project root does not stop requests (no history, no jar, warned once)", function()
    local ro = h.tmpdir("readonly")
    vim.fn.mkdir(ro .. "/.git", "p")
    h.write(ro .. "/ro.http", ("GET %s/me"):format(srv.url))
    vim.cmd.edit(ro .. "/ro.http")
    vim.uv.fs_chmod(ro, 365) -- 0555
    local enforced = vim.fn.filewritable(ro) == 0 -- (root ignores permissions)
    local ok, err = pcall(function()
      run_and_wait(function()
        rest.run_cursor()
      end)
      run_and_wait(function()
        rest.run_cursor()
      end)
    end)
    vim.uv.fs_chmod(ro, 493)
    assert.is_true(ok, tostring(err))
    assert.equal(2, #srv.requests)
    if enforced then
      local warned = vim.tbl_filter(function(n)
        return n.msg:find("cannot create the state folder", 1, true) ~= nil
      end, notes)
      assert.equal(1, #warned)
      assert.is_nil(vim.uv.fs_stat(ro .. "/.nvim"))
    end
  end)

  it("keeps the state folder, the history and the cookie jar private", function()
    local f = http_file("p.http", ('POST %s/login\n\n{"user": "p"}'):format(srv.url))
    vim.cmd.edit(f)
    run_and_wait(function()
      rest.run_cursor()
    end)
    local dir = root .. "/.nvim/state/rest"
    assert.equal(448, vim.uv.fs_stat(dir).mode % 512)
    assert.equal(384, vim.uv.fs_stat(dir .. "/cookies.txt").mode % 512)
    assert.equal(384, vim.uv.fs_stat(dir .. "/history.json").mode % 512)
  end)

  it("cancel replaces the running state of the view", function()
    local f = http_file("hang.http", ("GET %s/hang"):format(srv.url))
    vim.cmd.edit(f)
    rest.run_cursor()
    wait_for(function()
      return #srv.requests == 1
    end)
    local win = require("slop.core.ui.scratch").win("rest/result")
    assert.matches("running", vim.wo[win].winbar)
    assert.is_true(rest.cancel())
    assert.matches("request cancelled", vim.wo[win].winbar)
    assert.falsy(vim.wo[win].winbar:find("running", 1, true))
  end)

  it("r in the result window reruns in the project of the request, not the cwd's", function()
    local other = h.tmpdir("other")
    vim.fn.mkdir(other .. "/.git", "p")
    h.write(other .. "/http-client.env.json", vim.json.encode({ dev = { base = srv.url } }))
    h.write(other .. "/o.http", "### o\n# @name o\nGET {{base}}/me")
    vim.cmd.edit(other .. "/o.http") -- the cwd stays `root`
    vim.api.nvim_win_set_cursor(0, { 3, 0 })
    run_and_wait(function()
      rest.run_cursor()
    end)
    vim.api.nvim_set_current_win(require("slop.core.ui.scratch").win("rest/result"))
    local api = require("slop.modules.rest.api")
    assert.equal(other, api.root())
    run_and_wait(function()
      h.feed("r")
    end)
    assert.equal(2, #srv.requests)
    assert.is_nil(api._state.results[root])
    assert.equal(200, api._state.results[other].res.status)
  end)

  it("chains inside an unnamed http buffer", function()
    vim.cmd("enew")
    vim.bo.filetype = "http"
    vim.api.nvim_buf_set_lines(0, 0, -1, false, {
      "@base = " .. srv.url,
      "### Login",
      "# @name login",
      "POST {{base}}/login",
      "",
      '{"user": "unnamed"}',
      "",
      "### Me",
      "# @name me",
      "GET {{base}}/me",
      "Authorization: Bearer {{login.response.body.$.token}}",
    })
    vim.api.nvim_win_set_cursor(0, { 10, 0 })
    run_and_wait(function()
      rest.run_cursor()
    end)
    wait_for(function()
      return #srv.requests == 2
    end)
    assert.are.same({ "/login", "/me" }, { srv.requests[1].path, srv.requests[2].path })
    assert.equal("Bearer tok-unnamed", srv.requests[2].headers.authorization)
  end)

  it("a loaded <file>.orig buffer does not replace the requests of <file>", function()
    local f = http_file("api.http", "### Real\n# @name real\nGET http://x/real")
    h.write(root .. "/api.http.orig", "### Old\n# @name old\nDELETE http://x/old")
    vim.cmd.edit(root .. "/api.http.orig") -- only the backup is loaded
    local p = require("slop.modules.rest.discover").parse(f)
    assert.are.same({ "real", "GET", "http://x/real" }, { p.requests[1].name, p.requests[1].method, p.requests[1].url })
    local of_file = vim.tbl_filter(function(r)
      return r.file == f
    end, rest.requests(root))
    assert.are.same(
      { "real" },
      vim.tbl_map(function(r)
        return r.name
      end, of_file)
    )
  end)

  it("status() never scans the project", function()
    h.write(root .. "/http-client.env.json", vim.json.encode({ dev = { base = "x" } }))
    local discover = require("slop.modules.rest.discover")
    local scan, scans = discover.scan, 0
    discover.scan = function(...)
      scans = scans + 1
      return scan(...)
    end
    discover.invalidate()
    for _ = 1, 5 do
      assert.equal("", rest.status())
    end
    assert.equal(0, scans)
    discover.get(root) -- a picker / run scanned meanwhile
    assert.equal("rest[dev]", rest.status())
    require("slop.modules.rest.history").set_env(root, "prod")
    assert.equal("rest[prod]", rest.status())
    assert.equal(1, scans)
  end)

  it("running a request does not scan the project (the dev default comes from the env files it sees)", function()
    h.write(root .. "/api/http-client.env.json", vim.json.encode({ dev = { base = srv.url } }))
    local f = http_file("api/e.http", "GET {{base}}/me")
    local discover = require("slop.modules.rest.discover")
    local scan, scans = discover.scan, 0
    discover.scan = function(...)
      scans = scans + 1
      return scan(...)
    end
    discover.invalidate()
    vim.cmd.edit(f)
    local entry
    local api = require("slop.modules.rest.api")
    api.run(api.request_at_cursor(0), {
      on_done = function(e)
        entry = e
      end,
    })
    wait_for(function()
      return entry ~= nil
    end)
    assert.equal(200, entry.res.status)
    assert.equal("dev", entry.env)
    assert.equal(0, scans)
  end)

  it("the parse cache notices a same-size rewrite within the same second", function()
    local f = http_file("same.http", "GET http://x/aaaa")
    local discover = require("slop.modules.rest.discover")
    assert.equal("http://x/aaaa", discover.parse(f).requests[1].url)
    h.write(f, "GET http://x/bbbb")
    assert.equal("http://x/bbbb", discover.parse(f).requests[1].url)
  end)

  it("a late pretty-print of an older response does not overwrite a newer result", function()
    local view = require("slop.modules.rest.view")
    local format, pending = view.format, nil
    view.format = function(body, _, _, cb)
      pending = function()
        cb(body)
      end
    end
    local old = { status = 200, headers = {}, body = '{"old": true}', content_type = "application/json" }
    view.show({ req = { method = "GET", url = "/a" }, res = old })
    view.format = format
    view.show({ req = { method = "GET", url = "/b" }, err = "GET /b: unresolved variable: {{id}}" })
    pending() -- the old pretty-printer finishes last
    local buf = assert(result_buf())
    assert.equal("GET /b: unresolved variable: {{id}}", vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1])
  end)

  it("the result keys (H, q, r) are back after the result buffer was :bdelete'd", function()
    local view = require("slop.modules.rest.view")
    local function show()
      local shown
      local res = { status = 200, headers = {}, body = "hi", content_type = "text/plain" }
      view.show({ req = { method = "GET", url = "/x" }, res = res }, function(b)
        shown = b
      end)
      wait_for(function()
        return shown ~= nil
      end)
      return shown
    end
    vim.cmd("bdelete! " .. show()) -- clears the buffer's mappings (the buffer itself stays)
    local buf = show()
    local lhs = vim.tbl_map(function(m)
      return m.lhs
    end, vim.api.nvim_buf_get_keymap(buf, "n"))
    for _, key in ipairs({ "H", "q", "r" }) do
      assert.truthy(vim.tbl_contains(lhs, key), key .. " not mapped: " .. vim.inspect(lhs))
    end
  end)

  it("shows CRLF text bodies without CRs and SVG as XML", function()
    local view = require("slop.modules.rest.view")
    local function show(ctype, body)
      local shown
      local res = { status = 200, headers = {}, body = body, content_type = ctype }
      view.show({ req = { method = "GET", url = "/x" }, res = res }, function(b)
        shown = b
      end)
      wait_for(function()
        return shown ~= nil
      end)
      return vim.api.nvim_buf_get_lines(shown, 0, -1, false), vim.bo[shown].filetype
    end
    assert.are.same({ "line one", "line two" }, (show("text/plain", "line one\r\nline two\r\n")))
    local lines, ft = show("image/svg+xml", '<svg xmlns="http://www.w3.org/2000/svg"/>')
    assert.equal("xml", ft)
    assert.truthy(table.concat(lines, "\n"):find("<svg", 1, true))
    assert.is_true(view.is_binary("\0\1", "image/png"))
  end)
end)

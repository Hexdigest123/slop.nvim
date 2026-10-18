local parser = require("slop.modules.rest.parser")
local chain = require("slop.modules.rest.chain")

local function setup(text, have)
  local parsed = parser.parse(vim.split(text, "\n", { plain = true }), "/p/a.http")
  local by = {}
  for _, r in ipairs(parsed.requests) do
    by[r.name] = r
  end
  local opts = {
    lookup = function(name)
      return by[name], by[name] == nil and ("unknown request '%s'"):format(name) or nil
    end,
    has_response = function(r)
      return (have or {})[r.name] == true
    end,
    file_vars = function(r)
      return parser.file_vars(parsed, r)
    end,
  }
  return by, opts
end

local function names(plan)
  return vim.tbl_map(function(r)
    return r.name
  end, plan)
end

local FILE = table.concat({
  "@token = {{login.response.body.$.token}}",
  "### login",
  "# @name login",
  "POST /login",
  "### me",
  "# @name me",
  "GET /me",
  "Authorization: Bearer {{token}}",
  "### order",
  "# @name order",
  "# @depends me",
  "POST /orders",
  "X-User: {{me.response.body.$.id}}",
  "",
  '{"by": "{{me.response.headers.X-Id}}"}',
  "### pay",
  "# @name pay",
  "POST /pay/{{order.response.body.$.id}}",
}, "\n")

describe("rest chain", function()
  it("deps(): explicit + inferred (url, headers, body, file vars transitively), unique", function()
    local by, opts = setup(FILE)
    assert.are.same({}, chain.deps(by.login, opts.file_vars(by.login)))
    assert.are.same({ "login" }, chain.deps(by.me, opts.file_vars(by.me)))
    assert.are.same({ "me" }, chain.deps(by.order, opts.file_vars(by.order)))
    assert.are.same({ "order" }, chain.deps(by.pay, opts.file_vars(by.pay)))
  end)

  local plans = {
    { "no deps", "login", {}, { "login" } },
    { "one missing dep", "me", {}, { "login", "me" } },
    { "transitive, topological", "pay", {}, { "login", "me", "order", "pay" } },
    { "deps with responses are not re-run", "pay", { me = true }, { "order", "pay" } },
    { "target is always run even with a response", "me", { me = true, login = true }, { "me" } },
  }
  for _, c in ipairs(plans) do
    it("plan(): " .. c[1], function()
      local by, opts = setup(FILE, c[3])
      local plan, err = chain.plan(by[c[2]], opts)
      assert.is_nil(err)
      assert.are.same(c[4], names(plan))
    end)
  end

  it("diamond dependencies run once", function()
    local by, opts = setup(table.concat({
      "# @name a",
      "GET /a",
      "###",
      "# @name b",
      "# @depends a",
      "GET /b",
      "###",
      "# @name c",
      "# @depends a",
      "GET /c",
      "###",
      "# @name d",
      "# @depends b, c",
      "GET /d",
    }, "\n"))
    assert.are.same({ "a", "b", "c", "d" }, names((chain.plan(by.d, opts))))
  end)

  it("detects cycles and names them", function()
    local by, opts = setup(table.concat({
      "# @name a",
      "# @depends b",
      "GET /a",
      "###",
      "# @name b",
      "GET /b?x={{c.response.body.$.x}}",
      "###",
      "# @name c",
      "# @depends a",
      "GET /c",
    }, "\n"))
    local plan, err = chain.plan(by.a, opts)
    assert.is_nil(plan)
    assert.equal("dependency cycle: a -> b -> c -> a", err)
  end)

  it("a cycle through a dependency that already has a response is not an error", function()
    local by, opts = setup("# @name a\n# @depends b\nGET /a\n###\n# @name b\n# @depends a\nGET /b", { b = true })
    assert.are.same({ "a" }, names((chain.plan(by.a, opts))))
  end)

  it("self references are ignored (they resolve from the previous response)", function()
    local by, opts = setup('# @name refresh\nPOST /r\n\n{"t": "{{refresh.response.body.$.t}}"}')
    assert.are.same({}, chain.deps(by.refresh))
    assert.are.same({ "refresh" }, names((chain.plan(by.refresh, opts))))
  end)

  it("unknown dependencies are errors", function()
    local by, opts = setup("# @name a\n# @depends ghost\nGET /a")
    local plan, err = chain.plan(by.a, opts)
    assert.is_nil(plan)
    assert.equal("unknown request 'ghost'", err)
  end)
end)

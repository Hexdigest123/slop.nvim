--# selene: allow(global_usage)
-- Minimal busted-style test runner for Neovim (no busted/nlua needed).
--
--   nvim --headless --clean -u NONE -l spec/runner.lua [path ...]   (or ./scripts/test [path ...])
--
-- Paths may be spec files, directories, or substrings of spec paths. Default: every spec/**/*_spec.lua.
-- Each spec FILE runs in its own `nvim --headless --clean -u NONE` child process (isolation), with
-- XDG_{DATA,STATE,CACHE,CONFIG}_HOME pointed at a fresh temp dir. Files run in parallel (SLOP_TEST_JOBS).
--
-- Globals inside specs (busted-compatible subset):
--   describe(name, fn)  it(name, fn)  pending(name)  before_each(fn)  after_each(fn)
--   assert(v, msg)  assert.equal/equals(expected, actual)  assert.are.same / assert.same / assert.eq (deep)
--   assert.truthy/falsy  assert.is_true/is_false/is_nil/not_nil
--   assert.has_error/errors(fn, pattern?)  (pattern = Lua pattern, matched against the error message)
--   assert.matches(pattern, str)  assert.not_equal(a, b)  assert.not_same(a, b)
-- Helpers for specs: require("helpers") (spec/helpers.lua).

local uv = vim.uv
local script = vim.fs.normalize(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))
local ROOT = vim.fs.dirname(vim.fs.dirname(script))

local args = _G.arg or {}

---------------------------------------------------------------------------------------------------
-- Child mode: run one spec file in this process.
---------------------------------------------------------------------------------------------------
local function run_child(file)
  vim.opt.rtp:prepend(ROOT)
  package.path = ROOT .. "/spec/?.lua;" .. ROOT .. "/lua/?.lua;" .. ROOT .. "/lua/?/init.lua;" .. package.path
  vim.g.mapleader = " "

  local root_suite = { name = "", children = {}, before = {}, after = {} }
  local current = root_suite

  _G.describe = function(name, fn)
    local suite = { name = name, children = {}, before = {}, after = {}, parent = current }
    table.insert(current.children, suite)
    local prev = current
    current = suite
    local ok, err = pcall(fn)
    current = prev
    if not ok then
      table.insert(suite.children, {
        name = "(describe body)",
        fn = function()
          error(err, 0)
        end,
      })
    end
  end
  _G.it = function(name, fn)
    table.insert(current.children, { name = name, fn = fn })
  end
  _G.pending = function(name)
    table.insert(current.children, { name = name, pending = true })
  end
  _G.before_each = function(fn)
    table.insert(current.before, fn)
  end
  _G.after_each = function(fn)
    table.insert(current.after, fn)
  end

  -- assertions ---------------------------------------------------------------------------------
  local function fail(msg, level)
    error(msg, (level or 1) + 2)
  end
  local function show(v)
    return vim.inspect(v)
  end
  local A = {}
  function A.equal(expected, actual, msg)
    if expected ~= actual then
      fail((msg and msg .. "\n" or "") .. ("expected: %s\n  actual: %s"):format(show(expected), show(actual)))
    end
  end
  A.equals = A.equal
  function A.same(expected, actual, msg)
    if not vim.deep_equal(expected, actual) then
      fail((msg and msg .. "\n" or "") .. ("expected (deep): %s\n  actual: %s"):format(show(expected), show(actual)))
    end
  end
  A.eq = A.same
  function A.not_equal(a, b, msg)
    if a == b then
      fail(msg or ("expected values to differ: %s"):format(show(a)))
    end
  end
  function A.not_same(a, b, msg)
    if vim.deep_equal(a, b) then
      fail(msg or ("expected values to differ (deep): %s"):format(show(a)))
    end
  end
  function A.truthy(v, msg)
    if not v then
      fail(msg or ("expected truthy, got %s"):format(show(v)))
    end
  end
  function A.falsy(v, msg)
    if v then
      fail(msg or ("expected falsy, got %s"):format(show(v)))
    end
  end
  function A.is_true(v, msg)
    A.equal(true, v, msg)
  end
  function A.is_false(v, msg)
    A.equal(false, v, msg)
  end
  function A.is_nil(v, msg)
    A.equal(nil, v, msg)
  end
  function A.not_nil(v, msg)
    if v == nil then
      fail(msg or "expected non-nil")
    end
  end
  A.is_not_nil = A.not_nil
  function A.has_error(fn, pattern, msg)
    local ok, err = pcall(fn)
    if ok then
      fail(msg or "expected an error")
    end
    if pattern and not tostring(err):find(pattern) then
      fail(msg or ("error %s does not match %s"):format(show(tostring(err)), show(pattern)))
    end
  end
  A.errors = A.has_error
  A.error = A.has_error
  function A.matches(pattern, str, msg)
    if type(str) ~= "string" or not str:find(pattern) then
      fail(msg or ("%s does not match pattern %s"):format(show(str), show(pattern)))
    end
  end
  A.are = { same = A.same, equal = A.equal, equals = A.equal }
  A.is = { ["true"] = A.is_true, ["false"] = A.is_false, truthy = A.truthy, falsy = A.falsy, ["nil"] = A.is_nil }
  A.are_not = { same = A.not_same, equal = A.not_equal }
  _G.assert = setmetatable(A, {
    __call = function(_, v, msg, ...)
      if not v then
        fail(msg or "assertion failed!")
      end
      return v, msg, ...
    end,
  })

  -- load + run -----------------------------------------------------------------------------------
  local results = { passed = 0, failed = 0, pending = 0, failures = {} }
  local chunk, lerr = loadfile(file)
  if not chunk then
    io.write(("  ✗ load error: %s\n"):format(lerr))
    io.write("@@RESULT 0 1 0\n")
    return 1
  end
  local ok, err = pcall(chunk)
  if not ok then
    io.write(("  ✗ load error: %s\n"):format(err))
    io.write("@@RESULT 0 1 0\n")
    return 1
  end

  local function chain(suite, field)
    local list = {}
    local s = suite
    local stack = {}
    while s do
      table.insert(stack, 1, s)
      s = s.parent
    end
    for _, x in ipairs(stack) do
      for _, f in ipairs(x[field]) do
        table.insert(list, f)
      end
    end
    if field == "after" then
      local rev = {}
      for i = #list, 1, -1 do
        rev[#rev + 1] = list[i]
      end
      return rev
    end
    return list
  end

  local function run_suite(suite, names)
    for _, child in ipairs(suite.children) do
      local full = vim.list_extend(vim.deepcopy(names), { child.name })
      if child.children then
        run_suite(child, full)
      elseif child.pending then
        results.pending = results.pending + 1
        io.write(("  - %s (pending)\n"):format(table.concat(full, " › ")))
      else
        local tok, terr = true, nil
        for _, f in ipairs(chain(suite, "before")) do
          if tok then
            tok, terr = xpcall(f, debug.traceback)
          end
        end
        if tok then
          tok, terr = xpcall(child.fn, debug.traceback)
        end
        for _, f in ipairs(chain(suite, "after")) do
          local aok, aerr = xpcall(f, debug.traceback)
          if tok and not aok then
            tok, terr = false, aerr
          end
        end
        if tok then
          results.passed = results.passed + 1
          io.write(("  ✓ %s\n"):format(table.concat(full, " › ")))
        else
          results.failed = results.failed + 1
          io.write(("  ✗ %s\n      %s\n"):format(table.concat(full, " › "), tostring(terr):gsub("\n", "\n      ")))
        end
      end
    end
  end
  run_suite(root_suite, {})
  io.write(("@@RESULT %d %d %d\n"):format(results.passed, results.failed, results.pending))
  return results.failed > 0 and 1 or 0
end

---------------------------------------------------------------------------------------------------
-- Parent mode: discover spec files and run each in a child nvim.
---------------------------------------------------------------------------------------------------
local function discover(filters)
  local all = vim.fs.find(function(name)
    return name:match("_spec%.lua$") ~= nil
  end, { path = ROOT .. "/spec", type = "file", limit = math.huge })
  table.sort(all)
  if #filters == 0 then
    return all
  end
  local out, seen = {}, {}
  for _, f in ipairs(filters) do
    local abs = vim.fs.normalize(vim.fn.fnamemodify(f, ":p"))
    for _, file in ipairs(all) do
      if
        not seen[file] and (file == abs or vim.startswith(file, abs:gsub("/$", "") .. "/") or file:find(f, 1, true))
      then
        seen[file] = true
        out[#out + 1] = file
      end
    end
  end
  return out
end

local function run_parent(filters)
  local files = discover(filters)
  if #files == 0 then
    io.write("no spec files found\n")
    return 1
  end
  local nvim = vim.v.progpath
  local jobs = tonumber(os.getenv("SLOP_TEST_JOBS") or "") or math.max(1, math.min(8, #uv.cpu_info()))
  local queue, running, results = vim.list_slice(files), 0, {}
  local total = { passed = 0, failed = 0, pending = 0 }
  local start = uv.hrtime()

  local function start_next()
    local file = table.remove(queue, 1)
    if not file then
      return
    end
    running = running + 1
    local home = vim.fn.tempname()
    vim.fn.mkdir(home, "p")
    local env = {
      XDG_DATA_HOME = home .. "/data",
      XDG_STATE_HOME = home .. "/state",
      XDG_CACHE_HOME = home .. "/cache",
      XDG_CONFIG_HOME = home .. "/config",
      SLOP_TEST_TMP = home,
    }
    vim.system({ nvim, "--headless", "--clean", "-u", "NONE", "-l", script, "--child", file }, {
      cwd = ROOT,
      env = env,
      text = true,
      timeout = 120000,
    }, function(res)
      results[file] = res
      running = running - 1
      vim.schedule(function()
        vim.fn.delete(home, "rf")
        start_next()
      end)
    end)
  end
  for _ = 1, jobs do
    start_next()
  end
  vim.wait(600000, function()
    return running == 0 and #queue == 0
  end, 20)

  local failed_files = {}
  for _, file in ipairs(files) do
    local res = results[file]
    local rel = file:sub(#ROOT + 2)
    io.write(rel .. "\n")
    local out = (res and res.stdout or "") .. ""
    local p, f, pe = out:match("@@RESULT (%d+) (%d+) (%d+)")
    io.write((out:gsub("@@RESULT[^\n]*\n?", "")))
    if res and res.stderr and res.stderr ~= "" and (not p or res.code ~= 0) then
      io.write("  stderr: " .. res.stderr:gsub("\n", "\n  ") .. "\n")
    end
    if not p then
      failed_files[#failed_files + 1] = rel
      total.failed = total.failed + 1
      io.write(("  ✗ crashed (exit %s, signal %s)\n"):format(res and res.code, res and res.signal))
    else
      total.passed = total.passed + tonumber(p)
      total.failed = total.failed + tonumber(f)
      total.pending = total.pending + tonumber(pe)
      if tonumber(f) > 0 or res.code ~= 0 then
        failed_files[#failed_files + 1] = rel
      end
    end
  end
  local ms = (uv.hrtime() - start) / 1e6
  io.write(
    ("\n%d passed, %d failed, %d pending — %d files in %.0f ms\n"):format(
      total.passed,
      total.failed,
      total.pending,
      #files,
      ms
    )
  )
  if #failed_files > 0 then
    io.write("failed: " .. table.concat(failed_files, ", ") .. "\n")
    return 1
  end
  return 0
end

local code
if args[1] == "--child" then
  code = run_child(args[2])
else
  code = run_parent(args)
end
io.flush()
os.exit(code)

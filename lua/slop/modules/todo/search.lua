--- todo: project-wide search (rg, else git grep, else an async Lua walk). Every backend only pre-filters
--- lines with the same regex; the Lua matcher (keywords.match) then extracts the hits, so all backends yield
--- identical results.
local M = {}

local uv = vim.uv

---@class slop.todo.Result
---@field path string      absolute path
---@field lnum integer     1-based
---@field col integer      1-based byte column of the keyword
---@field line string
---@field keyword string
---@field group string     keyword group name
---@field author? string
---@field message string

---@class slop.todo.SearchOpts
---@field keywords? string[]                 group names / aliases (nil = all)
---@field root? string                       default: core.project root of the current buffer
---@field backend? "auto"|"rg"|"git"|"lua"   default: config search.backend

local LUA_MAX_FILE = 1024 * 1024
local LUA_BUDGET_MS = 8
local LUA_SKIP_DIRS = { node_modules = true }

--- Backend actually used for `want` in `root`.
---@param want string
---@param root string
---@return "rg"|"git"|"lua"
function M.backend(want, root)
  if want == "rg" or want == "git" or want == "lua" then
    return want
  end
  if vim.fn.executable("rg") == 1 then
    return "rg"
  end
  if vim.fn.executable("git") == 1 and vim.fs.root(root, ".git") then
    return "git"
  end
  return "lua"
end

--- Results of one matched line.
---@param out slop.todo.Result[]
---@param path string
---@param lnum integer
---@param line string
---@param words table<string, slop.todo.Group>
local function add(out, path, lnum, line, words)
  for _, m in ipairs(require("slop.modules.todo.keywords").match(line, words)) do
    out[#out + 1] = {
      path = path,
      lnum = lnum,
      col = m.col + 1,
      line = line,
      keyword = m.keyword,
      group = m.group.name,
      author = m.author,
      message = m.message,
    }
  end
end

--- Parse NUL-separated grep output: `path\0lnum:text` (rg --null) or `path\0lnum\0text` (git grep -z).
---@param stdout string
---@param root string
---@param words table<string, slop.todo.Group>
---@return slop.todo.Result[]
function M.parse(stdout, root, words)
  local out = {}
  for l in vim.gsplit(stdout, "\n", { plain = true, trimempty = true }) do
    local path, lnum, text = l:match("^(.-)%z(%d+)[:%z](.*)$")
    if path then
      path = path:sub(1, 1) == "/" and path or vim.fs.joinpath(root, (path:gsub("^%./", "")))
      add(out, vim.fs.normalize(path), tonumber(lnum) --[[@as integer]], (text:gsub("\r$", "")), words)
    end
  end
  return out
end

---@param a slop.todo.Result
---@param b slop.todo.Result
local function order(a, b)
  if a.path ~= b.path then
    return a.path < b.path
  end
  if a.lnum ~= b.lnum then
    return a.lnum < b.lnum
  end
  return a.col < b.col
end

--- Command line of a grep backend.
---@param backend "rg"|"git"
---@param words table<string, any>
---@param args string[]  extra rg arguments (config search.args)
---@return string[]
function M.cmd(backend, words, args)
  local rg, ere = require("slop.modules.todo.keywords").patterns(words)
  if backend == "rg" then
    local cmd = { "rg", "--color=never", "--no-heading", "--with-filename", "--line-number", "--null" }
    vim.list_extend(cmd, args or {})
    vim.list_extend(cmd, { "-e", rg, "--", "." })
    return cmd
  end
  return { "git", "grep", "--untracked", "-I", "-n", "-z", "--no-color", "-E", "-e", ere }
end

--- Async Lua walk of `root` (hidden entries and node_modules skipped, binary and > 1 MiB files skipped),
--- a time-sliced batch per main-loop tick.
---@param root string
---@param words table<string, slop.todo.Group>
---@param cb fun(results: slop.todo.Result[])
local function walk(root, words, cb)
  local out = {}
  local quick = {}
  for w in pairs(words) do
    quick[#quick + 1] = w
  end
  local iter = vim.fs.dir(root, {
    depth = 64,
    skip = function(name)
      local base = vim.fs.basename(name)
      return not (base:sub(1, 1) == "." or LUA_SKIP_DIRS[base])
    end,
  })
  local function scan(rel)
    if rel:match("^%.") or rel:match("/%.") then
      return
    end
    local path = vim.fs.joinpath(root, rel)
    local stat = uv.fs_stat(path)
    if not stat or stat.size > LUA_MAX_FILE or stat.size == 0 then
      return
    end
    local f = io.open(path, "rb")
    if not f then
      return
    end
    local data = f:read("*a") or ""
    f:close()
    if data:sub(1, 8000):find("%z") then
      return
    end
    local any = false
    for _, w in ipairs(quick) do
      if data:find(w, 1, true) then
        any = true
        break
      end
    end
    if not any then
      return
    end
    local lnum = 0
    for line in vim.gsplit(data, "\n", { plain = true }) do
      lnum = lnum + 1
      if line:find("[:(]") then
        add(out, path, lnum, (line:gsub("\r$", "")), words)
      end
    end
  end
  local function step()
    local deadline = uv.hrtime() + LUA_BUDGET_MS * 1e6
    while uv.hrtime() < deadline do
      local ok, rel, kind = pcall(iter)
      if not ok or not rel then
        return cb(out)
      end
      if kind == "file" then
        scan(rel)
      end
    end
    vim.schedule(step)
  end
  vim.schedule(step)
end

--- Search the project for todos (async). `cb` runs on the main loop with sorted results (+ error message).
---@param opts slop.todo.SearchOpts
---@param words table<string, slop.todo.Group>
---@param cb fun(results: slop.todo.Result[], err?: string)
function M.run(opts, words, cb)
  local cfg = require("slop.config").get("todo")
  local root = opts.root or require("slop.core.project").root()
  local backend = M.backend(opts.backend or cfg.search.backend, root)
  local function done(results, err)
    table.sort(results, order)
    cb(results, err)
  end
  if next(words) == nil then
    return vim.schedule(function()
      done({})
    end)
  end
  if backend == "lua" then
    return walk(root, words, done)
  end
  local cmd = M.cmd(backend, words, cfg.search.args)
  local ok, err = pcall(vim.system, cmd, { cwd = root, text = true }, function(res)
    vim.schedule(function()
      local results = M.parse(res.stdout or "", root, words)
      -- rg: 1 = no match, 2 = error (partial output still counts); git grep: 1 = no match, 128 = not a repo
      if #results == 0 and res.code ~= 0 and res.code ~= 1 then
        if backend == "git" then
          return walk(root, words, done)
        end
        local msg = vim.trim(res.stderr or "")
        return done({}, ("%s failed (exit %d)%s"):format(cmd[1], res.code, msg ~= "" and ": " .. msg or ""))
      end
      done(results)
    end)
  end)
  if not ok then
    vim.schedule(function()
      done({}, tostring(err))
    end)
  end
end

return M

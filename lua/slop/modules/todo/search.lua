--- todo: project-wide search (rg, else git grep, else an async Lua walk). Every backend only pre-filters
--- lines with the same regex; the Lua matcher (keywords.match) then extracts the hits. All backends skip the
--- same files where they can: ignored ones (git), hidden entries, node_modules, files over 1 MiB, binary files
--- (see :h slop-todo-search for what still differs).
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

local MAX_FILE = 1024 * 1024
local LUA_BUDGET_MS = 8
local SKIP_DIRS = { node_modules = true }

--- Paths (relative to the root) no backend searches: hidden entries and node_modules, at any depth.
---@param rel string
---@return boolean
local function skipped(rel)
  for part in rel:gsub("^%./", ""):gmatch("[^/]+") do
    if part:sub(1, 1) == "." or SKIP_DIRS[part] then
      return true
    end
  end
  return false
end

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
    -- --no-config: a RIPGREP_CONFIG_PATH with --column/--trim/--max-columns would change the parsed output
    local cmd = { "rg", "--no-config", "--color=never", "--no-heading", "--with-filename", "--line-number" }
    vim.list_extend(cmd, { "--null", "--max-filesize=" .. MAX_FILE, "--glob=!node_modules" })
    vim.list_extend(cmd, args or {})
    vim.list_extend(cmd, { "-e", rg, "--", "." })
    return cmd
  end
  -- grep.column / grep.fullName in the user's git config would change the parsed output too
  local git = { "git", "-c", "grep.column=false", "-c", "grep.fullName=false", "grep", "--untracked", "-I", "-n" }
  return vim.list_extend(git, { "-z", "--no-color", "-E", "-e", ere })
end

--- git grep has no hidden / node_modules / size rules: drop what rg and the Lua walk skip.
---@param results slop.todo.Result[]
---@param root string
---@return slop.todo.Result[]
local function filter(results, root)
  local big = {} ---@type table<string, boolean>
  return vim.tbl_filter(function(r)
    if skipped(vim.fs.relpath(root, r.path) or r.path) then
      return false
    end
    if big[r.path] == nil then
      local stat = uv.fs_stat(r.path)
      big[r.path] = stat ~= nil and stat.size > MAX_FILE
    end
    return not big[r.path]
  end, results)
end

--- Files git searches (tracked + untracked, minus ignored), relative to `root`; nil outside a repository.
---@param root string
---@param cb fun(files: string[]?)
local function git_files(root, cb)
  if vim.fn.executable("git") ~= 1 or not vim.fs.root(root, ".git") then
    return vim.schedule(function()
      cb(nil)
    end)
  end
  local cmd = { "git", "ls-files", "--cached", "--others", "--exclude-standard", "-z" }
  local ok = pcall(vim.system, cmd, { cwd = root }, function(res)
    vim.schedule(function()
      if res.code ~= 0 then
        return cb(nil)
      end
      local seen, files = {}, {} -- unmerged paths are listed once per stage
      for _, f in ipairs(vim.split(res.stdout or "", "\0", { plain = true, trimempty = true })) do
        if not seen[f] then
          seen[f], files[#files + 1] = true, f
        end
      end
      cb(files)
    end)
  end)
  if not ok then
    vim.schedule(function()
      cb(nil)
    end)
  end
end

--- Async Lua walk of `root` (hidden entries and node_modules skipped, binary and > 1 MiB files skipped),
--- a time-sliced batch per main-loop tick. Inside a git repository only the files git lists are read, so
--- ignored files are skipped like with rg / git grep.
---@param root string
---@param words table<string, slop.todo.Group>
---@param cb fun(results: slop.todo.Result[])
local function walk(root, words, cb)
  local out = {}
  local quick = {}
  for w in pairs(words) do
    quick[#quick + 1] = w
  end
  local function scan(rel)
    if skipped(rel) then
      return
    end
    local path = vim.fs.joinpath(root, rel)
    local stat = uv.fs_lstat(path) -- links are not followed (rg neither)
    if not stat or stat.type ~= "file" or stat.size > MAX_FILE or stat.size == 0 then
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
  git_files(root, function(files)
    local iter
    if files then
      local i = 0
      iter = function()
        i = i + 1
        return files[i], "file"
      end
    else
      iter = vim.fs.dir(root, {
        depth = 64,
        skip = function(name)
          return not skipped(name)
        end,
      })
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
    step()
  end)
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
  -- LC_ALL=C: git's [:alnum:] is locale-aware ("éTODO:" would not match), keywords.match's %w is not
  local env = backend == "git" and { LC_ALL = "C" } or nil
  local ok, err = pcall(vim.system, cmd, { cwd = root, text = true, env = env }, function(res)
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
      done(backend == "git" and filter(results, root) or results)
    end)
  end)
  if not ok then
    vim.schedule(function()
      done({}, tostring(err))
    end)
  end
end

return M

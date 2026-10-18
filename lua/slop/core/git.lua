--- Async git helpers (vim.system, never blocking). OWNER: commit.
---
--- Every command runs through `git.run()`: `git -c core.quotepath=off --no-pager <args>` with the editor's
--- environment inherited (so a `GIT_INDEX_FILE` that `git commit -a` / `git commit <paths>` exported to
--- `$EDITOR` is honoured) plus `GIT_OPTIONAL_LOCKS=0` (never fight the index lock held by `git commit`).
--- Callbacks always run on the main loop.
---
--- Pure helpers (no process spawned): `root`, `git_dir`, `parse_commit_buffer`, `split_diff`.
---@class slop.git
local M = {}

local uv = vim.uv

--- `git hash-object -t tree /dev/null`: diff base for root commits.
M.EMPTY_TREE = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"

---@class slop.git.Result
---@field code integer
---@field stdout string
---@field stderr string

---@class slop.git.RunOpts
---@field cwd? string                    default git.root(0), else the cwd
---@field env? table<string, string>     e.g. { GIT_INDEX_FILE = ... } (inherits the environment)
---@field stdin? string
---@field timeout? integer               ms (default 10000)

local function is_dir(p)
  local st = p and uv.fs_stat(p)
  return st ~= nil and st.type == "directory"
end

local function is_file(p)
  local st = p and uv.fs_stat(p)
  return st ~= nil and st.type == "file"
end

local function read(p)
  local f = io.open(p, "r")
  if not f then
    return nil
  end
  local s = f:read("*a")
  f:close()
  return s
end

local function abs(p, base)
  if not p or p == "" then
    return nil
  end
  if not vim.startswith(p, "/") and not p:match("^%a:[/\\]") then
    p = vim.fs.joinpath(base or uv.cwd(), p)
  end
  return vim.fs.normalize(vim.fs.abspath(p))
end

--- Run `git <args>`; cb runs on the main loop.
---@param args string[]
---@param opts? slop.git.RunOpts
---@param cb fun(res: slop.git.Result)
---@return vim.SystemObj?
function M.run(args, opts, cb)
  opts = opts or {}
  local cmd = { "git", "-c", "core.quotepath=off", "--no-pager" }
  vim.list_extend(cmd, args)
  local env = { GIT_OPTIONAL_LOCKS = "0", GIT_TERMINAL_PROMPT = "0", LC_ALL = "C" }
  for k, v in pairs(opts.env or {}) do
    env[k] = v
  end
  local done = vim.schedule_wrap(function(res)
    cb({ code = res.code or -1, stdout = res.stdout or "", stderr = res.stderr or "" })
  end)
  local ok, obj = pcall(vim.system, cmd, {
    cwd = opts.cwd or M.root(0) or uv.cwd(),
    env = env,
    stdin = opts.stdin,
    timeout = opts.timeout or 10000,
    text = true,
  }, done)
  if not ok then
    done({ code = -1, stdout = "", stderr = tostring(obj) })
    return nil
  end
  return obj
end

local function first_line(s)
  return (s or ""):match("^[^\n]*") or ""
end

local function err_of(res, what)
  local msg = vim.trim(res.stderr or "")
  return ("git %s failed (%d)%s"):format(what, res.code, msg ~= "" and (": " .. first_line(msg)) or "")
end

-- Roots ------------------------------------------------------------------------------------------

--- Is `dir` a git directory (".git", ".git/worktrees/<n>", ".git/modules/<n>", bare repo)?
local function looks_like_git_dir(dir)
  return is_file(dir .. "/HEAD") and (is_dir(dir .. "/objects") or is_file(dir .. "/commondir"))
end

--- Work tree of a git dir, or nil (bare repo / unknown layout).
---@param gitdir string
---@return string?
local function worktree_of(gitdir)
  gitdir = vim.fs.normalize(gitdir)
  if vim.fs.basename(gitdir) == ".git" then
    return vim.fs.dirname(gitdir)
  end
  -- linked worktree: <main>/.git/worktrees/<n>/gitdir -> "<wt>/.git"
  local link = read(gitdir .. "/gitdir")
  if link then
    local p = abs(vim.trim(link), gitdir)
    return p and vim.fs.dirname(p)
  end
  -- submodule: <super>/.git/modules/<n>/config has core.worktree = ../../../sub
  local conf = read(gitdir .. "/config")
  local wt = conf and conf:match("\n%s*worktree%s*=%s*([^\n]+)")
  if wt then
    return abs(vim.trim(wt), gitdir)
  end
  return nil
end

--- Path + explicit git dir hint for a source.
---@param src? string|integer
---@return string? path, string? gitdir
local function source(src)
  if src == nil or type(src) == "number" then
    local buf = (src == nil or src == 0) and vim.api.nvim_get_current_buf() or src --[[@as integer]]
    if not vim.api.nvim_buf_is_valid(buf) then
      return nil
    end
    local gd = vim.b[buf].git_dir
    local name = vim.api.nvim_buf_get_name(buf)
    return name ~= "" and name or nil, type(gd) == "string" and gd ~= "" and gd or nil
  end
  return src, --[[@as string]]
    nil
end

--- Git dir for a path/buffer (sync, cheap). Handles b:git_dir (fugitive), fugitive:// names, files inside a
--- git dir (COMMIT_EDITMSG), linked worktrees (".git" file) and plain repos.
---@param src? string|integer  path or buffer (default current)
---@return string?
function M.git_dir(src)
  local path, hint = source(src)
  if hint then
    return abs(hint)
  end
  if path then
    local fug = path:match("^fugitive://(.-)//")
    if fug then
      return abs(fug)
    end
    if path:match("^%a[%w+.-]*://") then
      path = nil
    end
  end
  path = abs(path) or uv.cwd()
  -- inside a git dir?
  local dir = is_dir(path) and path or vim.fs.dirname(path)
  for d in vim.fs.parents(dir .. "/x") do
    if looks_like_git_dir(d) then
      return d
    end
    if vim.fs.basename(d) == ".git" then
      break
    end
  end
  local root = vim.fs.root(path, ".git")
  if not root then
    return nil
  end
  local dotgit = root .. "/.git"
  if is_dir(dotgit) then
    return dotgit
  end
  local txt = read(dotgit)
  local gd = txt and txt:match("^gitdir:%s*([^\n]+)")
  return gd and abs(vim.trim(gd), root) or nil
end

--- Git work-tree root of a path/buffer (nil outside a repo). Sync, cheap (no process spawned).
--- A buffer editing `.git/COMMIT_EDITMSG` (or a worktree/submodule git dir file) maps to its work tree.
---@param src? string|integer
---@return string?
function M.root(src)
  local path, hint = source(src)
  if hint then
    local wt = worktree_of(abs(hint) --[[@as string]])
    if wt then
      return wt
    end
  end
  local gd = M.git_dir(src)
  if gd then
    local wt = worktree_of(gd)
    if wt then
      return wt
    end
  end
  if path and not path:match("^%a[%w+.-]*://") then
    local r = vim.fs.root(abs(path) --[[@as string]], ".git")
    if r then
      return vim.fs.normalize(r)
    end
  end
  local r = vim.fs.root(uv.cwd(), ".git")
  return r and vim.fs.normalize(r) or nil
end

-- Diffs ------------------------------------------------------------------------------------------

local DIFF_ARGS = { "--no-color", "--no-ext-diff", "--no-textconv", "-M", "--src-prefix=a/", "--dst-prefix=b/" }

---@class slop.git.DiffOpts
---@field cwd? string
---@field amend? boolean           diff the index against HEAD~1 (the amended commit's parent)
---@field worktree? boolean        unstaged tracked changes (`git diff HEAD`) instead of the index
---@field env? table<string, string>
---@field context? integer         -U lines (default 3)
---@field paths? string[]

--- Staged diff (`git diff --cached`, honouring GIT_INDEX_FILE / --amend). Output is NOT redacted:
--- pass it through core.secrets.redact_diff() before sending it anywhere.
---@param opts? slop.git.DiffOpts
---@param cb fun(diff: string?, err: string?)
function M.staged_diff(opts, cb)
  opts = opts or {}
  local ro = { cwd = opts.cwd, env = opts.env }
  local function go(base)
    local args = { "diff" }
    if not opts.worktree then
      args[#args + 1] = "--cached"
    end
    vim.list_extend(args, DIFF_ARGS)
    args[#args + 1] = "-U" .. tostring(opts.context or 3)
    if base then
      args[#args + 1] = base
    end
    if opts.paths and #opts.paths > 0 then
      args[#args + 1] = "--"
      vim.list_extend(args, opts.paths)
    end
    M.run(args, ro, function(res)
      if res.code ~= 0 then
        cb(nil, err_of(res, "diff"))
      else
        cb(res.stdout)
      end
    end)
  end
  if opts.amend or opts.worktree then
    local rev = opts.amend and "HEAD~1^{commit}" or "HEAD^{commit}"
    M.run({ "rev-parse", "-q", "--verify", rev }, ro, function(res)
      local sha = res.code == 0 and vim.trim(res.stdout) or ""
      go(sha ~= "" and sha or M.EMPTY_TREE)
    end)
  else
    go(nil)
  end
end

--- Current branch name (nil when detached). Works on an unborn branch.
---@param opts? {cwd?: string}
---@param cb fun(branch: string?, err: string?)
function M.branch(opts, cb)
  opts = opts or {}
  M.run({ "symbolic-ref", "--short", "-q", "HEAD" }, { cwd = opts.cwd }, function(res)
    local b = vim.trim(res.stdout)
    if res.code == 0 and b ~= "" then
      cb(b)
    elseif res.code == 1 then
      cb(nil) -- detached HEAD
    else
      cb(nil, err_of(res, "symbolic-ref"))
    end
  end)
end

--- Last `n` commit subjects (newest first, merges skipped), for style hints. {} for an unborn HEAD.
---@param opts? {cwd?: string, n?: integer, author?: string, format?: string}
---@param cb fun(subjects: string[]?, err: string?)
function M.log(opts, cb)
  opts = opts or {}
  local n = opts.n or 5
  if n <= 0 then
    cb({})
    return
  end
  local args = { "log", "-n", tostring(n), "--no-merges", "--format=" .. (opts.format or "%s") }
  if opts.author then
    vim.list_extend(args, { "--fixed-strings", "--author=" .. opts.author })
  end
  M.run(args, { cwd = opts.cwd }, function(res)
    if res.code ~= 0 then
      if res.stderr:match("does not have any commits") or res.stderr:match("bad default revision") then
        cb({})
      else
        cb(nil, err_of(res, "log"))
      end
      return
    end
    local out = {}
    for _, l in ipairs(vim.split(res.stdout, "\n", { plain = true, trimempty = true })) do
      if vim.trim(l) ~= "" then
        out[#out + 1] = l
      end
    end
    cb(out)
  end)
end

--- `git config --get <key>` (nil when unset).
---@param key string
---@param opts? {cwd?: string}
---@param cb fun(value: string?, err: string?)
function M.config_get(key, opts, cb)
  opts = opts or {}
  M.run({ "config", "--get", key }, { cwd = opts.cwd }, function(res)
    if res.code == 0 then
      cb((res.stdout:gsub("\n$", "")))
    elseif res.code == 1 then
      cb(nil)
    else
      cb(nil, err_of(res, "config"))
    end
  end)
end

--- Recent subjects: the user's own (author = `git config user.email`) and the repository's.
---@param opts? {cwd?: string, n?: integer}
---@param cb fun(commits: {user: string[], repo: string[]})
function M.recent_commits(opts, cb)
  opts = opts or {}
  local out, pending = { user = {}, repo = {} }, 2
  local function finish()
    pending = pending - 1
    if pending == 0 then
      cb(out)
    end
  end
  M.log({ cwd = opts.cwd, n = opts.n }, function(subjects)
    out.repo = subjects or {}
    finish()
  end)
  M.config_get("user.email", { cwd = opts.cwd }, function(email)
    if not email or email == "" then
      finish()
      return
    end
    M.log({ cwd = opts.cwd, n = opts.n, author = email }, function(subjects)
      out.user = subjects or {}
      finish()
    end)
  end)
end

--- Full message of HEAD (nil on an unborn branch).
---@param opts? {cwd?: string}
---@param cb fun(msg: string?)
function M.head_message(opts, cb)
  opts = opts or {}
  M.run({ "log", "-1", "--format=%B", "HEAD" }, { cwd = opts.cwd }, function(res)
    cb(res.code == 0 and res.stdout or nil)
  end)
end

--- Was nvim started by `git commit ... --amend`? Walks the parent process chain (Linux /proc, <= 4 levels:
--- git may run $EDITOR through `sh -c`). Always false elsewhere.
---@param pid? integer  start pid (default: nvim's parent)
---@return boolean
function M.parent_amend(pid)
  pid = pid or uv.os_getppid()
  if not is_dir("/proc/self") then
    return false
  end
  for _ = 1, 4 do
    if not pid or pid <= 1 then
      return false
    end
    local cmdline = read("/proc/" .. pid .. "/cmdline")
    if cmdline then
      local argv = vim.split(cmdline, "\0", { plain = true, trimempty = true })
      local exe = vim.fs.basename(argv[1] or "")
      if exe == "git" or exe == "git-commit" then
        local is_commit = exe == "git-commit"
        for i = 2, #argv do
          if argv[i] == "commit" then
            is_commit = true
          end
        end
        if is_commit then
          for i = 2, #argv do
            local a = argv[i]
            if #a >= 4 and vim.startswith("--amend", a) then
              return true
            end
          end
          return false
        end
      end
    end
    local stat = read("/proc/" .. pid .. "/stat")
    pid = stat and tonumber(stat:match("^%d+ %b() %S+ (%d+)")) or nil
  end
  return false
end

-- Parsing (pure) ---------------------------------------------------------------------------------

---@class slop.git.CommitBuffer
---@field message string[]          message lines without comments, leading/trailing blank lines trimmed
---@field empty boolean             no message text at all (comments / scissors section don't count)
---@field comment_char string
---@field first_comment? integer    1-based line of the first comment line above the scissors
---@field scissors? integer         1-based line of the scissors line
---@field diff? string              verbose (`commit -v`) staged diff below the scissors, a/ b/ prefixes
---@field diff_error? string        a verbose diff was present but could not be parsed safely

local function scissors_prefix(line)
  return line:match(
    "^(.-) %-%-%-%-%-%-%-%-%-%-%-%-%-%-%-%-%-%-%-%-%-%-%-%- >8 %-%-%-%-%-%-%-%-%-%-%-%-%-%-%-%-%-%-%-%-%-%-%-%-$"
  )
end

--- Normalise a verbose diff's prefixes (mnemonic c/ i/ w/ o/ …) to a/ b/. Returns nil + error when a
--- file header cannot be read (e.g. diff.noprefix), so callers never hand redact_diff unknown paths.
---@param lines string[]
---@return string? diff, string? err
local function normalise_diff(lines)
  local out, in_hunk, files = {}, false, 0
  for _, l in ipairs(lines) do
    if vim.startswith(l, "diff --git ") then
      in_hunk = false
      local p1, p2 = l:match("^diff %-%-git %l/(.-) %l/(.+)$")
      if not p1 then
        return nil, "unrecognised diff header: " .. l
      end
      files = files + 1
      l = ("diff --git a/%s b/%s"):format(p1, p2)
    elseif not in_hunk and vim.startswith(l, "@@") then
      in_hunk = true
    elseif not in_hunk then -- file header lines (content lines are kept verbatim)
      local p = l:match("^%-%-%- %l/(.*)$")
      if p then
        l = "--- a/" .. p
      else
        p = l:match("^%+%+%+ %l/(.*)$")
        if p then
          l = "+++ b/" .. p
        end
      end
    end
    out[#out + 1] = l
  end
  if files == 0 then
    return nil, "no diff found below the scissors line"
  end
  return table.concat(out, "\n") .. "\n"
end

--- Split a COMMIT_EDITMSG buffer into message / comments / verbose diff.
---@param lines string[]
---@param opts? {comment_char?: string}
---@return slop.git.CommitBuffer
function M.parse_commit_buffer(lines, opts)
  opts = opts or {}
  local cc = opts.comment_char
  local scissors
  for i, l in ipairs(lines) do
    local pre = scissors_prefix(l)
    if pre and pre ~= "" and (not cc or pre == cc) then
      scissors, cc = i, pre
      break
    end
  end
  cc = (cc and cc ~= "") and cc or "#"
  ---@type slop.git.CommitBuffer
  local res = { message = {}, empty = true, comment_char = cc, scissors = scissors }
  local last = scissors and scissors - 1 or #lines
  local msg = {}
  for i = 1, last do
    local l = lines[i]
    if vim.startswith(l, cc) then
      res.first_comment = res.first_comment or i
    else
      msg[#msg + 1] = (l:gsub("%s+$", ""))
    end
  end
  while #msg > 0 and msg[1] == "" do
    table.remove(msg, 1)
  end
  while #msg > 0 and msg[#msg] == "" do
    table.remove(msg)
  end
  res.message = msg
  res.empty = #msg == 0
  if scissors then
    local start
    for i = scissors + 1, #lines do
      if vim.startswith(lines[i], "diff --git ") then
        start = i
        break
      end
    end
    if start then
      local body = {}
      for i = start, #lines do
        local l = lines[i]
        if vim.startswith(l, cc) then
          break -- `commit -vv`: the unstaged section starts with a comment header
        end
        body[#body + 1] = l
      end
      while #body > 0 and body[#body] == "" do
        table.remove(body)
      end
      res.diff, res.diff_error = normalise_diff(body)
    end
  end
  return res
end

---@class slop.git.FileDiff
---@field path string               b/ path (new name for renames)
---@field old_path? string          a/ path when it differs (rename/copy)
---@field text string               the section, newline-terminated
---@field added integer
---@field removed integer
---@field binary boolean

--- Split a unified diff into per-file sections (pure). Text before the first "diff --git" is dropped.
---@param diff string
---@return slop.git.FileDiff[]
function M.split_diff(diff)
  local files, cur, buf, in_hunk = {}, nil, nil, false
  local function close()
    if cur then
      cur.text = table.concat(buf, "\n") .. "\n"
      files[#files + 1] = cur
    end
  end
  for _, l in ipairs(vim.split(diff or "", "\n", { plain = true })) do
    if vim.startswith(l, "diff --git ") then
      close()
      local a, b = l:match("^diff %-%-git a/(.-) b/(.+)$")
      cur = { path = b or l:sub(12), old_path = (a and a ~= b) and a or nil, added = 0, removed = 0, binary = false }
      buf, in_hunk = { l }, false
    elseif cur then
      buf[#buf + 1] = l
      if vim.startswith(l, "@@") then
        in_hunk = true
      elseif in_hunk then
        local c = l:sub(1, 1)
        if c == "+" then
          cur.added = cur.added + 1
        elseif c == "-" then
          cur.removed = cur.removed + 1
        end
      elseif vim.startswith(l, "Binary files ") or l == "GIT binary patch" then
        cur.binary = true
      end
    end
  end
  if cur then
    while #buf > 1 and buf[#buf] == "" do
      table.remove(buf)
    end
  end
  close()
  return files
end

return M

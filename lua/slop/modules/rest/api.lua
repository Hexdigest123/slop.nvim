--- rest orchestration: run (with chaining + prompts), pick, last, env, cancel, lint.
---@class slop.rest.api
local M = {}

local api = vim.api

local function log()
  return require("slop.core.log").scope("rest")
end
local function cfg()
  return require("slop.config").get("rest")
end
local discover = function()
  return require("slop.modules.rest.discover")
end
local history = function()
  return require("slop.modules.rest.history")
end

---@class slop.rest.State
local S = {
  responses = {}, ---@type table<string, table<string, slop.rest.Response>>  root -> name -> response
  prompts = {}, ---@type table<string, table<string, string>>                root -> var -> last answer
  results = {}, ---@type table<string, table>                                root -> last entry {req, resolved, res, err}
  failed = {}, ---@type table<string, table>                                 root -> last failed entry
  handle = nil, ---@type slop.rest.RunHandle?
  seq = 0,
}
M._state = S

--- Project root for rest (the current buffer's root).
---@param buf? integer
---@return string
function M.root(buf)
  return require("slop.core.project").root(buf)
end

local function responses(root)
  S.responses[root] = S.responses[root] or {}
  return S.responses[root]
end

--- Effective env name for a root: the persisted selection, else "dev" when it exists.
---@param root string
---@return string?
function M.current_env(root)
  root = root or M.root()
  local sel = history().env(root)
  if sel == false then
    return nil
  end
  if type(sel) == "string" then
    return sel
  end
  local names = require("slop.modules.rest.env").names(discover().get(root).env_files)
  if vim.tbl_contains(names, "dev") then
    return "dev"
  end
  return nil
end

--- Parse the source of a request (buffer or file).
---@param req slop.rest.Request
---@return slop.rest.File
local function parsed_of(req)
  if req.file then
    return discover().parse(req.file)
  end
  return { vars = req._vars or {}, requests = { req }, warnings = {} }
end

--- Variable context for `req`.
---@param req slop.rest.Request
---@param root string
---@param prompt table<string, string>
---@return slop.rest.VarCtx
function M.ctx(req, root, prompt)
  local c = cfg()
  local env = require("slop.modules.rest.env")
  local file = req.file or (vim.fn.getcwd() .. "/[buffer].http")
  local envvars = env.load(file, root, M.current_env(root))
  local dot = env.dotenv(file, root, c.env_file)
  return {
    prompt = prompt,
    file = require("slop.modules.rest.parser").file_vars(parsed_of(req), req),
    env = envvars,
    dotenv = dot,
    process = c.process_env,
    dynamic = c.dynamic,
    response = function(name)
      return responses(root)[name]
    end,
  }
end

local function label(req)
  return req.name or (req.method .. " " .. req.url)
end

-- Diagnostics -------------------------------------------------------------------------------------

local function diag_ns()
  return require("slop.core.util").ns("rest.diagnostics")
end

---@param file? string
---@return integer?
local function buf_of(file)
  if not file then
    return nil
  end
  local nr = vim.fn.bufnr(file)
  return nr > 0 and api.nvim_buf_is_loaded(nr) and nr or nil
end

--- Parser warnings (+ `extra` errors) as diagnostics in an http buffer.
---@param buf integer
---@param extra? vim.Diagnostic[]
function M.lint(buf, extra)
  if not api.nvim_buf_is_valid(buf) then
    return
  end
  local parsed = require("slop.modules.rest.parser").parse(api.nvim_buf_get_lines(buf, 0, -1, false))
  local d = {}
  for _, w in ipairs(parsed.warnings) do
    d[#d + 1] =
      { lnum = w.lnum - 1, col = 0, severity = vim.diagnostic.severity.WARN, message = w.msg, source = "slop" }
  end
  vim.list_extend(d, extra or {})
  vim.diagnostic.set(diag_ns(), buf, d)
end

-- Prompts -----------------------------------------------------------------------------------------

---@param req slop.rest.Request
---@param root string
---@param cb fun(answers: table<string, string>?)
local function ask_prompts(req, root, cb)
  local list = req.meta and req.meta.prompt or {}
  local answers = {}
  S.prompts[root] = S.prompts[root] or {}
  local i = 0
  local function next_prompt()
    i = i + 1
    local p = list[i]
    if not p then
      return cb(answers)
    end
    vim.ui.input({
      prompt = (p.desc or p.name) .. ": ",
      default = S.prompts[root][p.name],
    }, function(value)
      if value == nil then
        return cb(nil)
      end
      answers[p.name] = value
      S.prompts[root][p.name] = value
      vim.schedule(next_prompt)
    end)
  end
  next_prompt()
end

-- Running -----------------------------------------------------------------------------------------

--- Cancel the request in flight.
function M.cancel()
  if S.handle and S.handle:is_active() then
    S.handle:cancel()
    S.handle = nil
    S.seq = S.seq + 1
    log().notify("request cancelled", vim.log.levels.INFO)
    return true
  end
  return false
end

---@param root string
---@return table
local function resolve_opts(root, ctx)
  local c = cfg()
  return {
    ctx = ctx,
    timeout = c.timeout,
    follow_redirects = c.follow_redirects,
    cookie_jar = c.cookies and require("slop.core.project").state("rest", "cookies.txt", { root = root }) or false,
    insecure = c.insecure,
    headers = c.headers,
  }
end

---@class slop.rest.RunOpts
---@field root? string
---@field on_done? fun(entry: table)   final entry {req, resolved?, res?, err?}
---@field show? boolean                 show in the result view (default true)

--- Run one request (plus its missing dependencies first).
---@param req slop.rest.Request
---@param opts? slop.rest.RunOpts
function M.run(req, opts)
  opts = opts or {}
  local root = opts.root or M.root()
  local show = opts.show ~= false
  local view = require("slop.modules.rest.view")
  local events = require("slop.core.events")
  M.cancel()
  S.seq = S.seq + 1
  local seq = S.seq
  local env = M.current_env(root)

  local plan, perr = require("slop.modules.rest.chain").plan(req, {
    lookup = function(name, from)
      return discover().lookup(name, from, root)
    end,
    has_response = function(r)
      return r.name ~= nil and responses(root)[r.name] ~= nil
    end,
    file_vars = function(r)
      return require("slop.modules.rest.parser").file_vars(parsed_of(r), r)
    end,
  })

  local function finish(entry)
    if seq ~= S.seq then
      return
    end
    S.handle = nil
    entry.env = env
    S.results[root] = entry
    if entry.err or (entry.res and entry.res.status >= 400) then
      S.failed[root] = entry
    end
    if show then
      view.show(entry)
    end
    if opts.on_done then
      opts.on_done(entry)
    end
  end

  if not plan then
    log().notify(perr --[[@as string]], vim.log.levels.ERROR)
    return finish({ req = req, err = perr })
  end
  history().touch(root, req)

  local i = 0
  local function step()
    if seq ~= S.seq then
      return
    end
    i = i + 1
    local r = plan[i]
    if not r then
      return
    end
    local is_target = i == #plan
    ask_prompts(r, root, function(answers)
      if seq ~= S.seq then
        return
      end
      if not answers then
        log().notify("request cancelled (prompt)", vim.log.levels.INFO)
        S.seq = S.seq + 1
        return
      end
      local resolved, err = require("slop.modules.rest.runner").resolve(r, resolve_opts(root, M.ctx(r, root, answers)))
      if not resolved then
        local msg = ("%s: %s"):format(label(r), err)
        log().notify(msg, vim.log.levels.ERROR)
        local b = buf_of(r.file)
        if b then
          M.lint(b, {
            { lnum = r.line - 1, col = 0, severity = vim.diagnostic.severity.ERROR, message = err, source = "slop" },
          })
        end
        return finish({ req = r, err = msg })
      end
      local id = history().id(r, root)
      events.emit("rest", "Request", { id = id, name = r.name, method = resolved.method })
      if show then
        view.running({
          req = r,
          resolved = resolved,
          env = env,
          running = is_target and true or ("dependency " .. label(r)),
        })
      end
      S.handle = require("slop.modules.rest.runner").execute(resolved, function(res, rerr)
        if seq ~= S.seq then
          return
        end
        if res and r.name then
          responses(root)[r.name] = res
        end
        events.emit("rest", "Response", {
          id = id,
          name = r.name,
          status = res and res.status or 0,
          time_ms = res and res.time_ms or 0,
          ok = res ~= nil and res.status < 400,
        })
        if rerr then
          local msg = rerr.message
          if not is_target then
            msg = ("dependency '%s' failed: %s"):format(label(r), msg)
          end
          return finish({ req = r, resolved = resolved, err = msg })
        end
        if is_target then
          return finish({ req = r, resolved = resolved, res = res })
        end
        step()
      end)
    end)
  end
  step()
end

-- Entry points ------------------------------------------------------------------------------------

--- Request under the cursor of an http buffer.
---@param buf? integer
---@return slop.rest.Request?
function M.request_at_cursor(buf)
  buf = (buf == nil or buf == 0) and api.nvim_get_current_buf() or buf
  local name = api.nvim_buf_get_name(buf)
  local lines = api.nvim_buf_get_lines(buf, 0, -1, false)
  local parsed = require("slop.modules.rest.parser").parse(lines, name ~= "" and vim.fs.normalize(name) or nil)
  local win = vim.fn.bufwinid(buf)
  local lnum = win ~= -1 and api.nvim_win_get_cursor(win)[1] or 1
  local req = require("slop.modules.rest.parser").at(parsed, lnum)
  if req and name == "" then
    req._vars = parsed.vars
  end
  return req
end

--- Run the request under the cursor (http buffers).
function M.run_cursor()
  local req = M.request_at_cursor(0)
  if not req then
    log().notify("no request under the cursor", vim.log.levels.WARN)
    return
  end
  M.run(req)
end

--- Find a request by name (current buffer's file first, then the whole root).
---@param name string
---@return slop.rest.Request?
function M.find(name)
  local root = M.root()
  local cur = M.request_at_cursor(0)
  local r = discover().lookup(name, cur or {}, root)
  return r
end

--- <leader>rr: in http buffers the request under the cursor, else the picker.
---@param name? string
function M.run_cmd(name)
  if name and name ~= "" then
    local r = M.find(name)
    if not r then
      log().notify(("unknown request '%s'"):format(name), vim.log.levels.ERROR)
      return
    end
    return M.run(r)
  end
  if vim.bo.filetype == "http" then
    return M.run_cursor()
  end
  M.pick()
end

--- Rerun the last request (re-read from its file: edits and fresh dynamic values apply).
function M.last()
  local root = M.root()
  local last = history().last(root)
  if not last then
    log().notify("no request has been run yet", vim.log.levels.WARN)
    return
  end
  local file = last.file:sub(1, 1) == "/" and last.file or vim.fs.joinpath(root, last.file)
  discover().invalidate(root, file)
  local parsed = discover().parse(file)
  local found
  for _, r in ipairs(parsed.requests) do
    if last.name and r.name == last.name then
      found = r
      break
    end
  end
  if not found then
    found = require("slop.modules.rest.parser").at(parsed, last.line or 1)
  end
  if not found then
    log().notify(("last request not found in %s"):format(last.file), vim.log.levels.ERROR)
    return
  end
  M.run(found, { root = root })
end

--- Lines of a request's block (from its buffer if loaded, else from disk).
---@param req slop.rest.Request
---@return string[]
function M.block_lines(req)
  local b = buf_of(req.file)
  local lines
  if b then
    lines = api.nvim_buf_get_lines(b, req.start - 1, req.stop, false)
  elseif req.file then
    local all = vim.fn.readfile(req.file)
    lines = vim.list_slice(all, req.start, req.stop)
  else
    lines = {}
  end
  return lines
end

--- Picker over every request under the root (recent first).
function M.pick()
  local root = M.root()
  local reqs = discover().requests(root)
  if #reqs == 0 then
    log().notify(("no .http/.rest files under %s"):format(root), vim.log.levels.WARN)
    return
  end
  local project = require("slop.core.project")
  local ranks = history().ranks(root)
  local items = {}
  local wfile, wtitle = 0, 0
  for i, r in ipairs(reqs) do
    local rel = project.relpath(r.file, root)
    local title = r.title or r.name or "(untitled)"
    items[i] = { req = r, rel = rel, title = title, rank = ranks[history().id(r, root)], order = i }
    wfile = math.max(wfile, vim.fn.strdisplaywidth(rel))
    wtitle = math.max(wtitle, math.min(48, vim.fn.strdisplaywidth(title)))
  end
  table.sort(items, function(a, b)
    if a.rank and b.rank then
      return a.rank < b.rank
    elseif a.rank or b.rank then
      return a.rank ~= nil
    end
    return a.order < b.order
  end)
  local function pad(s, w)
    local d = vim.fn.strdisplaywidth(s)
    if d > w then
      return vim.fn.strcharpart(s, 0, w - 1) .. "…"
    end
    return s .. string.rep(" ", w - d)
  end
  require("slop.core.ui.picker").pick(items, {
    prompt = "Requests",
    title = "slop rest",
    format = function(it)
      return {
        { pad(it.rel, wfile), "SlopRestFile" },
        { " › ", "SlopDim" },
        { pad(it.title, wtitle) },
        { "  " },
        { pad(it.req.method, 7), "SlopRestMethod" },
        { " " .. it.req.url, "SlopDim" },
      }
    end,
    preview = function(it)
      local lines = M.block_lines(it.req)
      local res = it.req.name and responses(root)[it.req.name]
      if res then
        table.insert(
          lines,
          1,
          ("# last: %d %s · %s"):format(
            res.status,
            res.reason or "",
            require("slop.modules.rest.view").human_time(res.time_ms)
          )
        )
      end
      return { lines = lines, filetype = "http" }
    end,
    actions = { ["<C-e>"] = "edit", ["<C-v>"] = "vsplit" },
    on_select = function(it, action)
      if not it then
        return
      end
      if action == "edit" or action == "vsplit" then
        vim.cmd[action == "edit" and "edit" or "vsplit"](vim.fn.fnameescape(it.req.file))
        pcall(api.nvim_win_set_cursor, 0, { it.req.line, 0 })
        return
      end
      M.run(it.req, { root = root })
    end,
  })
end

--- Select the env (picker over the names in http-client*.env.json under the root), or set it by name.
---@param name? string
function M.env(name)
  local root = M.root()
  local names = require("slop.modules.rest.env").names(discover().get(root, true).env_files)
  if name and name ~= "" then
    if name == "none" then
      history().set_env(root, false)
    else
      if not vim.tbl_contains(names, name) then
        log().notify(("env '%s' is not defined in any http-client*.env.json"):format(name), vim.log.levels.WARN)
      end
      history().set_env(root, name)
    end
    log().notify("env: " .. name, vim.log.levels.INFO)
    return
  end
  if #names == 0 then
    log().notify("no http-client.env.json under " .. root, vim.log.levels.WARN)
    return
  end
  local cur = M.current_env(root)
  local items = vim.list_extend({ "none" }, names)
  require("slop.core.ui.picker").pick(items, {
    prompt = "Env",
    title = "rest env" .. (cur and (" (" .. cur .. ")") or ""),
    on_select = function(choice)
      if choice then
        M.env(choice)
      end
    end,
  })
end

--- Delete (clear) the cookie jar of the root.
function M.clear_cookies()
  local root = M.root()
  local path = require("slop.core.project").dir({ root = root }, "state", "rest", "cookies.txt")
  os.remove(path)
  log().notify("cookie jar cleared", vim.log.levels.INFO)
end

--- Open the cookie jar file.
function M.open_cookies()
  local root = M.root()
  local path = require("slop.core.project").dir({ root = root }, "state", "rest", "cookies.txt")
  if not vim.uv.fs_stat(path) then
    log().notify("cookie jar is empty", vim.log.levels.INFO)
    return
  end
  vim.cmd.split(vim.fn.fnameescape(path))
end

--- Rerun what the result view shows.
function M.rerun_view()
  local e = require("slop.modules.rest.view").current()
  if not (e and e.req) then
    return M.last()
  end
  local req = e.req
  if req.file then
    local parsed = discover().parse(req.file)
    for _, r in ipairs(parsed.requests) do
      if (req.name and r.name == req.name) or (not req.name and r.line == req.line) then
        req = r
        break
      end
    end
  end
  M.run(req)
end

--- Statusline helper: "rest[env]" or "".
---@return string
function M.status()
  local ok, env = pcall(M.current_env)
  return ok and env and ("rest[" .. env .. "]") or ""
end

--- Last result / last failed result entry of the current root.
---@return table? last, table? failed
function M.results()
  local root = M.root()
  return S.results[root], S.failed[root]
end

--- Forget stored responses (all roots).
function M.reset()
  S.responses, S.prompts, S.results, S.failed = {}, {}, {}, {}
end

return M

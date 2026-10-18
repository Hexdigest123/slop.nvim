--- commit: per-buffer generation flow (gather -> redact -> prompt -> ai.chat stream -> ghost text at line 1).
local M = {}

local api = vim.api

---@class slop.commit.State
---@field buf integer
---@field status "idle"|"gathering"|"streaming"|"done"|"accepted"|"partial"|"dismissed"|"stale"|"error"
---@field seq integer                  request generation (bumped on every request / cancel)
---@field variants string[][]
---@field index integer                variant shown (0 = none)
---@field attempt integer              requests made so far (temperature ramp)
---@field initial string[]             message when the buffer was attached (amend heuristic)
---@field handle? slop.http.Handle
---@field ctx? table                   gathered + redacted context, reused by regenerate
---@field error? string

local states = {} ---@type table<integer, slop.commit.State>

local function log()
  return require("slop.core.log").scope("commit")
end

local function cfg()
  return require("slop.config").get("commit")
end

local function ghost()
  return require("slop.core.ui.ghost")
end

local function git()
  return require("slop.core.git")
end

local function util()
  return require("slop.core.util")
end

local function ns()
  return util().ns("commit")
end

local function resolve(buf)
  if buf == nil or buf == 0 then
    return api.nvim_get_current_buf()
  end
  return buf
end

local function parse(buf, cc)
  return git().parse_commit_buffer(api.nvim_buf_get_lines(buf, 0, -1, false), { comment_char = cc })
end

local function ghost_id(st)
  return ("slop.commit:%d:%d"):format(st.buf, st.seq)
end

--- Is the visible ghost in `buf` one of ours?
local function ours(buf)
  local g = ghost().get(buf)
  return g ~= nil and type(g.id) == "string" and vim.startswith(g.id, "slop.commit:"), g
end

local function set_status(st, text)
  if not util().buf_valid(st.buf) then
    return
  end
  api.nvim_buf_clear_namespace(st.buf, ns(), 0, -1)
  if text then
    pcall(api.nvim_buf_set_extmark, st.buf, ns(), 0, 0, {
      virt_text = { { text, "SlopCommitStatus" } },
      virt_text_pos = "eol",
      hl_mode = "combine",
      undo_restore = false,
    })
  end
end

local function cancel(st)
  st.seq = st.seq + 1
  if st.handle then
    local h = st.handle
    st.handle = nil
    pcall(function()
      h:cancel()
    end)
  end
end

local function clear_ghost(st)
  if util().buf_valid(st.buf) and ours(st.buf) then
    ghost().clear(st.buf)
  end
  set_status(st, nil)
end

--- The user typed a message (or the buffer went away): drop whatever is in flight / shown.
---@return boolean stale
local function check_stale(st)
  if not util().buf_valid(st.buf) then
    cancel(st)
    return true
  end
  local cc = st.ctx and st.ctx.comment_char or nil
  if parse(st.buf, cc).empty then
    return false
  end
  if st.status == "partial" then
    return true
  end
  if st.status == "gathering" or st.status == "streaming" or ours(st.buf) then
    cancel(st)
    clear_ghost(st)
    st.status = "stale"
  end
  return true
end

local function show(st, lines, loading)
  local buf = st.buf
  local first = api.nvim_buf_get_lines(buf, 0, 1, false)[1] or ""
  local text = vim.deepcopy(lines)
  if first ~= "" then
    text[#text + 1] = "" -- line 1 holds a comment: insert above it, not into it
  end
  local n = #st.variants
  ghost().show(buf, 0, 0, text, {
    id = ghost_id(st),
    counter = (not loading and n > 1) and { st.index, n } or nil,
    loading = loading,
    on_accept = function(_, kind)
      cancel(st)
      set_status(st, nil)
      if kind ~= "all" and ours(buf) then
        st.status = "partial" -- the remainder stays visible (e.g. complete's accept-word key)
        return
      end
      st.status = "accepted"
      require("slop.core.events").emit("commit", "Accepted", { buf = buf, variant = st.index })
    end,
  })
end

local function fail(st, err)
  st.status = "error"
  st.handle = nil
  st.error = type(err) == "table" and (err.message or vim.inspect(err)) or tostring(err)
  set_status(st, nil)
  log().warn("commit message generation failed: %s", st.error)
end

local function textwidth(buf)
  local tw = vim.bo[buf].textwidth
  return (tw and tw > 0) and tw or 72
end

-- Gathering --------------------------------------------------------------------------------------

local function read_conventions(root, c)
  if not c.conventions or c.conventions == "" then
    return nil
  end
  local project = require("slop.core.project")
  local path = project.file(c.conventions, { root = root })
  if not path then
    return nil
  end
  local secrets = require("slop.core.secrets")
  if secrets.is_blocked(path) then
    return nil
  end
  local text = project.read_file(path)
  return text and (secrets.redact_text(text, path)) or nil
end

--- Collect everything the prompt needs (async, in parallel) and redact it.
---@param st slop.commit.State
---@param parsed slop.git.CommitBuffer
---@param opts {amend?: boolean}
---@param cb fun(ctx: table?, err: string?)
local function gather(st, parsed, opts, cb)
  local g = git()
  local c = cfg()
  local root = g.root(st.buf)
  if not root then
    cb(nil, "not inside a git repository")
    return
  end
  local raw = { root = root, comment_char = parsed.comment_char }
  local pending = 1
  local function done()
    pending = pending - 1
    if pending > 0 then
      return
    end
    if not raw.diff or vim.trim(raw.diff) == "" then
      cb(nil, raw.diff_err or "nothing to describe: no staged changes")
      return
    end
    local secrets = require("slop.core.secrets")
    local prompt = require("slop.modules.commit.prompt")
    local diff = prompt.sanitize_diff(raw.diff)
    diff = secrets.redact_diff(diff)
    diff = prompt.redact_hunks(diff)
    local budgeted, files, cut = prompt.budget_diff(diff, { max_chars = c.max_diff_chars, summarize = c.summarize })
    local function red(list)
      return vim.tbl_map(function(s)
        return (secrets.redact_text(s))
      end, list or {})
    end
    cb({
      root = root,
      comment_char = raw.comment_char,
      source = raw.source,
      amend = raw.amend,
      repo = vim.fs.basename(root),
      branch = raw.branch and (secrets.redact_text(raw.branch)) or nil,
      user_commits = red(raw.user_commits),
      repo_commits = red(raw.repo_commits),
      previous = raw.amend and #st.initial > 0 and red(st.initial) or nil,
      diff = budgeted,
      files = files,
      cut = cut,
      conventions = read_conventions(root, c),
      instructions = c.instructions,
      style = c.style,
      textwidth = textwidth(st.buf),
    })
  end
  local function task(fn)
    pending = pending + 1
    fn(done)
  end

  task(function(fin)
    g.config_get("core.commentChar", { cwd = root }, function(v)
      if v and v ~= "" and v ~= "auto" and not parsed.scissors then
        raw.comment_char = v
      end
      fin()
    end)
  end)

  task(function(fin)
    if parsed.diff then
      raw.diff, raw.source = parsed.diff, "verbose"
      fin()
      return
    end
    if parsed.diff_error then
      log().debug("verbose diff ignored: %s", parsed.diff_error)
    end
    local function with_amend(amend)
      raw.amend = amend
      g.staged_diff({ cwd = root, amend = amend }, function(diff, err)
        if diff and vim.trim(diff) ~= "" then
          raw.diff, raw.source = diff, amend and "amend" or "index"
          fin()
          return
        end
        raw.diff_err = err
        if not c.unstaged_fallback or amend then
          fin()
          return
        end
        g.staged_diff({ cwd = root, worktree = true }, function(wdiff)
          if wdiff and vim.trim(wdiff) ~= "" then
            raw.diff, raw.source = wdiff, "worktree"
          end
          fin()
        end)
      end)
    end
    if opts.amend ~= nil then
      with_amend(opts.amend)
    elseif g.parent_amend() then
      with_amend(true)
    elseif #st.initial > 0 then
      g.head_message({ cwd = root }, function(msg)
        local prev = msg and g.parse_commit_buffer(vim.split(msg, "\n", { plain = true }), {}).message
        with_amend(prev ~= nil and #prev > 0 and vim.deep_equal(prev, st.initial))
      end)
    else
      with_amend(false)
    end
  end)

  if c.branch then
    task(function(fin)
      g.branch({ cwd = root }, function(b)
        raw.branch = b
        fin()
      end)
    end)
  end

  if c.recent > 0 then
    task(function(fin)
      g.recent_commits({ cwd = root, n = c.recent }, function(rc)
        raw.user_commits, raw.repo_commits = rc.user, rc.repo
        fin()
      end)
    end)
  end

  done()
end

-- Requests ---------------------------------------------------------------------------------------

local function request(st)
  local c = cfg()
  local ctx = st.ctx
  local prompt = require("slop.modules.commit.prompt")
  local seq = st.seq
  local attempt = st.attempt
  st.attempt = st.attempt + 1
  st.status = "streaming"
  local parse_opts = { comment_char = ctx.comment_char, partial = true }
  local shown = false
  local function on_chunk(_, so_far, acc)
    if seq ~= st.seq or check_stale(st) then
      return
    end
    local lines = prompt.parse_reply(so_far or acc, parse_opts)
    if #lines > 0 then
      if not shown then
        set_status(st, nil)
        shown = true
      end
      show(st, lines, true)
    end
  end
  local acc = ""
  local ok, handle = pcall(function()
    return require("slop.core.registry").service("ai").chat({
      provider = c.provider,
      messages = prompt.build(ctx),
      max_tokens = c.max_tokens,
      temperature = math.min(c.temperature * (1 + attempt), c.max_temperature),
      timeout = c.timeout,
      stream = c.stream,
      on_chunk = c.stream and function(delta, so_far)
        acc = acc .. (delta or "")
        util().main(function()
          on_chunk(delta, so_far, acc)
        end)
      end or nil,
      on_done = function(text, err)
        util().main(function()
          if seq ~= st.seq then
            return
          end
          st.handle = nil
          if err then
            if type(err) == "table" and err.kind == "cancelled" then
              return
            end
            fail(st, err)
            return
          end
          if check_stale(st) then
            return
          end
          local lines = prompt.parse_reply(text or acc, {
            comment_char = ctx.comment_char,
            wrap = c.wrap,
            textwidth = ctx.textwidth,
          })
          if #lines == 0 then
            fail(st, "the model returned an empty message")
            if ours(st.buf) then
              ghost().clear(st.buf)
            end
            return
          end
          st.variants[#st.variants + 1] = lines
          st.index = #st.variants
          st.status = "done"
          set_status(st, nil)
          show(st, lines, false)
          require("slop.core.events").emit(
            "commit",
            "Generated",
            { buf = st.buf, variant = st.index, count = #st.variants }
          )
        end)
      end,
    })
  end)
  if not ok then
    fail(st, handle)
    return
  end
  if seq == st.seq and st.status == "streaming" then
    st.handle = handle
  end
end

-- Public -----------------------------------------------------------------------------------------

--- Start tracking a gitcommit buffer (idempotent). Auto-generates when enabled and the message is empty.
---@param buf integer
---@param opts? {auto?: boolean}
---@return slop.commit.State?
function M.attach(buf, opts)
  opts = opts or {}
  buf = resolve(buf)
  if states[buf] then
    return states[buf]
  end
  if not util().buf_valid(buf) or vim.bo[buf].buftype ~= "" or not vim.bo[buf].modifiable then
    return nil
  end
  local parsed = parse(buf)
  ---@type slop.commit.State
  local st = { buf = buf, status = "idle", seq = 0, variants = {}, index = 0, attempt = 0, initial = parsed.message }
  states[buf] = st
  local group = util().augroup("commit")
  api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "TextChangedP" }, {
    group = group,
    buffer = buf,
    desc = "slop: commit: discard stale suggestions",
    callback = function()
      if states[buf] == st then
        check_stale(st)
      end
    end,
  })
  api.nvim_create_autocmd({ "BufUnload", "BufWipeout" }, {
    group = group,
    buffer = buf,
    desc = "slop: commit: forget buffer",
    callback = function()
      cancel(st)
      if states[buf] == st then
        states[buf] = nil
      end
      return true
    end,
  })
  if opts.auto ~= false and cfg().auto and parsed.empty then
    M.generate(buf)
  end
  return st
end

--- Generate a message for `buf` (gitcommit). A non-empty message is only replaced with `force`.
---@param buf? integer
---@param opts? {amend?: boolean, force?: boolean, fresh?: boolean, explicit?: boolean}
---@return boolean started
function M.generate(buf, opts)
  opts = opts or {}
  buf = resolve(buf)
  local function say(msg)
    if opts.explicit then
      log().notify(msg, vim.log.levels.WARN)
    else
      log().info("%s", msg)
    end
  end
  if not util().buf_valid(buf) or vim.bo[buf].filetype ~= "gitcommit" then
    log().notify("not a git commit message buffer", vim.log.levels.WARN)
    return false
  end
  local st = states[buf] or M.attach(buf, { auto = false })
  if not st then
    log().notify("this commit buffer is not modifiable", vim.log.levels.WARN)
    return false
  end
  local parsed = parse(buf, st.ctx and st.ctx.comment_char or nil)
  if not parsed.empty then
    if not opts.force then
      say("the commit message is not empty (regenerate or :Slop commit! replaces it)")
      return false
    end
    -- drop the current message (one undo step), keep comments and the scissors section
    local stop = (parsed.first_comment or parsed.scissors or (api.nvim_buf_line_count(buf) + 1)) - 1
    cancel(st)
    clear_ghost(st)
    api.nvim_buf_set_lines(buf, 0, stop, false, { "" })
    parsed = parse(buf, st.ctx and st.ctx.comment_char or nil)
  end
  cancel(st)
  clear_ghost(st)
  local seq = st.seq
  st.error = nil
  local label = #st.variants > 0 and ("slop: generating variant %d…"):format(#st.variants + 1)
    or "slop: generating commit message…"
  set_status(st, label)
  if st.ctx and not opts.fresh and opts.amend == nil then
    request(st)
    return true
  end
  st.status = "gathering"
  gather(st, parsed, opts, function(ctx, err)
    if seq ~= st.seq or not util().buf_valid(buf) then
      return
    end
    if err then
      st.status = "idle"
      set_status(st, nil)
      say(err)
      return
    end
    st.ctx = ctx
    if check_stale(st) then
      return
    end
    request(st)
  end)
  return true
end

--- Ask for a new variant (replaces a typed message; one undo step).
---@param buf? integer
---@return boolean
function M.regenerate(buf)
  return M.generate(buf, { force = true })
end

---@param buf? integer
---@return boolean accepted  false when no commit suggestion is visible (keymaps fall through)
function M.accept(buf)
  buf = resolve(buf)
  local st = states[buf]
  if not st or not ours(buf) then
    return false
  end
  if st.status == "streaming" then
    cancel(st) -- accept what is visible now
    set_status(st, nil)
  end
  return ghost().accept(buf)
end

---@param buf? integer
---@return boolean
function M.dismiss(buf)
  buf = resolve(buf)
  local st = states[buf]
  if not st then
    return false
  end
  local busy = st.status == "gathering" or st.status == "streaming"
  if not busy and not ours(buf) then
    return false
  end
  cancel(st)
  clear_ghost(st)
  st.status = "dismissed"
  return true
end

---@param buf? integer
---@return boolean
function M.next(buf)
  buf = resolve(buf)
  local st = states[buf]
  if not st or not ours(buf) then
    return false
  end
  if st.status == "streaming" then
    return true
  end
  if st.index < #st.variants then
    st.index = st.index + 1
    show(st, st.variants[st.index], false)
    return true
  end
  return M.generate(buf, { force = true })
end

---@param buf? integer
---@return boolean
function M.prev(buf)
  buf = resolve(buf)
  local st = states[buf]
  if not st or not ours(buf) then
    return false
  end
  if st.status == "streaming" or #st.variants < 2 then
    return true
  end
  st.index = st.index > 1 and st.index - 1 or #st.variants
  show(st, st.variants[st.index], false)
  return true
end

---@param buf? integer
---@return boolean
function M.is_visible(buf)
  return (ours(resolve(buf)))
end

---@param buf? integer
---@return {status: string, variants: string[][], index: integer, attempt: integer, error?: string, source?: string, amend?: boolean}?
function M.state(buf)
  local st = states[resolve(buf)]
  if not st then
    return nil
  end
  return {
    status = st.status,
    variants = vim.deepcopy(st.variants),
    index = st.index,
    attempt = st.attempt,
    error = st.error,
    source = st.ctx and st.ctx.source or nil,
    amend = st.ctx and st.ctx.amend or nil,
  }
end

--- Last built prompt context of `buf` (for tests / debugging).
---@param buf? integer
---@return table?
function M.context(buf)
  local st = states[resolve(buf)]
  return st and st.ctx and vim.deepcopy(st.ctx) or nil
end

--- Forget every buffer (teardown).
function M.reset()
  for _, st in pairs(states) do
    cancel(st)
    clear_ghost(st)
  end
  states = {}
end

return M

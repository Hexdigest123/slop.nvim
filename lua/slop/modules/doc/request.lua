--- doc: one generation per buffer (target -> redacted prompt -> ai.chat -> parse -> inline diff review).
---@class slop.doc.request
local M = {}

local api = vim.api

---@class slop.doc.Job
---@field buf integer
---@field target slop.doc.Target
---@field mark integer                region of the doc range (tracks edits while in flight)
---@field old string[]                lines of the doc range when the request started
---@field next_line string            line right after the doc range (the item / body line)
---@field handle? slop.http.Handle
---@field spinner? slop.Spinner
---@field progress? slop.Progress
---@field vline? integer              spinner virt_line extmark

local jobs = {} ---@type table<integer, slop.doc.Job>

local function log()
  return require("slop.core.log").scope("doc")
end

local function cfg()
  return require("slop.config").get("doc")
end

local function ns()
  return require("slop.core.util").ns("doc")
end

local function line(buf, row)
  return api.nvim_buf_get_lines(buf, row, row + 1, false)[1]
end

---@param buf? integer
---@return integer
local function bufnr(buf)
  return (buf == nil or buf == 0) and api.nvim_get_current_buf() or buf
end

--- Stop the spinner/progress and drop the job's extmarks.
---@param job slop.doc.Job
---@param status? "success"|"failed"|"cancel"
---@param msg? string
local function finish(job, status, msg)
  if jobs[job.buf] == job then
    jobs[job.buf] = nil
  end
  if job.spinner then
    job.spinner:stop()
    job.spinner = nil
  end
  if job.progress then
    pcall(job.progress.finish, job.progress, status or "success", msg)
    job.progress = nil
  end
  if api.nvim_buf_is_valid(job.buf) then
    pcall(api.nvim_buf_del_extmark, job.buf, ns(), job.mark)
    if job.vline then
      pcall(api.nvim_buf_del_extmark, job.buf, ns(), job.vline)
    end
  end
end

---@param job slop.doc.Job
---@param frame string
local function draw(job, frame)
  local r = require("slop.core.util").mark_range(job.buf, ns(), job.mark)
  if not r then
    return
  end
  local text = ("%s slop doc: writing the doc comment… (:Slop doc cancel)"):format(frame)
  local ok, id = pcall(api.nvim_buf_set_extmark, job.buf, ns(), r[1], 0, {
    id = job.vline,
    virt_lines = { { { text, "SlopSpinner" } } },
    virt_lines_above = true,
  })
  if ok then
    job.vline = id
  end
end

--- Label for messages: "function `name`" or the item's first line.
---@param t slop.doc.Target
---@return string
local function label(t)
  local kinds = { func = "function", class = "class", type = "type" }
  if t.name then
    return ("%s `%s`"):format(kinds[t.kind] or t.kind, t.name)
  end
  local sig = t.signature
  return #sig > 40 and (sig:sub(1, 40) .. "…") or sig
end

--- Apply a parsed answer: re-check the tracked region, then open the inline diff.
---@param job slop.doc.Job
---@param lines string[]
local function apply(job, lines)
  local buf = job.buf
  local r = require("slop.core.util").mark_range(buf, ns(), job.mark)
  if not r then
    log().notify("the buffer changed while waiting; doc comment discarded", vim.log.levels.WARN)
    return
  end
  local s, e = r[1], r[3]
  local cur = api.nvim_buf_get_lines(buf, s, e, false)
  if not vim.deep_equal(cur, job.old) or (line(buf, e) or "") ~= job.next_line then
    log().notify("the target changed while waiting; doc comment discarded", vim.log.levels.WARN)
    return
  end
  local ok, handle = pcall(
    require("slop.core.ui.diff").show,
    buf,
    { s, e },
    lines,
    { title = "slop doc: " .. label(job.target) }
  )
  if not ok then
    log().notify("diff preview failed: " .. tostring(handle), vim.log.levels.ERROR)
    return
  end
  if vim.fn.bufwinid(buf) == -1 then
    log().notify(("doc comment ready for review in %s"):format(vim.fn.bufname(buf)), vim.log.levels.INFO)
  end
end

---@class slop.doc.GenerateOpts
---@field buf? integer
---@field pos? {[1]: integer, [2]: integer}  0-based {row, col}; default cursor

--- Document the item at the cursor. Returns false (after notifying) when nothing was sent.
---@param kind? slop.doc.Kind  nil: the innermost documentable item
---@param opts? slop.doc.GenerateOpts
---@return boolean started
function M.generate(kind, opts)
  opts = opts or {}
  local buf = bufnr(opts.buf)
  local c = cfg()
  local secrets = require("slop.core.secrets")
  if secrets.is_blocked(buf) then
    log().notify("this file is blocked by core.secrets; refusing to send it", vim.log.levels.ERROR)
    return false
  end
  local target, terr = require("slop.modules.doc.target").find(buf, opts.pos, kind)
  if not target then
    log().notify(terr or "nothing to document here", vim.log.levels.WARN)
    return false
  end
  local langs = require("slop.modules.doc.langs")
  local prompt = require("slop.modules.doc.prompt")
  local ft, cs = vim.bo[buf].filetype, vim.bo[buf].commentstring
  local syntax = langs.syntax_for(ft, cs)
  if not syntax and not target.docstring then
    log().notify(("no comment syntax known for filetype '%s' (set 'commentstring')"):format(ft), vim.log.levels.WARN)
    return false
  end
  M.cancel(buf)

  local system = prompt.system(target, prompt.style(ft, c.styles, cs), c.instructions)
  local user = prompt.message(target, { context_lines = c.context_lines, max_chars = c.max_chars })
  local code = api.nvim_buf_get_lines(buf, target.rows[1], target.rows[2] + 1, false)
  local s, e = target.range[1], target.range[2]
  ---@type slop.doc.Job
  local job = {
    buf = buf,
    target = target,
    mark = require("slop.core.util").region_mark(buf, ns(), { s, 0, e, 0 }),
    old = api.nvim_buf_get_lines(buf, s, e, false),
    next_line = line(buf, e) or "",
  }
  jobs[buf] = job

  local spinner = require("slop.core.ui.spinner")
  job.spinner = spinner.new({
    on_tick = function(frame)
      if jobs[buf] == job then
        draw(job, frame)
      end
    end,
  })
  job.spinner:start()
  job.progress = spinner.progress({
    title = "slop doc",
    message = "documenting " .. label(target) .. "…",
    on_cancel = function()
      if jobs[buf] == job then
        M.cancel(buf)
      end
    end,
  })

  local ok, err = pcall(function()
    job.handle = require("slop.core.registry").service("ai").chat({
      provider = c.provider,
      system = system,
      messages = { { role = "user", content = user } },
      max_tokens = c.max_tokens,
      temperature = c.temperature,
      timeout = c.timeout,
      stream = false,
      on_done = function(text, aerr)
        if jobs[buf] ~= job then
          return -- cancelled or superseded
        end
        if aerr then
          finish(job, "failed", "failed")
          if type(aerr) == "table" and aerr.kind == "cancelled" then
            return
          end
          local msg = type(aerr) == "table" and (aerr.message or vim.inspect(aerr)) or tostring(aerr)
          log().notify("AI request failed: " .. msg, vim.log.levels.ERROR)
          return
        end
        if not api.nvim_buf_is_valid(buf) then
          return finish(job, "cancel", "buffer closed")
        end
        local lines, perr = prompt.parse(text or "", target, code, syntax)
        if not lines then
          finish(job, "failed", "failed")
          log().debug("rejected answer:\n%s", text or "")
          log().notify(perr .. "; nothing inserted (see :Slop log)", vim.log.levels.ERROR)
          return
        end
        apply(job, lines)
        finish(job, "success", "done")
      end,
    })
  end)
  if not ok then
    finish(job, "failed", "failed")
    log().notify("AI request failed: " .. tostring(err), vim.log.levels.ERROR)
    return false
  end
  return true
end

--- Cancel the running request of `buf` (default current).
---@param buf? integer
---@return boolean cancelled
function M.cancel(buf)
  buf = bufnr(buf)
  local job = jobs[buf]
  if not job then
    return false
  end
  jobs[buf] = nil
  if job.handle then
    pcall(job.handle.cancel, job.handle)
  end
  finish(job, "cancel", "cancelled")
  return true
end

---@param buf? integer
---@return boolean
function M.is_running(buf)
  return jobs[bufnr(buf)] ~= nil
end

--- Cancel everything (teardown).
function M.reset()
  for buf in pairs(vim.deepcopy(jobs)) do
    M.cancel(buf)
  end
end

return M

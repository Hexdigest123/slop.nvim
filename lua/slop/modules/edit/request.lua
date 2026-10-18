--- One edit request: region -> ACP session -> live progress -> replacement -> inline diff review.
---@class slop.edit.request_mod
local M = {}

local api = vim.api
local util = require("slop.core.util")
local ui = require("slop.modules.edit.ui")

local function log()
  return require("slop.core.log").scope("edit")
end

---@type table<integer, slop.edit.Request>
M.active = {}
local next_id = 0

---@class slop.edit.RequestOpts
---@field buf integer
---@field range slop.Range                 0-based, charwise, end exclusive
---@field linewise boolean
---@field instruction string               text without the #preset token
---@field preset? slop.edit.Preset
---@field agent string
---@field cfg table                        edit module config

---@class slop.edit.Request
---@field id integer
---@field buf integer
---@field range slop.Range
---@field linewise boolean
---@field instruction string
---@field preset? slop.edit.Preset
---@field sink "diff"|"float"|"scratch"
---@field agent string
---@field cfg table
---@field state "new"|"starting"|"running"|"review"|"done"|"cancelled"|"failed"
---@field mark integer?
---@field status_id integer?
---@field status string
---@field message string
---@field started integer
---@field cancel_key string|false
---@field old_lines string[]
---@field diffs table[]
---@field tools table<string, table>
---@field session slop.acp.Session?
---@field diff slop.diff.Handle?
---@field private _spinner slop.Spinner?
---@field private _progress slop.Progress?
---@field private _finished boolean
---@field private _refining boolean
---@field private _busy boolean
---@field private _warned_write boolean
---@field private _ctx slop.edit.ReplaceCtx
---@field private _full_rows integer
local Request = {}
Request.__index = Request

local function get_line(buf, row)
  return api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ""
end

local function short(s, n)
  s = (s or ""):gsub("%s+", " ")
  if #s > n then
    return s:sub(1, n - 1) .. "…"
  end
  return s
end

--- Does the region contain secrets? core.secrets.is_cloaked plus a full-buffer redaction pass (multi-line rules
--- such as PEM blocks only match with their surrounding lines).
---@param buf integer
---@param r slop.Range
---@return boolean
function M.region_has_secrets(buf, r)
  local secrets = require("slop.core.secrets")
  if secrets.is_cloaked(buf, r) then
    return true
  end
  local all = api.nvim_buf_get_lines(buf, 0, -1, false)
  local red = secrets.redact_lines(buf, all, 0)
  for row = r[1], r[3] do
    if red[row + 1] ~= all[row + 1] then
      return true
    end
  end
  return false
end

---@param o slop.edit.RequestOpts
---@return slop.edit.Request
function M.new(o)
  next_id = next_id + 1
  local cancel = util.tbl_get(o.cfg, "keymaps", "cancel")
  return setmetatable({
    id = next_id,
    buf = o.buf,
    range = o.range,
    linewise = o.linewise,
    instruction = o.instruction,
    preset = o.preset,
    sink = o.preset and o.preset.sink or "diff",
    agent = o.agent,
    cfg = o.cfg,
    state = "new",
    status = "starting",
    message = "",
    started = vim.uv.now(),
    cancel_key = type(cancel) == "string" and cancel or false,
    diffs = {},
    tools = {},
    _finished = false,
    _refining = false,
  }, Request)
end

---@return string
function Request:label()
  local p = self.preset and ("#" .. self.preset.name .. " ") or ""
  return short(p .. self.instruction, 60)
end

function Request:_progress_start()
  local spinner = require("slop.core.ui.spinner")
  self._spinner = spinner.new({
    on_tick = function(frame)
      if self.state ~= "starting" and self.state ~= "running" then
        return
      end
      ui.render_status(self, frame)
    end,
  })
  self._spinner:start()
  self._progress = spinner.progress({
    title = "slop edit",
    message = self.agent .. ": " .. self.status,
    source = "slop",
    on_cancel = function()
      self:cancel()
    end,
  })
  if not self._busy then
    self._busy = true
    pcall(function()
      vim.bo[self.buf].busy = vim.bo[self.buf].busy + 1
    end)
  end
end

function Request:_progress_stop(status, msg)
  if self._spinner then
    self._spinner:stop()
    self._spinner = nil
  end
  if self._progress then
    self._progress:finish(status, msg)
    self._progress = nil
  end
  if self._busy then
    self._busy = false
    pcall(function()
      if api.nvim_buf_is_valid(self.buf) then
        vim.bo[self.buf].busy = math.max(0, vim.bo[self.buf].busy - 1)
      end
    end)
  end
end

---@param status string
--- Current region (linewise regions are normalised to whole lines).
---@return slop.Range?
function Request:region()
  local r = ui.region(self.buf, self.mark)
  if r and self.linewise then
    if r[4] == 0 and r[3] > r[1] then
      r[3] = r[3] - 1
    end
    r[2], r[4] = 0, #get_line(self.buf, r[3])
  end
  return r
end

function Request:_set_status(status)
  if status == self.status then
    return
  end
  self.status = status
  if self._progress then
    self._progress:update(self.agent .. ": " .. status)
  end
end

--- Build the first prompt (redacted).
---@param embedded boolean
---@return table[] blocks
function Request:_build_prompt(embedded)
  local secrets = require("slop.core.secrets")
  local context = require("slop.modules.edit.context")
  local prompt = require("slop.modules.edit.prompt")
  local buf, r = self.buf, self.range
  local root = context.root(buf)
  local path = vim.fs.normalize(api.nvim_buf_get_name(buf))
  local rel = path
  if path ~= "" and vim.startswith(path, root .. "/") then
    rel = path:sub(#root + 2)
  end
  local n = tonumber(self.cfg.surrounding) or 50
  local lc = api.nvim_buf_line_count(buf)
  local b0 = math.max(0, r[1] - n)
  local before = secrets.redact_lines(buf, api.nvim_buf_get_lines(buf, b0, r[1], false), b0)
  local after =
    secrets.redact_lines(buf, api.nvim_buf_get_lines(buf, r[3] + 1, math.min(lc, r[3] + 1 + n), false), r[3] + 1)
  if not self.linewise then
    local first, last = get_line(buf, r[1]), get_line(buf, r[3])
    local prefix, suffix = first:sub(1, r[2]), last:sub(r[4] + 1)
    if prefix ~= "" then
      before[#before + 1] = (secrets.redact_text(prefix, buf))
    end
    if suffix ~= "" then
      table.insert(after, 1, (secrets.redact_text(suffix, buf)))
    end
  end
  local region = vim.split((secrets.redact_text(table.concat(self.old_lines, "\n"), buf)), "\n", { plain = true })

  local files = {}
  for _, m in ipairs(context.mentions(self.instruction)) do
    local fc, err = context.file(m, root)
    if fc then
      files[#files + 1] = fc
    else
      log().warn("@%s not attached: %s", m, err or "?")
    end
  end
  local rules = context.rules(root, self.cfg.rules_files or {})
  local diags = (self.preset and self.preset.diagnostics) and context.diagnostics(buf, r[1], r[3]) or nil
  local blocks = prompt.build({
    sink = self.sink,
    path = path,
    rel = rel,
    filetype = vim.bo[buf].filetype,
    srow = r[1],
    erow = r[3],
    scol = not self.linewise and r[2] or nil,
    ecol = not self.linewise and r[4] or nil,
    region = region,
    before = before,
    after = after,
    instruction = prompt.instruction(self.preset, self.instruction),
    rules = rules,
    files = files,
    diagnostics = diags,
    embedded = embedded,
  })
  return blocks
end

--- Start: validate, mark the region, open a session on the long-lived agent and send the prompt.
---@return boolean ok, string? err
function Request:start()
  local buf, r = self.buf, self.range
  local secrets = require("slop.core.secrets")
  if not util.buf_valid(buf) then
    return false, "invalid buffer"
  end
  if secrets.is_blocked(buf) then
    return false, "this buffer is blocked by the secrets policy: nothing is sent"
  end
  if M.region_has_secrets(buf, r) then
    return false, "the region contains secrets: refusing to send it (the replacement would destroy them)"
  end
  if self.sink == "diff" and not vim.bo[buf].modifiable then
    return false, "buffer is not modifiable"
  end
  self.old_lines = util.range_text(buf, r)
  local full_before = api.nvim_buf_get_text(buf, 0, 0, r[1], r[2], {})
  local lc = api.nvim_buf_line_count(buf)
  local last = get_line(buf, lc - 1)
  local full_after = api.nvim_buf_get_text(buf, r[3], r[4], lc - 1, #last, {})
  self._ctx = {
    path = vim.fs.normalize(api.nvim_buf_get_name(buf)),
    old_text = table.concat(self.old_lines, "\n"),
    file_before = table.concat(full_before, "\n"),
    file_after = table.concat(full_after, "\n"),
  }
  self.mark = ui.region_mark(buf, r)
  self.state = "starting"
  M.active[self.id] = self
  self:_progress_start()
  require("slop.core.events").emit("edit", "Start", { id = self.id, buf = buf, agent = self.agent })

  local acp = require("slop.services.ai.acp")
  local client = acp.client({ agent = self.agent })
  self:_set_status(client.state == "ready" and "opening session" or "starting agent")
  client:new_session({ cwd = require("slop.modules.edit.context").root(buf) }, function(session, err)
    if self.state ~= "starting" then
      if session then
        session:close()
      end
      return
    end
    if not session then
      self:_fail(err or "cannot start the agent")
      return
    end
    self.session = session
    local caps = client.capabilities or {}
    local embedded = type(caps.promptCapabilities) == "table" and caps.promptCapabilities.embeddedContext == true
    local ok, blocks = pcall(self._build_prompt, self, embedded)
    if not ok then
      self:_fail("building the prompt failed: " .. tostring(blocks))
      return
    end
    self:_send(blocks)
  end)
  return true
end

---@param blocks table[]
function Request:_send(blocks)
  self.state = "running"
  self.message = ""
  self.diffs = {}
  self:_set_status("waiting for " .. self.agent)
  self.session:prompt(blocks, {
    on_update = function(u)
      self:_on_update(u)
    end,
    on_permission = function(req, respond)
      self:_on_permission(req, respond)
    end,
    on_done = function(stop, err)
      self:_on_done(stop, err)
    end,
  })
end

---@param u table
function Request:_on_update(u)
  if self.state ~= "running" then
    return
  end
  local acp = require("slop.services.ai.acp")
  local kind = u.sessionUpdate
  if kind == "agent_message_chunk" then
    self.message = self.message .. acp.block_text(u.content)
    self:_set_status("writing")
  elseif kind == "agent_thought_chunk" then
    self:_set_status("thinking")
  elseif kind == "tool_call" or kind == "tool_call_update" then
    local id = u.toolCallId or "?"
    local tc = self.tools[id] or {}
    for k, v in pairs(u) do
      if not (k == "content" and type(v) == "table" and #v == 0) then
        tc[k] = v
      end
    end
    self.tools[id] = tc
    local title = tc.title or tc.kind or "tool"
    local st = tc.status
    self:_set_status(st and st ~= "pending" and st ~= "in_progress" and (title .. " (" .. st .. ")") or title)
    if tc.kind == "edit" and st == "completed" and not self._warned_write then
      for _, p in ipairs(acp.tool_paths(tc)) do
        if vim.fs.normalize(p) == self._ctx.path then
          self._warned_write = true
          log().warn(
            "agent %s modified %s itself (configure it to ask for permissions); slop only applies its replacement",
            self.agent,
            p
          )
          break
        end
      end
    end
  elseif kind == "plan" and type(u.entries) == "table" then
    local done = 0
    for _, e in ipairs(u.entries) do
      if type(e) == "table" and e.status == "completed" then
        done = done + 1
      end
    end
    self:_set_status(("plan %d/%d"):format(done, #u.entries))
  end
end

---@param req table
---@param respond fun(option_id: string|nil)
function Request:_on_permission(req, respond)
  local acp = require("slop.services.ai.acp")
  local policy = self.cfg.permissions or acp.default_policy
  local id, verdict, reason = acp.decide(req, policy)
  local tc = type(req.toolCall) == "table" and req.toolCall or {}
  if verdict == "reject" then
    for _, c in ipairs(type(tc.content) == "table" and tc.content or {}) do
      if type(c) == "table" and c.type == "diff" then
        self.diffs[#self.diffs + 1] = c
      end
    end
    local known = tc.toolCallId and self.tools[tc.toolCallId]
    for _, c in ipairs(known and type(known.content) == "table" and known.content or {}) do
      if type(c) == "table" and c.type == "diff" then
        self.diffs[#self.diffs + 1] = c
      end
    end
    self:_set_status("rejected: " .. (tc.title or tc.kind or "tool"))
  end
  log().debug("permission %s -> %s (%s)", tc.title or tc.kind or "?", tostring(id), reason)
  respond(id)
end

---@param stop string?
---@param err table?
function Request:_on_done(stop, err)
  if self.state ~= "running" then
    return
  end
  if err then
    local msg = err.message or vim.inspect(err)
    if err.stderr and err.stderr ~= "" then
      msg = msg .. "\n" .. err.stderr
    end
    self:_fail(msg, true)
    return
  end
  if stop == "cancelled" then
    self.state = "cancelled"
    self:_finish("cancelled")
    return
  end
  if stop == "refusal" then
    self:_fail("the agent refused the request", true)
    return
  end
  if stop == "max_tokens" or stop == "max_turn_requests" then
    log().warn("the agent stopped early (%s); the answer may be incomplete", stop)
  end
  self:_complete()
end

function Request:_complete()
  local replacement = require("slop.modules.edit.replacement")
  local secrets = require("slop.core.secrets")
  local title = ("slop %s: %s"):format(self.agent, self:label())
  if self.sink == "float" then
    self:_progress_stop("success", "done")
    ui.clear(self)
    if vim.trim(self.message) == "" then
      self:_fail("the agent returned no answer")
      return
    end
    ui.show_float(title, self.message)
    self.state = "done"
    self:_finish("explained")
    return
  end
  local text, src = replacement.extract(self.message, self._ctx, self.diffs)
  if not text then
    self:_fail(src, true)
    return
  end
  if src ~= "tag" then
    log().info(
      "the agent ignored the replacement protocol; using its %s",
      src == "diff" and "proposed edit" or "last code block"
    )
  end
  if self.sink == "scratch" then
    self:_progress_stop("success", "done")
    ui.clear(self)
    local lines = replacement.validate(text, { old_text = "", linewise = true, placeholder = secrets.placeholder() })
      or vim.split(text, "\n", { plain = true })
    ui.show_scratch(
      ("edit/%s-%d"):format(self.preset and self.preset.name or "result", self.id),
      lines,
      vim.bo[self.buf].filetype
    )
    self.state = "done"
    self:_finish("scratch")
    return
  end
  local lines, verr = replacement.validate(text, {
    old_text = self._ctx.old_text,
    linewise = self.linewise,
    placeholder = secrets.placeholder(),
  })
  if not lines then
    self:_fail(verr, true)
    return
  end
  local buf = self.buf
  local r = util.buf_valid(buf) and self:region() or nil
  if not r then
    self:_fail("the region was deleted while the request was running; the answer is in a scratch buffer", true)
    return
  end
  local conflict = not vim.deep_equal(util.range_text(buf, r), self.old_lines)
  local new_full
  if self.linewise then
    new_full = lines
  else
    local prefix = get_line(buf, r[1]):sub(1, r[2])
    local suffix = get_line(buf, r[3]):sub(r[4] + 1)
    new_full = vim.split(prefix .. table.concat(lines, "\n") .. suffix, "\n", { plain = true })
  end
  self:_progress_stop("success", "review")
  ui.clear(self)
  self.state = "review"
  self._full_rows = r[3] - r[1] + 1
  local diff = require("slop.core.ui.diff")
  self.diff = diff.show(buf, { r[1], r[3] + 1 }, new_full, {
    keymaps = util.tbl_get(self.cfg, "keymaps", "diff"),
    title = title,
    conflict = conflict,
    on_refine = self.sink == "diff" and function()
      self:refine_prompt()
    end or nil,
    on_done = function(result)
      if self._refining then
        return
      end
      self:_finish(result)
    end,
  })
  if conflict then
    log().warn("the region changed while %s was working: review the diff before accepting", self.agent)
  elseif self.cfg.apply == "auto" and self.diff:is_active() then
    self.diff:accept_all()
  end
end

--- Open the refine prompt for a request in review.
function Request:refine_prompt()
  if self.state ~= "review" or not self.diff then
    return
  end
  local r = self.diff:range()
  require("slop.core.ui.input").open({
    title = ("Refine · %s"):format(self.agent),
    anchor = r and { buf = self.buf, row = r[1], end_row = math.max(r[1], r[2] - 1) } or nil,
    history = "edit",
    on_submit = function(text)
      self:refine(text)
    end,
  })
end

--- Ask the same session for a new replacement of the original region.
---@param text string
---@return boolean
function Request:refine(text)
  if self.state ~= "review" or not self.diff or not self.session then
    return false
  end
  local hr = self.diff:range()
  if not hr then
    return false
  end
  self._refining = true
  self.diff:reject_all()
  self._refining = false
  self.diff = nil
  local buf = self.buf
  local srow = hr[1]
  local erow = math.min(api.nvim_buf_line_count(buf) - 1, srow + self._full_rows - 1)
  local range =
    { srow, self.linewise and 0 or self.range[2], erow, self.linewise and #get_line(buf, erow) or self.range[4] }
  range[4] = math.min(range[4], #get_line(buf, erow))
  self.range = range
  self.old_lines = util.range_text(buf, range)
  self._ctx.old_text = table.concat(self.old_lines, "\n")
  self.mark = ui.region_mark(buf, range)
  self.instruction = self.instruction .. " (refined: " .. text .. ")"
  self.started = vim.uv.now()
  M.active[self.id] = self
  self:_progress_start()
  local blocks = require("slop.modules.edit.prompt").refine(text, self.sink)
  self:_send(blocks)
  return true
end

--- Cancel a starting/running request.
---@return boolean
function Request:cancel()
  if self.state ~= "starting" and self.state ~= "running" then
    return false
  end
  self.state = "cancelled"
  if self.session then
    self.session:cancel()
  end
  self:_finish("cancelled")
  return true
end

---@return boolean
function Request:is_running()
  return self.state == "starting" or self.state == "running"
end

---@param msg string
---@param show_raw? boolean
function Request:_fail(msg, show_raw)
  if self._finished then
    return
  end
  self.state = "failed"
  local r = ui.region(self.buf, self.mark)
  log().notify("edit failed: " .. msg, vim.log.levels.ERROR)
  if r then
    ui.flash_error(self.buf, r[1], (msg:gsub("\n.*", "")))
  end
  if show_raw and vim.trim(self.message) ~= "" then
    ui.show_scratch("edit/output-" .. self.id, vim.split(self.message, "\n", { plain = true }), "markdown")
  end
  self:_finish("failed")
end

---@param result string
function Request:_finish(result)
  if self._finished then
    return
  end
  self._finished = true
  local status = result == "cancelled" and "cancel" or (result == "failed" and "failed" or "success")
  self:_progress_stop(status, result)
  ui.clear(self)
  if self.diff and self.diff:is_active() then
    self._refining = true
    self.diff:close()
    self._refining = false
  end
  if self.session then
    pcall(self.session.close, self.session)
  end
  M.active[self.id] = nil
  if result == "unchanged" then
    log().notify("the agent made no changes", vim.log.levels.INFO)
  elseif result == "cancelled" then
    log().notify("edit cancelled", vim.log.levels.INFO)
  end
  require("slop.core.events").emit("edit", "Done", { id = self.id, buf = self.buf, result = result })
end

--- Running/reviewing requests, oldest first.
---@return slop.edit.Request[]
function M.list()
  local out = {}
  for _, r in pairs(M.active) do
    out[#out + 1] = r
  end
  table.sort(out, function(a, b)
    return a.id < b.id
  end)
  return out
end

return M

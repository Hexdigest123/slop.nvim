--- Spinner frames + ticking timer (main-loop callbacks), and native progress messages. OWNER: edit.
---
---   spinner.new({ on_tick = function(frame) ... end }):start()   -- redraw your virt_text in on_tick
---   local p = spinner.progress({ title = "slop edit", on_cancel = cancel })
---   p:update("reading foo.lua", 30) ... p:finish("success", "done")
---
--- Progress uses `nvim_echo(..., { kind = "progress" })` (Neovim 0.12): the default statusline shows it via
--- vim.ui.progress_status(), the TUI emits OSC 9;4. Ticks are never written to :messages (history only on finish).
---@class slop.ui.spinner
local M = {}

local uv = vim.uv

local STYLES = {
  dots = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" },
  line = { "-", "\\", "|", "/" },
  arc = { "◜", "◠", "◝", "◞", "◡", "◟" },
  circle = { "◐", "◓", "◑", "◒" },
  bounce = { "⠁", "⠂", "⠄", "⡀", "⢀", "⠠", "⠐", "⠈" },
  moon = { "🌑", "🌒", "🌓", "🌔", "🌕", "🌖", "🌗", "🌘" },
}

local function default_style()
  local ok, ui = pcall(function()
    return require("slop.config").get("ui")
  end)
  return ok and ui and ui.spinner or "dots"
end

--- Available style names.
---@return string[]
function M.styles()
  local out = vim.tbl_keys(STYLES)
  table.sort(out)
  return out
end

--- Frames of a style (default: config ui.spinner; unknown styles fall back to "dots").
---@param style? string
---@return string[]
function M.frames(style)
  return vim.deepcopy(STYLES[style or default_style()] or STYLES.dots)
end

---@class slop.spinner.Opts
---@field style? string                    default config ui.spinner ("dots")
---@field interval? integer                ms, default 80
---@field on_tick fun(frame: string)       called on the main loop

---@class slop.Spinner
---@field private _frames string[]
---@field private _i integer
---@field private _timer uv.uv_timer_t?
---@field private _opts slop.spinner.Opts
local Spinner = {}
Spinner.__index = Spinner

function Spinner:start()
  if self._timer then
    return
  end
  local timer = assert(uv.new_timer())
  self._timer = timer
  local interval = self._opts.interval or 80
  timer:start(
    0,
    interval,
    vim.schedule_wrap(function()
      if self._timer ~= timer then
        return
      end
      self._i = self._i % #self._frames + 1
      local ok, err = pcall(self._opts.on_tick, self._frames[self._i])
      if not ok then
        self:stop()
        require("slop.core.log").error("spinner on_tick: %s", err)
      end
    end)
  )
end

function Spinner:stop()
  local timer = self._timer
  self._timer = nil
  if timer then
    timer:stop()
    if not timer:is_closing() then
      timer:close()
    end
  end
end

---@return string
function Spinner:frame()
  return self._frames[math.max(1, self._i)]
end

---@return boolean
function Spinner:is_running()
  return self._timer ~= nil
end

---@param opts slop.spinner.Opts
---@return slop.Spinner
function M.new(opts)
  assert(type(opts) == "table" and type(opts.on_tick) == "function", "slop: spinner.new needs on_tick")
  return setmetatable({ _frames = M.frames(opts.style), _i = 0, _opts = opts }, Spinner)
end

-- Native progress ---------------------------------------------------------------------------------

---@class slop.spinner.ProgressOpts
---@field title? string                    default "slop"
---@field message? string                  initial message
---@field source? string                   Progress autocmd pattern (default "slop")
---@field percent? integer
---@field on_cancel? fun()                 the UI asked to cancel (Progress event with status "cancel")

---@class slop.Progress
---@field id string
---@field private _opts slop.spinner.ProgressOpts
---@field private _done boolean
---@field private _au integer?
---@field private _msg string
local Progress = {}
Progress.__index = Progress

local counter = 0

---@param status string
---@param message string
---@param percent? integer
---@param history boolean
function Progress:_echo(status, message, percent, history)
  local o = self._opts
  pcall(vim.api.nvim_echo, { { message ~= "" and message or (o.title or "slop") } }, history, {
    kind = "progress",
    id = self.id,
    title = o.title or "slop",
    source = o.source or "slop",
    status = status,
    percent = percent,
  })
end

--- Update the message (and optionally the percentage).
---@param message string
---@param percent? integer
function Progress:update(message, percent)
  if self._done then
    return
  end
  self._msg = message or self._msg
  self:_echo("running", self._msg, percent, false)
end

--- Finish: status "success" (default) | "failed" | "cancel".
---@param status? "success"|"failed"|"cancel"
---@param message? string
function Progress:finish(status, message)
  if self._done then
    return
  end
  self._done = true
  if self._au then
    pcall(vim.api.nvim_del_autocmd, self._au)
    self._au = nil
  end
  status = status or "success"
  self:_echo(status, message or self._msg, status == "success" and 100 or nil, false)
end

---@return boolean
function Progress:is_done()
  return self._done
end

--- Start a native progress message.
---@param opts? slop.spinner.ProgressOpts
---@return slop.Progress
function M.progress(opts)
  opts = opts or {}
  counter = counter + 1
  local source = opts.source or "slop"
  local self = setmetatable({
    id = ("slop.%s.%d"):format(source:gsub("[^%w_.-]", "_"), counter),
    _opts = opts,
    _done = false,
    _msg = opts.message or "",
  }, Progress)
  if opts.on_cancel then
    local ok, au = pcall(vim.api.nvim_create_autocmd, "Progress", {
      group = require("slop.core.util").augroup("progress"),
      pattern = source,
      desc = "slop: progress cancel",
      callback = function(ev)
        local d = ev.data or {}
        if d.id == self.id and d.status == "cancel" and not self._done then
          opts.on_cancel()
        end
      end,
    })
    self._au = ok and au or nil
  end
  self:_echo("running", self._msg, opts.percent, false)
  return self
end

return M

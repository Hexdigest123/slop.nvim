--# selene: allow(unused_variable)
--- Terminal jobs: spawn hidden, show/hide in a window (job + scrollback persist), send, kill, list.
--- OWNER: term. STATUS: stub (interface only). Used by the term module and any future task runner.
---
--- Design notes (research/12-term.md §4.3): one window "slot" per layout per tabpage; floats via
--- core.ui.float (always bordered with config ui.border); TermClose -> exit_code + User SlopTermExit;
--- multi-line send uses bracketed paste (nvim_paste) when the app supports it.
---@class slop.term
local M = {}

local function todo(name)
  error("slop: core.term." .. name .. " not implemented yet", 2)
end

---@alias slop.term.Layout "float"|"split"|"vsplit"

---@class slop.term.Spec
---@field name? string                 display name (default: basename of cmd[1])
---@field cmd? string|string[]          default: { vim.o.shell }
---@field cwd? string                   default: core.project.root()
---@field env? table<string, string>
---@field owner? string                 "term" | "task" | ...  (default "term")
---@field hidden? boolean               excluded from list()/smart toggles by default
---@field layout? slop.term.Layout      default layout for show()
---@field float? slop.float.Opts        float overrides (size, title, ...)
---@field close_on_exit? boolean|"success"  wipe buffer when the job exits (default true)
---@field on_exit? fun(term: slop.Term, code: integer)

---@class slop.Term
---@field id integer                    1..n, gap-filling
---@field name string
---@field owner string
---@field cmd string[]
---@field cwd string
---@field buf integer?                  terminal buffer (nil until spawned)
---@field win integer?                  window currently showing it
---@field job integer?                  channel id
---@field layout slop.term.Layout
---@field hidden boolean
---@field exit_code integer?
---@field show fun(self: slop.Term, opts?: slop.term.ShowOpts): slop.Term
---@field hide fun(self: slop.Term)
---@field toggle fun(self: slop.Term, opts?: slop.term.ShowOpts)
---@field focus fun(self: slop.Term)
---@field send fun(self: slop.Term, data: string|string[], opts?: slop.term.SendOpts)
---@field kill fun(self: slop.Term)
---@field is_visible fun(self: slop.Term): boolean
---@field is_running fun(self: slop.Term): boolean

---@class slop.term.ShowOpts
---@field layout? slop.term.Layout
---@field enter? boolean                focus the window (default true)
---@field insert? boolean               start insert (default: restore remembered mode)

---@class slop.term.SendOpts
---@field submit? boolean               append <CR> (default true)
---@field paste? boolean|"auto"         bracketed paste for multi-line (default "auto")
---@field dedent? boolean               strip common indent (default true)
---@field show? boolean                 show the terminal first (default: keep visibility)

--- Spawn a terminal job in a hidden buffer (not shown).
---@param spec? slop.term.Spec
---@return slop.Term
function M.spawn(spec)
  todo("spawn")
end

--- Show a terminal (spawning it if needed) in a float/split/vsplit.
---@param term slop.Term|integer|string  object, id or name
---@param opts? slop.term.ShowOpts
---@return slop.Term
function M.show(term, opts)
  todo("show")
end

---@param term slop.Term|integer|string
function M.hide(term)
  todo("hide")
end

---@param term slop.Term|integer|string
---@param opts? slop.term.ShowOpts
function M.toggle(term, opts)
  todo("toggle")
end

--- Send text to the job.
---@param term slop.Term|integer|string
---@param data string|string[]
---@param opts? slop.term.SendOpts
function M.send(term, data, opts)
  todo("send")
end

--- Stop the job and wipe its buffer.
---@param term slop.Term|integer|string
function M.kill(term)
  todo("kill")
end

---@param target integer|string  id or name
---@return slop.Term?
function M.get(target)
  todo("get")
end

---@param opts? {hidden?: boolean, owner?: string}  include hidden terminals / filter by owner
---@return slop.Term[]
function M.list(opts)
  return {}
end

--- Most recently used visible-able (non-hidden) terminal.
---@return slop.Term?
function M.last()
  return nil
end

return M

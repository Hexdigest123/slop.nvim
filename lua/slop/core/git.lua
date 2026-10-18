--# selene: allow(unused_variable)
--- Async git helpers (vim.system, never blocking). OWNER: commit. STATUS: stub (interface only).
---@class slop.git
local M = {}

---@class slop.git.Result
---@field code integer
---@field stdout string
---@field stderr string

---@class slop.git.RunOpts
---@field cwd? string                    default core.project.root()
---@field env? table<string, string>     e.g. { GIT_INDEX_FILE = ... } (inherits the environment)
---@field stdin? string
---@field timeout? integer               ms

--- Run `git <args>`; cb runs on the main loop.
---@param args string[]
---@param opts? slop.git.RunOpts
---@param cb fun(res: slop.git.Result)
---@return vim.SystemObj
function M.run(args, opts, cb)
  error("slop: core.git.run not implemented yet", 2)
end

--- Git work-tree root of a path/buffer (nil outside a repo). Sync, cheap (vim.fs.root on ".git").
---@param src? string|integer
---@return string?
function M.root(src)
  error("slop: core.git.root not implemented yet", 2)
end

--- Staged diff (`git diff --cached`, honouring GIT_INDEX_FILE / --amend). Output is NOT redacted:
--- pass it through core.secrets.redact_diff() before sending it anywhere.
---@param opts? {cwd?: string, amend?: boolean, env?: table<string, string>, context?: integer}
---@param cb fun(diff: string?, err: string?)
function M.staged_diff(opts, cb)
  error("slop: core.git.staged_diff not implemented yet", 2)
end

--- Current branch name (nil when detached).
---@param opts? {cwd?: string}
---@param cb fun(branch: string?, err: string?)
function M.branch(opts, cb)
  error("slop: core.git.branch not implemented yet", 2)
end

--- Last `n` commit subjects (newest first), for style hints.
---@param opts? {cwd?: string, n?: integer}
---@param cb fun(subjects: string[]?, err: string?)
function M.log(opts, cb)
  error("slop: core.git.log not implemented yet", 2)
end

return M

--- commit: AI commit message as ghost text in gitcommit buffers (`git commit` with EDITOR=nvim, fugitive).
---
--- On `FileType gitcommit` with an empty message area, the staged diff (verbose scissors section, else
--- `git diff --cached` honouring GIT_INDEX_FILE / --amend), branch, recent commits and <root>/.nvim/commit.md are
--- redacted (core.secrets), sent to services.ai.chat and streamed as ghost text at line 1 (core.ui.ghost).
--- The heavy parts live in session.lua / prompt.lua and are required lazily.
local function session()
  return require("slop.modules.commit.session")
end

local api = {}

--- Generate a message for `buf` (default current). A non-empty message is only replaced with `force`.
---@param buf? integer
---@param opts? {amend?: boolean, force?: boolean, fresh?: boolean}
---@return boolean started
function api.generate(buf, opts)
  return session().generate(buf, opts)
end

--- New variant (higher temperature); clears a typed message first (one undo step).
---@param buf? integer
---@return boolean
function api.regenerate(buf)
  return session().regenerate(buf)
end

---@param buf? integer
---@return boolean accepted  false when no commit suggestion is visible
function api.accept(buf)
  return session().accept(buf)
end

---@param buf? integer
---@return boolean
function api.dismiss(buf)
  return session().dismiss(buf)
end

--- Next variant; past the last one a new variant is generated.
---@param buf? integer
---@return boolean
function api.next(buf)
  return session().next(buf)
end

---@param buf? integer
---@return boolean
function api.prev(buf)
  return session().prev(buf)
end

---@param buf? integer
---@return boolean
function api.is_visible(buf)
  return session().is_visible(buf)
end

---@param buf? integer
---@return {status: string, variants: string[][], index: integer, attempt: integer, error?: string, source?: string, amend?: boolean}?
function api.state(buf)
  return session().state(buf)
end

local function key(fn, desc)
  return {
    mode = { "n", "i" },
    ft = { "gitcommit" },
    fallthrough = true,
    desc = desc,
    rhs = function()
      return fn(0)
    end,
  }
end

local STYLES = { auto = true, conventional = true, plain = true }

local function is_int(v)
  return type(v) == "number" and v == math.floor(v)
end

---@type slop.ModuleSpec
return {
  name = "commit",
  description = "AI commit message as ghost text in gitcommit buffers",
  services = { "ai" },
  defaults = {
    enabled = true,
    provider = "mistral_chat",
    style = "auto", -- "auto" (follow recent commits) | "conventional" | "plain"
    auto = true, -- generate when a gitcommit buffer opens with an empty message
    stream = true,
    recent = 5, -- recent subjects (user's own + repository's) sent for style
    branch = true, -- send the branch name
    conventions = "commit.md", -- <root>/.nvim/<file> with project conventions; false to disable
    instructions = "", -- extra instructions appended to the prompt
    max_diff_chars = 24000,
    summarize = {
      "*.lock",
      "package-lock.json",
      "npm-shrinkwrap.json",
      "pnpm-lock.yaml",
      "yarn.lock",
      "go.sum",
      "*.min.js",
      "*.min.css",
      "*.map",
    },
    unstaged_fallback = true, -- nothing staged (e.g. fugitive `:Git commit -a`): describe tracked changes
    temperature = 0.3,
    max_temperature = 1.0,
    max_tokens = 512,
    timeout = 30000,
    wrap = true, -- re-wrap the body at 'textwidth'
    keymaps = {
      regenerate = "<leader>ac",
      accept = "<C-y>",
      dismiss = "<C-e>",
      next = "<C-n>",
      prev = "<C-p>",
    },
  },
  schema = function(cfg, check)
    check("provider", cfg.provider, "string")
    check("style", cfg.style, function(v)
      return STYLES[v] == true
    end, false, "'auto'|'conventional'|'plain'")
    check("auto", cfg.auto, "boolean")
    check("stream", cfg.stream, "boolean")
    check("recent", cfg.recent, function(v)
      return is_int(v) and v >= 0
    end, false, "integer >= 0")
    check("branch", cfg.branch, "boolean")
    check("conventions", cfg.conventions, function(v)
      return v == false or type(v) == "string"
    end, false, "file name|false")
    check("instructions", cfg.instructions, "string")
    check("max_diff_chars", cfg.max_diff_chars, function(v)
      return is_int(v) and v >= 1000
    end, false, "integer >= 1000")
    check("summarize", cfg.summarize, "table")
    check("unstaged_fallback", cfg.unstaged_fallback, "boolean")
    check("temperature", cfg.temperature, function(v)
      return type(v) == "number" and v >= 0 and v <= 2
    end, false, "number in [0, 2]")
    check("max_temperature", cfg.max_temperature, function(v)
      return type(v) == "number" and v >= 0 and v <= 2
    end, false, "number in [0, 2]")
    check("max_tokens", cfg.max_tokens, function(v)
      return is_int(v) and v > 0
    end, false, "integer > 0")
    check("timeout", cfg.timeout, function(v)
      return is_int(v) and v > 0
    end, false, "integer > 0 (ms)")
    check("wrap", cfg.wrap, "boolean")
  end,
  setup = function(_)
    local util = require("slop.core.util")
    vim.api.nvim_create_autocmd("FileType", {
      group = util.augroup("commit"),
      pattern = "gitcommit",
      desc = "slop: commit message ghost text",
      callback = function(ev)
        -- let fugitive / the ftplugin finish setting the buffer up first
        vim.schedule(function()
          if util.buf_valid(ev.buf) and vim.bo[ev.buf].filetype == "gitcommit" then
            session().attach(ev.buf)
          end
        end)
      end,
    })
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if util.buf_valid(buf) and vim.bo[buf].filetype == "gitcommit" then
        vim.schedule(function()
          if util.buf_valid(buf) then
            session().attach(buf)
          end
        end)
      end
    end
  end,
  teardown = function()
    session().reset()
    pcall(vim.api.nvim_del_augroup_by_name, "slop.commit")
  end,
  commands = {
    generate = {
      desc = "generate a commit message (! replaces the current message)",
      default = true,
      impl = function(_, cmd)
        session().generate(0, { force = cmd and cmd.bang or false, explicit = true })
      end,
    },
    regenerate = {
      desc = "new variant (replaces the current message)",
      impl = function()
        session().generate(0, { force = true, explicit = true })
      end,
    },
    accept = {
      desc = "accept the suggestion",
      impl = function()
        session().accept(0)
      end,
    },
    dismiss = {
      desc = "dismiss the suggestion",
      impl = function()
        session().dismiss(0)
      end,
    },
    next = {
      desc = "next variant",
      impl = function()
        session().next(0)
      end,
    },
    prev = {
      desc = "previous variant",
      impl = function()
        session().prev(0)
      end,
    },
  },
  keymaps = {
    regenerate = {
      mode = "n",
      ft = { "gitcommit" },
      desc = "regenerate commit message",
      rhs = function()
        session().generate(0, { force = true, explicit = true })
      end,
    },
    accept = key(function(b)
      return session().accept(b)
    end, "accept commit message"),
    dismiss = key(function(b)
      return session().dismiss(b)
    end, "dismiss commit message"),
    next = key(function(b)
      return session().next(b)
    end, "next commit message variant"),
    prev = key(function(b)
      return session().prev(b)
    end, "previous commit message variant"),
  },
  highlights = {
    SlopCommitStatus = { link = "Comment" },
  },
  health = function()
    local h = vim.health
    if vim.fn.executable("git") == 1 then
      h.ok("`git` found")
    else
      h.error("`git` not found in $PATH")
    end
    local c = require("slop.config").get("commit")
    local ok, ai = pcall(require, "slop.services.ai")
    local p = ok and ai.provider(c.provider) or nil
    if not p then
      h.error(("provider `%s` is not configured in ai.providers"):format(c.provider))
    elseif p.kind ~= "chat" then
      h.error(("provider `%s` has kind `%s`; commit needs a chat provider"):format(c.provider, tostring(p.kind)))
    else
      local src, var = ai.api_key_source(p)
      local set = src ~= "env" or ((os.getenv(var or "") or "") ~= "")
      if set then
        h.ok(("provider `%s` (%s)"):format(c.provider, p.model))
      else
        h.warn(("provider `%s`: $%s is NOT set"):format(c.provider, var))
      end
    end
    h.info(
      ("auto = %s, style = %s, keys: accept %s, regenerate %s"):format(
        tostring(c.auto),
        c.style,
        tostring(c.keymaps.accept),
        tostring(c.keymaps.regenerate)
      )
    )
    h.info(
      "tip: `git config --global commit.verbose true` lets slop read the exact diff from the buffer "
        .. "(covers -a, pathspecs, --amend and fugitive)"
    )
  end,
  api = api,
}

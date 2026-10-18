--- commit: prompt building, diff budgeting and reply parsing (pure, no buffer/process access).
---
--- The system rules and the tag layout of the user message are adapted from Microsoft's VS Code Copilot Chat
--- extension, src/extension/prompts/node/git/gitCommitMessagePrompt.tsx (microsoft/vscode-copilot-chat):
---
---   Copyright (c) Microsoft Corporation. All rights reserved.
---   MIT License
---
---   Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated
---   documentation files (the "Software"), to deal in the Software without restriction, including without limitation
---   the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and
---   to permit persons to whom the Software is furnished to do so, subject to the following conditions:
---
---   The above copyright notice and this permission notice shall be included in all copies or substantial portions
---   of the Software.
---
---   THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO
---   THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
---   AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF
---   CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS
---   IN THE SOFTWARE.
---
--- Changes: the ORIGINAL CODE block is not sent (too expensive), so step 2 is dropped; a changed-files summary,
--- the message of an amended commit and slop's style hints were added; typos fixed.
local M = {}

M.SYSTEM = table.concat({
  "You are an AI programming assistant, helping a software developer to come with the best git commit message for their code changes.",
  "You excel in interpreting the purpose behind code changes to craft succinct, clear commit messages that adhere to the repository's guidelines.",
  "",
  "# First, think step-by-step:",
  "1. Analyze the CODE CHANGES thoroughly to understand what's been modified.",
  "2. Identify the purpose of the changes to answer the *why* for the commit messages, also considering the optionally provided RECENT USER COMMITS.",
  "3. Review the provided RECENT REPOSITORY COMMITS to identify established commit message conventions. Focus on the format and style, ignoring commit-specific details like refs, tags, and authors.",
  "4. Generate a thoughtful and succinct commit message for the given CODE CHANGES. It MUST follow the established writing conventions.",
  "5. Remove any meta information like issue references, tags, or author names from the commit message. The developer will add them.",
  "6. Now only show your message, wrapped with a single markdown ```text codeblock! Do not provide any explanations or details",
}, "\n")

M.REMINDER = table.concat({
  "Now generate a commit message that describes the CODE CHANGES.",
  "DO NOT COPY commits from RECENT COMMITS, but use it as reference for the commit style.",
  "ONLY return a single markdown code block, NO OTHER PROSE!",
  "```text",
  "commit message goes here",
  "```",
}, "\n")

M.STYLES = {
  auto = "Follow the conventions of the RECENT REPOSITORY COMMITS. If there are none, write a concise imperative "
    .. "subject line (at most 72 characters), then a blank line and an optional short body explaining what and why.",
  conventional = "Use the Conventional Commits format for the subject: `type(scope): subject` (scope optional), with "
    .. "type one of feat, fix, docs, style, refactor, perf, test, build, ci, chore, revert; imperative mood, lower-case, "
    .. "no trailing period, at most 72 characters. Optionally add a blank line and a short body explaining what and why.",
  plain = "Do not use Conventional Commits prefixes. Write an imperative, capitalised subject line (at most 72 "
    .. "characters, no trailing period), then a blank line and an optional short body explaining what and why.",
}

local function tag(name, body)
  return ("<%s>\n%s\n</%s>"):format(name, body, name)
end

local function fence_for(text)
  local f = "```"
  while text:find(f, 1, true) do
    f = f .. "`"
  end
  return f
end

-- Diff sanitising / budgeting -------------------------------------------------------------------

--- Drop every diff section whose header slop cannot read (quoted / prefix-less paths) and any text before the
--- first section, so core.secrets.redact_diff always knows which file a line belongs to.
---@param diff string
---@return string diff, integer dropped
function M.sanitize_diff(diff)
  local out, keep, dropped, started = {}, false, 0, false
  for _, l in ipairs(vim.split(diff or "", "\n", { plain = true })) do
    if vim.startswith(l, "diff --git ") then
      started = true
      keep = l:match("^diff %-%-git a/.- b/.+$") ~= nil and not l:find('"', 1, true)
      if not keep then
        dropped = dropped + 1
        out[#out + 1] = "[slop: diff of a file with an unreadable path omitted]"
      end
    end
    if started and keep then
      out[#out + 1] = l
    end
  end
  return table.concat(out, "\n"), dropped
end

--- Defence in depth after core.secrets.redact_diff (which works line by line): re-run the secret rules over each
--- hunk's content as a whole, so multi-line rules (PEM private-key blocks) also apply inside diffs.
---@param diff string  a/ b/ headers (see sanitize_diff)
---@return string diff, integer n
function M.redact_hunks(diff)
  local secrets = require("slop.core.secrets")
  local out, n = {}, 0
  local path, signs, bodies = nil, {}, {}
  local function flush()
    if #bodies > 0 then
      local red, k = secrets.redact_lines(path, bodies, 0)
      n = n + k
      for i, b in ipairs(red) do
        out[#out + 1] = signs[i] .. b
      end
    end
    signs, bodies = {}, {}
  end
  local in_hunk = false
  for _, l in ipairs(vim.split(diff, "\n", { plain = true })) do
    local b = l:match("^diff %-%-git a/.- b/(.+)$")
    local sign, body = l:match("^([+%- ])(.*)$")
    if in_hunk and sign and not b then
      signs[#signs + 1], bodies[#bodies + 1] = sign, body
    else
      flush()
      if b then
        path, in_hunk = b, false
      elseif vim.startswith(l, "@@") then
        in_hunk = true
      elseif not sign and l ~= "" and not vim.startswith(l, "\\") then
        in_hunk = false
      end
      out[#out + 1] = l
    end
  end
  flush()
  return table.concat(out, "\n"), n
end

local function summary(f, why)
  return ("diff --git a/%s b/%s\n[slop: diff omitted (%s): +%d -%d lines]\n"):format(
    f.old_path or f.path,
    f.path,
    why,
    f.added,
    f.removed
  )
end

local function truncate(f, limit)
  local note = ("[slop: diff truncated: +%d -%d lines in this file]\n"):format(f.added, f.removed)
  limit = limit - #note
  local out, size = {}, 0
  for _, l in ipairs(vim.split(f.text, "\n", { plain = true, trimempty = true })) do
    if size + #l + 1 > limit then
      break
    end
    out[#out + 1] = l
    size = size + #l + 1
  end
  return table.concat(out, "\n") .. "\n" .. note
end

---@class slop.commit.BudgetOpts
---@field max_chars integer
---@field summarize? string[]   globs (core.secrets.match_glob) of files only summarised (lock/generated files)
---@field min_file_chars? integer  below this share a file is summarised instead of truncated (default 400)

---@class slop.commit.FileInfo
---@field path string
---@field added integer
---@field removed integer
---@field note? "summarized"|"truncated"|"omitted"

--- Fit a (redacted) diff into `max_chars`: lock/generated files are summarised; when the rest is still too big
--- the budget is shared per file (small files kept whole, big ones truncated, tiny shares summarised).
---@param diff string
---@param opts slop.commit.BudgetOpts
---@return string diff, slop.commit.FileInfo[] files, boolean cut
function M.budget_diff(diff, opts)
  local git = require("slop.core.git")
  local match = require("slop.core.secrets").match_glob
  local files = git.split_diff(diff)
  local items, infos, cut = {}, {}, false
  for i, f in ipairs(files) do
    local info = { path = f.path, added = f.added, removed = f.removed }
    local text = f.text
    for _, g in ipairs(opts.summarize or {}) do
      if match(g, f.path) then
        text, info.note, cut = summary(f, "generated or lock file"), "summarized", true
        break
      end
    end
    items[i] = { f = f, text = text, fixed = info.note ~= nil }
    infos[i] = info
  end
  local total = 0
  for _, it in ipairs(items) do
    total = total + #it.text
  end
  if total > opts.max_chars then
    cut = true
    local budget = opts.max_chars
    local flex = {}
    for i, it in ipairs(items) do
      if it.fixed then
        budget = budget - #it.text
      else
        flex[#flex + 1] = i
      end
    end
    table.sort(flex, function(a, b)
      return #items[a].text < #items[b].text
    end)
    local n = #flex
    local min = opts.min_file_chars or 400
    for _, i in ipairs(flex) do
      local it = items[i]
      local share = math.floor(math.max(budget, 0) / n)
      if #it.text > share then
        if share >= min then
          it.text, infos[i].note = truncate(it.f, share), "truncated"
        else
          it.text, infos[i].note = summary(it.f, "too large"), "omitted"
        end
      end
      budget = budget - #it.text
      n = n - 1
    end
  end
  local out = {}
  for _, it in ipairs(items) do
    out[#out + 1] = it.text
  end
  return table.concat(out), infos, cut
end

-- Prompt -----------------------------------------------------------------------------------------

---@class slop.commit.Context
---@field repo string              repository name (basename of the root)
---@field branch? string
---@field user_commits? string[]
---@field repo_commits? string[]
---@field diff string              redacted + budgeted
---@field files? slop.commit.FileInfo[]
---@field cut? boolean             the diff was summarised/truncated
---@field previous? string[]       message of the commit being amended
---@field conventions? string      <root>/.nvim/commit.md (redacted)
---@field instructions? string     config instructions
---@field style? "auto"|"conventional"|"plain"
---@field textwidth? integer

local function bullets(list)
  local out = {}
  for _, s in ipairs(list) do
    out[#out + 1] = "- " .. s
  end
  return table.concat(out, "\n")
end

--- Build the chat messages for a commit message request.
---@param ctx slop.commit.Context
---@return slop.ai.ChatMessage[]
function M.build(ctx)
  local parts = {}
  local repo = { "# REPOSITORY DETAILS:", "Repository name: " .. (ctx.repo or "") }
  if ctx.branch and ctx.branch ~= "" then
    repo[#repo + 1] = "Branch name: " .. ctx.branch
  end
  parts[#parts + 1] = tag("repository-context", table.concat(repo, "\n"))
  if ctx.user_commits and #ctx.user_commits > 0 then
    parts[#parts + 1] =
      tag("user-commits", "# RECENT USER COMMITS (For reference only, do not copy!):\n" .. bullets(ctx.user_commits))
  end
  if ctx.repo_commits and #ctx.repo_commits > 0 then
    parts[#parts + 1] = tag(
      "recent-commits",
      "# RECENT REPOSITORY COMMITS (For reference only, do not copy!):\n" .. bullets(ctx.repo_commits)
    )
  end
  if ctx.previous and #ctx.previous > 0 then
    parts[#parts + 1] = tag(
      "amended-commit",
      "# MESSAGE OF THE COMMIT BEING AMENDED (update it to describe all CODE CHANGES):\n"
        .. table.concat(ctx.previous, "\n")
    )
  end
  local changes = {}
  if ctx.cut and ctx.files and #ctx.files > 0 then
    local list = {}
    for _, f in ipairs(ctx.files) do
      list[#list + 1] = ("- %s (+%d -%d)%s"):format(
        f.path,
        f.added,
        f.removed,
        f.note and (" [" .. f.note .. "]") or ""
      )
    end
    changes[#changes + 1] =
      tag("changed-files", "# CHANGED FILES (the diff below is shortened):\n" .. table.concat(list, "\n"))
  end
  local diff = ctx.diff:gsub("\n+$", "")
  local fence = fence_for(diff)
  changes[#changes + 1] = tag("code-changes", ("# CODE CHANGES:\n%sdiff\n%s\n%s"):format(fence, diff, fence))
  parts[#parts + 1] = tag("changes", table.concat(changes, "\n"))
  parts[#parts + 1] = tag("reminder", M.REMINDER)
  local custom = {}
  local style = M.STYLES[ctx.style or "auto"] or M.STYLES.auto
  custom[#custom + 1] = style
  if ctx.textwidth and ctx.textwidth > 0 then
    custom[#custom + 1] = ("Wrap body lines at %d characters."):format(ctx.textwidth)
  end
  if ctx.conventions and vim.trim(ctx.conventions) ~= "" then
    custom[#custom + 1] = vim.trim(ctx.conventions)
  end
  if ctx.instructions and vim.trim(ctx.instructions) ~= "" then
    custom[#custom + 1] = vim.trim(ctx.instructions)
  end
  parts[#parts + 1] = tag(
    "custom-instructions",
    "When generating the commit message, please use the following custom instructions provided by the user.\n"
      .. table.concat(custom, "\n\n")
  )
  return {
    { role = "system", content = M.SYSTEM },
    { role = "user", content = table.concat(parts, "\n") },
  }
end

-- Reply parsing ----------------------------------------------------------------------------------

--- Wrap one line at `tw` (word boundaries; bullets get a hanging indent). Long words are not split.
---@param line string
---@param tw integer
---@return string[]
local function wrap_line(line, tw)
  if vim.fn.strdisplaywidth(line) <= tw or line:match("^%S+:%s") and not line:match("^[-*]") then
    return { line }
  end
  local lead = line:match("^(%s*[-*+]%s+)") or line:match("^(%s*%d+[.)]%s+)") or line:match("^(%s*)")
  local hang = string.rep(" ", vim.fn.strdisplaywidth(lead))
  local out, cur = {}, lead
  local width = vim.fn.strdisplaywidth(lead)
  local first = true
  for word in line:sub(#lead + 1):gmatch("%S+") do
    local w = vim.fn.strdisplaywidth(word)
    if first then
      cur, width, first = cur .. word, width + w, false
    elseif width + 1 + w > tw then
      out[#out + 1] = cur
      cur, width = hang .. word, #hang + w
    else
      cur, width = cur .. " " .. word, width + 1 + w
    end
  end
  out[#out + 1] = cur
  return out
end

---@class slop.commit.ParseOpts
---@field comment_char? string   lines starting with it are dropped (git would strip them), default "#"
---@field partial? boolean       streaming: tolerate an unterminated fence
---@field wrap? boolean          re-wrap body lines (not the subject) at textwidth
---@field textwidth? integer     default 72

--- Extract the commit message from a model reply: the ```text block (else the first fenced block, else the
--- raw reply), comment lines dropped, blank edges trimmed, runs of blank lines collapsed.
---@param text string
---@param opts? slop.commit.ParseOpts
---@return string[] lines
function M.parse_reply(text, opts)
  opts = opts or {}
  text = (text or ""):gsub("\r", "")
  local body = text:match("```text[ \t]*\n(.-)\n?```") or text:match("```[%w_+-]*[ \t]*\n(.-)\n?```")
  if not body then
    local open = text:match("```text[ \t]*\n(.*)$") or text:match("```[%w_+-]*[ \t]*\n(.*)$")
    if open then
      body = open
    elseif opts.partial and (text:match("^%s*`*[%w_+-]*$")) then
      body = "" -- the opening fence is still arriving
    else
      body = text
    end
    if opts.partial then
      body = body:gsub("\n?`+$", "")
    end
  end
  local cc = opts.comment_char or "#"
  local lines, blank = {}, false
  for _, l in ipairs(vim.split(body, "\n", { plain = true })) do
    l = l:gsub("%s+$", "")
    -- comment lines are dropped (git strips them), and so are stray fences
    local skip = vim.startswith(l, cc) or l:match("^```") ~= nil
    if not skip and l == "" then
      blank = #lines > 0
    elseif not skip then
      if blank then
        lines[#lines + 1] = ""
        blank = false
      end
      lines[#lines + 1] = l
    end
  end
  if opts.wrap and #lines > 2 then
    local tw = (opts.textwidth and opts.textwidth > 0) and opts.textwidth or 72
    local out = { lines[1] }
    for i = 2, #lines do
      vim.list_extend(out, wrap_line(lines[i], tw))
    end
    lines = out
  end
  return lines
end

return M

--- Jaccard-scored snippets from other open buffers ("neighbouring tabs").
--- Ported from microsoft/vscode-copilot-chat completions-core (MIT, (c) Microsoft Corporation):
--- prompt/src/snippetInclusion/{jaccardMatching,similarFiles}.ts — 60-line windows, alphanumeric token sets minus
--- stop words, best window per file, top 4, best snippet last. OWNER: complete.
---@class slop.ai.context.neighbors
local M = {}

local api = vim.api

M.window = 60
M.stride = 4
M.max_files = 20
M.max_file_chars = 10000 * 10
M.max_snippets = 4
M.threshold = 0.0

-- English stop words + generic keywords (copilot's list, abridged)
local STOP = {}
for w in
  ([[
  a an and are as at be but by for if in into is it no not of on or such that the their then there these they this
  to was will with we you your i me my our us he she him her his its them those what which who whom why how when
  where all any both each few more most other some own same so than too very can just should now
  var let const function return import export from class new this self def end local elif else while for do
  try catch finally throw raise async await yield public private protected static void int string bool true false
  null nil none undefined package use using namespace struct impl fn pub mut type interface enum switch case break
  continue default goto lambda pass with as is not and or in require module
]]):gmatch("%S+")
do
  STOP[w] = true
end

--- Token set of a text (alphanumeric runs, lower-cased, stop words removed).
---@param text string
---@return table<string, true>, integer
function M.tokens(text)
  local set, n = {}, 0
  for tok in text:gmatch("[%w_]+") do
    tok = tok:lower()
    if #tok > 1 and not STOP[tok] and not set[tok] then
      set[tok] = true
      n = n + 1
    end
  end
  return set, n
end

---@param a table<string, true>
---@param na integer
---@param b table<string, true>
---@param nb integer
---@return number
function M.jaccard(a, na, b, nb)
  if na == 0 or nb == 0 then
    return 0
  end
  local inter = 0
  local small, big = a, b
  if na > nb then
    small, big = b, a
  end
  for k in pairs(small) do
    if big[k] then
      inter = inter + 1
    end
  end
  return inter / (na + nb - inter)
end

local cache = {} ---@type table<integer, {tick: integer, windows: {srow: integer, set: table, n: integer}[]}>

local function windows_of(buf)
  local tick = api.nvim_buf_get_changedtick(buf)
  local c = cache[buf]
  if c and c.tick == tick then
    return c.windows
  end
  local lines = api.nvim_buf_get_lines(buf, 0, -1, false)
  local out = {}
  local last = math.max(1, #lines - M.window + 1)
  for s = 1, last, M.stride do
    local set, n = M.tokens(table.concat(lines, "\n", s, math.min(#lines, s + M.window - 1)))
    out[#out + 1] = { srow = s - 1, set = set, n = n }
  end
  cache[buf] = { tick = tick, windows = out }
  return out
end

--- Language family (javascriptreact -> javascript, c -> cpp, ...).
---@param ft string
---@return string
function M.family(ft)
  local map = {
    javascriptreact = "javascript",
    typescriptreact = "typescript",
    typescript = "typescript",
    javascript = "javascript",
    c = "cpp",
    cpp = "cpp",
    objc = "cpp",
    sh = "bash",
    zsh = "bash",
  }
  return map[ft] or ft
end

local EXCLUDED = { "/node_modules/", "/dist/", "/site-packages/", "/.git/", "/vendor/", "/target/" }

---@class slop.ai.Snippet
---@field buf integer
---@field path string
---@field srow integer                 0-based
---@field lines string[]               redacted
---@field score number

--- Best snippets from other loaded buffers for the text before the cursor. Best snippet LAST.
---@param buf integer
---@param ref_text string              the reference window (≈ last 60 lines before the cursor)
---@param opts? {max_snippets?: integer, threshold?: number, buffers?: integer[]}
---@return slop.ai.Snippet[]
function M.snippets(buf, ref_text, opts)
  opts = opts or {}
  local secrets = require("slop.core.secrets")
  local ft = M.family(vim.bo[buf].filetype)
  local ref, nref = M.tokens(ref_text)
  if nref == 0 then
    return {}
  end
  local cands = {}
  local bufs = vim.deepcopy(opts.buffers or api.nvim_list_bufs())
  -- most recently used first
  local used = {}
  for _, info in ipairs(vim.fn.getbufinfo()) do
    used[info.bufnr] = info.lastused or 0
  end
  table.sort(bufs, function(a, b)
    return (used[a] or 0) > (used[b] or 0)
  end)
  for _, b in ipairs(bufs) do
    if #cands >= M.max_files then
      break
    end
    local name = api.nvim_buf_get_name(b)
    if
      b ~= buf
      and api.nvim_buf_is_loaded(b)
      and vim.bo[b].buftype == ""
      and name ~= ""
      and M.family(vim.bo[b].filetype) == ft
      and not secrets.is_blocked(b)
    then
      local excluded = false
      for _, e in ipairs(EXCLUDED) do
        if name:find(e, 1, true) then
          excluded = true
        end
      end
      if not excluded and api.nvim_buf_get_offset(b, api.nvim_buf_line_count(b)) <= M.max_file_chars then
        cands[#cands + 1] = b
      end
    end
  end
  local best = {}
  for _, b in ipairs(cands) do
    local top
    for _, w in ipairs(windows_of(b)) do
      local s = M.jaccard(ref, nref, w.set, w.n)
      if not top or s > top.score then
        top = { buf = b, srow = w.srow, score = s }
      end
    end
    if top and top.score > (opts.threshold or M.threshold) then
      best[#best + 1] = top
    end
  end
  table.sort(best, function(a, b)
    return a.score > b.score
  end)
  local out = {}
  for i = 1, math.min(#best, opts.max_snippets or M.max_snippets) do
    local s = best[i]
    local lines = api.nvim_buf_get_lines(s.buf, s.srow, s.srow + M.window, false)
    s.lines = secrets.redact_lines(s.buf, lines, s.srow)
    s.path = api.nvim_buf_get_name(s.buf)
    table.insert(out, 1, s) -- best last
  end
  return out
end

--- Drop cached token sets of a buffer.
---@param buf integer
function M.forget(buf)
  cache[buf] = nil
end

return M

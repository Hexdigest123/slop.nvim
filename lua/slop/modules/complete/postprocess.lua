--- Pure post-processing of completion candidates. OWNER: complete.
---
--- Heuristics ported from microsoft/vscode-copilot-chat completions-core (MIT, (c) Microsoft Corporation):
---   * repetition filter (KMP prefix function over the reversed tail tokens, anomalyDetection.ts)
---   * "already in document" duplicate-of-next-line rejection (suggestions.ts)
---   * closing-bracket de-duplication against the following lines (maybeSnipCompletion)
---   * rest-of-line suffix overlap for mid-line completions (checkSuffix)
---   * indentation normalisation to the buffer's expandtab/shiftwidth (normalizeIndent.ts)
---   * block-end truncation while streaming (blockTrimmer / isBlockBodyFinished idea, indentation based here)
---   * middle-of-line request gate (xtab/common/inlineSuggestion.ts isValidMiddleOfTheLineFromTextAfterCursor)
---@class slop.complete.postprocess
local M = {}

---@class slop.complete.PPContext
---@field before string                    current line up to the cursor
---@field after string                     rest of the current line
---@field next_lines? string[]             following document lines (up to ~20)
---@field multiline? boolean               false = keep only the first line
---@field max_lines? integer               default 20
---@field expandtab? boolean
---@field tabstop? integer
---@field chat? boolean                    candidate came from a chat model (extra trimming)

--- Copilot: requests in the middle of a line only when the rest of the line is closers / punctuation.
---@param after string
---@return boolean
function M.valid_mid_line(after)
  local rest = vim.trim(after or "")
  return rest:match("^[%)>}%]\"'`]*%s*[:{;,]?%s*$") ~= nil
end

local function indent_width(s, ts)
  local w = 0
  for c in (s:match("^[ \t]*") or ""):gmatch(".") do
    if c == "\t" then
      w = w + ts - (w % ts)
    else
      w = w + 1
    end
  end
  return w
end
M.indent_width = indent_width

local CLOSER_LINE = {
  "^%s*[%)%]}>]+[;,%)]*%s*$",
  "^%s*end%f[%W][%s%)%],;]*$",
  "^%s*fi%s*$",
  "^%s*done%s*$",
  "^%s*esac%s*$",
  "^%s*</[%w%-_:%.]+>%s*$",
  "^%s*[%)%]}]+%s*else%s*[{:]?%s*$",
}

---@param line string
---@return boolean
function M.is_closer(line)
  for _, p in ipairs(CLOSER_LINE) do
    if line:match(p) then
      return true
    end
  end
  return false
end

--- Tokens for the repetition filter: identifier runs and single punctuation characters.
---@param text string
---@return string[]
function M.tokens(text)
  local out = {}
  local i = 1
  while i <= #text do
    local s, e = text:find("^[%w_]+", i)
    if s then
      out[#out + 1] = text:sub(s, e)
      i = e + 1
    else
      local c = text:sub(i, i)
      if not c:match("%s") then
        out[#out + 1] = c
      end
      i = i + 1
    end
  end
  return out
end

local REPETITION =
  { { max_len = 1, last = 10 }, { max_len = 10, last = 30 }, { max_len = 20, last = 45 }, { max_len = 30, last = 60 } }

local function kmp(pattern)
  local pi = { [1] = 0 }
  local k = 0
  for q = 2, #pattern do
    while k > 0 and pattern[k + 1] ~= pattern[q] do
      k = pi[k]
    end
    if pattern[k + 1] == pattern[q] then
      k = k + 1
    end
    pi[q] = k
  end
  return pi
end

--- Copilot's isRepetitive: the tail of the completion is a short pattern repeated many times.
---@param text string
---@return boolean
function M.is_repetitive(text)
  local toks = M.tokens(text)
  local rev = {}
  for i = #toks, 1, -1 do
    rev[#rev + 1] = toks[i]
  end
  for _, cfg in ipairs(REPETITION) do
    if #rev >= cfg.last then
      local pat = vim.list_slice(rev, 1, cfg.last)
      local pi = kmp(pat)
      local period = cfg.last - pi[cfg.last]
      if period <= cfg.max_len then
        return true
      end
    end
  end
  return false
end

--- Cut a multi-line completion where the block that contains the cursor ends. The base indentation is the cursor
--- line's; when the completion opens a deeper block (its first body line is indented more), a line back at the base
--- level ends it; otherwise a line indented less than the base does. A closer at that point is kept.
--- Returns the cut text and whether a cut happened.
---@param text string
---@param pctx slop.complete.PPContext
---@return string text, boolean cut
function M.trim_block(text, pctx)
  local lines = vim.split(text, "\n", { plain = true })
  if #lines < 2 then
    return text, false
  end
  local ts = pctx.tabstop or 8
  local base = indent_width(pctx.before or "", ts)
  local body
  for i = 2, #lines do
    if lines[i]:match("%S") then
      body = indent_width(lines[i], ts)
      break
    end
  end
  local deeper = body ~= nil and body > base
  for i = 2, #lines do
    local l = lines[i]
    if l:match("%S") then
      local w = indent_width(l, ts)
      if w < base or (deeper and w <= base) then
        if M.is_closer(l) then
          return table.concat(vim.list_slice(lines, 1, i), "\n"), true
        end
        return table.concat(vim.list_slice(lines, 1, i - 1), "\n"), true
      end
    end
  end
  return text, false
end

--- Remove trailing completion lines that only close brackets and duplicate the next document lines.
---@param text string
---@param next_lines string[]
---@return string
function M.snip_closers(text, next_lines)
  local lines = vim.split(text, "\n", { plain = true })
  local doc = {}
  for _, l in ipairs(next_lines or {}) do
    if l:match("%S") then
      doc[#doc + 1] = vim.trim(l)
    end
    if #doc >= 8 then
      break
    end
  end
  if #doc == 0 then
    return text
  end
  -- trailing closer-only block of the completion
  local first_closer = #lines + 1
  for i = #lines, 2, -1 do
    if M.is_closer(lines[i]) or not lines[i]:match("%S") then
      first_closer = i
    else
      break
    end
  end
  if first_closer > #lines then
    return text
  end
  local closers = {}
  for i = first_closer, #lines do
    if lines[i]:match("%S") then
      closers[#closers + 1] = vim.trim(lines[i])
    end
  end
  -- does the document continue with the same closers?
  local matched = 0
  for i, c in ipairs(closers) do
    local d = doc[i]
    if d and (d == c or vim.startswith(d, c) or vim.startswith(c, d)) then
      matched = i
    else
      break
    end
  end
  if matched == #closers and matched > 0 then
    local kept = vim.list_slice(lines, 1, first_closer - 1)
    return (table.concat(kept, "\n"):gsub("%s+$", ""))
  end
  return text
end

--- Mid-line: if the completion ends with the existing rest of the line, drop that ending (no duplicates on accept).
---@param text string
---@param after string
---@return string
function M.trim_rest_of_line(text, after)
  local rest = vim.trim(after or "")
  if rest == "" then
    return text
  end
  local function strip(s)
    s = s:sub(1, #s - #rest)
    if after:match("^%s") then
      s = s:gsub("[ \t]+$", "")
    end
    return s
  end
  local stripped = text:gsub("%s+$", "")
  if #stripped > #rest and stripped:sub(-#rest) == rest then
    return strip(stripped)
  end
  -- the rest of the line at the end of the FIRST line of a multi-line completion
  local first, more = text:match("^([^\n]*)(\n.*)$")
  if first and #first > #rest and first:sub(-#rest) == rest then
    return strip(first) .. more
  end
  return text
end

--- Normalise indentation of lines 2.. to the buffer style.
---@param text string
---@param pctx slop.complete.PPContext
---@return string
function M.normalize_indent(text, pctx)
  local ts = pctx.tabstop or 8
  local lines = vim.split(text, "\n", { plain = true })
  for i = 2, #lines do
    local ws, rest = lines[i]:match("^([ \t]*)(.*)$")
    if ws ~= "" then
      local w = indent_width(ws, ts)
      if pctx.expandtab then
        ws = string.rep(" ", w)
      elseif pctx.expandtab == false then
        ws = string.rep("\t", math.floor(w / ts)) .. string.rep(" ", w % ts)
      end
      lines[i] = ws .. rest
    end
  end
  return table.concat(lines, "\n")
end

local function first_doc_line(next_lines)
  for _, l in ipairs(next_lines or {}) do
    if l:match("%S") then
      return vim.trim(l)
    end
  end
  return nil
end

--- Processing applied while streaming: returns the text to display and whether generation can stop now.
---@param text string
---@param pctx slop.complete.PPContext
---@return string display, boolean done
function M.partial(text, pctx)
  text = text:gsub("\r\n", "\n")
  if pctx.multiline == false then
    local nl = text:find("\n", 1, true)
    if nl then
      return text:sub(1, nl - 1), true
    end
    return text, false
  end
  local max = pctx.max_lines or 20
  local lines = vim.split(text, "\n", { plain = true })
  if #lines > max + 1 then
    return table.concat(vim.list_slice(lines, 1, max), "\n"), true
  end
  -- only judge complete lines (the last one may still grow)
  local complete = table.concat(vim.list_slice(lines, 1, #lines - 1), "\n")
  if #lines > 2 then
    local cut, was_cut = M.trim_block(complete, pctx)
    if was_cut then
      return cut, true
    end
  end
  return text, false
end

--- Full processing of a final candidate. Returns "" when the candidate should be dropped.
---@param text string
---@param pctx slop.complete.PPContext
---@return string
function M.process(text, pctx)
  text = (text or ""):gsub("\r\n", "\n")
  if pctx.chat then
    -- chat models tend to repeat the typed indentation / the start of the line
    local before = pctx.before or ""
    if before:match("^%s+$") and vim.startswith(text, before) then
      text = text:sub(#before + 1)
    else
      local tail = before:match("(%S+)$")
      if tail and #tail >= 2 and vim.startswith(text, tail) then
        text = text:sub(#tail + 1)
      end
    end
  end
  if pctx.multiline == false then
    local nl = text:find("\n", 1, true)
    if nl then
      text = text:sub(1, nl - 1)
    end
  else
    local lines = vim.split(text, "\n", { plain = true })
    local max = pctx.max_lines or 20
    if #lines > max then
      text = table.concat(vim.list_slice(lines, 1, max), "\n")
    end
    text = (M.trim_block(text, pctx))
    text = M.snip_closers(text, pctx.next_lines or {})
  end
  text = M.trim_rest_of_line(text, pctx.after or "")
  if (pctx.after or ""):match("%S") then
    text = text:gsub("\n%s*$", "") -- text follows on this line: keep trailing spaces
  else
    text = text:gsub("%s+$", "")
  end
  if not text:match("%S") then
    return ""
  end
  -- already in the document
  local nxt = first_doc_line(pctx.next_lines)
  if nxt and vim.trim(text) == nxt then
    return ""
  end
  if M.is_repetitive(text) then
    return ""
  end
  return M.normalize_indent(text, pctx)
end

--- Process + dedupe a list of candidates (order kept).
---@param items string[]
---@param pctx slop.complete.PPContext
---@return string[]
function M.process_all(items, pctx)
  local out, seen = {}, {}
  for _, it in ipairs(items or {}) do
    local t = M.process(it, pctx)
    if t ~= "" and not seen[t] then
      seen[t] = true
      out[#out + 1] = t
    end
  end
  return out
end

return M

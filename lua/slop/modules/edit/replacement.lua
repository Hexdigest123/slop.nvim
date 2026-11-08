--- Replacement-text protocol: extraction (with fallbacks) and validation of the agent's answer. Pure.
---
--- Order: the last complete <slop:replacement> block -> diffs of rejected edits for this file -> the last fenced
--- code block -> error. Validation strips CR, rejects nested tags and "<redacted>" placeholders the original did
--- not contain, normalises the trailing newline of linewise regions and restores a dropped base indentation.
---@class slop.edit.replacement
local M = {}

M.OPEN = "<slop:replacement>"
M.CLOSE = "</slop:replacement>"

local function strip_edges(s)
  s = s:gsub("^[ \t]*\r?\n", "", 1)
  s = s:gsub("\r?\n[ \t]*$", "", 1)
  return s
end

--- Unwrap content that is entirely one fenced code block.
---@param s string
---@return string
function M.unfence(s)
  local inner = s:match("^%s*```[^\n]*\n(.-)\n?```%s*$")
  if inner and not inner:find("\n```", 1, true) then
    return inner
  end
  return s
end

--- Content of the last complete replacement block.
---@param text string
---@param keep_fence? boolean              keep a code fence that wraps the whole block (the region is one)
---@return string? content, string? err  err = "unterminated" when an opening tag has no closing tag
function M.from_tag(text, keep_fence)
  local last
  local pos = 1
  while true do
    local s, e = text:find(M.OPEN, pos, true)
    if not s then
      break
    end
    local cs, ce = text:find(M.CLOSE, e + 1, true)
    -- the tag mentioned in prose before the real block: use the innermost open tag
    local s2, e2 = text:find(M.OPEN, e + 1, true)
    while cs and s2 and s2 < cs do
      e = e2
      s2, e2 = text:find(M.OPEN, e + 1, true)
    end
    if not cs then
      if not last then
        return nil, "unterminated"
      end
      break
    end
    last = text:sub(e + 1, cs - 1)
    pos = ce + 1
  end
  if not last then
    return nil
  end
  last = strip_edges(last)
  return keep_fence and last or M.unfence(last)
end

--- Content of the last fenced code block.
---@param text string
---@return string?
function M.from_fence(text)
  local last
  for body in ("\n" .. text):gmatch("\n[ \t]*```[^\n]*\n(.-)\n[ \t]*```") do
    last = body
  end
  return last
end

---@class slop.edit.ReplaceCtx
---@field path? string                     absolute path of the buffer
---@field old_text string                  original region text
---@field file_before? string              file text before the region
---@field file_after? string               file text after the region

--- The region's part of a whole-file text, when the text keeps everything before and after the region.
---@param text string
---@param before string
---@param after string
---@return string?
local function cut_file(text, before, after)
  if #text >= #before + #after and text:sub(1, #before) == before and (after == "" or text:sub(-#after) == after) then
    return text:sub(#before + 1, #text - #after)
  end
end

--- Apply ACP diffs ({path, oldText, newText}) of rejected edits for our file to the region.
---@param diffs table[]
---@param ctx slop.edit.ReplaceCtx
---@return string?
function M.from_diffs(diffs, ctx)
  local region = ctx.old_text
  local applied = false
  for _, d in ipairs(diffs or {}) do
    if
      type(d) == "table"
      and type(d.newText) == "string"
      and (not ctx.path or not d.path or vim.fs.normalize(d.path) == ctx.path)
    then
      local old = type(d.oldText) == "string" and d.oldText or nil
      local before, after = ctx.file_before, ctx.file_after
      if old and old ~= "" and select(2, region:gsub(vim.pesc(old), "")) == 1 then
        local s, e = region:find(old, 1, true)
        region = region:sub(1, s - 1) .. d.newText .. region:sub(e + 1)
        applied = true
      elseif before and after then
        -- whole-file contents usually end with the file's final newline, which buffer text never has
        local cut = d.newText:sub(-1) == "\n" and cut_file(d.newText:sub(1, -2), before, after)
          or cut_file(d.newText, before, after)
        if cut then
          region = cut
          applied = true
        end
      end
    end
  end
  return applied and region or nil
end

--- Extract the replacement from the agent's answer.
---@param message string                   concatenated agent message text
---@param ctx slop.edit.ReplaceCtx
---@param diffs? table[]                   diffs of rejected edit permissions / tool calls
---@return string? text, string source_or_err  source = "tag"|"diff"|"fence"
function M.extract(message, ctx, diffs)
  -- a region that is itself one fenced block (Markdown) keeps its fences
  local tag, terr = M.from_tag(message or "", (ctx and ctx.old_text or ""):match("^%s*```") ~= nil)
  if tag then
    return tag, "tag"
  end
  local d = M.from_diffs(diffs or {}, ctx)
  if d then
    return d, "diff"
  end
  local fence = M.from_fence(message or "")
  if fence then
    return fence, "fence"
  end
  if terr == "unterminated" then
    return nil, "the answer ended inside a <slop:replacement> block (truncated?)"
  end
  return nil, "the agent did not return a <slop:replacement> block"
end

local function min_indent(lines)
  local best
  for _, l in ipairs(lines) do
    if l:find("%S") then
      local ind = l:match("^[ \t]*")
      if not best or #ind < #best then
        best = ind
      end
    end
  end
  return best
end

--- Re-indent `new` to the base indentation of `old` when the agent dropped it entirely.
---@param old string[]
---@param new string[]
---@return string[]
function M.reindent(old, new)
  local base_old, base_new = min_indent(old), min_indent(new)
  if not base_old or base_old == "" or not base_new or base_new ~= "" then
    return new
  end
  local out = {}
  for i, l in ipairs(new) do
    out[i] = l:find("%S") and (base_old .. l) or l
  end
  return out
end

---@class slop.edit.ValidateCtx
---@field old_text string
---@field linewise boolean
---@field placeholder? string               default "<redacted>"

--- Validate and normalise a replacement.
---@param text string
---@param ctx slop.edit.ValidateCtx
---@return string[]? lines, string? err
function M.validate(text, ctx)
  if type(text) ~= "string" then
    return nil, "no replacement"
  end
  text = text:gsub("\r\n", "\n"):gsub("\r", "\n")
  if text:find(M.OPEN, 1, true) or text:find(M.CLOSE, 1, true) then
    return nil, "the replacement contains nested <slop:replacement> tags"
  end
  local ph = ctx.placeholder or "<redacted>"
  if text:find(ph, 1, true) and not ctx.old_text:find(ph, 1, true) then
    return nil, ("the replacement contains the secret placeholder %s"):format(ph)
  end
  -- a region whose last line is empty ends with "\n" itself: its replacement's final newline is that line
  if ctx.linewise and text:sub(-1) == "\n" and ctx.old_text:sub(-1) ~= "\n" then
    text = text:sub(1, -2)
  end
  local lines = vim.split(text, "\n", { plain = true })
  if ctx.linewise then
    if text == "" then
      lines = {}
    else
      lines = M.reindent(vim.split(ctx.old_text, "\n", { plain = true }), lines)
    end
  end
  return lines
end

return M

--- Fill-in-the-middle through a CHAT model: builds messages that ask for the text at the cursor and parses up to
--- `n` alternatives separated by "<END>". OWNER: complete. (Original prompt text; not derived from GPL sources.)
---
--- Customise per provider: ai.providers.<name>.chat_fim = { system?, input?, few_shots?, vars? } where strings may use
--- {{lang}} {{indent}} {{n}} {{prefix}} {{suffix}} and any key of `vars` (string or fun(info): string),
--- `few_shots` is a list of {role, content} messages (or a function(info) returning one).
---@class slop.ai.chat_fim
local M = {}

M.separator = "<END>"

M.system = table.concat({
  "You are the code-completion engine of a text editor.",
  "You receive the text before the cursor and the text after the cursor of one file.",
  "Reply with exactly the text to insert at the cursor and nothing else.",
  "",
  "Rules:",
  "1. Start precisely at the cursor. Never repeat text that already exists before or after it.",
  "2. Follow the file's language, indentation, naming and style. Inside comments or strings, write prose.",
  "3. No explanations, no markdown, no code fences.",
  "4. Prefer short completions: finish the current statement or add a few lines.",
  "5. Give up to {{n}} different alternatives, separated by a line containing only " .. M.separator .. ".",
}, "\n")

M.input = table.concat({
  "{{lang}}",
  "{{indent}}",
  "<before_cursor>",
  "{{prefix}}</before_cursor>",
  "<after_cursor>{{suffix}}",
  "</after_cursor>",
  "Write the text that belongs between before_cursor and after_cursor.",
}, "\n")

M.few_shots = {
  {
    role = "user",
    content = table.concat({
      "Language: python",
      "Indentation: 4 spaces",
      "<before_cursor>",
      "def area(radius):",
      "    return math.pi * </before_cursor>",
      "<after_cursor>",
      "",
      "print(area(2))",
      "</after_cursor>",
      "Write the text that belongs between before_cursor and after_cursor.",
    }, "\n"),
  },
  { role = "assistant", content = "radius ** 2\n" .. M.separator .. "\nradius * radius" },
}

local function expand(tpl, info, vars)
  return (
    tpl:gsub("{{([%w_]+)}}", function(k)
      local v = vars and vars[k]
      if v == nil then
        v = info[k]
      end
      if type(v) == "function" then
        local ok, r = pcall(v, info)
        v = ok and r or ""
      end
      if v == nil then
        return ""
      end
      return tostring(v)
    end)
  )
end

--- Chat messages for a FIM request.
---@param p slop.ai.ProviderConfig
---@param req slop.ai.FimRequest
---@return slop.ai.ChatMessage[]
function M.messages(p, req)
  local o = type(p.chat_fim) == "table" and p.chat_fim or {}
  local info = {
    lang = req.filetype and ("Language: " .. req.filetype) or "",
    indent = req.indent or "",
    n = math.max(1, req.n or 1),
    prefix = req.prompt or "",
    suffix = req.suffix or "",
  }
  local msgs = { { role = "system", content = expand(o.system or M.system, info, o.vars) } }
  local shots = o.few_shots
  if type(shots) == "function" then
    shots = shots(info)
  end
  for _, m in ipairs(shots or M.few_shots) do
    msgs[#msgs + 1] = { role = m.role, content = m.content }
  end
  local input = o.input or M.input
  if type(input) == "function" then
    input = input(info)
  end
  msgs[#msgs + 1] = { role = "user", content = expand(input, info, o.vars) }
  return msgs
end

--- Strip a surrounding ``` fence (first fenced block wins).
---@param s string
---@return string
function M.strip_fence(s)
  local body = s:match("^%s*```[%w_+%-]*\n(.-)\n?```%s*$")
  return body or s
end

--- Split a chat reply into candidates.
---@param text string
---@return string[]
function M.parse(text)
  local out = {}
  text = (text or ""):gsub("\r\n", "\n")
  for part in (text .. "\n" .. M.separator):gmatch("(.-)\n?%s*" .. vim.pesc(M.separator)) do
    part = M.strip_fence(part):gsub("^\n", ""):gsub("%s+$", "")
    if part:match("%S") then
      out[#out + 1] = part
    end
  end
  return out
end

--- Text of the FIRST candidate within a partial streamed reply (for live ghost text).
---@param text string
---@return string
function M.first_partial(text)
  local at = text:find(M.separator, 1, true)
  local first = at and text:sub(1, at - 1) or text
  -- hide a partially streamed separator ("<EN") and the line break before a separator
  local cut
  first, cut = first:gsub("<[%u]*$", "")
  if at or cut > 0 then
    first = first:gsub("\n%s*$", "")
  end
  first = first:gsub("^%s*```[%w_+%-]*\n", "")
  return (first:gsub("^\n", ""))
end

return M

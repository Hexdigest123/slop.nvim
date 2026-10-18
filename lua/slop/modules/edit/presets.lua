--- Built-in edit presets (data). User presets in `edit.presets` are merged by name; `false` removes one.
---
---   { desc, prompt, sink? = "diff"|"float"|"scratch", diagnostics? = boolean, input? = boolean, agent? = string }
---   sink "diff" (default): the answer replaces the region (reviewed as an inline diff)
---   sink "float": the answer (markdown) is shown in a float; nothing is changed
---   sink "scratch": the answer's code goes to a scratch buffer with the buffer's filetype
---   input: ask for extra instructions in the prompt float before sending
---@class slop.edit.presets
local M = {}

---@class slop.edit.Preset
---@field name? string
---@field desc string
---@field prompt string
---@field sink? "diff"|"float"|"scratch"
---@field diagnostics? boolean
---@field input? boolean
---@field agent? string

---@type table<string, slop.edit.Preset>
M.builtin = {
  explain = {
    desc = "Explain the code",
    sink = "float",
    prompt = "Explain what this code does, how it works and anything surprising about it. Be concise; "
      .. "use Markdown with short sections. Do not rewrite the code.",
  },
  fix = {
    desc = "Fix the diagnostics in the region",
    diagnostics = true,
    prompt = "Fix the problems reported by the diagnostics listed above (and any obvious bug next to them). "
      .. "Change as little as possible.",
  },
  docs = {
    desc = "Add documentation comments",
    prompt = "Add or improve documentation comments for this code, in the idiomatic doc-comment style of the "
      .. "language (e.g. LuaLS annotations, JSDoc, docstrings). Do not change behaviour.",
  },
  tests = {
    desc = "Write tests (opens a scratch buffer)",
    sink = "scratch",
    prompt = "Write thorough unit tests for this code using the test framework the project already uses "
      .. "(look at existing tests if needed). Put the complete test code in the replacement block.",
  },
  refactor = {
    desc = "Refactor for readability",
    prompt = "Refactor this code for readability and maintainability without changing its behaviour.",
  },
  optimize = {
    desc = "Optimize for performance",
    prompt = "Optimize this code for performance without changing its behaviour; keep it readable.",
  },
}

--- Effective presets: built-ins merged with the user's.
---@param user? table<string, slop.edit.Preset|false>
---@return table<string, slop.edit.Preset>
function M.all(user)
  local out = {}
  for name, p in pairs(M.builtin) do
    out[name] = vim.tbl_extend("force", { name = name }, p)
  end
  for name, p in pairs(user or {}) do
    if p == false then
      out[name] = nil
    elseif type(p) == "table" then
      out[name] = vim.tbl_extend("force", out[name] or { name = name, desc = name }, p, { name = name })
    end
  end
  return out
end

--- Sorted preset names.
---@param user? table
---@return string[]
function M.names(user)
  local names = vim.tbl_keys(M.all(user))
  table.sort(names)
  return names
end

--- Split "#preset rest of the instruction" -> preset name, instruction (preset only when known).
---@param text string
---@param presets table<string, slop.edit.Preset>
---@return string? preset, string instruction
function M.parse(text, presets)
  local name, rest = text:match("^%s*#([%w_%-]+)%s*(.*)$")
  if name and presets[name] then
    return name, rest
  end
  return nil, text
end

return M

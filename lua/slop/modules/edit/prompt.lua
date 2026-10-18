--- Prompt assembly for edit requests (replacement-text protocol). Pure apart from content-block helpers.
--- Every text passed in must already be redacted.
---@class slop.edit.prompt
local M = {}

---@class slop.edit.PromptParts
---@field sink "diff"|"float"|"scratch"
---@field path string                      absolute path ("" for unnamed buffers)
---@field rel string                       path relative to the project root
---@field filetype string
---@field srow integer                     0-based
---@field erow integer                     0-based, inclusive
---@field scol? integer                    charwise regions only (0-based byte cols)
---@field ecol? integer
---@field region string[]
---@field before string[]
---@field after string[]
---@field instruction string
---@field rules? {rel: string, text: string}[]
---@field files? {path: string, rel: string, text: string, filetype?: string}[]
---@field diagnostics? string[]
---@field embedded? boolean                agent accepts embedded `resource` blocks

local PROTOCOL = {
  diff = {
    "You are editing code in the user's editor (Neovim, via slop.nvim). You get a REGION of a file and an instruction.",
    "",
    "How to answer:",
    "- You may read files and search the project for context. Do NOT edit, create, delete or move files and do NOT",
    "  run commands: the editor rejects such requests and applies your answer itself.",
    "- Reply with the complete new text of the region inside exactly one block:",
    "<slop:replacement>",
    "(new text of the region)",
    "</slop:replacement>",
    "- Put only the code inside the block: no code fences, no line numbers, no comments addressed to the user.",
    "  Keep the indentation style of the surrounding code. An empty block deletes the region.",
    "- Outside the block, at most one short sentence.",
  },
  scratch = {
    "You are helping the user in their editor (Neovim, via slop.nvim). You get a REGION of a file and an instruction.",
    "",
    "How to answer:",
    "- You may read files and search the project for context. Do NOT edit, create, delete or move files and do NOT",
    "  run commands: the editor rejects such requests.",
    "- Reply with the complete resulting code inside exactly one block (no code fences inside):",
    "<slop:replacement>",
    "(the code)",
    "</slop:replacement>",
    "- The code is opened in a new buffer; the region itself is not changed.",
  },
  float = {
    "You are helping the user in their editor (Neovim, via slop.nvim). You get a REGION of a file and a question.",
    "",
    "How to answer:",
    "- You may read files and search the project for context. Do NOT edit, create, delete or move files and do NOT",
    "  run commands: the editor rejects such requests.",
    "- Answer in concise Markdown. Do not return a <slop:replacement> block.",
  },
}

local function push(out, lines)
  for _, l in ipairs(lines) do
    out[#out + 1] = l
  end
end

--- Instruction text for a preset plus the user's extra text.
---@param preset? slop.edit.Preset
---@param extra? string
---@return string
function M.instruction(preset, extra)
  extra = extra and vim.trim(extra) or ""
  if not preset then
    return extra
  end
  if extra == "" then
    return preset.prompt
  end
  return preset.prompt .. "\n\nAdditional instructions from the user: " .. extra
end

--- Build the content blocks of the first prompt.
---@param p slop.edit.PromptParts
---@return table[] blocks, string text  (text = the main text block, for logs/tests)
function M.build(p)
  local acp = require("slop.services.ai.acp")
  local out = {}
  push(out, PROTOCOL[p.sink] or PROTOCOL.diff)
  out[#out + 1] = ""
  local where = p.rel ~= "" and p.rel or "[unnamed buffer]"
  out[#out + 1] = ("File: %s (filetype: %s%s)"):format(
    where,
    p.filetype ~= "" and p.filetype or "none",
    p.path ~= "" and (", absolute path: " .. p.path) or ""
  )
  local region = ("Region: lines %d-%d (1-based, inclusive)"):format(p.srow + 1, p.erow + 1)
  if p.scol then
    region = region
      .. (". The region is part of those lines: it starts at byte column %d of line %d and ends before byte column %d of line %d; return only the replacement for the region text itself."):format(
        p.scol + 1,
        p.srow + 1,
        p.ecol + 1,
        p.erow + 1
      )
  end
  out[#out + 1] = region
  for _, r in ipairs(p.rules or {}) do
    out[#out + 1] = ""
    out[#out + 1] = ('<project_rules path="%s">'):format(r.rel)
    push(out, vim.split(r.text, "\n", { plain = true }))
    out[#out + 1] = "</project_rules>"
  end
  if p.diagnostics and #p.diagnostics > 0 then
    out[#out + 1] = ""
    out[#out + 1] = "Diagnostics in the region:"
    push(out, p.diagnostics)
  end
  if #p.before > 0 then
    out[#out + 1] = ""
    out[#out + 1] = "Code before the region (context, do not repeat it):"
    out[#out + 1] = "<before>"
    push(out, p.before)
    out[#out + 1] = "</before>"
  end
  out[#out + 1] = ""
  out[#out + 1] = "<region>"
  push(out, p.region)
  out[#out + 1] = "</region>"
  if #p.after > 0 then
    out[#out + 1] = ""
    out[#out + 1] = "Code after the region (context, do not repeat it):"
    out[#out + 1] = "<after>"
    push(out, p.after)
    out[#out + 1] = "</after>"
  end
  local files = p.files or {}
  if #files > 0 and not p.embedded then
    for _, f in ipairs(files) do
      out[#out + 1] = ""
      out[#out + 1] = ('<file path="%s">'):format(f.rel)
      push(out, vim.split(f.text, "\n", { plain = true }))
      out[#out + 1] = "</file>"
    end
  elseif #files > 0 then
    out[#out + 1] = ""
    out[#out + 1] = "Files referenced by the user are attached."
  end
  out[#out + 1] = ""
  out[#out + 1] = "Instruction: " .. p.instruction
  local text = table.concat(out, "\n")
  local blocks = { acp.text(text) }
  if p.embedded then
    for _, f in ipairs(files) do
      blocks[#blocks + 1] = acp.resource(vim.uri_from_fname(f.path), f.text, "text/plain")
    end
  end
  return blocks, text
end

--- Follow-up prompt in the same session (refine).
---@param instruction string
---@param sink? string
---@return table[] blocks, string text
function M.refine(instruction, sink)
  local acp = require("slop.services.ai.acp")
  local text
  if sink == "float" then
    text = "Follow-up question about the same region: " .. instruction
  else
    text = table.concat({
      "The user reviewed your replacement and wants changes: " .. instruction,
      "",
      "Reply again with the complete new text for the ORIGINAL region (as given in the first message) inside",
      "exactly one <slop:replacement>...</slop:replacement> block, following the same rules.",
    }, "\n")
  end
  return { acp.text(text) }, text
end

return M

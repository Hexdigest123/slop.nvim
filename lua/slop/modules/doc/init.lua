--- doc: AI-written doc comments (replaces neogen). The function / class / type at the cursor (treesitter) is sent,
--- redacted (core.secrets), to services.ai.chat with a per-filetype style; the answer is checked to be a comment
--- (python: a docstring), re-indented and reviewed as an inline diff (core.ui.diff: ga/gr/gA/gR). An existing doc
--- comment is updated in place. See doc/slop-doc.txt.
--- Heavy code lives in request/target/prompt/langs.lua and is required lazily.
local function request()
  return require("slop.modules.doc.request")
end

local api = {}

--- Document the item at the cursor: kind "func" | "class" | "type", nil = the innermost documentable item.
---@param kind? "func"|"class"|"type"
---@param opts? slop.doc.GenerateOpts
---@return boolean started
function api.generate(kind, opts)
  return request().generate(kind, opts)
end

--- Cancel the running request of `buf` (default current).
---@param buf? integer
---@return boolean cancelled
function api.cancel(buf)
  return request().cancel(buf)
end

---@param buf? integer
---@return boolean
function api.is_running(buf)
  return request().is_running(buf)
end

--- The item `generate()` would document (no request is sent).
---@param buf? integer
---@param pos? {[1]: integer, [2]: integer}  0-based {row, col}; default cursor
---@param kind? "func"|"class"|"type"
---@return slop.doc.Target? target, string? err
function api.find(buf, pos, kind)
  return require("slop.modules.doc.target").find(buf, pos, kind)
end

local KINDS = { "func", "class", "type" }

local function is_int(v)
  return type(v) == "number" and v == math.floor(v)
end

local function cmd(kind, desc, default)
  return {
    desc = desc,
    default = default,
    impl = function()
      api.generate(kind)
    end,
  }
end

local function key(kind, desc)
  return {
    mode = "n",
    desc = desc,
    rhs = function()
      api.generate(kind)
    end,
  }
end

---@type slop.ModuleSpec
return {
  name = "doc",
  description = "AI-written doc comments for the function/class/type at the cursor",
  services = { "ai" },
  defaults = {
    enabled = true,
    provider = "mistral_chat", -- a `chat` provider from ai.providers
    max_tokens = 1024,
    timeout = 30000,
    temperature = 0.2,
    styles = {}, -- [filetype] = style name ("luals", "jsdoc", ...) or free-text instructions
    instructions = "", -- extra instructions appended to the prompt
    context_lines = 30, -- surrounding lines sent for context (0 = only the item)
    max_chars = 16000, -- budget for the item's code
    keymaps = {
      generate = "<leader>nd",
      func = "<leader>nf",
      class = "<leader>nc",
      type = "<leader>nt",
    },
  },
  schema = function(cfg, check)
    check("provider", cfg.provider, "string")
    check("max_tokens", cfg.max_tokens, function(v)
      return is_int(v) and v > 0
    end, false, "integer > 0")
    check("timeout", cfg.timeout, function(v)
      return is_int(v) and v > 0
    end, false, "integer > 0 (ms)")
    check("temperature", cfg.temperature, function(v)
      return type(v) == "number" and v >= 0 and v <= 2
    end, false, "number in [0, 2]")
    check("styles", cfg.styles, function(v)
      if type(v) ~= "table" then
        return false
      end
      for ft, s in pairs(v) do
        if type(ft) ~= "string" or type(s) ~= "string" then
          return false
        end
      end
      return true
    end, false, "table<filetype, style name|text>")
    check("instructions", cfg.instructions, "string")
    check("context_lines", cfg.context_lines, function(v)
      return is_int(v) and v >= 0
    end, false, "integer >= 0")
    check("max_chars", cfg.max_chars, function(v)
      return is_int(v) and v >= 500
    end, false, "integer >= 500")
  end,
  setup = function(_) end,
  teardown = function()
    request().reset()
  end,
  commands = {
    generate = cmd(nil, "document the innermost function/class/type at the cursor", true),
    func = cmd("func", "document the function at the cursor"),
    class = cmd("class", "document the class at the cursor"),
    type = cmd("type", "document the type at the cursor"),
    cancel = {
      desc = "cancel the running request",
      impl = function()
        if not api.cancel() then
          require("slop.core.log").scope("doc").notify("no doc request running", vim.log.levels.INFO)
        end
      end,
    },
  },
  keymaps = {
    generate = key(nil, "doc comment (auto-detect)"),
    func = key("func", "doc comment for the function"),
    class = key("class", "doc comment for the class"),
    type = key("type", "doc comment for the type"),
  },
  health = function()
    local h = vim.health
    local c = require("slop.config").get("doc")
    local ok, ai = pcall(require, "slop.services.ai")
    local p = ok and ai.provider(c.provider) or nil
    if not p then
      h.error(("provider `%s` is not configured in ai.providers"):format(c.provider))
    elseif p.kind ~= "chat" then
      h.error(("provider `%s` has kind `%s`; doc needs a chat provider"):format(c.provider, tostring(p.kind)))
    else
      local src, var = ai.api_key_source(p)
      if src ~= "env" or (os.getenv(var or "") or "") ~= "" then
        h.ok(("provider `%s` (%s)%s"):format(c.provider, p.model, src == "env" and (", $" .. var .. " is set") or ""))
      else
        h.warn(("provider `%s`: $%s is NOT set"):format(c.provider, var))
      end
    end
    local keys = {}
    for _, k in ipairs(vim.list_extend({ "generate" }, vim.deepcopy(KINDS))) do
      keys[#keys + 1] = ("%s %s"):format(k, tostring(c.keymaps[k]))
    end
    h.info("keys: " .. table.concat(keys, ", "))
    local styled = vim.tbl_keys(c.styles)
    table.sort(styled)
    if #styled > 0 then
      h.info("style overrides: " .. table.concat(styled, ", "))
    end
    local buf = vim.api.nvim_get_current_buf()
    local ft = vim.bo[buf].filetype
    if ft ~= "" then
      local tok, tlang = pcall(require("slop.core.ts").lang, buf)
      if tok and tlang then
        h.ok(("current buffer (%s): treesitter parser `%s`"):format(ft, tlang))
      else
        h.info(("current buffer (%s): no treesitter parser, doc cannot find items here"):format(ft))
      end
    end
  end,
  api = api,
}

--- nvim-cmp source "slop" (frontend = "cmp" | "both"). OWNER: complete.
---
--- * frontend "both": the source serves the suggestion the ghost-text engine already has (no second request).
--- * frontend "cmp": the source drives requests itself (cmp already debounces; no ghost text).
--- Keyword pattern never matches, so cmp only asks on trigger characters or a manual complete — an LLM source never
--- blocks the menu on ordinary typing. Registered with pcall, only when cmp is loaded. Users add { name = "slop" }.
---@class slop.complete.cmp
local M = {}

local api = vim.api
local registered = false
local source_id ---@type integer? cmp.register_source() result, for unregister_source()

local function engine()
  return require("slop.modules.complete.engine")
end

local source = {}
source.__index = source

function source.new()
  return setmetatable({}, source)
end

function source:get_debug_name()
  return "slop"
end

-- A cmp that keeps the source after the module was disabled must not get answers (they send buffer text).
local function module_loaded()
  return require("slop.core.registry").is_loaded("complete")
end

function source:is_available()
  if not module_loaded() then
    return false
  end
  return (engine().allowed(api.nvim_get_current_buf(), true))
end

function source:get_keyword_pattern()
  return [[\%(\)]] -- matches nothing: only trigger characters / manual completion
end

function source:get_trigger_characters()
  return { "@", ".", "(", "[", ":", " ", "{" }
end

--- cmp items from completion remainders.
---@param items string[]
---@param buf integer
---@return table[]
function M.make_items(items, buf)
  local ft = vim.bo[buf].filetype
  local out = {}
  for _, text in ipairs(items) do
    local first = text:match("^[^\n]*")
    local multi = text:find("\n", 1, true) ~= nil
    if first == "" and multi then
      first = (text:match("\n%s*([^\n]*)") or "") .. " ⏎"
    end
    out[#out + 1] = {
      label = first .. (multi and " …" or ""),
      insertText = text,
      filterText = "",
      kind = 1, -- Text
      documentation = { kind = "markdown", value = ("```%s\n%s\n```"):format(ft, text) },
      cmp = { kind_text = "slop", kind_hl_group = "SlopCompleteCmpKind" },
    }
  end
  return out
end

function source:complete(params, callback)
  local buf = (params.context and params.context.bufnr) or api.nvim_get_current_buf()
  if vim.b[buf].completion == false or not module_loaded() then
    return callback({ items = {}, isIncomplete = false })
  end
  local eng = engine()
  local have = eng.items(buf)
  if #have > 0 then
    return callback({ items = M.make_items(have, buf), isIncomplete = true })
  end
  local cfg = require("slop.config").get("complete")
  local manual = params.context and params.context.option and params.context.option.reason == "manual"
  if cfg.frontend ~= "cmp" and not manual then
    return callback({ items = {}, isIncomplete = true })
  end
  local done = false
  eng.trigger(buf, {
    manual = manual,
    no_render = cfg.frontend == "cmp",
    on_items = function(items)
      if done then
        return
      end
      done = true
      callback({ items = M.make_items(items, buf), isIncomplete = true })
    end,
  })
end

--- Register the source if nvim-cmp is loaded. Returns true once registered.
---@return boolean
function M.register()
  if registered then
    return true
  end
  local cmp = package.loaded["cmp"]
  if type(cmp) ~= "table" or type(cmp.register_source) ~= "function" then
    return false
  end
  local ok, res = pcall(cmp.register_source, "slop", source.new())
  if not ok then
    require("slop.core.log").scope("complete").debug("cmp.register_source failed: %s", res)
    return false
  end
  registered = true
  source_id = type(res) == "number" and res or nil
  return true
end

--- Unregister the source (module teardown; a later setup() registers it again).
function M.unregister()
  local cmp = package.loaded["cmp"]
  if registered and source_id and type(cmp) == "table" and type(cmp.unregister_source) == "function" then
    pcall(cmp.unregister_source, source_id)
  end
  registered, source_id = false, nil
end

---@return boolean
function M.is_registered()
  return registered
end

M.source = source

return M

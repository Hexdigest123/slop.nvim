--- Prefix cache for completions (copilot's completionsCache idea, MIT (c) Microsoft: entries keyed by the document
--- prefix; a lookup walks back to shorter cached prefixes whose choices start with what was typed since, provided
--- the suffix is equal — this also serves backspacing). OWNER: complete.
---@class slop.complete.Cache
---@field size integer
---@field entries {prefix: string, suffix: string, items: string[]}[]  newest last
local Cache = {}
Cache.__index = Cache

---@param size? integer
---@return slop.complete.Cache
function Cache.new(size)
  return setmetatable({ size = size or 64, entries = {} }, Cache)
end

--- Store items for (prefix, suffix); replaces an equal key.
---@param prefix string
---@param suffix string
---@param items string[]
function Cache:put(prefix, suffix, items)
  if #items == 0 then
    return
  end
  for i = #self.entries, 1, -1 do
    local e = self.entries[i]
    if e.prefix == prefix and e.suffix == suffix then
      table.remove(self.entries, i)
    end
  end
  self.entries[#self.entries + 1] = { prefix = prefix, suffix = suffix, items = vim.deepcopy(items) }
  while #self.entries > self.size do
    table.remove(self.entries, 1)
  end
end

--- Remaining completions at (prefix, suffix), or nil.
---@param prefix string
---@param suffix string
---@param max_typed? integer             how far the prefix may have advanced past a cached one (default 400)
---@return string[]?
function Cache:get(prefix, suffix, max_typed)
  max_typed = max_typed or 400
  for i = #self.entries, 1, -1 do
    local e = self.entries[i]
    if e.suffix == suffix and #prefix >= #e.prefix and #prefix - #e.prefix <= max_typed then
      if prefix:sub(1, #e.prefix) == e.prefix then
        local typed = prefix:sub(#e.prefix + 1)
        local out = {}
        for _, it in ipairs(e.items) do
          if #it > #typed and it:sub(1, #typed) == typed then
            out[#out + 1] = it:sub(#typed + 1)
          end
        end
        if #out > 0 then
          return out
        end
      end
    end
  end
  return nil
end

function Cache:clear()
  self.entries = {}
end

return Cache

--- todo: keyword groups, colors, highlight groups and the line matcher shared by highlighting, jumps and the
--- project search (one definition of "a todo": word boundary + KEYWORD + ":" or "(author)" [":"]).
local M = {}

--- todo-comments.nvim defaults (icons are Nerd Font glyphs).
M.defaults = {
  FIX = { icon = " ", color = "error", alt = { "FIXME", "BUG", "FIXIT", "ISSUE" } }, -- bug
  TODO = { icon = " ", color = "info", alt = {} }, -- check
  HACK = { icon = " ", color = "warning", alt = {} }, -- flame
  WARN = { icon = " ", color = "warning", alt = { "WARNING", "XXX" } }, -- warning
  PERF = { icon = " ", color = "default", alt = { "OPTIM", "PERFORMANCE", "OPTIMIZE" } }, -- tachometer
  NOTE = { icon = " ", color = "hint", alt = { "INFO" } }, -- sticky note
  TEST = { icon = "⏲ ", color = "test", alt = { "TESTING", "PASSED", "FAILED" } }, -- timer
}

--- Color name -> highlight group(s) / "#hex" (first existing group wins, then the hex fallback).
M.colors = {
  error = { "DiagnosticError", "ErrorMsg", "#DC2626" },
  warning = { "DiagnosticWarn", "WarningMsg", "#FBBF24" },
  info = { "DiagnosticInfo", "#2563EB" },
  hint = { "DiagnosticHint", "#10B981" },
  default = { "Identifier", "#7C3AED" },
  test = { "Identifier", "#FF00FF" },
}

---@class slop.todo.Group
---@field name string        group name (the keywords table key), e.g. "FIX"
---@field words string[]     name + aliases
---@field icon string
---@field color string       color name, highlight group or "#hex" as configured
---@field signs boolean
---@field hl string          SlopTodo<Name>      (keyword / sign / fg)
---@field hl_text string     SlopTodo<Name>Text  (comment text after the keyword)

---@class slop.todo.Keywords
---@field groups table<string, slop.todo.Group>   by group name
---@field order string[]                          group names, sorted
---@field by_word table<string, slop.todo.Group>  keyword or alias -> group

---@class slop.todo.Match
---@field col integer        0-based byte column of the keyword
---@field kw_end integer     0-based exclusive end of the keyword
---@field end_col integer    0-based exclusive end of "KEYWORD(author):"
---@field keyword string
---@field group slop.todo.Group
---@field author? string
---@field message string     text after the keyword, trimmed

--- Highlight group name for a keyword group ("FIX" -> "SlopTodoFix", "MY_KW" -> "SlopTodoMyKw").
---@param name string
---@return string
function M.hl_name(name)
  local parts = {}
  for w in name:gmatch("[%w]+") do
    parts[#parts + 1] = w:sub(1, 1):upper() .. w:sub(2):lower()
  end
  return "SlopTodo" .. table.concat(parts)
end

--- Default highlights of the built-in groups (spec.highlights). SlopTodoKeyword is stacked on the group's
--- color for the keyword badge.
M.highlights = { SlopTodoKeyword = { bold = true, reverse = true } }
for name, kw in pairs(M.defaults) do
  local hl = M.hl_name(name)
  M.highlights[hl] = { link = M.colors[kw.color][1] }
  M.highlights[hl .. "Text"] = { link = hl }
end

local forced = {} ---@type table<string, boolean>  built-in groups whose configured color replaced the link

--- Validation errors of a user `keywords` table (paths relative to the module).
---@param keywords any
---@return string[]
function M.validate(keywords)
  local errs = {}
  if type(keywords) ~= "table" then
    return { "keywords: expected table, got " .. type(keywords) }
  end
  local function word_ok(w)
    return type(w) == "string" and w:match("^[%w_]+$") ~= nil
  end
  for name, kw in pairs(keywords) do
    local p = "keywords." .. tostring(name)
    if not word_ok(name) then
      errs[#errs + 1] = p .. ": keyword names must match [%w_]+"
    elseif kw ~= false then
      if type(kw) ~= "table" then
        errs[#errs + 1] = p .. ": expected table or false, got " .. type(kw)
      else
        if kw.icon ~= nil and type(kw.icon) ~= "string" then
          errs[#errs + 1] = p .. ".icon: expected string, got " .. type(kw.icon)
        end
        if kw.color ~= nil and type(kw.color) ~= "string" then
          errs[#errs + 1] = p .. ".color: expected string, got " .. type(kw.color)
        end
        if kw.signs ~= nil and type(kw.signs) ~= "boolean" then
          errs[#errs + 1] = p .. ".signs: expected boolean, got " .. type(kw.signs)
        end
        if kw.alt ~= nil then
          if type(kw.alt) ~= "table" then
            errs[#errs + 1] = p .. ".alt: expected list, got " .. type(kw.alt)
          else
            for i, a in ipairs(kw.alt) do
              if not word_ok(a) then
                errs[#errs + 1] = ("%s.alt[%d]: aliases must match [%%w_]+"):format(p, i)
              end
            end
          end
        end
      end
    end
  end
  table.sort(errs)
  return errs
end

--- Compile the configured keyword groups (cfg.keywords, `false` entries dropped).
---@param cfg table  module config
---@return slop.todo.Keywords
function M.compile(cfg)
  local out = { groups = {}, order = {}, by_word = {} }
  for name, kw in pairs(cfg.keywords or {}) do
    if type(kw) == "table" then
      out.order[#out.order + 1] = name
    end
  end
  table.sort(out.order)
  for _, name in ipairs(out.order) do
    local kw = cfg.keywords[name]
    local hl = M.hl_name(name)
    local g = {
      name = name,
      words = { name },
      icon = kw.icon or "",
      color = kw.color or "default",
      signs = kw.signs ~= false,
      hl = hl,
      hl_text = hl .. "Text",
    }
    vim.list_extend(g.words, kw.alt or {})
    out.groups[name] = g
    for _, w in ipairs(g.words) do
      out.by_word[w] = out.by_word[w] or g
    end
  end
  return out
end

--- Highlight definition for a color: color name (cfg.colors) | highlight group | "#hex".
---@param color string
---@param colors table<string, string|string[]>
---@return vim.api.keyset.highlight
function M.color_def(color, colors)
  local spec = colors[color] or color
  local list = type(spec) == "table" and spec or { spec }
  for _, c in ipairs(list) do
    if type(c) == "string" then
      if c:match("^#%x+$") then
        return { fg = c }
      elseif vim.fn.hlexists(c) == 1 then
        return { link = c }
      end
    end
  end
  return { link = M.colors.default[1] }
end

--- Define the highlight groups of every compiled group. Built-in groups whose color is unchanged keep the
--- spec.highlights default links (so colorschemes can override them); configured colors are forced.
---@param kw slop.todo.Keywords
---@param colors table
function M.apply_highlights(kw, colors)
  local util = require("slop.core.util")
  for _, name in ipairs(kw.order) do
    local g = kw.groups[name]
    local def = M.color_def(g.color, colors)
    local builtin = M.highlights[g.hl]
    if not builtin then
      util.hl({ [g.hl] = def, [g.hl_text] = { link = g.hl } })
    elseif not vim.deep_equal(def, builtin) then
      forced[g.hl] = true
      vim.api.nvim_set_hl(0, g.hl, def)
    elseif forced[g.hl] then
      forced[g.hl] = nil
      vim.api.nvim_set_hl(0, g.hl, builtin)
    end
  end
end

--- Group names / words a filter list selects: a group name selects the group with its aliases, an alias only
--- itself. nil/empty -> every word.
---@param kw slop.todo.Keywords
---@param filter? string[]
---@return table<string, slop.todo.Group> words, string[] unknown
function M.select(kw, filter)
  if not filter or #filter == 0 then
    return kw.by_word, {}
  end
  local out, unknown = {}, {}
  for _, f in ipairs(filter) do
    local g = kw.groups[f]
    if g then
      for _, w in ipairs(g.words) do
        out[w] = g
      end
    elseif kw.by_word[f] then
      out[f] = kw.by_word[f]
    else
      unknown[#unknown + 1] = f
    end
  end
  return out, unknown
end

--- Parse a keyword filter: { "TODO,FIX", "keywords=NOTE" } / "TODO,FIX" -> { "TODO", "FIX", "NOTE" }.
---@param args? string|string[]
---@return string[]
function M.parse_filter(args)
  if type(args) == "string" then
    args = { args }
  end
  local out = {}
  for _, a in ipairs(args or {}) do
    a = a:gsub("^keywords=", "")
    for w in a:gmatch("[^,%s]+") do
      out[#out + 1] = w
    end
  end
  return out
end

--- Todo matches of one line.
---@param line string
---@param words table<string, slop.todo.Group>  keyword -> group (Keywords.by_word or M.select())
---@return slop.todo.Match[]
function M.match(line, words)
  local out = {}
  if not line:find("[:(]") then
    return out
  end
  local pos = 1
  while true do
    local s, w, e = line:match("()([%w_]+)()", pos)
    if not s then
      break
    end
    pos = e
    local g = words[w]
    if g then
      local nxt = line:sub(e, e)
      local stop, author
      if nxt == ":" then
        stop = e + 1
      elseif nxt == "(" then
        local close = line:find(")", e + 1, true)
        if close then
          author = line:sub(e + 1, close - 1)
          stop = close + 1
          if line:sub(stop, stop) == ":" then
            stop = stop + 1
          end
        end
      end
      if stop then
        out[#out + 1] = {
          col = s - 1,
          kw_end = e - 1,
          end_col = stop - 1,
          keyword = w,
          group = g,
          author = author,
          message = vim.trim(line:sub(stop)),
        }
        pos = stop
      end
    end
  end
  return out
end

--- Search regexes for the given words: rust-regex (rg) and POSIX ERE (git grep -E).
---@param words table<string, any>
---@return string rg, string ere
function M.patterns(words)
  local list = vim.tbl_keys(words)
  table.sort(list, function(a, b)
    return #a > #b or (#a == #b and a < b)
  end)
  local alt = table.concat(list, "|")
  return ([[\b(%s)(:|\([^)]*\))]]):format(alt), ([[(^|[^[:alnum:]_])(%s)(:|\([^)]*\))]]):format(alt)
end

return M

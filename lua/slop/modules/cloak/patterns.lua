--- cloak: pure rule normalisation + matching (cloak.nvim-compatible semantics, MIT, minus its bugs).
---
--- A rule (cloak.nvim format):
---   { file_pattern = string|string[], cloak_pattern = string | { string | { lua_pat, replace = r }, replace = r },
---     replace = string|table|function|nil, block = boolean? (slop: never send matching files to AI) }
--- Precedence of `replace`: inner table's own > cloak_pattern.replace > rule.replace; an inner TABLE without
--- `replace` does not inherit (cloak.nvim quirk, kept so README examples render identically).
---
--- Matching per line (cloak.nvim): repeatedly search from `start`; the best inner pattern is the earliest
--- start, ties broken by the longest match (try_all_patterns = true) or the first pattern in list order that
--- matches anywhere (false). The first char of a match stays visible (legacy), unless the pattern has capture
--- groups and a `replace`: then the gsub result is the prefix; a prefix equal to the original text stays as
--- real text and only the rest is masked, otherwise the prefix is drawn over the original.
--- Fixed: every rule matching a file contributes (spans are unioned), the search always advances (no infinite
--- loop on 1-char/empty matches), and file patterns use one matcher everywhere (core.secrets.match_glob).
--- Fail closed: validate() checks the pattern syntax statically, and a pattern that throws anyway counts the
--- whole line as secret (screen and AI) instead of matching nothing.
local M = {}

---@class slop.cloak.Pattern
---@field [1] string     Lua pattern
---@field replace? any   gsub repl (string|table|function)

---@class slop.cloak.Rule
---@field file_patterns string[]
---@field patterns slop.cloak.Pattern[]
---@field block boolean
---@field source string   "patterns" | "builtin" | add_rules() name
---@field index integer

---@class slop.cloak.Span
---@field row integer      0-based
---@field col integer      0-based byte col of the masked region
---@field end_col integer  exclusive
---@field prefix string    text drawn over the start of the region ("" = only mask chars)

--- Case-insensitive Lua pattern for a lowercase word: "key" -> "[Kk][Ee][Yy]".
---@param word string
---@return string
local function ci(word)
  return (word:gsub("%a", function(c)
    return "[" .. c:upper() .. c .. "]"
  end))
end

--- Parts of names that mark a value as secret in .http/.rest files (header names are case-insensitive).
local HTTP_WORDS = { "auth", "token", "key", "secret", "passw", "pwd", "cookie", "session" }

---@return string[]
local function http_patterns()
  -- Authorization-style headers keep their scheme visible ("Bearer ****"); first in the list so it wins ties
  local pats = { "^(%s*[%w%-]*" .. ci("authorization") .. "[%w%-]*:%s*%a+%s+)%S.*" }
  for _, word in ipairs(HTTP_WORDS) do
    local w = ci(word)
    vim.list_extend(pats, {
      "^(%s*[%w%-]*" .. w .. "[%w%-]*:%s*).+", -- header
      "^(%s*@[%w_%-%.]*" .. w .. "[%w_%-%.]*%s*=%s*).+", -- @variable = value
      "(%f[%w_][%w_%-%.]*" .. w .. '[%w_%-%.]*=)[^&%s#"]+', -- ?query= / form body
      '("[%w_%-%.]*' .. w .. '[%w_%-%.]*"%s*:%s*").*[^\\]"', -- "json": "value" (escaped quotes included)
    })
  end
  return pats
end

--- Extra rules shipped by slop (`builtin_patterns = true`), on top of the user's/cloak.nvim `patterns`.
M.builtin = {
  {
    file_pattern = { "http-client.env.json", "http-client.private.env.json", "*.private.env.json" },
    -- a value with an escaped quote ("a\"b") is matched up to its real end by the longer first pattern
    cloak_pattern = { '(":%s*")[^"]*\\".*[^\\]"', '(":%s*")[^"]+' },
    replace = "%1",
  },
  {
    file_pattern = { ".npmrc", ".yarnrc", ".yarnrc.yml" },
    cloak_pattern = {
      "([%w_]*[Tt]oken%s*[=:]%s*).+",
      "([%w_]*[Aa]uth[%w_]*%s*[=:]%s*).+", -- _auth=, npmAuthIdent: (yarn's user:password)
      "(_password%s*=%s*).+",
    },
    replace = "%1",
  },
  { file_pattern = { ".netrc", "_netrc" }, cloak_pattern = "(password%s+)%S+", replace = "%1", block = true },
  {
    file_pattern = { ".aws/credentials" },
    cloak_pattern = {
      "(aws_secret_access_key%s*=%s*).+",
      "(aws_session_token%s*=%s*).+",
      "(aws_access_key_id%s*=%s*).+",
    },
    replace = "%1",
    block = true,
  },
  { file_pattern = { ".nvim/state/**" }, cloak_pattern = "^(%s*)%S.*", replace = "%1", block = true },
  { file_pattern = { "*.http", "*.rest" }, cloak_pattern = http_patterns(), replace = "%1" },
}

---@param v any
---@return string[]
local function as_list(v)
  if type(v) == "string" then
    return { v }
  end
  return type(v) == "table" and v or {}
end

--- Normalise cloak.nvim-style rules (does not mutate the input).
---@param rules table[]
---@param source? string
---@return slop.cloak.Rule[]
function M.normalize(rules, source)
  local out = {}
  for i, r in ipairs(rules or {}) do
    local pats = {}
    local cp = r.cloak_pattern
    if type(cp) == "string" then
      pats[1] = { cp, replace = r.replace }
    elseif type(cp) == "table" then
      local outer = cp.replace
      if outer == nil then
        outer = r.replace
      end
      for _, inner in ipairs(cp) do
        if type(inner) == "string" then
          pats[#pats + 1] = { inner, replace = outer }
        elseif type(inner) == "table" and type(inner[1]) == "string" then
          pats[#pats + 1] = { inner[1], replace = inner.replace }
        end
      end
    end
    out[#out + 1] = {
      file_patterns = vim.deepcopy(as_list(r.file_pattern)),
      patterns = pats,
      block = r.block == true,
      source = source or "patterns",
      index = i,
    }
  end
  return out
end

--- Index after the set that starts at `i` (pat:sub(i, i) == "["), nil when it is not closed (Lua's classEnd).
---@param pat string
---@param i integer
---@return integer?
local function set_end(pat, i)
  local p = i + 1
  if pat:sub(p, p) == "^" then
    p = p + 1
  end
  repeat -- the first char always belongs to the set: "[]]" and "[^]]" are valid
    if p > #pat then
      return nil
    end
    if pat:sub(p, p) == "%" then
      p = p + 1
    end
    p = p + 1
  until pat:sub(p, p) == "]"
  return p + 1
end

--- Syntax errors that string.find only raises once the matcher reaches them (so `find("", pat)` misses them):
--- a trailing "%", an unclosed set, unbalanced captures, %b without its 2 chars, %f without a set, and back
--- references to captures that are not closed yet.
---@param pat string
---@return string? err
function M.pattern_error(pat)
  local i, n = 1, #pat
  local open, closed, level = {}, {}, 0
  while i <= n do
    local c = pat:sub(i, i)
    if c == "%" then
      local x = pat:sub(i + 1, i + 1)
      if x == "" then
        return "malformed pattern (ends with '%')"
      elseif x == "b" then
        if i + 3 > n then
          return "missing arguments to '%b'"
        end
        i = i + 4
      elseif x == "f" then
        if pat:sub(i + 2, i + 2) ~= "[" then
          return "missing '[' after '%f' in pattern"
        end
        local e = set_end(pat, i + 2)
        if not e then
          return "malformed pattern (missing ']')"
        end
        i = e
      elseif x:match("%d") then
        if x == "0" or not closed[tonumber(x)] then
          return "invalid capture index %" .. x
        end
        i = i + 2
      else
        i = i + 2
      end
    elseif c == "[" then
      local e = set_end(pat, i)
      if not e then
        return "malformed pattern (missing ']')"
      end
      i = e
    elseif c == "(" then
      level = level + 1
      if level > 32 then
        return "too many captures"
      end
      open[#open + 1] = level
      i = i + 1
    elseif c == ")" then
      local k = table.remove(open)
      if not k then
        return "invalid pattern capture"
      end
      closed[k] = true
      i = i + 1
    else
      i = i + 1
    end
  end
  if #open > 0 then
    return "unfinished capture"
  end
  return nil
end

--- Validation errors of a rule list (for spec.schema). Paths like "patterns[2].cloak_pattern[1]".
---@param rules any
---@param prefix string
---@return string[]
function M.validate(rules, prefix)
  local errs = {}
  if type(rules) ~= "table" then
    return { ("%s: expected a list of rules, got %s"):format(prefix, type(rules)) }
  end
  local function check_pat(path, pat)
    if type(pat) ~= "string" then
      errs[#errs + 1] = ("%s: expected a Lua pattern string, got %s"):format(path, type(pat))
      return
    end
    local err = M.pattern_error(pat)
    if not err then
      local ok, e = pcall(string.find, "", pat)
      err = not ok and (tostring(e):gsub("^.-:%d+: ", "")) or nil
    end
    if err then
      errs[#errs + 1] = ("%s: invalid Lua pattern %q: %s"):format(path, pat, err)
    end
  end
  for i, r in ipairs(rules) do
    local p = ("%s[%d]"):format(prefix, i)
    if type(r) ~= "table" then
      errs[#errs + 1] = p .. ": expected table, got " .. type(r)
    else
      local fp = r.file_pattern
      local fp_ok = type(fp) == "string" or (type(fp) == "table" and #fp > 0)
      for _, f in ipairs(type(fp) == "table" and fp or {}) do
        fp_ok = fp_ok and type(f) == "string"
      end
      if not fp_ok then
        errs[#errs + 1] = p .. ".file_pattern: expected string|string[]"
      end
      local cp = r.cloak_pattern
      if type(cp) == "string" then
        check_pat(p .. ".cloak_pattern", cp)
      elseif type(cp) == "table" then
        for j, inner in ipairs(cp) do
          local ip = ("%s.cloak_pattern[%d]"):format(p, j)
          if type(inner) == "table" then
            check_pat(ip .. "[1]", inner[1])
          else
            check_pat(ip, inner)
          end
        end
      else
        errs[#errs + 1] = p .. ".cloak_pattern: expected string|table, got " .. type(cp)
      end
      if r.block ~= nil and type(r.block) ~= "boolean" then
        errs[#errs + 1] = p .. ".block: expected boolean"
      end
    end
  end
  return errs
end

--- Does any of the rule's file patterns match `path`?
---@param rule slop.cloak.Rule
---@param path string
---@return boolean
function M.rule_matches(rule, path)
  if not path or path == "" then
    return false
  end
  local match_glob = require("slop.core.secrets").match_glob
  for _, g in ipairs(rule.file_patterns) do
    if match_glob(g, path) then
      return true
    end
  end
  return false
end

--- Rules applying to `path` (minus `exclude` globs).
---@param rules slop.cloak.Rule[]
---@param path string
---@param exclude? string[]
---@return slop.cloak.Rule[]
function M.rules_for(rules, path, exclude)
  if not path or path == "" then
    return {}
  end
  local match_glob = require("slop.core.secrets").match_glob
  for _, g in ipairs(exclude or {}) do
    if match_glob(g, path) then
      return {}
    end
  end
  local out = {}
  for _, r in ipairs(rules) do
    if M.rule_matches(r, path) then
      out[#out + 1] = r
    end
  end
  return out
end

--- Matches of one rule's patterns in one line (cloak.nvim algorithm, terminating).
---@param line string
---@param pats slop.cloak.Pattern[]
---@param try_all boolean
---@return {col: integer, end_col: integer, prefix: string}[]
function M.match_line(line, pats, try_all)
  local out = {}
  local start = 1
  while start <= #line do
    local first, last, best, groups
    for _, p in ipairs(pats) do
      local res = { line:find(p[1], start) }
      local f, l = res[1], res[2]
      if f and (not first or f < first or (f == first and l > last)) then
        first, last, best, groups = f, l, p, #res > 2
        if try_all == false then
          break
        end
      end
    end
    if not first or last < first then
      break -- no match, or an empty match: stop (cloak.nvim looped forever here)
    end
    local prefix = line:sub(first, first)
    if groups and best.replace ~= nil then
      local ok, res = pcall(string.gsub, line:sub(first, last), best[1], best.replace, 1)
      if ok then
        prefix = res
      end
    end
    local col = first
    if prefix == line:sub(first, first + #prefix - 1) then
      col, prefix = first + #prefix, ""
    end
    if last >= col then
      out[#out + 1] = { col = col - 1, end_col = last, prefix = prefix }
    end
    start = math.max(last, first) + 1
  end
  return out
end

local reported = setmetatable({}, { __mode = "k" }) ---@type table<slop.cloak.Rule, boolean>

--- A pattern threw although validate() accepted it: tell the user once per rule (scheduled, since compute()
--- runs inside redraws and secrets queries).
---@param rule slop.cloak.Rule
---@param err any
local function report(rule, err)
  if reported[rule] then
    return
  end
  reported[rule] = true
  local msg = ("%s[%d]: pattern error (%s); the lines it fails on are masked and redacted entirely"):format(
    rule.source,
    rule.index,
    (tostring(err):gsub("^.-:%d+: ", ""))
  )
  vim.schedule(function()
    require("slop.core.log").notify(msg, vim.log.levels.ERROR, { scope = "cloak" })
  end)
end

--- Spans of `rules` over `lines` (rows absolute: first_row + index - 1), merged per row.
---@param rules slop.cloak.Rule[]
---@param lines string[]
---@param first_row? integer
---@param opts? {try_all_patterns?: boolean}
---@return slop.cloak.Span[]
function M.compute(rules, lines, first_row, opts)
  first_row = first_row or 0
  local try_all = not (opts and opts.try_all_patterns == false)
  local out = {}
  if #rules == 0 then
    return out
  end
  for i, line in ipairs(lines) do
    local row_spans = {}
    for _, r in ipairs(rules) do
      local ok, res = pcall(M.match_line, line, r.patterns, try_all)
      if not ok then
        -- fail closed: where the secret is cannot be known, so the whole line counts as secret
        report(r, res)
        res = #line > 0 and { { col = 0, end_col = #line, prefix = "" } } or {}
      end
      vim.list_extend(row_spans, res)
    end
    if #row_spans > 0 then
      table.sort(row_spans, function(a, b)
        return a.col < b.col or (a.col == b.col and a.end_col > b.end_col)
      end)
      local last
      for _, s in ipairs(row_spans) do
        if last and s.col < last.end_col then
          last.end_col = math.max(last.end_col, s.end_col)
        else
          last = { row = first_row + i - 1, col = s.col, end_col = s.end_col, prefix = s.prefix }
          out[#out + 1] = last
        end
      end
    end
  end
  return out
end

return M

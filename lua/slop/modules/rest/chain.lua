--- Request chaining: dependencies from `# @depends a, b` plus `{{name.response...}}` references (also inside the
--- file variables a request uses, transitively), and a topological run plan for the missing ones. Pure.
---@class slop.rest.chain
local M = {}

local vars = require("slop.modules.rest.vars")

---@param req slop.rest.Request
---@return string[] texts
local function texts(req)
  local out = { req.url or "" }
  for _, h in ipairs(req.headers or {}) do
    out[#out + 1] = h[1]
    out[#out + 1] = h[2]
  end
  out[#out + 1] = req.body or ""
  return out
end

--- Names this request depends on (explicit first, then inferred; unique, self excluded).
---@param req slop.rest.Request
---@param file_vars? table<string, string>  file variables visible to the request
---@return string[]
function M.deps(req, file_vars)
  local out, seen = {}, {}
  local function add(name)
    if name and name ~= "" and not seen[name] and name ~= req.name then
      seen[name] = true
      out[#out + 1] = name
    end
  end
  for _, d in ipairs(req.meta and req.meta.depends or {}) do
    add(d)
  end
  local visited = {}
  local function scan(text)
    for _, ref in ipairs(vars.refs(text)) do
      local cname = vars.chain_ref(ref)
      if cname then
        add(cname)
      elseif file_vars and file_vars[ref] and not visited[ref] then
        visited[ref] = true
        scan(file_vars[ref])
      end
    end
  end
  for _, t in ipairs(texts(req)) do
    scan(t)
  end
  return out
end

---@class slop.rest.ChainOpts
---@field lookup fun(name: string, from: slop.rest.Request): slop.rest.Request?, string?  resolve a dependency name
---@field has_response fun(req: slop.rest.Request): boolean
---@field file_vars? fun(req: slop.rest.Request): table<string, string>

---@param req slop.rest.Request
---@return string
local function label(req)
  return req.name or ((req.file and vim.fs.basename(req.file) or "?") .. ":" .. tostring(req.line))
end

---@param req slop.rest.Request
---@return string
local function key(req)
  return (req.file or "") .. ":" .. tostring(req.line)
end

--- Run plan for `target`: missing dependencies first (depth-first, topological), `target` last.
--- Dependencies that already have a response are not re-run (and not traversed).
---@param target slop.rest.Request
---@param opts slop.rest.ChainOpts
---@return slop.rest.Request[]? plan, string? err
function M.plan(target, opts)
  local order, done, onstack, path = {}, {}, {}, {}

  local function visit(req, is_target)
    local k = key(req)
    if done[k] then
      return true
    end
    if onstack[k] then
      local cyc = {}
      local started = false
      for _, p in ipairs(path) do
        if key(p) == k then
          started = true
        end
        if started then
          cyc[#cyc + 1] = label(p)
        end
      end
      cyc[#cyc + 1] = label(req)
      return false, "dependency cycle: " .. table.concat(cyc, " -> ")
    end
    if not is_target and opts.has_response(req) then
      done[k] = true
      return true
    end
    onstack[k] = true
    path[#path + 1] = req
    local fv = opts.file_vars and opts.file_vars(req) or nil
    for _, name in ipairs(M.deps(req, fv)) do
      local dep, lerr = opts.lookup(name, req)
      if not dep then
        onstack[k] = nil
        return false, lerr or ("unknown dependency '%s' of '%s'"):format(name, label(req))
      end
      local ok, err = visit(dep, false)
      if not ok then
        return false, err
      end
    end
    path[#path] = nil
    onstack[k] = nil
    done[k] = true
    order[#order + 1] = req
    return true
  end

  local ok, err = visit(target, true)
  if not ok then
    return nil, err
  end
  return order
end

return M

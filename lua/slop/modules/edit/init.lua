--- edit: selection -> prompt -> ACP agent -> live in-region progress -> inline diff accept/reject. OWNER: edit.
---
--- <leader>aa (x: the selection, n: the enclosing treesitter scope) opens the prompt float; the request runs in
--- its own session on a long-lived agent (default "vibe"); the answer comes back as a <slop:replacement> block and
--- is reviewed with core.ui.diff (ga/gr/gA/gR/]h/[h, <C-r> refine). See doc/slop-edit.txt.
--- Heavy code lives in request/prompt/replacement/context/ui/presets.lua and is required lazily.
local api = vim.api

local state = {
  cfg = nil, ---@type table?
  agent = nil, ---@type string?  runtime override (<leader>ag / :Slop edit agent)
}

local function cfg()
  return state.cfg or require("slop.config").get("edit")
end

local function log()
  return require("slop.core.log").scope("edit")
end

local function presets()
  return require("slop.modules.edit.presets").all(cfg().presets)
end

local function current_agent()
  return state.agent or cfg().agent
end

local function agent_names()
  local ok, agents = pcall(function()
    return require("slop.config").get("ai").agents
  end)
  local names = ok and vim.tbl_keys(agents or {}) or {}
  table.sort(names)
  return names
end

local function get_line(buf, row)
  return api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ""
end

--- Region for the current mode: visual selection (exits visual mode) or the enclosing scope.
---@param buf integer
---@return slop.Range range, boolean linewise
local function region_from_mode(buf)
  local util = require("slop.core.util")
  local mode = vim.fn.mode()
  if mode:match("^[vV\22]") then
    local r = util.visual_range(buf)
    api.nvim_feedkeys(vim.keycode("<Esc>"), "nx", false)
    if mode ~= "v" then
      return { r[1], 0, r[3], #get_line(buf, r[3]) }, true
    end
    local linewise = r[2] == 0 and r[4] >= #get_line(buf, r[3])
    if linewise then
      r[4] = #get_line(buf, r[3])
    end
    return r, linewise
  end
  local row = api.nvim_win_get_cursor(0)[1] - 1
  local lc = api.nvim_buf_line_count(buf)
  local srow, erow
  if cfg().context == "line" then
    srow, erow = row, row
  else
    local ok, scope = pcall(function()
      return require("slop.core.ts").scope(buf, { row, api.nvim_win_get_cursor(0)[2] })
    end)
    if ok and scope and scope.range then
      srow, erow = scope.range[1], scope.range[3]
      if scope.range[4] == 0 and erow > srow then
        erow = erow - 1
      end
    else
      local n = tonumber(cfg().surrounding) or 50
      srow, erow = math.max(0, row - n), math.min(lc - 1, row + n)
    end
  end
  return { srow, 0, erow, #get_line(buf, erow) }, true
end

---@class slop.edit.StartOpts
---@field buf? integer
---@field range? slop.Range                charwise 0-based range (end exclusive)
---@field lines? {[1]: integer, [2]: integer}  0-based inclusive rows (linewise), e.g. from a :range
---@field linewise? boolean
---@field instruction? string             skip the prompt float
---@field preset? string
---@field agent? string

local api_tbl = {}

--- Start an edit. Without `instruction` (and without an input-less preset) the prompt float opens first.
---@param opts? slop.edit.StartOpts
---@return integer? id                     request id when started synchronously
function api_tbl.start(opts)
  opts = opts or {}
  local buf = opts.buf or api.nvim_get_current_buf()
  if buf == 0 then
    buf = api.nvim_get_current_buf()
  end
  local range, linewise = opts.range, opts.linewise
  if opts.lines then
    local s, e = opts.lines[1], opts.lines[2]
    range, linewise = { s, 0, e, #get_line(buf, e) }, true
  elseif not range then
    range, linewise = region_from_mode(buf)
  end
  if linewise == nil then
    linewise = range[2] == 0 and range[4] >= #get_line(buf, range[3])
  end
  local all = presets()
  local agent = opts.agent or current_agent()

  local function go(text)
    local P = require("slop.modules.edit.presets")
    local pname, rest = P.parse(text or "", all)
    pname = pname or opts.preset
    local preset = pname and all[pname] or nil
    if pname and not preset then
      log().notify(("unknown preset '%s'"):format(pname), vim.log.levels.WARN)
      return nil
    end
    rest = vim.trim(rest or "")
    if not preset and rest == "" then
      return nil
    end
    local req = require("slop.modules.edit.request").new({
      buf = buf,
      range = range,
      linewise = linewise,
      instruction = rest,
      preset = preset,
      agent = (preset and preset.agent) or agent,
      cfg = cfg(),
    })
    local ok, err = req:start()
    if not ok then
      log().notify("edit: " .. tostring(err), vim.log.levels.WARN)
      return nil
    end
    return req.id
  end

  local preset = opts.preset and all[opts.preset]
  if opts.instruction or (preset and not preset.input) then
    local text = opts.instruction or ""
    if opts.preset then
      text = "#" .. opts.preset .. " " .. text
    end
    return go(text)
  end
  local context = require("slop.modules.edit.context")
  local root = context.root(buf)
  require("slop.core.ui.input").open({
    title = ("slop edit · %s"):format(agent),
    default = opts.preset and ("#" .. opts.preset .. " ") or nil,
    anchor = { buf = buf, row = range[1], end_row = range[3] },
    history = "edit",
    footer = "<C-s> submit · <Esc> cancel · #preset · @file",
    complete = function(lead)
      return context.complete(lead, all, root)
    end,
    on_submit = go,
  })
end

--- Pick a preset and run it on the current region (input presets open the prompt prefilled).
---@param name? string
---@param opts? slop.edit.StartOpts
function api_tbl.preset(name, opts)
  opts = vim.tbl_extend("force", {}, opts or {})
  local buf = opts.buf or api.nvim_get_current_buf()
  if not opts.range and not opts.lines then
    opts.range, opts.linewise = region_from_mode(buf)
  end
  if name then
    opts.preset = name
    return api_tbl.start(opts)
  end
  local all = presets()
  local names = vim.tbl_keys(all)
  table.sort(names)
  local function chosen(item)
    if item then
      opts.preset = item
      api_tbl.start(opts)
    end
  end
  local ok = pcall(function()
    require("slop.core.ui.picker").pick(names, {
      prompt = "Edit preset",
      format = function(n)
        return { { ("%-10s"):format(n), "SlopMatch" }, { " " .. (all[n].desc or "") } }
      end,
      on_select = chosen,
    })
  end)
  if not ok then
    vim.ui.select(names, {
      prompt = "Edit preset",
      format_item = function(n)
        return n .. " — " .. (all[n].desc or "")
      end,
    }, chosen)
  end
end

--- Get or set the agent used by new requests (nil -> picker).
---@param name? string
---@return string current
function api_tbl.agent(name)
  if name then
    if not vim.tbl_contains(agent_names(), name) then
      log().notify(("unknown agent '%s' (configure ai.agents.%s)"):format(name, name), vim.log.levels.WARN)
      return current_agent()
    end
    state.agent = name
    log().notify("edit agent: " .. name, vim.log.levels.INFO)
    return name
  end
  return current_agent()
end

function api_tbl.pick_agent()
  local names = agent_names()
  local function chosen(item)
    if item then
      api_tbl.agent(item)
    end
  end
  local ok = pcall(function()
    require("slop.core.ui.picker").pick(names, {
      prompt = "Edit agent (current: " .. current_agent() .. ")",
      on_select = chosen,
    })
  end)
  if not ok then
    vim.ui.select(names, { prompt = "Edit agent" }, chosen)
  end
end

--- Running/reviewing requests.
---@return {id: integer, buf: integer, agent: string, state: string, instruction: string}[]
function api_tbl.requests()
  local out = {}
  for _, r in ipairs(require("slop.modules.edit.request").list()) do
    out[#out + 1] = { id = r.id, buf = r.buf, agent = r.agent, state = r.state, instruction = r:label() }
  end
  return out
end

--- Cancel a request: id, "all", or (nil) the one under the cursor / the only one / a picker.
---@param target? integer|"all"
---@return boolean
function api_tbl.cancel(target)
  local mod = require("slop.modules.edit.request")
  local running = vim.tbl_filter(function(r)
    return r:is_running()
  end, mod.list())
  if target == "all" then
    for _, r in ipairs(running) do
      r:cancel()
    end
    return #running > 0
  end
  if type(target) == "number" then
    local r = mod.active[target]
    return r ~= nil and r:cancel()
  end
  if #running == 0 then
    log().notify("no running edit", vim.log.levels.INFO)
    return false
  end
  local buf = api.nvim_get_current_buf()
  local row = api.nvim_win_get_cursor(0)[1] - 1
  local ui = require("slop.modules.edit.ui")
  for _, r in ipairs(running) do
    local rg = r.buf == buf and ui.region(buf, r.mark)
    if rg and row >= rg[1] - 1 and row <= rg[3] + 1 then
      return r:cancel()
    end
  end
  if #running == 1 then
    return running[1]:cancel()
  end
  local function chosen(item)
    if item then
      item:cancel()
    end
  end
  local function fmt(r)
    local name = vim.fn.fnamemodify(api.nvim_buf_get_name(r.buf), ":t")
    return ("#%d %s:%d %s · %s"):format(r.id, name, (ui.region(r.buf, r.mark) or { 0 })[1] + 1, r.agent, r:label())
  end
  local ok = pcall(function()
    require("slop.core.ui.picker").pick(running, { prompt = "Cancel edit", format = fmt, on_select = chosen })
  end)
  if not ok then
    vim.ui.select(running, { prompt = "Cancel edit", format_item = fmt }, chosen)
  end
  return true
end

--- Effective presets.
---@return table<string, slop.edit.Preset>
function api_tbl.presets()
  return presets()
end

local function cmd_lines(cmd)
  if cmd and cmd.range and cmd.range > 0 then
    return { cmd.line1 - 1, cmd.line2 - 1 }
  end
end

---@type slop.ModuleSpec
return {
  name = "edit",
  description = "AI edits of a selection through an ACP agent, reviewed as an inline diff",
  services = { "ai" },
  open_keys = { "presets" },
  defaults = {
    enabled = true,
    agent = "vibe",
    apply = "diff",
    context = "scope",
    surrounding = 50,
    presets = {},
    rules_files = { ".nvim/rules.md", "AGENTS.md", "CLAUDE.md" },
    permissions = { allow = { "read", "search", "fetch", "think" } },
    keymaps = {
      edit = "<leader>aa",
      preset = "<leader>ap",
      agent = "<leader>ag",
      cancel = "<leader>as",
      diff = {
        accept = "ga",
        reject = "gr",
        accept_all = "gA",
        reject_all = "gR",
        next = "]h",
        prev = "[h",
        refine = "<C-r>",
      },
    },
  },
  schema = function(c, check)
    check("agent", c.agent, "string")
    check("apply", c.apply, function(v)
      return v == "diff" or v == "auto"
    end, false, "'diff'|'auto'")
    check("context", c.context, function(v)
      return v == "scope" or v == "line"
    end, false, "'scope'|'line'")
    check("surrounding", c.surrounding, function(v)
      return type(v) == "number" and v >= 0
    end, false, "number >= 0")
    check("presets", c.presets, "table")
    check("rules_files", c.rules_files, function(v)
      return vim.islist(v)
    end, false, "list of file names")
    check("permissions", c.permissions, "table")
    check("permissions.allow", type(c.permissions) == "table" and c.permissions.allow or nil, function(v)
      return vim.islist(v)
    end, false, "list of tool kinds")
    for name, p in pairs(type(c.presets) == "table" and c.presets or {}) do
      check("presets." .. name, p, function(v)
        return v == false or (type(v) == "table" and (v.prompt == nil or type(v.prompt) == "string"))
      end, false, "false|{prompt, desc?, sink?, diagnostics?, input?, agent?}")
      if type(p) == "table" and p.sink ~= nil then
        check("presets." .. name .. ".sink", p.sink, function(v)
          return v == "diff" or v == "float" or v == "scratch"
        end, false, "'diff'|'float'|'scratch'")
      end
    end
    for k, v in pairs(type(c.keymaps) == "table" and type(c.keymaps.diff) == "table" and c.keymaps.diff or {}) do
      check("keymaps.diff." .. k, v, function(x)
        return x == false or type(x) == "string"
      end, false, "string|false")
    end
  end,
  setup = function(c)
    state.cfg = c
    require("slop.core.events").on(nil, "ConfigChanged", function()
      state.cfg = nil
    end, { group = require("slop.core.util").augroup("edit") })
  end,
  highlights = {
    SlopEditRegion = { link = "SlopDim" },
    SlopEditStatus = { link = "Comment" },
    SlopEditSpinner = { link = "SlopSpinner" },
    SlopEditError = { link = "DiagnosticError" },
  },
  commands = {
    run = {
      desc = "[range] run [instruction]: edit the selection/scope (prompt float without instruction)",
      default = true,
      impl = function(args, cmd)
        local text = table.concat(args or {}, " ")
        api_tbl.start({ lines = cmd_lines(cmd), instruction = text ~= "" and text or nil })
      end,
    },
    preset = {
      desc = "[range] preset [name]: run a preset",
      impl = function(args, cmd)
        local lines = cmd_lines(cmd)
        local opts = lines and { lines = lines } or nil
        if not opts then
          local buf = api.nvim_get_current_buf()
          local r, lw = region_from_mode(buf)
          opts = { range = r, linewise = lw }
        end
        api_tbl.preset(args[1], opts)
      end,
      complete = function(lead)
        local ok, names = pcall(function()
          return require("slop.modules.edit.presets").names(require("slop.config").get("edit").presets)
        end)
        return require("slop.core.util").complete_prefix(ok and names or {}, lead)
      end,
    },
    agent = {
      desc = "agent [name]: show or switch the agent",
      impl = function(args)
        if args[1] then
          api_tbl.agent(args[1])
        else
          api_tbl.pick_agent()
        end
      end,
      complete = function(lead)
        return require("slop.core.util").complete_prefix(agent_names(), lead)
      end,
    },
    cancel = {
      desc = "cancel [all]: cancel the request under the cursor / pick one / all",
      impl = function(args)
        api_tbl.cancel(args[1] == "all" and "all" or tonumber(args[1]))
      end,
      complete = function(lead)
        return require("slop.core.util").complete_prefix({ "all" }, lead)
      end,
    },
    list = {
      desc = "list running edits",
      impl = function()
        local reqs = api_tbl.requests()
        if #reqs == 0 then
          log().notify("no edit requests", vim.log.levels.INFO)
          return
        end
        local lines = {}
        for _, r in ipairs(reqs) do
          lines[#lines + 1] = ("#%d [%s] %s: %s"):format(r.id, r.state, r.agent, r.instruction)
        end
        log().notify(table.concat(lines, "\n"), vim.log.levels.INFO)
      end,
    },
  },
  keymaps = {
    edit = {
      mode = { "n", "x" },
      desc = "AI edit",
      rhs = function()
        api_tbl.start()
      end,
    },
    preset = {
      mode = { "n", "x" },
      desc = "AI edit preset",
      rhs = function()
        api_tbl.preset()
      end,
    },
    agent = {
      mode = "n",
      desc = "select AI agent",
      rhs = function()
        api_tbl.pick_agent()
      end,
    },
    cancel = {
      mode = "n",
      desc = "cancel AI edit",
      rhs = function()
        api_tbl.cancel()
      end,
    },
  },
  health = function()
    local h = vim.health
    local c = require("slop.config").get("edit")
    local agent = state.agent or c.agent
    local ok, agents = pcall(function()
      return require("slop.config").get("ai").agents
    end)
    local a = ok and agents and agents[agent]
    if not a then
      h.error(("agent `%s` is not configured in ai.agents"):format(agent))
    else
      local exe = type(a.cmd) == "table" and a.cmd[1] or nil
      if exe and vim.fn.executable(exe) == 1 then
        h.ok(("agent `%s`: `%s` found"):format(agent, exe))
      else
        h.warn(("agent `%s`: `%s` not found in $PATH"):format(agent, tostring(exe)), {
          ("install it or set edit.agent / :Slop edit agent <name> (configured: %s)"):format(
            table.concat(agent_names(), ", ")
          ),
        })
      end
    end
    h.info(
      ("apply = %s, context = %s, presets: %s"):format(
        c.apply,
        c.context,
        table.concat(require("slop.modules.edit.presets").names(c.presets), ", ")
      )
    )
    local acp = package.loaded["slop.services.ai.acp"]
    for _, cl in ipairs(acp and acp.clients() or {}) do
      h.info(("ACP client `%s`: %s%s"):format(cl.agent, cl.state, cl:is_running() and " (running)" or ""))
    end
  end,
  api = api_tbl,
}

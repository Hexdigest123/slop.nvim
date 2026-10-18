--- rest: run .http requests from anywhere in the project (picker, chaining, cookie jar, AI gen/fix).
--- Replaces rest.nvim (ideas only; no code taken from it). OWNER: rest.
---
--- Files: discover (file walk + parse cache), parser (pure), vars (expansion), env (env files), chain (deps),
--- runner (curl), view (result buffer), history (persisted MRU/env/last), api (orchestration), ai (gen/fix).
--- Everything is required lazily so that this spec stays cheap to load.
local function A()
  return require("slop.modules.rest.api")
end

local api = {
  run = function(name)
    A().run_cmd(name)
  end,
  run_cursor = function()
    A().run_cursor()
  end,
  pick = function()
    A().pick()
  end,
  last = function()
    A().last()
  end,
  env = function(name)
    A().env(name)
  end,
  current_env = function()
    return A().current_env()
  end,
  cancel = function()
    return A().cancel()
  end,
  gen = function(opts)
    require("slop.modules.rest.ai").gen(opts)
  end,
  fix = function()
    require("slop.modules.rest.ai").fix()
  end,
  requests = function(root)
    return require("slop.modules.rest.discover").requests(root or A().root())
  end,
  status = function()
    return A().status()
  end,
  parse = function(lines, file)
    return require("slop.modules.rest.parser").parse(lines, file)
  end,
}

local GEN_MODES = { "desc", "code", "openapi" }

---@param cfg table
local function setup(cfg)
  local util = require("slop.core.util")
  local group = util.augroup("rest")
  vim.filetype.add({ extension = { rest = "http" } })
  local pattern = {}
  for _, e in ipairs(cfg.extensions) do
    pattern[#pattern + 1] = "*." .. e
  end
  vim.api.nvim_create_autocmd({ "BufWritePost", "BufNewFile", "BufDelete", "BufFilePost" }, {
    group = group,
    pattern = vim.list_extend({ "http-client.env.json", "http-client.private.env.json" }, pattern),
    desc = "slop: rest invalidate discovery cache",
    callback = function(ev)
      require("slop.modules.rest.discover").invalidate(nil, ev.match)
    end,
  })
  vim.api.nvim_create_autocmd({ "FileType", "BufWritePost", "InsertLeave" }, {
    group = group,
    pattern = vim.list_extend({ "http" }, pattern),
    desc = "slop: rest lint",
    callback = function(ev)
      if vim.bo[ev.buf].filetype == "http" then
        A().lint(ev.buf)
      end
    end,
  })
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(b) and vim.bo[b].filetype == "http" then
      A().lint(b)
    end
  end
end

local function health()
  local h = vim.health
  if vim.fn.executable("curl") == 1 then
    local out = vim.fn.system({ "curl", "--version" })
    local v = out:match("curl (%d+%.%d+)")
    local major, minor = (v or "0.0"):match("(%d+)%.(%d+)")
    if tonumber(major) * 100 + tonumber(minor) >= 775 then
      h.ok("curl " .. (v or "?"))
    else
      h.warn(("curl %s is older than 7.75 (%%{json} / errormsg needed)"):format(v or "?"))
    end
  else
    h.error("curl not found (required)")
  end
  for _, tool in ipairs({ "jq", "xmllint" }) do
    if vim.fn.executable(tool) == 1 then
      h.ok(tool .. " found (pretty-printing)")
    else
      h.info(tool .. " not found (optional pretty-printer)")
    end
  end
  local ok_root, root = pcall(function()
    return require("slop.core.project").root()
  end)
  if ok_root then
    local ok, d = pcall(require("slop.modules.rest.discover").get, root, true)
    if ok then
      h.info(("%d .http/.rest file(s), %d env file(s) under %s"):format(#d.files, #d.env_files, root))
    end
  end
  if pcall(require, "rest-nvim") then
    h.warn("rest.nvim is also installed: its http keymaps may conflict")
  end
  if pcall(require, "kulala") then
    h.warn("kulala.nvim is also installed: its http keymaps may conflict")
  end
  local cfg = require("slop.config").get("rest")
  if cfg.ai.backend == "acp" then
    h.info("AI backend: ACP agent " .. tostring(cfg.ai.agent))
  else
    h.info("AI backend: chat provider " .. tostring(cfg.ai.provider))
  end
end

---@type slop.ModuleSpec
return {
  name = "rest",
  description = "HTTP client for .http files across the project",
  defaults = {
    enabled = true,
    ai = { backend = "chat", provider = "mistral_chat", agent = "vibe", target = "requests.http" }, -- backend "chat" | "acp"
    env_file = ".env", -- nearest file of this name feeds {{VAR}} (false disables)
    process_env = true, -- plain {{VAR}} falls back to the process environment
    cookies = true,
    follow_redirects = true,
    insecure = false,
    timeout = 30000, -- ms (per request: # @timeout)
    extensions = { "http", "rest" },
    skip = {}, -- extra directory names skipped by discovery
    headers = {}, -- default headers added when a request does not set them
    dynamic = {}, -- extra dynamic variables: { name = function(args) return "..." end } -> {{$name args}}
    result = { layout = "vsplit", format = true, focus = false, size = 0.5 },
    keymaps = {
      run = "<leader>rr",
      pick = "<leader>rp",
      last = "<leader>rl",
      env = "<leader>re",
      headers = "H", -- result buffer only
      close = "q", -- result buffer only
      rerun = "r", -- result buffer only
      gen = "<leader>ra",
      fix = "<leader>rx",
      run_cursor = "<CR>", -- http buffers only
    },
  },
  open_keys = { "headers", "dynamic" },
  schema = function(cfg, check)
    check("ai", cfg.ai, "table")
    check("ai.backend", cfg.ai.backend, function(v)
      return v == "chat" or v == "acp"
    end, false, "'chat'|'acp'")
    check("ai.provider", cfg.ai.provider, "string")
    check("ai.agent", cfg.ai.agent, "string")
    check("ai.target", cfg.ai.target, "string")
    check("env_file", cfg.env_file, function(v)
      return v == false or type(v) == "string"
    end, false, "string|false")
    check("process_env", cfg.process_env, "boolean")
    check("cookies", cfg.cookies, "boolean")
    check("follow_redirects", cfg.follow_redirects, "boolean")
    check("insecure", cfg.insecure, "boolean")
    check("timeout", cfg.timeout, function(v)
      return type(v) == "number" and v > 0
    end, false, "positive number (ms)")
    check("extensions", cfg.extensions, "table")
    check("skip", cfg.skip, "table")
    check("headers", cfg.headers, "table")
    check("dynamic", cfg.dynamic, "table")
    check("result", cfg.result, "table")
    check("result.layout", cfg.result.layout, function(v)
      return v == "vsplit" or v == "split" or v == "float" or v == "tab" or v == "current"
    end, false, "'vsplit'|'split'|'float'|'tab'|'current'")
    check("result.format", cfg.result.format, "boolean")
    check("result.focus", cfg.result.focus, "boolean")
    check("result.size", cfg.result.size, "number")
  end,
  setup = setup,
  commands = {
    pick = {
      desc = "pick a request (whole project)",
      default = true,
      impl = function()
        A().pick()
      end,
    },
    run = {
      desc = "run [name] (default: request under the cursor / picker)",
      impl = function(args)
        A().run_cmd(args[1])
      end,
      complete = function(lead)
        local ok, reqs = pcall(function()
          return require("slop.modules.rest.discover").requests(require("slop.core.project").root())
        end)
        local names = {}
        for _, r in ipairs(ok and reqs or {}) do
          if r.name and not r.name:find("%s") then
            names[#names + 1] = r.name
          end
        end
        return require("slop.core.util").complete_prefix(require("slop.core.util").uniq(names), lead)
      end,
    },
    last = {
      desc = "rerun the last request",
      impl = function()
        A().last()
      end,
    },
    env = {
      desc = "env [name|none]",
      impl = function(args)
        A().env(args[1])
      end,
      complete = function(lead)
        local ok, names = pcall(function()
          local root = require("slop.core.project").root()
          local d = require("slop.modules.rest.discover").get(root)
          return require("slop.modules.rest.env").names(d.env_files)
        end)
        return require("slop.core.util").complete_prefix(vim.list_extend({ "none" }, ok and names or {}), lead)
      end,
    },
    cookies = {
      desc = "cookies [clear]: open or clear the cookie jar",
      impl = function(args)
        if args[1] == "clear" then
          A().clear_cookies()
        else
          A().open_cookies()
        end
      end,
      complete = function(lead)
        return require("slop.core.util").complete_prefix({ "clear" }, lead)
      end,
    },
    refresh = {
      desc = "re-scan the project for .http files",
      impl = function()
        require("slop.modules.rest.discover").invalidate()
      end,
    },
    cancel = {
      desc = "cancel the request in flight",
      impl = function()
        A().cancel()
      end,
    },
    open = {
      desc = "show the last result",
      impl = function()
        local last = A().results()
        if last then
          require("slop.modules.rest.view").show(last)
        end
      end,
    },
    gen = {
      desc = "gen [desc|code|openapi [path]] [text]: AI-generate requests",
      impl = function(args, cmd)
        local opts = {}
        if vim.tbl_contains(GEN_MODES, args[1]) then
          opts.mode = table.remove(args, 1)
        end
        if opts.mode == "openapi" and args[1] and vim.uv.fs_stat(vim.fn.expand(args[1])) then
          opts.path = vim.fs.normalize(vim.fn.fnamemodify(vim.fn.expand(table.remove(args, 1)), ":p"))
        end
        if cmd and cmd.range and cmd.range > 0 then
          opts.range = { cmd.line1, cmd.line2 }
          opts.mode = opts.mode or "code"
        end
        opts.text = #args > 0 and table.concat(args, " ") or nil
        require("slop.modules.rest.ai").gen(opts)
      end,
      complete = function(lead, args)
        if #args <= 1 then
          return require("slop.core.util").complete_prefix(GEN_MODES, lead)
        end
        if args[1] == "openapi" then
          return vim.fn.getcompletion(lead, "file")
        end
        return {}
      end,
    },
    fix = {
      desc = "AI-fix the last failed request",
      impl = function()
        require("slop.modules.rest.ai").fix()
      end,
    },
  },
  keymaps = {
    run = {
      mode = "n",
      desc = "run request",
      rhs = function()
        A().run_cmd()
      end,
    },
    pick = {
      mode = "n",
      desc = "pick request",
      rhs = function()
        A().pick()
      end,
    },
    last = {
      mode = "n",
      desc = "rerun last request",
      rhs = function()
        A().last()
      end,
    },
    env = {
      mode = "n",
      desc = "select rest env",
      rhs = function()
        A().env()
      end,
    },
    gen = {
      mode = "n",
      desc = "AI generate request",
      rhs = function()
        require("slop.modules.rest.ai").gen()
      end,
    },
    fix = {
      mode = "n",
      desc = "AI fix request",
      rhs = function()
        require("slop.modules.rest.ai").fix()
      end,
    },
    headers = {
      mode = "n",
      buffer = true,
      desc = "toggle response headers",
      rhs = function()
        require("slop.modules.rest.view").toggle_headers()
      end,
    },
    close = {
      mode = "n",
      buffer = true,
      desc = "close rest result",
      rhs = function()
        require("slop.modules.rest.view").close()
      end,
    },
    rerun = {
      mode = "n",
      buffer = true,
      desc = "rerun rest request",
      rhs = function()
        A().rerun_view()
      end,
    },
    run_cursor = {
      mode = "n",
      ft = { "http" },
      desc = "run request under cursor",
      rhs = function()
        A().run_cursor()
      end,
    },
  },
  highlights = {
    SlopRestOk = { link = "DiagnosticOk" },
    SlopRestWarn = { link = "DiagnosticWarn" },
    SlopRestError = { link = "DiagnosticError" },
    SlopRestRunning = { link = "DiagnosticInfo" },
    SlopRestMethod = { link = "Keyword" },
    SlopRestFile = { link = "Directory" },
    SlopRestStatus = { link = "Title" },
    SlopRestHeaderName = { link = "Identifier" },
    SlopRestHeaderValue = { link = "String" },
  },
  health = health,
  api = api,
}

--- rest: run .http requests from anywhere in the project (picker, chaining, cookie jar, AI gen/fix).
--- Replaces rest.nvim. OWNER: rest. STATUS: stub spec (defaults from plan §2.4); not implemented yet.
local function todo(what)
  return function()
    require("slop.core.log").notify("slop: rest: " .. what .. " not implemented yet", vim.log.levels.WARN)
  end
end

---@type slop.ModuleSpec
return {
  name = "rest",
  description = "HTTP client for .http files across the project",
  defaults = {
    enabled = true,
    ai = { backend = "chat", provider = "mistral_chat", agent = "vibe" }, -- backend "chat" | "acp"
    env_file = ".env",
    cookies = true,
    follow_redirects = true,
    timeout = 30000,
    result = { layout = "vsplit", format = true },
    keymaps = {
      run = "<leader>rr",
      pick = "<leader>rp",
      last = "<leader>rl",
      env = "<leader>re",
      headers = "H", -- result buffer only
      gen = "<leader>ra",
      fix = "<leader>rx",
      run_cursor = "<CR>", -- http buffers only
    },
  },
  setup = function(_) end,
  keymaps = {
    run = { mode = "n", desc = "run request", rhs = todo("run") },
    pick = { mode = "n", desc = "pick request", rhs = todo("pick") },
    last = { mode = "n", desc = "rerun last request", rhs = todo("last") },
    env = { mode = "n", desc = "select rest env", rhs = todo("env") },
    gen = { mode = "n", desc = "AI generate request", rhs = todo("gen") },
    fix = { mode = "n", desc = "AI fix request", rhs = todo("fix") },
    headers = { mode = "n", buffer = true, desc = "toggle response headers", rhs = todo("headers") },
    run_cursor = { mode = "n", ft = { "http" }, desc = "run request under cursor", rhs = todo("run_cursor") },
  },
}

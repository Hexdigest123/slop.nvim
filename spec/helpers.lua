-- Shared test helpers: `local h = require("helpers")`.
local M = {}

M.root = vim.fs.dirname(vim.fs.dirname(vim.fs.normalize(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))))

--- Unload every slop Lua module, clear slop augroups/keymaps/commands and globals.
function M.reset()
  for name in pairs(package.loaded) do
    if name == "slop" or name:match("^slop%.") then
      package.loaded[name] = nil
    end
  end
  for _, ac in ipairs(vim.api.nvim_get_autocmds({})) do
    if ac.group_name and ac.group_name:match("^slop") then
      pcall(vim.api.nvim_del_augroup_by_name, ac.group_name)
    end
  end
  for _, mode in ipairs({ "n", "x", "i", "t", "o", "s" }) do
    for _, m in ipairs(vim.api.nvim_get_keymap(mode)) do
      if
        (m.desc and m.desc:match("^slop"))
        or (m.rhs and m.rhs:match("<Plug>%(slop"))
        or m.lhs:match("<Plug>%(slop")
      then
        pcall(vim.keymap.del, mode, m.lhs)
      end
    end
  end
  pcall(vim.api.nvim_del_user_command, "Slop")
  vim.g.loaded_slop = nil
  vim.g.slop = nil
end

--- Source plugin/slop.lua fresh.
function M.source_plugin()
  vim.g.loaded_slop = nil
  vim.cmd.source(M.root .. "/plugin/slop.lua")
end

--- Fresh temp directory (removed by the runner when the child exits).
---@param name? string
---@return string
function M.tmpdir(name)
  local base = os.getenv("SLOP_TEST_TMP") or vim.fn.tempname()
  local dir = vim.fs.joinpath(base, (name or "tmp") .. "-" .. tostring(vim.uv.hrtime()))
  vim.fn.mkdir(dir, "p")
  return vim.fs.normalize(vim.fn.resolve(dir))
end

---@param path string
---@param text string
function M.write(path, text)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local f = assert(io.open(path, "w"))
  f:write(text)
  f:close()
end

---@param path string
---@return string?
function M.read(path)
  local f = io.open(path, "r")
  if not f then
    return nil
  end
  local s = f:read("*a")
  f:close()
  return s
end

--- Feed keys and process them (like typing). Modes default to "x" (execute immediately).
---@param keys string
---@param mode? string
function M.feed(keys, mode)
  vim.api.nvim_feedkeys(vim.keycode(keys), mode or "mtx", false)
end

--- Names of loaded slop Lua modules.
---@return string[]
function M.loaded()
  local out = {}
  for name in pairs(package.loaded) do
    if name == "slop" or name:match("^slop%.") then
      out[#out + 1] = name
    end
  end
  table.sort(out)
  return out
end

--- Run a separate nvim (`--clean`, slop on rtp) and return its stdout. `lua` is executed after startup
--- (VimEnter); print results with io.stdout:write.
---@param lua string
---@param opts? {cmd?: string[], init?: string}
---@return string stdout, integer code
function M.nvim(lua, opts)
  opts = opts or {}
  local script = vim.fn.tempname() .. ".lua"
  M.write(script, lua)
  local cmd = { vim.v.progpath, "--headless", "--clean", "--cmd", "set rtp^=" .. M.root }
  if opts.init then
    local init = vim.fn.tempname() .. ".lua"
    M.write(init, opts.init)
    vim.list_extend(cmd, { "--cmd", "luafile " .. init })
  end
  -- run after startup has fully completed (VimEnter fires after -c commands)
  local run = (
    "lua vim.schedule(function() local ok, e = pcall(dofile, %q) "
    .. "if not ok then io.stdout:write('ERR=' .. tostring(e) .. '\\n') end vim.cmd('qa!') end)"
  ):format(script)
  vim.list_extend(cmd, { "-c", run })
  local res = vim.system(cmd, { text = true }):wait(30000)
  return (res.stdout or "") .. (res.stderr or ""), res.code
end

return M

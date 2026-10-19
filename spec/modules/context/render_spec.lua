-- context floats: what is shown, gutter, highlights, leftcol, lifecycle, commands, go_to_context.
local h = require("helpers")

local api = vim.api

local function screen_row(r, cols)
  local t = {}
  for c = 1, cols or 40 do
    t[#t + 1] = vim.fn.screenstring(r, c)
  end
  return (table.concat(t):gsub("%s+$", ""))
end

local function redraw()
  vim.cmd("redraw!")
  vim.cmd("redraw")
end

-- 1 local M = {} / 3-4 two-row signature / 5 if / 6.. body / for at 30
local LUA = { "local M = {}", "", "function M.outer(a,", "  b)", "  if a then" }
for i = 1, 24 do
  LUA[#LUA + 1] = "    print(" .. i .. ")"
end
vim.list_extend(LUA, { "    for i = 1, 3 do" })
for i = 1, 20 do
  LUA[#LUA + 1] = "      x(" .. i .. ")"
end
vim.list_extend(LUA, { "    end", "  end", "end", "return M" })

describe("context render", function()
  local dir, ctx
  before_each(function()
    h.reset()
    vim.notify = function() end
    vim.cmd("silent! %bwipe!")
    vim.cmd("silent! only")
    h.source_plugin()
    dir = h.tmpdir("context")
  end)
  after_each(function()
    pcall(function()
      require("slop.core.registry").disable("context")
    end)
    vim.cmd("silent! %bwipe!")
  end)

  local function open(lines, ft, opts)
    require("slop").setup({ context = opts or {} })
    local path = dir .. "/f." .. (ft == "lua" and "lua" or ft)
    h.write(path, table.concat(lines, "\n") .. "\n")
    vim.cmd.edit(vim.fn.fnameescape(path))
    local buf = api.nvim_get_current_buf()
    vim.bo[buf].filetype = ft
    if ft ~= "" then
      vim.treesitter.start(buf, ft)
    end
    vim.wo.number = true
    vim.wo.relativenumber = false
    vim.wo.signcolumn = "no"
    vim.wo.wrap = false
    ctx = require("slop").context
    return buf
  end

  --- Scroll so `top` is the first line, put the cursor on `lnum`, refresh.
  local function view(top, lnum, col)
    vim.fn.winrestview({ topline = top, lnum = lnum, col = col or 0, leftcol = 0 })
    ctx.refresh()
    redraw()
  end

  local function wstate()
    return require("slop.modules.context.render")._state.wins[api.nvim_get_current_win()]
  end

  local function float_lines()
    local st = wstate()
    if not st or not st.fwin or not api.nvim_win_is_valid(st.fwin) then
      return {}
    end
    return api.nvim_buf_get_lines(st.buf, 0, -1, false)
  end

  local function gutter_lines()
    local st = wstate()
    return api.nvim_buf_get_lines(st.gbuf, 0, -1, false)
  end

  it("shows the hidden scope headers over the text area, numbers over the gutter", function()
    open(LUA, "lua")
    view(15, 25, 4)
    assert.are.same({ "function M.outer(a,", "  b)", "  if a then" }, float_lines())
    assert.are.same({ { row = 2, col = 0, rows = 2 }, { row = 4, col = 2, rows = 1 } }, ctx.contexts())
    assert.are.same({ "  3 function M.outer(a,", "  4   b)", "  5   if a then", " 18     print(13)" }, {
      screen_row(1),
      screen_row(2),
      screen_row(3),
      screen_row(4),
    })
    local st = wstate()
    local cfg = api.nvim_win_get_config(st.fwin)
    assert.equal("win", cfg.relative)
    assert.equal(api.nvim_get_current_win(), cfg.win)
    assert.equal(4, cfg.col)
    assert.equal(3, cfg.height)
    assert.equal(20, cfg.zindex)
    assert.is_false(cfg.focusable)
    assert.equal(4, api.nvim_win_get_config(st.gwin).width)
    assert.are.same({ "  3 ", "  4 ", "  5 " }, gutter_lines())
    assert.equal(dir .. "/f.lua", vim.b[st.buf].slop_secret_path)
  end)

  it("nothing while the scope starts are visible; never covers the cursor line", function()
    open(LUA, "lua")
    view(1, 10)
    assert.are.same({}, float_lines())
    view(15, 15) -- cursor on the topline
    assert.are.same({}, float_lines())
    view(15, 16) -- one row above the cursor
    assert.are.same({ "  if a then" }, float_lines())
  end)

  it("max_lines + trim_scope, multiline_threshold", function()
    open(LUA, "lua")
    view(40, 45, 6)
    assert.are.same({ "  if a then", "    for i = 1, 3 do" }, float_lines(), "whole outer scope dropped")
    require("slop").setup({ context = { trim_scope = "inner" } })
    view(40, 45, 6)
    assert.are.same({ "function M.outer(a,", "  b)", "  if a then" }, float_lines())
    require("slop").setup({ context = { max_lines = 0, multiline_threshold = 1 } })
    view(40, 45, 6)
    assert.are.same({ "function M.outer(a,", "  if a then", "    for i = 1, 3 do" }, float_lines())
    require("slop").setup({ context = { max_lines = 0 } })
    view(40, 45, 6)
    assert.equal(4, #float_lines())
  end)

  it("topline mode follows the first line below the float, not the cursor", function()
    open(LUA, "lua", { mode = "topline" })
    view(32, 50, 0) -- top inside the for loop, cursor far below
    assert.are.same({ "  if a then", "    for i = 1, 3 do" }, float_lines())
    require("slop").setup({ context = { mode = "topline", max_lines = 0 } })
    view(32, 50, 0)
    assert.are.same({ "function M.outer(a,", "  b)", "  if a then", "    for i = 1, 3 do" }, float_lines())
    view(1, 10)
    assert.are.same({}, float_lines())
  end)

  it("copies treesitter captures and extmark highlights; underline on the last row", function()
    local buf = open(LUA, "lua")
    local mine = api.nvim_create_namespace("context-spec")
    api.nvim_buf_set_extmark(buf, mine, 4, 5, { end_col = 6, hl_group = "ErrorMsg", priority = 300 })
    view(15, 25, 4)
    local st = wstate()
    local marks = api.nvim_buf_get_extmarks(st.buf, -1, 0, -1, { details = true })
    local found = {}
    for _, m in ipairs(marks) do
      found[("%d:%d-%d %s"):format(m[2], m[3], m[4].end_col or -1, m[4].hl_group)] = m[4]
    end
    assert.truthy(found["0:0-8 @keyword.function.lua"] or found["0:0-8 @keyword.lua"], vim.inspect(vim.tbl_keys(found)))
    assert.truthy(found["2:5-6 ErrorMsg"], "extmark highlight of the source row copied")
    local bottom = found["2:0-0 SlopContextBottom"]
    assert.truthy(bottom)
    assert.is_true(bottom.hl_eol)
    -- priorities are re-ranked but keep their order: ErrorMsg (300) above treesitter (100)
    local kw = found["0:0-8 @keyword.function.lua"] or found["0:0-8 @keyword.lua"]
    assert.truthy(found["2:5-6 ErrorMsg"].priority > kw.priority)
    -- the float buffer is never parsed
    assert.is_nil(vim.treesitter.highlighter.active[st.buf])
    assert.equal("", vim.bo[st.buf].filetype)
  end)

  it("separator: bottom-only border on both floats, no underline", function()
    open(LUA, "lua", { separator = "─" })
    view(15, 25, 4)
    local st = wstate()
    local b = api.nvim_win_get_config(st.fwin).border
    assert.are.same({ "", "", "", "", "─", "─", "─", "" }, b)
    assert.are.same(b, api.nvim_win_get_config(st.gwin).border)
    for _, m in ipairs(api.nvim_buf_get_extmarks(st.buf, -1, 0, -1, { details = true })) do
      assert.not_equal("SlopContextBottom", m[4].hl_group)
    end
    assert.equal("──────", screen_row(4):sub(1, #"──────"))
  end)

  it("gutter: relativenumber, signcolumn width, statuscolumn, line_numbers = false", function()
    open(LUA, "lua")
    vim.wo.relativenumber = true
    vim.wo.signcolumn = "yes:1"
    view(15, 25, 4)
    assert.are.same({ "   22 ", "   21 ", "   20 " }, gutter_lines())
    vim.wo.relativenumber = false
    vim.wo.statuscolumn = "%l|"
    view(15, 25, 4)
    assert.are.same({ "3|", "4|", "5|" }, vim.tbl_map(vim.trim, gutter_lines()))
    vim.wo.statuscolumn = ""
    require("slop").setup({ context = { line_numbers = false } })
    view(15, 25, 4)
    local st = wstate()
    assert.falsy(st.gwin and api.nvim_win_is_valid(st.gwin))
    assert.equal(3, #float_lines())
  end)

  it("mirrors the window's leftcol", function()
    local lines = vim.deepcopy(LUA)
    lines[5] = "  if a and " .. ("x"):rep(100) .. " then"
    lines[25] = "    print(" .. ("y"):rep(100) .. ")"
    open(lines, "lua")
    vim.fn.winrestview({ topline = 15, lnum = 25, col = 60, leftcol = 30 })
    ctx.refresh()
    redraw()
    local st = wstate()
    local lc = api.nvim_win_call(st.fwin, function()
      return vim.fn.winsaveview().leftcol
    end)
    assert.equal(30, lc)
    assert.equal(("x"):rep(36), screen_row(3, 40):sub(5))
  end)

  it("C: function, if and else-if headers", function()
    local lines = { "int f(int a, int b) {", "  if (a) {", "    a++;", "  } else if (b) {" }
    for i = 1, 30 do
      lines[#lines + 1] = "    b += " .. i .. ";"
    end
    vim.list_extend(lines, { "  }", "  return a;", "}" })
    open(lines, "c")
    view(20, 25, 4)
    assert.are.same({ "int f(int a, int b) {", "  if (a) {", "  } else if (b) {" }, float_lines())
  end)

  it("hidden: no parser, special buftype, float, small window, vim.b.slop_context, WinLeave", function()
    local buf = open(LUA, "lua")
    view(15, 25, 4)
    assert.equal(3, #float_lines())
    vim.b[buf].slop_context = false
    view(15, 25, 4)
    assert.are.same({}, float_lines())
    vim.b[buf].slop_context = nil
    view(15, 25, 4)
    assert.equal(3, #float_lines())
    -- WinLeave closes, WinClosed frees
    local win = api.nvim_get_current_win()
    vim.cmd("new")
    local R = require("slop.modules.context.render")
    assert.falsy(R._state.wins[win].fwin, "closed on WinLeave")
    vim.bo.buftype = "nofile"
    assert.equal("buftype nofile", R.hidden(api.nvim_get_current_win()))
    vim.cmd("close")
    assert.equal(win, api.nvim_get_current_win())
    vim.cmd("vsplit")
    local other = api.nvim_get_current_win()
    view(15, 25, 4)
    assert.equal(3, #float_lines())
    vim.cmd("close")
    assert.is_nil(R._state.wins[other], "freed on WinClosed")
    -- min_window_height
    require("slop").setup({ context = { min_window_height = 100 } })
    view(15, 25, 4)
    assert.are.same({}, float_lines())
    assert.equal("window too small", R.hidden(win))
    require("slop").setup({ context = {} })
    -- floats never get one
    local fb = api.nvim_create_buf(false, true)
    local fw = api.nvim_open_win(fb, false, { relative = "editor", row = 1, col = 1, width = 10, height = 5 })
    assert.equal("floating window", R.hidden(fw))
    api.nvim_win_close(fw, true)
    -- no parser
    open({ "a", "b", "c" }, "")
    for i = 1, 60 do
      api.nvim_buf_set_lines(0, -1, -1, false, { "line " .. i })
    end
    view(30, 35)
    assert.are.same({}, float_lines())
  end)

  it("updates from autocmds (scrolling) and toggles via :Slop context", function()
    open(LUA, "lua")
    ctx.refresh()
    vim.fn.winrestview({ topline = 15, lnum = 25, col = 4 })
    vim.api.nvim_exec_autocmds("WinScrolled", { pattern = tostring(api.nvim_get_current_win()) })
    vim.wait(200, function()
      return #float_lines() > 0
    end)
    assert.equal(3, #float_lines())
    vim.cmd("Slop context toggle")
    assert.is_false(ctx.is_enabled())
    assert.are.same({}, float_lines())
    vim.cmd("Slop context enable")
    assert.is_true(ctx.is_enabled())
    assert.equal(3, #float_lines())
    vim.cmd("Slop context disable")
    assert.are.same({}, float_lines())
    vim.cmd("Slop context")
    assert.equal(3, #float_lines())
    -- teardown closes everything
    local fwin = wstate().fwin
    require("slop.core.registry").disable("context")
    assert.is_false(api.nvim_win_is_valid(fwin))
  end)

  it("go_to_context climbs scopes (count = depth), with a jumplist entry", function()
    open(LUA, "lua")
    vim.fn.winrestview({ topline = 40, lnum = 45, col = 6 })
    assert.is_true(ctx.go_to_context())
    assert.are.same({ 30, 4 }, api.nvim_win_get_cursor(0))
    assert.is_true(ctx.go_to_context())
    assert.are.same({ 5, 2 }, api.nvim_win_get_cursor(0))
    vim.cmd("normal! ``")
    assert.are.same({ 30, 4 }, api.nvim_win_get_cursor(0))
    api.nvim_win_set_cursor(0, { 45, 6 })
    vim.cmd("Slop context goto 3")
    assert.are.same({ 3, 0 }, api.nvim_win_get_cursor(0))
    assert.is_false(ctx.go_to_context(), "nothing above the outermost scope")
    -- <Plug> mapping exists, no default lhs
    assert.truthy(vim.fn.maparg("<Plug>(slop-context-jump)", "n") ~= "")
  end)

  it("cloak masks secrets in the float (it carries the source path)", function()
    local lines = vim.deepcopy(LUA)
    lines[3] = "function M.outer(a, -- token=hunter22"
    open(lines, "lua", {})
    require("slop").setup({
      context = {},
      cloak = { patterns = { { file_pattern = "*.lua", cloak_pattern = "=.+" } } },
    })
    require("slop").load("cloak")
    view(15, 25, 4)
    assert.equal("function M.outer(a, -- token=hunter22", float_lines()[1])
    local row = screen_row(1, 60)
    assert.falsy(row:find("hunter22", 1, true), row)
    assert.matches("token=%*+", row)
    pcall(function()
      require("slop.core.registry").disable("cloak")
    end)
  end)

  it("health section", function()
    open(LUA, "lua")
    local out = {}
    local orig = vim.health
    vim.health = setmetatable({}, {
      __index = function(_, k)
        return function(msg)
          out[#out + 1] = k .. ": " .. msg
        end
      end,
    })
    local ok, err = pcall(require("slop.core.registry").spec("context").health)
    vim.health = orig
    assert.is_true(ok, err)
    local text = table.concat(out, "\n")
    assert.matches("ok: parsers with context node types: [^\n]*c, [^\n]*lua", text)
    assert.matches("open filetypes with a parser: lua", text)
  end)
end)

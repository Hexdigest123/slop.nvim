local h = require("helpers")

local api = vim.api

describe("marks module", function()
  local slop, root, notes, events

  local function state_file()
    return root .. "/.nvim/state/marks/marks.json"
  end

  local function stored()
    local data = assert(require("slop.core.project").read_json(state_file()))
    return vim.tbl_map(function(e)
      return e.path
    end, data.marks)
  end

  local function edit(rel)
    vim.cmd.edit(vim.fn.fnameescape(root .. "/" .. rel))
  end

  local function warned(pat)
    for _, n in ipairs(notes) do
      if n.msg:find(pat) and n.level == vim.log.levels.WARN then
        return true
      end
    end
    return false
  end

  before_each(function()
    h.reset()
    notes = {}
    vim.notify = function(msg, level)
      notes[#notes + 1] = { msg = msg, level = level }
    end
    pcall(vim.cmd, "silent! tabonly")
    pcall(vim.cmd, "silent! only")
    pcall(vim.cmd, "silent! %bwipeout!")
    vim.o.columns, vim.o.lines = 120, 40
    root = h.tmpdir("proj")
    vim.fn.mkdir(root .. "/.git", "p")
    for _, f in ipairs({ "a.lua", "b.lua", "c.lua", "sub/d.lua" }) do
      h.write(root .. "/" .. f, table.concat({ "line 1", "line 2", "line 3", "line 4", "line 5 is longer" }, "\n"))
    end
    vim.cmd.cd(root)
    h.source_plugin()
    slop = require("slop")
    slop.setup({})
    events = {}
    require("slop.core.events").on("marks", "Changed", function(data)
      events[#events + 1] = data
    end)
  end)

  it("is a valid module, lazy until used", function()
    local registry = require("slop.core.registry")
    local spec = assert(registry.spec("marks"))
    assert.are.same({}, registry.validate_spec(spec, "marks"))
    assert.are.same({}, require("slop.config").errors("marks"))
    assert.is_false(registry.is_loaded("marks"))
    assert.is_nil(package.loaded["slop.modules.marks.store"])
  end)

  it("adds the current file relative to the root, atomically, gitignored", function()
    edit("sub/d.lua")
    api.nvim_win_set_cursor(0, { 3, 2 })
    assert.equal(1, slop.marks.add())
    assert.are.same({ "sub/d.lua" }, stored())
    local data = require("slop.core.project").read_json(state_file())
    assert.equal(3, data.marks[1].row)
    assert.equal(2, data.marks[1].col)
    assert.equal(1, data.version)
    assert.equal("state/\n", h.read(root .. "/.nvim/.gitignore"))
    assert.equal(0, #vim.fn.glob(state_file() .. ".tmp.*", false, true))
    assert.are.same({ root = root, count = 1, action = "add" }, events[1])
    -- duplicate: same index, no new entry, no event
    assert.equal(1, slop.marks.add())
    assert.are.same({ "sub/d.lua" }, stored())
    assert.equal(1, #events)
  end)

  it("adds explicit paths: relative to cwd, absolute outside the root", function()
    slop.marks.add("b.lua")
    local outside = h.tmpdir("elsewhere") .. "/x.lua"
    h.write(outside, "x")
    slop.marks.add(outside)
    assert.are.same({ "b.lua", outside }, stored())
    local list = slop.marks.list()
    assert.equal(root .. "/b.lua", list[1].file)
    assert.equal(outside, list[2].file)
    assert.equal(1, list[1].row)
  end)

  it("refuses non-file buffers", function()
    vim.cmd("enew")
    vim.bo.buftype = "nofile"
    assert.is_nil(slop.marks.add())
    assert.truthy(warned("not a file"))
  end)

  it("removes the current file or a path", function()
    slop.marks.add("a.lua")
    slop.marks.add("b.lua")
    slop.marks.add("c.lua")
    edit("b.lua")
    assert.is_true(slop.marks.remove())
    assert.are.same({ "a.lua", "c.lua" }, stored())
    assert.is_true(slop.marks.remove("c.lua"))
    assert.is_false(slop.marks.remove("c.lua"))
    assert.are.same({ "a.lua" }, stored())
    assert.equal("remove", events[#events].action)
    slop.marks.clear()
    assert.are.same({}, stored())
    assert.are.same({ root = root, count = 0, action = "clear" }, events[#events])
  end)

  it("select(i) opens the file at the remembered cursor", function()
    edit("a.lua")
    api.nvim_win_set_cursor(0, { 4, 3 })
    slop.marks.add()
    slop.marks.add("b.lua")
    vim.cmd("enew")
    assert.is_true(slop.marks.select(1))
    assert.equal(root .. "/a.lua", api.nvim_buf_get_name(0))
    assert.are.same({ 4, 3 }, api.nvim_win_get_cursor(0))
    assert.is_true(slop.marks.select(2))
    assert.equal(root .. "/b.lua", api.nvim_buf_get_name(0))
    assert.are.same({ 1, 0 }, api.nvim_win_get_cursor(0))
  end)

  it("select(i) out of range or on a deleted file notifies without crashing", function()
    assert.is_false(slop.marks.select(1))
    assert.truthy(warned("no marks"))
    slop.marks.add("a.lua")
    assert.is_false(slop.marks.select(5))
    assert.truthy(warned("no mark 5 %(1 mark%)"))
    slop.marks.add("gone.lua")
    assert.is_false(slop.marks.select(2))
    assert.truthy(warned("file not found: gone.lua"))
    assert.are.same({ "a.lua", "gone.lua" }, stored())
  end)

  it("remembers the cursor on BufLeave and writes it on VimLeavePre", function()
    slop.marks.add("a.lua")
    slop.marks.add("b.lua")
    slop.marks.select(1)
    api.nvim_win_set_cursor(0, { 5, 4 })
    slop.marks.select(2) -- BufLeave of a.lua
    slop.marks.select(1)
    assert.are.same({ 5, 4 }, api.nvim_win_get_cursor(0))
    api.nvim_win_set_cursor(0, { 2, 1 })
    api.nvim_exec_autocmds("VimLeavePre", { group = "slop.marks" })
    local data = require("slop.core.project").read_json(state_file())
    assert.are.same({ 2, 1 }, { data.marks[1].row, data.marks[1].col })
    -- clamped when the file shrank
    h.write(root .. "/a.lua", "only\n")
    vim.cmd("enew!")
    vim.cmd("bwipeout! " .. vim.fn.bufnr(root .. "/a.lua"))
    assert.is_true(slop.marks.select(1))
    assert.are.same({ 1, 1 }, api.nvim_win_get_cursor(0))
  end)

  it("next/prev cycle from the current file, wrapping", function()
    for _, f in ipairs({ "a.lua", "b.lua", "c.lua" }) do
      slop.marks.add(f)
    end
    vim.cmd("enew")
    assert.is_true(slop.marks.next())
    assert.equal(root .. "/a.lua", api.nvim_buf_get_name(0))
    slop.marks.next()
    assert.equal(root .. "/b.lua", api.nvim_buf_get_name(0))
    slop.marks.prev()
    slop.marks.prev()
    assert.equal(root .. "/c.lua", api.nvim_buf_get_name(0))
    slop.setup({ marks = { wrap = false } })
    assert.is_false(slop.marks.next())
    assert.equal(root .. "/c.lua", api.nvim_buf_get_name(0))
  end)

  it("reads a missing file as empty without creating .nvim; tolerates a corrupt file", function()
    assert.are.same({}, slop.marks.list())
    assert.is_nil(vim.uv.fs_stat(root .. "/.nvim"))
    h.write(state_file(), "{ not json")
    package.loaded["slop.modules.marks.store"].reset()
    assert.are.same({}, slop.marks.list())
    assert.truthy(warned("unreadable marks file"))
    slop.marks.add("a.lua")
    assert.are.same({ "a.lua" }, stored())
    assert.equal("{ not json", h.read(state_file() .. ".bak"))
    -- bad entries are skipped, bare strings accepted
    h.write(
      state_file(),
      vim.json.encode({ marks = { "b.lua", { path = 3 }, { path = "c.lua", row = "x" }, "b.lua" } })
    )
    local list = slop.marks.list()
    assert.are.same(
      { "b.lua", "c.lua" },
      vim.tbl_map(function(e)
        return e.path
      end, list)
    )
    assert.equal(1, list[2].row)
  end)

  it("picks up changes written by another instance, keeping unsaved cursors", function()
    slop.marks.add("a.lua")
    slop.marks.select(1)
    api.nvim_win_set_cursor(0, { 3, 0 })
    vim.cmd("enew") -- BufLeave: in-memory cursor
    require("slop.core.project").write_json(state_file(), {
      version = 1,
      marks = { { path = "c.lua", row = 2, col = 0 }, { path = "a.lua", row = 1, col = 0 } },
    })
    assert.are.same(
      { "c.lua", "a.lua" },
      vim.tbl_map(function(e)
        return e.path
      end, slop.marks.list())
    )
    assert.equal(3, slop.marks.list()[2].row)
    slop.marks.add("b.lua")
    local data = require("slop.core.project").read_json(state_file())
    assert.are.same({ "c.lua", "a.lua", "b.lua" }, stored())
    assert.equal(3, data.marks[2].row)
  end)

  it("falls back to stdpath('data') keyed by cwd without a project root", function()
    local dir = h.tmpdir("loose")
    h.write(dir .. "/f.txt", "f")
    vim.cmd.cd(dir)
    slop.marks.add("f.txt")
    local file = slop.marks.file()
    assert.equal(vim.fn.stdpath("data") .. "/slop/marks/" .. dir:gsub("/", "%%") .. ".json", file)
    local data = require("slop.core.project").read_json(file)
    assert.equal("f.txt", data.marks[1].path)
    assert.is_nil(vim.uv.fs_stat(dir .. "/.nvim"))
  end)

  it("scope = 'buffer' uses the current buffer's project", function()
    local other = h.tmpdir("other")
    vim.fn.mkdir(other .. "/.git", "p")
    h.write(other .. "/o.lua", "o")
    slop.setup({ marks = { scope = "buffer" } })
    vim.cmd.edit(other .. "/o.lua")
    slop.marks.add()
    assert.equal(other .. "/.nvim/state/marks/marks.json", slop.marks.file())
    assert.equal("o.lua", slop.marks.list()[1].path)
    edit("a.lua")
    assert.are.same({}, slop.marks.list())
    slop.setup({ marks = { scope = "cwd" } })
    vim.cmd.edit(other .. "/o.lua")
    assert.are.same({}, slop.marks.list())
  end)

  describe("menu", function()
    local function menu_win()
      for _, w in ipairs(api.nvim_list_wins()) do
        if vim.bo[api.nvim_win_get_buf(w)].filetype == "slopmarks" then
          return w
        end
      end
    end

    local function labels(buf)
      local out = {}
      local ns = api.nvim_get_namespaces()["slop.marks"]
      for _, m in ipairs(api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
        out[m[2] + 1] = table.concat(vim.tbl_map(function(c)
          return c[1]
        end, m[4].virt_text))
      end
      return out
    end

    before_each(function()
      for _, f in ipairs({ "a.lua", "b.lua", "c.lua" }) do
        slop.marks.add(f)
      end
      events = {}
      edit("b.lua")
    end)

    it("shows one path per line in a bordered float with select-key labels", function()
      slop.marks.toggle_menu()
      local win = assert(menu_win())
      assert.equal(win, api.nvim_get_current_win())
      local buf = api.nvim_win_get_buf(win)
      assert.are.same({ "a.lua", "b.lua", "c.lua" }, api.nvim_buf_get_lines(buf, 0, -1, false))
      local c = api.nvim_win_get_config(win)
      assert.equal("editor", c.relative)
      assert.equal("╭", c.border[1])
      assert.matches("marks: proj", c.title[1][1])
      assert.matches("<CR> open", c.footer[1][1])
      assert.are.same({ 2, 0 }, api.nvim_win_get_cursor(win)) -- the current file
      assert.are.same({ "1  <leader>1", "2  <leader>2", "3  <leader>3" }, labels(buf))
      assert.equal(1, vim.fn.maparg("<CR>", "n", false, true).buffer)
      -- labels follow edits; missing files are flagged
      api.nvim_buf_set_lines(buf, 0, 1, false, { "", "gone.lua" })
      api.nvim_exec_autocmds("TextChanged", { buffer = buf })
      assert.are.same({ [2] = "missing 1  <leader>1", [3] = "2  <leader>2", [4] = "3  <leader>3" }, labels(buf))
      slop.marks.toggle_menu()
      assert.is_nil(menu_win())
      assert.are.same({ "gone.lua", "b.lua", "c.lua" }, stored())
    end)

    it("saves reorders and deletions on q, keeping cursor memory", function()
      slop.marks.toggle_menu()
      local buf = api.nvim_get_current_buf()
      api.nvim_buf_set_lines(buf, 0, -1, false, { "c.lua", "  a.lua  ", "c.lua", "" })
      h.feed("q")
      assert.is_nil(menu_win())
      assert.are.same({ "c.lua", "a.lua" }, stored())
      assert.are.same({ root = root, count = 2, action = "menu" }, events[#events])
      assert.equal(root .. "/b.lua", api.nvim_buf_get_name(0))
    end)

    it("does not write when nothing changed", function()
      local before = vim.uv.fs_stat(state_file()).mtime
      slop.marks.toggle_menu()
      h.feed("<Esc>")
      assert.is_nil(menu_win())
      assert.are.same(before, vim.uv.fs_stat(state_file()).mtime)
      assert.equal(0, #events)
    end)

    it("saves when focus leaves the menu", function()
      slop.marks.toggle_menu()
      local buf = api.nvim_get_current_buf()
      api.nvim_buf_set_lines(buf, 0, -1, false, { "b.lua" })
      vim.cmd("wincmd p")
      vim.wait(200, function()
        return menu_win() == nil
      end)
      assert.is_nil(menu_win())
      assert.are.same({ "b.lua" }, stored())
    end)

    it("<CR> opens the entry under the cursor; <C-v>/<C-x>/<C-t> open in splits/tabs", function()
      slop.marks.toggle_menu()
      api.nvim_win_set_cursor(0, { 3, 0 })
      h.feed("<CR>")
      assert.is_nil(menu_win())
      assert.equal(root .. "/c.lua", api.nvim_buf_get_name(0))
      assert.equal(1, #api.nvim_tabpage_list_wins(0))

      slop.marks.toggle_menu()
      api.nvim_win_set_cursor(0, { 1, 0 })
      h.feed("<C-v>")
      assert.equal("row", vim.fn.winlayout()[1])
      assert.equal(root .. "/a.lua", api.nvim_buf_get_name(0))
      vim.cmd("only")

      slop.marks.toggle_menu()
      api.nvim_win_set_cursor(0, { 2, 0 })
      h.feed("<C-x>")
      assert.equal("col", vim.fn.winlayout()[1])
      assert.equal(root .. "/b.lua", api.nvim_buf_get_name(0))
      vim.cmd("only")

      slop.marks.toggle_menu()
      h.feed("<C-t>")
      assert.equal(2, vim.fn.tabpagenr("$"))
      assert.equal(root .. "/b.lua", api.nvim_buf_get_name(0))
    end)

    it("<CR> uses the edited order", function()
      slop.marks.toggle_menu()
      local buf = api.nvim_get_current_buf()
      api.nvim_buf_set_lines(buf, 0, -1, false, { "c.lua", "a.lua" })
      api.nvim_win_set_cursor(0, { 2, 0 })
      h.feed("<CR>")
      assert.equal(root .. "/a.lua", api.nvim_buf_get_name(0))
      assert.are.same({ "c.lua", "a.lua" }, stored())
    end)

    it("is saved on VimLeavePre while open", function()
      slop.marks.toggle_menu()
      api.nvim_buf_set_lines(0, 0, -1, false, { "a.lua" })
      api.nvim_exec_autocmds("VimLeavePre", { group = "slop.marks" })
      assert.are.same({ "a.lua" }, stored())
    end)
  end)

  describe("commands and keymaps", function()
    it(":Slop marks subcommands with completion", function()
      local complete = require("slop.core.commands").complete
      local subs = complete("", "Slop marks ")
      table.sort(subs)
      assert.are.same({ "add", "clear", "list", "menu", "next", "prev", "remove", "select" }, subs)
      vim.cmd("Slop marks add a.lua")
      vim.cmd("Slop marks add b.lua")
      assert.are.same({ "a.lua", "b.lua" }, stored())
      assert.are.same({ "1", "2" }, complete("", "Slop marks select "))
      assert.are.same({ "b.lua" }, complete("b", "Slop marks remove b"))
      assert.truthy(vim.tbl_contains(complete("", "Slop marks add "), "c.lua"))
      vim.cmd("Slop marks select 2")
      assert.equal(root .. "/b.lua", api.nvim_buf_get_name(0))
      vim.cmd("Slop marks next")
      assert.equal(root .. "/a.lua", api.nvim_buf_get_name(0))
      vim.cmd("Slop marks prev")
      assert.equal(root .. "/b.lua", api.nvim_buf_get_name(0))
      local out = api.nvim_exec2("Slop marks list", { output = true }).output
      assert.matches("1  a.lua:1", out)
      assert.matches("2  b.lua:1", out)
      vim.cmd("Slop marks remove")
      assert.are.same({ "a.lua" }, stored())
      vim.cmd("Slop marks")
      assert.truthy(vim.bo.filetype == "slopmarks")
      vim.cmd("Slop marks menu")
      assert.truthy(vim.bo.filetype ~= "slopmarks")
      vim.cmd("Slop marks clear")
      assert.are.same({}, stored())
      vim.cmd("Slop marks select x")
      assert.truthy(vim.iter(notes):any(function(n)
        return n.msg:find("usage") ~= nil
      end))
    end)

    it("maps the harpoon keys once loaded; next/prev unmapped", function()
      slop.marks.list()
      assert.equal("<Plug>(slop-marks-add)", vim.fn.maparg("<leader>h", "n"))
      assert.equal("<Plug>(slop-marks-menu)", vim.fn.maparg("<C-e>", "n"))
      assert.equal("<Plug>(slop-marks-select-1)", vim.fn.maparg("<leader>1", "n"))
      assert.equal("<Plug>(slop-marks-select-10)", vim.fn.maparg("<leader>0", "n"))
      for _, km in ipairs(require("slop.core.keymaps").get("marks")) do
        if km.name == "next" or km.name == "prev" then
          assert.is_false(km.lhs)
        end
      end
      assert.truthy(vim.fn.maparg("<Plug>(slop-marks-next)", "n") ~= "")
      edit("c.lua")
      h.feed(" h")
      assert.are.same({ "c.lua" }, stored())
      vim.cmd("enew")
      h.feed(" 1")
      assert.equal(root .. "/c.lua", api.nvim_buf_get_name(0))
      h.feed("<C-e>")
      assert.equal("slopmarks", vim.bo.filetype)
      h.feed("<C-e>")
      assert.equal(root .. "/c.lua", api.nvim_buf_get_name(0))
    end)

    it("reports health without setup", function()
      local spec = require("slop.core.registry").spec("marks")
      local out = {}
      local orig = vim.health
      vim.health = {
        ok = function(m)
          out[#out + 1] = "ok " .. m
        end,
        info = function(m)
          out[#out + 1] = "info " .. m
        end,
        warn = function(m)
          out[#out + 1] = "warn " .. m
        end,
        error = function(m)
          out[#out + 1] = "error " .. m
        end,
      }
      local ok, err = pcall(spec.health)
      vim.health = orig
      assert.truthy(ok, err)
      assert.matches("^info list: .*marks%.json %(project state%)", out[1])
      assert.equal("ok 0 mark(s)", out[2])
      assert.is_false(require("slop.core.registry").is_loaded("marks"))
    end)
  end)
end)

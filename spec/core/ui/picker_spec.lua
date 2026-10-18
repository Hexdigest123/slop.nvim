local h = require("helpers")

--- Use the real core.ui.float when implemented; otherwise a minimal double (owner: term).
local function ensure_float()
  local float = require("slop.core.ui.float")
  local ok, handle = pcall(float.open, { enter = false, width = 0.3, height = 0.3 })
  if ok then
    handle:close()
    return
  end
  local Handle = {}
  Handle.__index = Handle
  function Handle:is_valid()
    return vim.api.nvim_win_is_valid(self.win)
  end
  function Handle:close()
    if self:is_valid() then
      vim.api.nvim_win_close(self.win, true)
    end
  end
  function Handle:update() end
  package.loaded["slop.core.ui.float"] = {
    border = function()
      return "rounded"
    end,
    open = function(o)
      local buf = o.buf or vim.api.nvim_create_buf(false, true)
      local function size(s, total)
        return type(s) == "function" and s() or (s <= 1 and math.floor(total * s) or s)
      end
      local win = vim.api.nvim_open_win(buf, o.enter ~= false, {
        relative = "editor",
        row = o.row or 1,
        col = o.col or 1,
        width = size(o.width or 0.5, vim.o.columns),
        height = size(o.height or 0.5, vim.o.lines),
        border = "rounded",
      })
      local hd = setmetatable({ buf = buf, win = win }, Handle)
      if o.on_close then
        vim.api.nvim_create_autocmd("WinClosed", { pattern = tostring(win), once = true, callback = o.on_close })
      end
      return hd
    end,
  }
end

local function wait_for(fn)
  assert.is_true(vim.wait(2000, fn, 10), "timed out")
end

describe("core.ui.picker", function()
  local picker
  before_each(function()
    h.reset()
    vim.notify = function() end
    require("slop").setup({})
    ensure_float()
    picker = require("slop.core.ui.picker")
  end)

  describe("pure helpers", function()
    it("text() uses format, item.text or tostring", function()
      assert.equal("abc", picker.text({ text = "abc" }))
      assert.equal("42", picker.text(42))
      assert.equal(
        "GET /x",
        picker.text({}, {
          format = function()
            return { { "GET", "Keyword" }, { " /x" } }
          end,
        })
      )
    end)

    it("filter() keeps order for an empty query and fuzzy-matches otherwise", function()
      local items = { "alpha", "beta", "gamma", "alphabet" }
      local all = picker.filter(items, "")
      assert.equal(4, #all)
      assert.equal("alpha", all[1].item)
      local m = picker.filter(items, "alp")
      local got = vim.tbl_map(function(x)
        return x.item
      end, m)
      table.sort(got)
      assert.are.same({ "alpha", "alphabet" }, got)
      assert.are.same({ 0, 1, 2 }, m[1].positions)
    end)

    it("filter() reports byte positions for multibyte text", function()
      local m = picker.filter({ "é-x" }, "x")
      assert.are.same({ 3 }, m[1].positions)
    end)

    it("fzf_key() translates vim key notation", function()
      assert.equal("ctrl-v", picker.fzf_key("<C-v>"))
      assert.equal("alt-x", picker.fzf_key("<M-x>"))
      assert.equal("enter", picker.fzf_key("<CR>"))
      assert.equal("ctrl-space", picker.fzf_key("<C-Space>"))
    end)

    it("backend() honours opts/config and falls back to builtin without fzf-lua", function()
      assert.equal("select", picker.backend({ backend = "select" }))
      assert.equal("builtin", picker.backend({ backend = "builtin" }))
      package.loaded["fzf-lua"] = nil
      local saved = package.preload["fzf-lua"]
      assert.equal("builtin", picker.backend({ backend = "auto" }))
      assert.equal("builtin", picker.backend({ backend = "fzf" }))
      package.preload["fzf-lua"] = function()
        return {}
      end
      assert.equal("fzf", picker.backend({ backend = "auto" }))
      package.preload["fzf-lua"] = saved
      package.loaded["fzf-lua"] = nil
      require("slop").setup({ ui = { picker = "select" } })
      assert.equal("select", picker.backend())
    end)
  end)

  describe("builtin backend", function()
    local function open(items, extra)
      local got = { called = 0 }
      local opts = vim.tbl_extend("force", {
        backend = "builtin",
        prompt = "Test",
        on_select = function(item, action)
          got.called = got.called + 1
          got.item, got.action = item, action
        end,
      }, extra or {})
      local hd = picker.pick(items, opts)
      return hd, got
    end

    local function type_query(hd, q)
      vim.api.nvim_buf_set_lines(hd._bufs.prompt, 0, -1, false, { q })
      vim.api.nvim_exec_autocmds("TextChangedI", { buffer = hd._bufs.prompt })
    end

    it("shows items, filters, moves and selects", function()
      local hd, got = open({ "one", "two", "three" })
      assert.equal(3, #hd._state.matches)
      assert.are.same({ "one", "two", "three" }, vim.api.nvim_buf_get_lines(hd._bufs.list, 0, -1, false))
      type_query(hd, "t")
      assert.equal(2, #hd._state.matches)
      hd._move(1)
      local expected = hd._state.matches[2].item
      hd._accept()
      wait_for(function()
        return got.called == 1
      end)
      assert.equal(expected, got.item)
      assert.is_nil(got.action)
      assert.is_false(vim.api.nvim_win_is_valid(hd._handles.prompt.win))
      assert.is_false(vim.api.nvim_win_is_valid(hd._handles.list.win))
    end)

    it("prompt keymaps drive the picker (<C-n>, <CR>) and action keys", function()
      local hd, got = open({ "a", "b" }, { actions = { ["<C-v>"] = "vsplit" } })
      local maps = vim.api.nvim_buf_get_keymap(hd._bufs.prompt, "i")
      local lhs = {}
      for _, m in ipairs(maps) do
        lhs[m.lhs] = true
      end
      assert.truthy(lhs["<C-N>"] and lhs["<CR>"] and lhs["<C-V>"] and lhs["<Esc>"])
      assert.is_nil(lhs["<Tab>"])
      h.feed("<C-n>")
      assert.equal(2, hd._state.sel)
      h.feed("<C-v>")
      wait_for(function()
        return got.called == 1
      end)
      assert.equal("b", got.item)
      assert.equal("vsplit", got.action)
    end)

    it("cancel calls on_select(nil) exactly once", function()
      local hd, got = open({ "a" })
      hd.close()
      hd.close()
      wait_for(function()
        return got.called == 1
      end)
      vim.wait(50)
      assert.equal(1, got.called)
      assert.is_nil(got.item)
    end)

    it("closing a picker window cancels", function()
      local hd, got = open({ "a" })
      vim.api.nvim_win_close(hd._handles.list.win, true)
      wait_for(function()
        return got.called == 1
      end)
      assert.is_nil(got.item)
      assert.is_false(vim.api.nvim_win_is_valid(hd._handles.prompt.win))
    end)

    it("renders the preview (lines + filetype, path + lnum)", function()
      vim.o.columns, vim.o.lines = 160, 50
      local dir = h.tmpdir("pv")
      h.write(dir .. "/x.lua", "local a = 1\nlocal b = 2\nlocal c = 3\n")
      local items = { { text = "lines" }, { text = "file" } }
      local hd = open(items, {
        preview = function(it)
          if it.text == "lines" then
            return { lines = { "{", '  "a": 1', "}" }, filetype = "json" }
          end
          return { path = dir .. "/x.lua", lnum = 2 }
        end,
      })
      assert.not_nil(hd._bufs.preview)
      assert.are.same({ "{", '  "a": 1', "}" }, vim.api.nvim_buf_get_lines(hd._bufs.preview, 0, -1, false))
      assert.equal("json", vim.bo[hd._bufs.preview].filetype)
      hd._move(1)
      assert.equal("local b = 2", vim.api.nvim_buf_get_lines(hd._bufs.preview, 1, 2, false)[1])
      assert.equal(2, vim.api.nvim_win_get_cursor(hd._handles.preview.win)[1])
      assert.equal("lua", vim.bo[hd._bufs.preview].filetype)
      assert.equal(dir .. "/x.lua", vim.b[hd._bufs.preview].slop_secret_path)
      hd.close()
    end)

    it("supports async item producers", function()
      local deliver
      local hd, got = open(function(cb)
        deliver = cb
      end)
      assert.is_true(hd._state.loading)
      assert.matches("loading", vim.api.nvim_buf_get_lines(hd._bufs.list, 0, 1, false)[1])
      deliver({ "x", "y" })
      wait_for(function()
        return not hd._state.loading
      end)
      assert.equal(2, #hd._state.matches)
      hd._accept()
      wait_for(function()
        return got.called == 1
      end)
      assert.equal("x", got.item)
    end)

    it("multi-select returns marked items (or the current one)", function()
      local hd, got = open({ "a", "b", "c" }, { multi = true })
      h.feed("<C-Space>")
      h.feed("<C-Space>")
      hd._accept()
      wait_for(function()
        return got.called == 1
      end)
      assert.are.same({ "a", "b" }, got.item)
    end)
  end)

  describe("fzf backend (fake fzf-lua)", function()
    local captured
    before_each(function()
      captured = nil
      package.loaded["fzf-lua"] = {
        fzf_exec = function(contents, o)
          captured = { contents = contents, opts = o }
        end,
      }
      package.loaded["fzf-lua.utils"] = {
        ansi_from_hl = function(_, s)
          return s
        end,
      }
    end)
    after_each(function()
      package.loaded["fzf-lua"] = nil
      package.loaded["fzf-lua.utils"] = nil
    end)

    it("passes indexed lines and maps fzf results back to items + actions", function()
      local got
      picker.pick({ { text = "first" }, { text = "second" } }, {
        prompt = "Req",
        actions = { ["<C-v>"] = "vsplit" },
        on_select = function(item, action)
          got = { item = item, action = action }
        end,
      })
      assert.not_nil(captured)
      assert.are.same({ "1\tfirst", "2\tsecond" }, captured.contents)
      assert.equal("\t", captured.opts.fzf_opts["--delimiter"])
      assert.truthy(captured.opts.actions["ctrl-v"])
      captured.opts.fn_selected({ "ctrl-v", "2\tsecond" })
      wait_for(function()
        return got ~= nil
      end)
      assert.equal("second", got.item.text)
      assert.equal("vsplit", got.action)
    end)

    it("esc cancels with on_select(nil)", function()
      local calls = 0
      local got = "unset"
      picker.pick({ "a" }, {
        on_select = function(item)
          calls = calls + 1
          got = item
        end,
      })
      captured.opts.fn_selected({ "esc" })
      captured.opts.winopts.on_close()
      wait_for(function()
        return calls == 1
      end)
      vim.wait(400)
      assert.equal(1, calls)
      assert.is_nil(got)
    end)
  end)

  describe("select backend", function()
    it("uses vim.ui.select with format_item", function()
      local seen
      vim.ui.select = function(items, o, cb)
        seen = { items = items, label = o.format_item(items[2]) }
        cb(items[2])
      end
      local got
      picker.pick({ { text = "a" }, { text = "b" } }, {
        backend = "select",
        on_select = function(item)
          got = item
        end,
      })
      wait_for(function()
        return got ~= nil
      end)
      assert.equal("b", seen.label)
      assert.equal("b", got.text)
    end)
  end)
end)

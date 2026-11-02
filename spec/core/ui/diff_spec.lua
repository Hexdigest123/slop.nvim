local h = require("helpers")

local api = vim.api

local function break_undo(buf)
  api.nvim_buf_call(buf or 0, function()
    vim.cmd("let &g:undolevels = &g:undolevels")
  end)
end

local function new_buf(lines)
  local buf = api.nvim_create_buf(true, false)
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modified = false
  break_undo(buf)
  return buf
end

local function lines(buf)
  return api.nvim_buf_get_lines(buf, 0, -1, false)
end

local function decor(buf)
  return api.nvim_buf_get_extmarks(buf, require("slop.core.util").ns("diff"), 0, -1, { details = true })
end

local function virt_texts(buf)
  local out = {}
  for _, m in ipairs(decor(buf)) do
    for _, vl in ipairs(m[4].virt_lines or {}) do
      out[#out + 1] = vim.trim(vl[1][1])
    end
  end
  return out
end

describe("core.ui.diff", function()
  local diff
  before_each(function()
    h.reset()
    diff = require("slop.core.ui.diff")
  end)

  describe("compute", function()
    it("finds changed, deleted and inserted hunks", function()
      local hunks = diff.compute({ "a", "b", "c", "d" }, { "a", "B", "c", "d", "e" })
      assert.equal(2, #hunks)
      assert.same({ "b" }, hunks[1].old_lines)
      assert.same({ "B" }, hunks[1].new_lines)
      assert.equal(1, hunks[1].old_start)
      assert.equal(1, hunks[1].old_count)
      assert.equal(4, hunks[2].old_start)
      assert.equal(0, hunks[2].old_count)
      assert.same({ "e" }, hunks[2].new_lines)
      assert.equal("pending", hunks[1].state)
    end)

    it("handles empty sides and identical input", function()
      assert.same({}, diff.compute({ "x" }, { "x" }))
      local ins = diff.compute({}, { "x", "y" })
      assert.equal(1, #ins)
      assert.equal(0, ins[1].old_start)
      local del = diff.compute({ "x", "y" }, {})
      assert.equal(1, #del)
      assert.same({ "x", "y" }, del[1].old_lines)
      assert.same({}, del[1].new_lines)
    end)
  end)

  describe("show", function()
    it("applies the new text, draws removed lines as virt_lines and accepts in one undo block", function()
      local buf = new_buf({ "one", "two", "three", "four", "five" })
      api.nvim_set_current_buf(buf)
      local done
      local hd = diff.show(buf, { 1, 4 }, { "TWO", "three", "FOUR", "extra" }, {
        on_done = function(r)
          done = r
        end,
      })
      assert.same({ "one", "TWO", "three", "FOUR", "extra", "five" }, lines(buf))
      assert.equal(2, #hd:hunks())
      assert.same({ "two", "four" }, virt_texts(buf))
      local hl = 0
      for _, m in ipairs(decor(buf)) do
        if m[4].line_hl_group == "SlopDiffAdd" then
          hl = hl + 1
        end
      end
      assert.equal(2, hl)
      assert.same({ 1, 5 }, hd:range())
      break_undo()
      hd:accept_all()
      assert.equal("accepted", done)
      assert.is_false(hd:is_active())
      assert.same({}, decor(buf))
      assert.same({}, diff.list(buf))
      vim.cmd("silent undo")
      assert.same({ "one", "two", "three", "four", "five" }, lines(buf))
    end)

    it("rejecting a hunk restores it; the review stays one undo block", function()
      local buf = new_buf({ "a", "b", "c", "d", "e" })
      api.nvim_set_current_buf(buf)
      local done
      local hd = diff.show(buf, { 0, 5 }, { "a", "B", "c", "D", "e" }, {
        on_done = function(r)
          done = r
        end,
      })
      assert.same({ "a", "B", "c", "D", "e" }, lines(buf))
      break_undo()
      assert.is_true(hd:reject(1))
      assert.same({ "a", "b", "c", "D", "e" }, lines(buf))
      assert.is_nil(done)
      break_undo()
      assert.is_true(hd:accept(2))
      assert.equal("partial", done)
      vim.cmd("silent undo")
      assert.same({ "a", "b", "c", "d", "e" }, lines(buf))
    end)

    it("reject_all undoes cleanly and leaves the buffer unmodified", function()
      local buf = new_buf({ "x", "y", "z" })
      api.nvim_set_current_buf(buf)
      local done
      local hd = diff.show(buf, { 0, 3 }, { "x", "Y", "z", "w" }, {
        on_done = function(r)
          done = r
        end,
      })
      assert.is_true(vim.bo[buf].modified)
      hd:reject_all()
      assert.equal("rejected", done)
      assert.same({ "x", "y", "z" }, lines(buf))
      assert.is_false(vim.bo[buf].modified)
    end)

    it("reject_all after a user edit elsewhere reverts only the hunks", function()
      local buf = new_buf({ "x", "y", "z", "tail" })
      api.nvim_set_current_buf(buf)
      local hd = diff.show(buf, { 0, 3 }, { "x", "Y", "z" })
      break_undo()
      api.nvim_buf_set_lines(buf, 3, 4, false, { "TAIL" })
      break_undo()
      hd:reject_all()
      assert.same({ "x", "y", "z", "TAIL" }, lines(buf))
    end)

    it("hunks track edits above the preview", function()
      local buf = new_buf({ "a", "b", "c" })
      api.nvim_set_current_buf(buf)
      local hd = diff.show(buf, { 1, 2 }, { "B1", "B2" })
      api.nvim_buf_set_lines(buf, 0, 0, false, { "new top" })
      assert.same({ 2, 4 }, hd:range())
      assert.truthy(hd:hunk_at(2))
      hd:reject()
      assert.same({ "new top", "a", "b", "c" }, lines(buf))
    end)

    it("supports pure insertions, deletions at EOF and an empty buffer", function()
      local buf = new_buf({ "a", "b" })
      local hd = diff.show(buf, { 1, 1 }, { "inserted" })
      assert.same({ "a", "inserted", "b" }, lines(buf))
      hd:reject_all()
      assert.same({ "a", "b" }, lines(buf))

      local hd2 = diff.show(buf, { 1, 2 }, {}, { hints = false })
      assert.same({ "a" }, lines(buf))
      assert.same({ "b" }, virt_texts(buf))
      hd2:reject(1)
      assert.same({ "a", "b" }, lines(buf))

      local empty = new_buf({ "" })
      local hd3 = diff.show(empty, { 0, 0 }, { "GET https://x", "" })
      assert.same({ "GET https://x", "" }, lines(empty))
      hd3:reject_all()
      assert.same({ "" }, lines(empty))
    end)

    it("works on a buffer that is not current (rest)", function()
      local cur = api.nvim_get_current_buf()
      local other = new_buf({ "### req", "GET http://a" })
      local hd = diff.show(other, { 1, 2 }, { "GET http://b" })
      assert.equal(cur, api.nvim_get_current_buf())
      assert.same({ "### req", "GET http://b" }, lines(other))
      assert.is_true(hd:accept(1))
      assert.same({ "### req", "GET http://b" }, lines(other))
    end)

    it("reports unchanged without touching the buffer", function()
      local buf = new_buf({ "same" })
      local done
      local hd = diff.show(buf, { 0, 1 }, { "same" }, {
        on_done = function(r)
          done = r
        end,
      })
      assert.is_false(hd:is_active())
      vim.wait(200, function()
        return done ~= nil
      end)
      assert.equal("unchanged", done)
      assert.is_false(vim.bo[buf].modified)
    end)

    it("closes as rejected when the user undoes the preview", function()
      local buf = new_buf({ "a", "b" })
      api.nvim_set_current_buf(buf)
      local done
      diff.show(buf, { 0, 2 }, { "A", "b" }, {
        on_done = function(r)
          done = r
        end,
      })
      break_undo()
      vim.cmd("silent undo")
      vim.api.nvim_exec_autocmds("TextChanged", { buf = buf })
      assert.equal("rejected", done)
      assert.same({ "a", "b" }, lines(buf))
      assert.same({}, diff.list(buf))
    end)

    it("several handles in one buffer are independent", function()
      local buf = new_buf({ "1", "2", "3", "4", "5", "6" })
      local h1 = diff.show(buf, { 0, 2 }, { "one", "two" })
      local h2 = diff.show(buf, { 4, 6 }, { "five" })
      assert.same({ "one", "two", "3", "4", "five" }, lines(buf))
      assert.equal(2, #diff.list(buf))
      h1:reject_all()
      assert.same({ "1", "2", "3", "4", "five" }, lines(buf))
      assert.is_true(h2:is_active())
      h2:accept_all()
      assert.same({}, diff.list(buf))
    end)

    it("reject_all after a user edit and a separate reject restores every hunk", function()
      local buf = new_buf({ "a", "b", "c", "d", "e", "tail" })
      api.nvim_set_current_buf(buf)
      local done
      local hd = diff.show(buf, { 0, 5 }, { "A", "b", "c", "D", "e" }, {
        on_done = function(r)
          done = r
        end,
      })
      break_undo()
      api.nvim_buf_set_lines(buf, 5, 6, false, { "TAIL" }) -- the user edits while reviewing
      break_undo()
      assert.is_true(hd:reject(1)) -- cannot be undojoined any more: its own undo block
      hd:reject_all()
      assert.same({ "a", "b", "c", "d", "e", "TAIL" }, lines(buf))
      assert.equal("rejected", done)
    end)

    it("reject_all restores the old text when 'undolevels' is -1", function()
      local buf = new_buf({ "x", "y" })
      vim.bo[buf].undolevels = -1
      local hd = diff.show(buf, { 0, 2 }, { "X", "y" })
      hd:reject_all()
      assert.same({ "x", "y" }, lines(buf))
    end)

    it("a line opened right above a hunk is not part of it", function()
      local buf = new_buf({ "one", "two", "three" })
      api.nvim_set_current_buf(buf)
      local hd = diff.show(buf, { 1, 2 }, { "TWO" })
      break_undo()
      api.nvim_win_set_cursor(0, { 2, 0 })
      h.feed("Omine<Esc>", "nx")
      api.nvim_win_set_cursor(0, { 3, 0 })
      assert.is_true(hd:reject())
      assert.same({ "one", "mine", "two", "three" }, lines(buf))
    end)

    it("restores EOF deletions after an empty last line and a whole-buffer deletion exactly", function()
      -- two pure deletions whose tracking marks share the (empty) last line
      local buf = new_buf({ "a", "a", "c", "", "c", "", "c" })
      local hd = diff.show(buf, { 2, 7 }, { "a", "", "" })
      assert.equal(3, #hd:hunks())
      for _, i in ipairs({ 2, 3, 1 }) do
        assert.is_true(hd:reject(i))
      end
      assert.same({ "a", "a", "c", "", "c", "", "c" }, lines(buf))

      local all = new_buf({ "a", "b" })
      local hd2 = diff.show(all, { 0, 2 }, {})
      assert.same({ "" }, lines(all))
      assert.is_true(hd2:reject(1))
      assert.same({ "a", "b" }, lines(all))

      local empty = new_buf({ "" })
      local done
      diff.show(empty, { 0, 1 }, {}, {
        on_done = function(r)
          done = r
        end,
      })
      vim.wait(200, function()
        return done ~= nil
      end)
      assert.equal("unchanged", done)
      assert.same({ "" }, lines(empty))
    end)

    it("close() wipes decorations and rejects pending hunks", function()
      local buf = new_buf({ "a" })
      local hd = diff.show(buf, { 0, 1 }, { "b" }, { title = "slop edit", conflict = true })
      local texts = virt_texts(buf)
      assert.equal("slop edit", texts[1])
      assert.matches("changed while", texts[2])
      hd:close()
      assert.same({ "a" }, lines(buf))
      assert.same({}, decor(buf))
    end)
  end)

  describe("keymaps", function()
    it("act on the hunk under the cursor, navigate, and are removed afterwards", function()
      local buf = new_buf({ "a", "b", "c", "d", "e", "f" })
      api.nvim_set_current_buf(buf)
      vim.keymap.set("n", "gA", "<Nop>", { buf = buf, desc = "user map" })
      local refined
      local hd = diff.show(buf, { 0, 6 }, { "A", "b", "c", "D", "e", "F" }, {
        on_refine = function()
          refined = true
        end,
      })
      assert.equal(3, #hd:hunks())
      api.nvim_win_set_cursor(0, { 1, 0 })
      h.feed("]h")
      assert.equal(4, api.nvim_win_get_cursor(0)[1])
      h.feed("[h")
      assert.equal(1, api.nvim_win_get_cursor(0)[1])
      h.feed("gr")
      assert.same({ "a", "b", "c", "D", "e", "F" }, lines(buf))
      api.nvim_win_set_cursor(0, { 4, 0 })
      h.feed("ga")
      assert.equal("accepted", hd:hunks()[2].state)
      h.feed("<C-r>")
      assert.is_true(refined)
      h.feed("gR")
      assert.same({ "a", "b", "c", "D", "e", "f" }, lines(buf))
      assert.is_false(hd:is_active())
      assert.equal("", vim.fn.maparg("ga", "n"))
      assert.equal("", vim.fn.maparg("]h", "n"))
      local restored = vim.fn.maparg("gA", "n", false, true)
      assert.equal("user map", restored.desc)
    end)

    it("act only inside a hunk or the review region and fall through elsewhere", function()
      local l = {}
      for i = 1, 30 do
        l[i] = "line " .. i
      end
      local buf = new_buf(l)
      api.nvim_set_current_buf(buf)
      local refined = 0
      local hd = diff.show(buf, { 20, 22 }, { "AI 21", "AI 22" }, {
        on_refine = function()
          refined = refined + 1
        end,
      })
      api.nvim_win_set_cursor(0, { 1, 0 }) -- far away from the review
      h.feed("<C-r>")
      assert.equal(0, refined)
      h.feed("gRxy<Esc>") -- native Virtual Replace mode
      assert.equal("xyne 1", lines(buf)[1])
      api.nvim_win_set_cursor(0, { 2, 0 })
      h.feed("grZ") -- native gr{char}
      assert.equal("Zine 2", lines(buf)[2])
      api.nvim_win_set_cursor(0, { 3, 0 })
      h.feed("gA")
      assert.is_true(hd:is_active())
      assert.same({ "AI 21", "AI 22" }, api.nvim_buf_get_lines(buf, 20, 22, false))
      -- inside the review they act
      api.nvim_win_set_cursor(0, { 21, 0 })
      h.feed("<C-r>")
      assert.equal(1, refined)
      h.feed("gR")
      assert.is_false(hd:is_active())
      assert.same({ "line 21", "line 22" }, api.nvim_buf_get_lines(buf, 20, 22, false))
    end)

    it("are mapped with nowait (0.11+ defines global gr* maps)", function()
      local keymaps = require("slop.core.keymaps")
      local orig = keymaps.fallthrough
      local seen = {}
      keymaps.fallthrough = function(mode, lhs, handler, opts)
        seen[lhs] = opts.nowait
        return orig(mode, lhs, handler, opts)
      end
      local buf = new_buf({ "a" })
      local ok, hd = pcall(diff.show, buf, { 0, 1 }, { "b" }, { on_refine = function() end })
      keymaps.fallthrough = orig
      assert.is_true(ok, hd)
      for _, lhs in ipairs({ "ga", "gr", "gA", "gR", "]h", "[h", "<C-r>" }) do
        assert.is_true(seen[lhs], lhs)
      end
      hd:close()
    end)

    it("a real review: `gr` is nowait, `grn` outside a hunk still runs the global grn (keymaps + diff)", function()
      for _, lhs in ipairs({ "grn", "grr", "gra", "gri", "grt", "grx" }) do
        pcall(vim.keymap.del, "n", lhs) -- the 0.11+ LSP defaults: replaced by test maps below
      end
      local renamed = 0
      vim.keymap.set("n", "grn", function()
        renamed = renamed + 1
      end)
      vim.keymap.set("n", "grr", "<Nop>")
      local text = {}
      for i = 1, 30 do
        text[i] = "line " .. i
      end
      local buf = new_buf(text)
      api.nvim_set_current_buf(buf)
      local hd = diff.show(buf, { 0, 1 }, { "AI 1" })
      assert.equal(1, vim.fn.maparg("gr", "n", false, true).nowait, "gr would wait for 'timeoutlen'")
      -- outside the hunk: as if slop had not mapped gr at all
      api.nvim_win_set_cursor(0, { 25, 0 })
      h.feed("grn")
      assert.equal(1, renamed)
      assert.equal("line 25", api.nvim_buf_get_lines(buf, 24, 25, false)[1])
      assert.is_true(hd:is_active())
      -- inside the hunk: rejects it
      api.nvim_win_set_cursor(0, { 1, 0 })
      h.feed("gr")
      assert.equal("line 1", api.nvim_buf_get_lines(buf, 0, 1, false)[1])
      assert.equal(1, renamed)
    end)

    it("save and restore the reviewed buffer's own maps when it is not the current buffer", function()
      local cur = api.nvim_get_current_buf()
      vim.keymap.set("n", "]h", "<Nop>", { buf = cur, desc = "current buffer map" })
      local other = new_buf({ "x" })
      vim.keymap.set("n", "]h", "<Nop>", { buf = other, desc = "reviewed buffer map" })
      local hd = diff.show(other, { 0, 1 }, { "y" })
      assert.equal(cur, api.nvim_get_current_buf())
      hd:accept_all()
      api.nvim_buf_call(other, function()
        assert.equal("reviewed buffer map", vim.fn.maparg("]h", "n", false, true).desc)
      end)
      assert.equal("current buffer map", vim.fn.maparg("]h", "n", false, true).desc)
    end)

    it("does not map <C-r> without on_refine", function()
      local buf = new_buf({ "a" })
      api.nvim_set_current_buf(buf)
      local hd = diff.show(buf, { 0, 1 }, { "b" }, { keymaps = { accept = "<leader>y" } })
      assert.equal("", vim.fn.maparg("<C-r>", "n"))
      assert.not_equal("", vim.fn.maparg("<leader>y", "n"))
      hd:close()
    end)
  end)
end)

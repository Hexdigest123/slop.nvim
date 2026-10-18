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
      vim.api.nvim_exec_autocmds("TextChanged", { buffer = buf })
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

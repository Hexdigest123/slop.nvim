-- cloak rendering: decoration-provider masks on screen, toggles, preview_line, side effects, integrations.
local h = require("helpers")

local api = vim.api

local function screen(rows, cols)
  local out = {}
  for r = 1, rows do
    local t = {}
    for c = 1, cols or 30 do
      t[#t + 1] = vim.fn.screenstring(r, c)
    end
    out[r] = (table.concat(t):gsub("%s+$", ""))
  end
  return out
end

local function all_screen()
  return table.concat(screen(vim.o.lines - 1, vim.o.columns), "\n")
end

describe("cloak render", function()
  local dir
  before_each(function()
    h.reset()
    vim.notify = function() end
    vim.cmd("silent! %bwipe!")
    vim.cmd("silent! only")
    vim.o.columns, vim.o.lines = 60, 24
    vim.o.wrap = true
    h.source_plugin()
    dir = h.tmpdir("cloak")
  end)
  after_each(function()
    pcall(function()
      require("slop.core.registry").disable("cloak")
    end)
    vim.cmd("silent! %bwipe!")
  end)

  local function open(name, text, opts)
    require("slop").setup(vim.tbl_extend("force", { cloak = {} }, opts or {}))
    local path = dir .. "/" .. name
    h.write(path, text)
    vim.cmd.edit(vim.fn.fnameescape(path))
    vim.cmd("redraw!")
    return path, api.nvim_get_current_buf()
  end

  it("masks on the very first redraw after :edit (no flash), sized by display width", function()
    open(".env", "KEY=supersecret\nTAB=a\tbcdefgh\nW=日本語ab\n# comment\n")
    assert.is_true(require("slop.core.registry").is_loaded("cloak"))
    assert.are.same({ "KEY=***********", "TAB=***********", "W=********", "# comment" }, screen(4))
    local s = all_screen()
    for _, raw in ipairs({ "supersecret", "bcdefgh", "日本語" }) do
      assert.falsy(s:find(raw, 1, true), raw)
    end
    assert.is_false(vim.wo.wrap, "overlay sets window-local nowrap")
  end)

  it("masks pasted text in the same redraw", function()
    open(".env.local", "A=1\n")
    api.nvim_win_set_cursor(0, { 1, 0 })
    vim.cmd("normal! o")
    api.nvim_paste("PASTED=hunter22", false, -1)
    vim.cmd("stopinsert")
    vim.cmd("redraw!")
    assert.are.same({ "A=*", "PASTED=********" }, screen(2))
  end)

  it("does not touch unrelated buffers", function()
    open("main.lua", "local KEY=supersecret\n")
    assert.are.same({ "local KEY=supersecret" }, screen(1))
    assert.is_true(vim.wo.wrap)
  end)

  it("cloak_length and cloak_character", function()
    open(".env", "KEY=supersecret\nK=ab\n", { cloak = { cloak_length = 4, cloak_character = "#" } })
    assert.are.same({ "KEY=####", "K=####" }, screen(2))
  end)

  it("toggle (global) reveals and restores wrap; display off keeps AI redaction", function()
    local path, buf = open(".env", "KEY=supersecret\n")
    local cloak = require("slop").cloak
    local fired = {}
    api.nvim_create_autocmd("User", {
      pattern = "SlopCloakToggled",
      callback = function(ev)
        fired[#fired + 1] = ev.data
      end,
    })
    cloak.toggle()
    vim.cmd("redraw!")
    assert.are.same({ "KEY=supersecret" }, screen(1))
    assert.is_true(vim.wo.wrap, "wrap restored")
    assert.is_false(cloak.is_enabled(buf))
    assert.equal(false, fired[1].enabled)
    assert.equal("global", fired[1].scope)
    -- redaction is computed from text, never from display state
    local secrets = require("slop.core.secrets")
    assert.is_true(secrets.is_cloaked(buf))
    local red = secrets.redact_lines("/x/app.http", { "Authorization: Bearer abc" })
    assert.are.same({ "Authorization: Bearer <redacted>" }, red)
    assert.is_true(secrets.is_blocked(path))
    cloak.toggle()
    vim.cmd("redraw!")
    assert.are.same({ "KEY=***********" }, screen(1))
  end)

  it("buffer-scoped disable only affects that buffer; global enable resets overrides", function()
    local _, b1 = open(".env", "A=secret1\n")
    vim.cmd("vsplit " .. vim.fn.fnameescape(dir .. "/.env.prod"))
    h.write(dir .. "/.env.prod", "")
    api.nvim_buf_set_lines(0, 0, -1, false, { "B=secret2" })
    local b2 = api.nvim_get_current_buf()
    vim.cmd("Slop cloak disable buffer")
    vim.cmd("redraw!")
    assert.is_false(require("slop").cloak.is_enabled(b2))
    assert.is_true(require("slop").cloak.is_enabled(b1))
    local s = all_screen()
    assert.truthy(s:find("B=secret2", 1, true))
    assert.falsy(s:find("secret1", 1, true))
    vim.cmd("Slop cloak enable")
    vim.cmd("redraw!")
    assert.falsy(all_screen():find("secret", 1, true))
  end)

  it("preview_line reveals the cursor row in this window only, re-cloaks on move, leaks no autocmds", function()
    open(".env", "A=secret1\nB=secret2\nC=secret3\n")
    local before = #api.nvim_get_autocmds({ group = "slop.cloak" })
    api.nvim_win_set_cursor(0, { 2, 0 })
    vim.cmd("vsplit")
    local w2 = api.nvim_get_current_win()
    assert.is_true(require("slop").cloak.preview_line())
    vim.cmd("redraw!")
    local s = all_screen()
    local _, n = s:gsub("secret2", "")
    assert.equal(1, n, "revealed in exactly one window")
    assert.falsy(s:find("secret1", 1, true))
    assert.truthy(#api.nvim_get_autocmds({ group = "slop.cloak" }) > before)
    api.nvim_win_set_cursor(w2, { 3, 0 })
    vim.api.nvim_exec_autocmds("CursorMoved", { buffer = 0 })
    vim.cmd("redraw!")
    assert.falsy(all_screen():find("secret", 1, true))
    assert.equal(before, #api.nvim_get_autocmds({ group = "slop.cloak" }))
  end)

  it("preview_line with a count reveals several rows; :Slop cloak preview_line works", function()
    open(".env", "A=secret1\nB=secret2\nC=secret3\n")
    vim.cmd("Slop cloak preview_line 2")
    vim.cmd("redraw!")
    assert.are.same({ "A=secret1", "B=secret2", "C=*******" }, screen(3))
    vim.api.nvim_exec_autocmds("BufLeave", { buffer = 0 })
    vim.cmd("redraw!")
    assert.are.same({ "A=*******", "B=*******", "C=*******" }, screen(3))
  end)

  it("conceal render: inline masks, wrap-safe, marks only on visible rows, window opts restored", function()
    local lines = {}
    for i = 1, 200 do
      lines[i] = ("K%d=%s"):format(i, ("v"):rep(i == 1 and 100 or 8))
    end
    local _, buf = open(".env", table.concat(lines, "\n") .. "\n", { cloak = { render = "conceal", cloak_length = 3 } })
    assert.equal(2, vim.wo.conceallevel)
    assert.equal("nvic", vim.wo.concealcursor)
    assert.is_true(vim.wo.wrap, "conceal mode keeps wrap")
    -- known Neovim limitation: wrapped line height ignores conceal, so the long line keeps 2 screen rows
    assert.are.same({ "K1=***", "", "K2=***" }, screen(3))
    local ns = require("slop.core.util").ns("cloak.conceal")
    local marks = api.nvim_buf_get_extmarks(buf, ns, 0, -1, {})
    assert.truthy(#marks > 10 and #marks < 40, "only visible rows: " .. #marks)
    assert.falsy(all_screen():find("vvv", 1, true))
    require("slop").cloak.disable()
    vim.cmd("redraw!")
    assert.equal(0, #api.nvim_buf_get_extmarks(buf, ns, 0, -1, {}))
    assert.equal(0, vim.wo.conceallevel)
    assert.truthy(all_screen():find("vvv", 1, true))
  end)

  it("disables completion in cloaked buffers and restores it (fake cmp)", function()
    local calls = {}
    package.loaded.cmp = {
      setup = {
        buffer = function(c)
          calls[#calls + 1] = { buf = api.nvim_get_current_buf(), enabled = c.enabled }
        end,
      },
    }
    local _, buf = open(".env", "A=1\n")
    vim.wait(50, function()
      return #calls > 0
    end)
    assert.equal(false, vim.b[buf].completion)
    assert.equal(false, vim.bo[buf].autocomplete)
    assert.are.same({ buf = buf, enabled = false }, calls[1])
    require("slop").cloak.toggle()
    assert.is_nil(vim.b[buf].completion)
    assert.are.same({ buf = buf, enabled = true }, calls[#calls])
    package.loaded.cmp = nil
  end)

  it("fzf-lua previewer patch tags preview buffers (fake previewer)", function()
    local posted = {}
    local cls = {
      preview_buf_post = function(_, entry)
        posted[#posted + 1] = entry
      end,
    }
    package.loaded["fzf-lua.previewer.builtin"] = { buffer_or_file = cls }
    open("main.lua", "x\n")
    local pbuf = api.nvim_create_buf(false, true)
    api.nvim_buf_set_lines(pbuf, 0, -1, false, { "TOKEN=abcdef" })
    api.nvim_win_set_buf(0, pbuf)
    cls.preview_buf_post({ preview_bufnr = pbuf }, { path = dir .. "/.env" })
    assert.equal(1, #posted, "original called")
    assert.equal(dir .. "/.env", vim.b[pbuf].slop_secret_path)
    vim.cmd("redraw!")
    assert.are.same({ "TOKEN=******" }, screen(1))
    package.loaded["fzf-lua.previewer.builtin"] = nil
  end)

  it("fzf-lua fallback: unnamed buffer in a w:fzf_lua_preview window", function()
    package.loaded["fzf-lua"] = {
      get_info = function()
        return { selected = "x", cwd = dir }
      end,
    }
    package.loaded["fzf-lua.path"] = {
      entry_to_file = function()
        return { path = ".env" }
      end,
    }
    open("main.lua", "x\n")
    local pbuf = api.nvim_create_buf(false, true)
    api.nvim_buf_set_lines(pbuf, 0, -1, false, { "TOKEN=abcdef" })
    api.nvim_win_set_buf(0, pbuf)
    vim.w.fzf_lua_preview = true
    vim.cmd("redraw!")
    assert.are.same({ "TOKEN=******" }, screen(1))
    package.loaded["fzf-lua"], package.loaded["fzf-lua.path"] = nil, nil
  end)

  it("telescope previews: TelescopePreviewerLoaded tags the preview buffer", function()
    open("main.lua", "x\n")
    local pbuf = api.nvim_create_buf(false, true)
    api.nvim_buf_set_lines(pbuf, 0, -1, false, { "Authorization: Bearer abcdef" })
    api.nvim_win_set_buf(0, pbuf)
    api.nvim_buf_call(pbuf, function()
      api.nvim_exec_autocmds("User", {
        pattern = "TelescopePreviewerLoaded",
        data = { bufname = dir .. "/api.http", title = "t", filetype = "http" },
      })
    end)
    vim.cmd("redraw!")
    assert.are.same({ "Authorization: Bearer ******" }, screen(1, 40))
  end)

  it("display providers from core.secrets are masked too", function()
    require("slop").setup({})
    require("slop.core.secrets").register({
      name = "test_display",
      display = true,
      spans = function(_, lines, first_row)
        local out = {}
        for i, l in ipairs(lines) do
          local s, e = l:find("SECRET%w+")
          if s then
            out[#out + 1] = { row = first_row + i - 1, col = s - 1, end_col = e }
          end
        end
        return out
      end,
    })
    open("notes.txt", "a SECRETabc b\n")
    assert.are.same({ "a ********* b" }, screen(1))
  end)

  it("cloak_on_leave re-enables the display when the buffer leaves its window", function()
    local _, buf = open(".env", "A=secret\n", { cloak = { cloak_on_leave = true } })
    require("slop").cloak.disable()
    assert.is_false(require("slop").cloak.is_enabled(buf))
    vim.cmd("enew")
    assert.is_true(require("slop").cloak.is_enabled(buf))
  end)

  it("status, commands and teardown", function()
    local _, buf = open(".env", "A=secret\nB=x\n")
    local st = require("slop").cloak.status()
    assert.is_true(st.cloaked)
    assert.is_true(st.blocked)
    assert.equal(2, st.spans)
    assert.equal("overlay", st.render)
    vim.cmd("Slop cloak status")
    vim.cmd("Slop cloak toggle")
    assert.is_false(require("slop").cloak.is_enabled(buf))
    vim.cmd("Slop cloak")
    assert.is_true(require("slop").cloak.is_enabled(buf))
    require("slop.core.registry").disable("cloak")
    local names = vim.tbl_map(function(p)
      return p.name
    end, require("slop.core.secrets").providers())
    assert.falsy(vim.tbl_contains(names, "cloak"))
    vim.cmd("redraw!")
    assert.are.same({ "A=secret" }, screen(1))
    assert.is_true(vim.wo.wrap)
  end)
end)

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
    vim.api.nvim_exec_autocmds("CursorMoved", { buf = 0 })
    vim.cmd("redraw!")
    assert.falsy(all_screen():find("secret", 1, true))
    assert.equal(before, #api.nvim_get_autocmds({ group = "slop.cloak" }))
  end)

  it("preview_line with a count reveals several rows; :Slop cloak preview_line works", function()
    open(".env", "A=secret1\nB=secret2\nC=secret3\n")
    vim.cmd("Slop cloak preview_line 2")
    vim.cmd("redraw!")
    assert.are.same({ "A=secret1", "B=secret2", "C=*******" }, screen(3))
    vim.api.nvim_exec_autocmds("BufLeave", { buf = 0 })
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
    vim.o.autocomplete = true -- the user's global value; no local one
    local _, buf = open(".env", "A=1\n")
    vim.wait(50, function()
      return #calls > 0
    end)
    assert.equal(false, vim.b[buf].completion)
    assert.equal(false, vim.bo[buf].autocomplete)
    assert.are.same({ buf = buf, enabled = false }, calls[1])
    require("slop").cloak.toggle()
    assert.is_nil(vim.b[buf].completion)
    -- the buffer override is dropped (enabled = true would beat the user's enabled() function)
    assert.are.same({ buf = buf }, calls[#calls])
    -- global-local 'autocomplete': the local value is removed again, so the global one applies
    assert.is_nil(api.nvim_get_option_value("autocomplete", { scope = "local", buf = buf }))
    assert.is_true(api.nvim_buf_call(buf, function()
      return vim.o.autocomplete
    end))
    vim.o.autocomplete = false
    package.loaded.cmp = nil
  end)

  it("completion restore puts the user's own cmp buffer config back", function()
    local store = { buffers = {} }
    package.loaded["cmp.config"] = store
    package.loaded.cmp = {
      setup = {
        buffer = function(c)
          store.buffers[api.nvim_get_current_buf()] = vim.tbl_extend("force", c, { revision = 9 })
        end,
      },
    }
    require("slop").setup({ cloak = {} })
    assert(require("slop").load("cloak"))
    local buf = api.nvim_create_buf(true, false)
    store.buffers[buf] = { sources = { { name = "path" } }, revision = 3 }
    local integ = require("slop.modules.cloak.integrations")
    integ.completion(buf, false)
    assert.equal(false, store.buffers[buf].enabled)
    assert.are.same({ { name = "path" } }, store.buffers[buf].sources)
    integ.completion(buf, true)
    assert.is_nil(store.buffers[buf].enabled)
    assert.are.same({ { name = "path" } }, store.buffers[buf].sources)
    package.loaded.cmp, package.loaded["cmp.config"] = nil, nil
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
    -- window-less lookups (apply_buf) keep the state on_win found instead of flipping it every redraw
    local R = require("slop.modules.cloak.render")
    vim.wait(50)
    local st = R._state.bufs[pbuf]
    assert.equal("table", type(st))
    for _ = 1, 3 do
      vim.cmd("redraw!")
      vim.wait(20)
      assert.equal(st, R._state.bufs[pbuf], "state rebuilt on redraw")
    end
    assert.is_true(R._state.completion[pbuf], "completion disabled in the cloaked preview")
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

  -- Regressions ---------------------------------------------------------------------------------

  it("closed folds and diff-mode folds stay masked; foldtext is restored, also in splits", function()
    local lines = {}
    for i = 1, 12 do
      lines[i] = ("KEY%02d=topsecret%02d"):format(i, i)
    end
    open(".env", table.concat(lines, "\n") .. "\n")
    assert.equal("", vim.wo.foldtext)
    vim.cmd("2,5fold")
    vim.cmd("redraw!")
    assert.falsy(all_screen():find("topsecret", 1, true), "manual fold")
    vim.cmd("normal! zE")
    lines[12] = "KEY12=CHANGED"
    h.write(dir .. "/.env.prod", table.concat(lines, "\n") .. "\n")
    vim.cmd("vert diffsplit " .. vim.fn.fnameescape(dir .. "/.env.prod"))
    vim.cmd("redraw!")
    local s = all_screen()
    assert.truthy(s:find("KEY01=*", 1, true), "diff fold line drawn with its mask")
    assert.falsy(s:find("topsecret", 1, true), "diff folds")
    vim.cmd("diffoff!")
    vim.cmd("split") -- inherits the cloaked window's local options
    require("slop").cloak.disable()
    for _, w in ipairs(api.nvim_list_wins()) do
      assert.equal("foldtext()", vim.wo[w].foldtext, "foldtext restored in window " .. w)
      assert.is_true(vim.wo[w].wrap, "wrap restored in window " .. w)
    end
  end)

  it("a pattern that throws anyway masks its whole line (screen and AI) and is reported once", function()
    local msgs = {}
    vim.notify = function(m)
      msgs[#msgs + 1] = m
    end
    local P = require("slop.modules.cloak.patterns")
    local orig = P.match_line
    P.match_line = function(line, ...)
      if line:find("boom", 1, true) then
        error("malformed pattern (simulated)")
      end
      return orig(line, ...)
    end
    local ok, err = pcall(function()
      open(".env", "A=fine\nboom TOKEN hunter2\nB=x\n")
      vim.cmd("redraw!")
      vim.cmd("redraw!")
      assert.are.same({ "A=****", "******************", "B=*" }, screen(3))
      -- the provider core.secrets redacts with fails closed too (no rule may silently stop redacting)
      local spans = require("slop.core.secrets").spans(dir .. "/x.http", { "GET /", "boom x" })
      assert.are.same({ { row = 1, col = 0, end_col = 6 } }, spans)
    end)
    P.match_line = orig
    assert.is_true(ok, err)
    vim.wait(20)
    local reports = vim.tbl_filter(function(m)
      return m:find("pattern error", 1, true) ~= nil
    end, msgs)
    assert.equal(2, #reports, "one per failing rule (.env rule, builtin .http rule)")
  end)

  it("'inccommand' is off while a : command is typed over a masked buffer", function()
    open(".env", "A=alpha_secret\n")
    -- :%s/=/: / would preview "A: alpha_secret", which no rule matches any more
    vim.o.inccommand = "split"
    local seen
    vim.keymap.set("c", "<F7>", function()
      seen = vim.o.inccommand
    end)
    h.feed(":s/=/: /<F7><Esc>")
    assert.equal("", seen)
    assert.equal("split", vim.o.inccommand, "restored when the cmdline is left")
    assert.equal("A=alpha_secret", api.nvim_get_current_line())
    vim.cmd.edit(vim.fn.fnameescape(dir .. "/notes.txt"))
    h.feed(":s/a/b/<F7><Esc>")
    assert.equal("split", seen, "other buffers keep the live preview")
    vim.keymap.del("c", "<F7>")
    vim.o.inccommand = "nosplit"
  end)

  for _, mode in ipairs({ "conceal", "overlay" }) do
    it(("first frame of an fzf-lua preview swapped without autocmds is masked (%s)"):format(mode), function()
      local cls = { preview_buf_post = function() end }
      package.loaded["fzf-lua.previewer.builtin"] = { buffer_or_file = cls }
      open("main.lua", "x\n", { cloak = { render = mode } })
      local pwin = api.nvim_open_win(api.nvim_create_buf(false, true), false, {
        relative = "editor",
        row = 2,
        col = 0,
        width = 40,
        height = 4,
        border = "none",
        style = "minimal",
      })
      for i = 1, 2 do
        -- what fzf-lua does: fill a tmp buffer, swap it in under eventignore, set wrap globally, post
        local tmp = api.nvim_create_buf(false, true)
        api.nvim_buf_set_lines(tmp, 0, -1, false, { "KEY=supersecret" .. i, "LONG=" .. ("x"):rep(40) .. "TAILSECRET" })
        vim.o.eventignore = "all"
        api.nvim_win_set_buf(pwin, tmp)
        vim.wo[pwin].wrap = true
        vim.o.eventignore = ""
        cls.preview_buf_post({ preview_bufnr = tmp }, { path = dir .. "/.env" })
        vim.cmd("redraw")
        vim.cmd("redraw") -- still before any vim.schedule() callback
        local s = all_screen()
        assert.falsy(s:find("supersecret", 1, true), "preview " .. i)
        assert.falsy(s:find("TAILSECRET", 1, true), "preview " .. i)
      end
      package.loaded["fzf-lua.previewer.builtin"] = nil
    end)
  end

  for _, len in ipairs({ false, 3 }) do
    it(("conceal mode masks a noautocmd float before its conceallevel is set (cloak_length %s)"):format(len), function()
      open("main.lua", "x\n", { cloak = { render = "conceal", cloak_length = len } })
      h.write(dir .. "/.env", "KEY=supersecret\n")
      local env = vim.fn.bufadd(dir .. "/.env")
      vim.fn.bufload(env)
      local w = api.nvim_open_win(env, false, {
        relative = "editor",
        row = 3,
        col = 2,
        width = 30,
        height = 2,
        style = "minimal",
        border = "none",
        noautocmd = true,
      })
      vim.cmd("redraw")
      vim.cmd("redraw")
      assert.equal(0, vim.wo[w].conceallevel, "not applied yet")
      local s = all_screen()
      assert.falsy(s:find("supersecret", 1, true))
      assert.falsy(s:find("ersecret", 1, true), "an exact (cloak_length) mask is padded as an overlay")
    end)
  end

  it("a display-only provider leaves buffers without spans alone (wrap, completion)", function()
    require("slop").setup({})
    require("slop.core.secrets").register({
      name = "test_display_only",
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
    local _, buf = open("main.lua", "local x = 1\n")
    vim.wait(30)
    assert.is_true(vim.wo.wrap)
    assert.is_nil(vim.b[buf].completion)
    open("notes.txt", "a SECRETabc b\n")
    vim.wait(30)
    assert.are.same({ "a ********* b" }, screen(1))
    assert.is_false(vim.wo.wrap, "a buffer with a drawn display span gets the side effects")
  end)

  it("nobuflisted = true unlists cloaked buffers while masked, so <C-n> elsewhere skips them", function()
    local _, buf = open(".env", "STRIPE=sk_live_abc\n", { cloak = { nobuflisted = true } })
    vim.wait(30)
    assert.is_false(vim.bo[buf].buflisted)
    vim.cmd("enew")
    vim.bo.complete = "b"
    h.feed("isk_l<C-n><Esc>")
    assert.equal("sk_l", api.nvim_get_current_line())
    require("slop").cloak.disable()
    assert.is_true(vim.bo[buf].buflisted, "listed again when the masks are off (buffer hidden)")
  end)

  it("overlay masks follow 'tabstop' changes, 'vartabstop' and ^X control characters", function()
    open(".env", "TAB=ab\tcdefgh\nC=ab\1cdefXY\n")
    assert.are.same({ "TAB=**********", "C=**********" }, screen(2))
    vim.bo.tabstop = 24
    vim.cmd("redraw!")
    assert.falsy(all_screen():find("cdefgh", 1, true), "tabstop changed without an edit")
    vim.bo.tabstop = 8
    vim.bo.vartabstop = "4,30"
    vim.cmd("redraw!")
    assert.falsy(all_screen():find("cdefgh", 1, true), "vartabstop")
  end)

  it("attach(0, path) masks the current buffer right away", function()
    open("main.lua", "x\n")
    local pbuf = api.nvim_create_buf(false, true)
    api.nvim_win_set_buf(0, pbuf)
    api.nvim_buf_set_lines(pbuf, 0, -1, false, { "TOKEN=abcdef" })
    vim.cmd("redraw")
    require("slop").cloak.attach(0, dir .. "/.env")
    vim.cmd("redraw") -- a normal redraw: attach() must have marked the window itself
    assert.are.same({ "TOKEN=******" }, screen(1))
    assert.is_false(vim.wo.wrap)
  end)

  it("live setup(): render mode options are swapped, cloak_on_leave and fzf_lua re-applied", function()
    local function count(event, pattern)
      return #api.nvim_get_autocmds({ group = "slop.cloak", event = event, pattern = pattern })
    end
    local _, buf = open(".env", "A=secret\n", { cloak = { render = "conceal" } })
    assert.equal(2, vim.wo.conceallevel)
    require("slop").setup({
      cloak = { render = "overlay", cloak_on_leave = true, fzf_lua = false, cloak_telescope = false },
    })
    assert.equal(0, vim.wo.conceallevel, "conceal options restored after switching to overlay")
    assert.equal("", vim.wo.concealcursor)
    assert.is_false(vim.wo.wrap)
    assert.is_nil(require("slop.modules.cloak.render")._state.fallback_path)
    assert.equal(0, count("FileType", "fzf"))
    assert.equal(0, count("User", "TelescopePreviewerLoaded"))
    require("slop").cloak.disable()
    vim.cmd("enew")
    assert.is_true(require("slop").cloak.is_enabled(buf), "cloak_on_leave turned on live")
    require("slop").setup({ cloak = { fzf_lua = true } })
    assert.equal(1, count("FileType", "fzf"))
    assert.equal(1, count("User", "TelescopePreviewerLoaded"))
    assert.equal(0, count("BufWinLeave"), "cloak_on_leave turned off live")
    assert.not_nil(require("slop.modules.cloak.render")._state.fallback_path)
  end)
end)

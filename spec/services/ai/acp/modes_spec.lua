local h = require("helpers")
local mock = require("services.ai.acp.mock")

-- claude-agent-acp's catalog (it starts in Claude Code's `permissions.defaultMode`).
local CLAUDE_MODES = {
  { id = "default", name = "Manual", description = "Always ask before making changes" },
  { id = "acceptEdits", name = "Accept edits", description = "Automatically accept all file edits" },
  { id = "plan", name = "Plan", description = "Create a plan before making changes" },
  { id = "auto", name = "Auto", description = "Claude handles permission decisions" },
}

local function config_option(current, modes)
  return {
    id = "mode",
    name = "Mode",
    category = "mode",
    type = "select",
    currentValue = current,
    options = vim.tbl_map(function(m)
      return { value = m.id, name = m.name, description = m.description }
    end, modes),
  }
end

local function open_session(acp, turn)
  local res = {}
  acp.client("mock"):new_session({}, function(session, err)
    res.session, res.err = session, err
    if session and turn then
      session:prompt({ { type = "text", text = "hi" } }, {
        on_done = function()
          res.done = true
        end,
      })
    else
      res.done = true
    end
  end)
  mock.wait(function()
    return res.done
  end)
  return res
end

describe("services.ai.acp permission modes", function()
  local acp, notes
  before_each(function()
    h.reset()
    notes = {}
    vim.notify = function(msg)
      notes[#notes + 1] = msg
    end
    acp = require("slop.services.ai.acp")
  end)
  after_each(function()
    acp.stop_all()
  end)

  local function warned(pat)
    for _, n in ipairs(notes) do
      if tostring(n):find(pat) then
        return true
      end
    end
    return false
  end

  it("switches a session that starts in an auto mode to the ask mode (legacy modes)", function()
    local log = mock.setup({ session_new = { modes = { currentModeId = "auto", availableModes = CLAUDE_MODES } } })
    local res = open_session(acp)
    assert.is_nil(res.err)
    local sent = log.received("session/set_mode")
    assert.equal(1, #sent)
    assert.equal("default", sent[1].params.modeId)
    assert.equal(res.session.id, sent[1].params.sessionId)
    assert.equal("default", res.session.mode)
  end)

  it("prefers session config options over legacy modes", function()
    local log = mock.setup({
      session_new = {
        modes = { currentModeId = "auto", availableModes = CLAUDE_MODES },
        configOptions = { config_option("auto", CLAUDE_MODES) },
      },
    })
    local res = open_session(acp)
    assert.equal(0, #log.received("session/set_mode"))
    local sent = log.received("session/set_config_option")
    assert.equal(1, #sent)
    assert.equal("mode", sent[1].params.configId)
    assert.equal("default", sent[1].params.value)
    assert.equal("default", res.session.mode)
  end)

  it("sets the mode before the first prompt", function()
    local log = mock.setup({ session_new = { modes = { currentModeId = "auto", availableModes = CLAUDE_MODES } } })
    open_session(acp, true)
    local order = {}
    for _, e in ipairs(log.entries()) do
      if e.event == nil and (e.method == "session/set_mode" or e.method == "session/prompt") then
        order[#order + 1] = e.method
      end
    end
    assert.same({ "session/set_mode", "session/prompt" }, order)
  end)

  it("does nothing when the session is already in the ask mode or the agent has no modes", function()
    local log = mock.setup({ session_new = { modes = { currentModeId = "default", availableModes = CLAUDE_MODES } } })
    local res = open_session(acp)
    assert.equal(0, #log.received("session/set_mode"))
    assert.equal("default", res.session.mode)
    acp.stop_all()
    log = mock.setup({})
    res = open_session(acp)
    assert.is_nil(res.err)
    assert.equal(0, #log.received("session/set_mode"))
    assert.is_nil(res.session.mode)
  end)

  it("honours an explicit agent mode and mode = false", function()
    local log = mock.setup(
      { session_new = { modes = { currentModeId = "auto", availableModes = CLAUDE_MODES } } },
      { ai = { agents = { mock = { mode = "plan" } } } }
    )
    open_session(acp)
    assert.equal("plan", log.received("session/set_mode")[1].params.modeId)
    acp.stop_all()
    log = mock.setup(
      { session_new = { modes = { currentModeId = "auto", availableModes = CLAUDE_MODES } } },
      { ai = { agents = { mock = { mode = false } } } }
    )
    local res = open_session(acp)
    assert.equal(0, #log.received("session/set_mode"))
    assert.equal("auto", res.session.mode)
  end)

  it("finds an ask mode by description when the id is unknown", function()
    local log = mock.setup({
      session_new = {
        modes = {
          currentModeId = "code",
          availableModes = {
            { id = "code", name = "Code", description = "Write and modify code with full tool access" },
            { id = "careful", name = "Careful", description = "Request permission before making any changes" },
          },
        },
      },
    })
    open_session(acp)
    assert.equal("careful", log.received("session/set_mode")[1].params.modeId)
  end)

  it("keeps the session and warns when switching fails or no ask mode exists", function()
    mock.setup({
      session_new = { modes = { currentModeId = "auto", availableModes = CLAUDE_MODES } },
      set_mode_error = true,
    })
    local res = open_session(acp)
    assert.is_nil(res.err)
    assert.is_not_nil(res.session)
    assert.equal("auto", res.session.mode)
    assert.is_true(warned("could not switch to mode"))
    acp.stop_all()
    notes = {}
    mock.setup({
      session_new = {
        modes = {
          currentModeId = "bypassPermissions",
          availableModes = { { id = "bypassPermissions", name = "Bypass permissions" } },
        },
      },
    })
    res = open_session(acp)
    assert.is_not_nil(res.session)
    assert.is_true(warned("offers no ask%-before%-acting mode"))
  end)

  it("tracks mode changes the agent reports and warns on auto modes", function()
    mock.setup({
      session_new = { modes = { currentModeId = "default", availableModes = CLAUDE_MODES } },
      turns = {
        { { update = { sessionUpdate = "current_mode_update", currentModeId = "bypassPermissions" } } },
      },
    })
    local res = open_session(acp, true)
    assert.equal("bypassPermissions", res.session.mode)
    assert.is_true(warned('switched to mode "bypassPermissions"'))
  end)

  it("validates the agent mode option", function()
    local config = require("slop.config")
    local function errs(mode)
      return table.concat(
        config.validate("ai", { providers = {}, agents = { x = { cmd = { "x" }, mode = mode } } }),
        "\n"
      )
    end
    assert.matches("ai%.agents%.x%.mode", errs(3))
    assert.equal("", errs("default"))
    assert.equal("", errs(false))
    assert.equal("", errs(nil))
  end)
end)

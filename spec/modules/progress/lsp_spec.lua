local h = require("helpers")

-- A real (in-process) LSP client sending $/progress through Neovim's own handler.
describe("progress with a real LSP client", function()
  local dispatchers, client_id

  before_each(function()
    h.reset()
    vim.notify = function() end
    h.source_plugin()
    require("slop.config").setup({ progress = { linger = 50 } })
    client_id = vim.lsp.start({
      name = "fakels",
      cmd = function(d)
        dispatchers = d
        return {
          request = function(method, _, callback)
            if method == "initialize" then
              callback(nil, { capabilities = {} })
            elseif method == "shutdown" then
              callback(nil, nil)
            end
            return true, 1
          end,
          notify = function(method)
            if method == "exit" then
              d.on_exit(0, 15)
            end
            return true
          end,
          is_closing = function()
            return false
          end,
          terminate = function() end,
        }
      end,
      root_dir = vim.uv.cwd(),
    })
    vim.wait(1000, function()
      local c = vim.lsp.get_client_by_id(client_id)
      return c and c.initialized
    end, 10)
  end)

  local function send(value)
    dispatchers.notification("$/progress", { token = "tok", value = value })
  end

  it("shows begin/report/end under the client name and drops it after linger", function()
    local p = require("slop").progress
    send({ kind = "begin", title = "Indexing", message = "start", percentage = 0 })
    assert.truthy(vim.wait(1000, function()
      return #p.items() == 1
    end, 10))
    local it = p.items()[1]
    assert.equal("fakels", it.group)
    assert.equal("Indexing", it.title)
    send({ kind = "report", message = "half", percentage = 50 })
    -- the core handler carries the title over to report/end
    assert.equal("Indexing", p.items()[1].title)
    assert.equal(50, p.items()[1].percent)
    send({ kind = "end", message = "ok" })
    assert.equal("success", p.items()[1].status)
    assert.truthy(vim.wait(1000, function()
      return #p.items() == 0
    end, 10))
    assert.equal(1, #p.history())
  end)

  it("a stopped client's running task is finished as cancel", function()
    local p = require("slop").progress
    send({ kind = "begin", title = "Indexing" })
    vim.lsp.get_client_by_id(client_id):stop(true)
    assert.truthy(vim.wait(2000, function()
      local it = p.items()[1] or p.history()[1]
      return it ~= nil and it.status == "cancel"
    end, 10))
  end)
end)

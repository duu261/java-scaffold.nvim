describe("Creation Center", function()
  local center
  local config
  local model
  local sessions

  before_each(function()
    package.loaded["duke.creation.center"] = nil
    package.loaded["duke.picker"] = nil
    center = require("duke.creation.center")
    config = require("duke.config").get()
    config.java_version = "17"
    model = require("duke.creation.model")
    sessions = {}
    vim.cmd("enew!")
  end)

  after_each(function()
    for _, session in ipairs(sessions) do
      pcall(function()
        session:cancel(true)
      end)
    end
    package.loaded["duke.picker"] = nil
    vim.cmd("silent! only!")
    vim.cmd("enew!")
  end)

  local function open(opts)
    opts = opts or {}
    opts.model = opts.model or model.new(config, { cwd = "/tmp" })
    opts.config = config
    if opts.confirm == nil then
      opts.confirm = false
    end
    opts.submit = opts.submit or function() end
    opts.finish = opts.finish or function() end
    local session = center.open(opts)
    sessions[#sessions + 1] = session
    return session
  end

  it("chooses responsive layout from editor size", function()
    assert.equals("wide", center.choose_layout(120, 40))
    assert.equals("narrow", center.choose_layout(99, 40))
    assert.equals("narrow", center.choose_layout(120, 27))
  end)

  it("opens a centered scratch float with local keymaps", function()
    local session = open({ layout = "wide" })
    local state = session:snapshot()
    local window = vim.api.nvim_win_get_config(state.win)

    assert.equals("wide", state.layout)
    assert.equals("editor", window.relative)
    assert.is_true(window.width >= math.floor(vim.o.columns * 0.8))
    assert.equals("nofile", vim.bo[state.buf].buftype)
    assert.equals(false, vim.bo[state.buf].modifiable)
    local maps = vim.api.nvim_buf_get_keymap(state.buf, "n")
    for _, lhs in ipairs({ "j", "k", "<CR>", "c", "q", "?" }) do
      assert.is_truthy(
        vim.iter(maps):any(function(map)
          return map.lhs == lhs
        end),
        lhs
      )
    end
  end)

  it("restores original narrow-window editor state on cancel", function()
    local origin_buf = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_lines(origin_buf, 0, -1, false, { "one", "two", "three" })
    vim.api.nvim_win_set_cursor(0, { 2, 1 })
    vim.bo[origin_buf].modified = true
    local origin_cwd = vim.fn.getcwd()

    local session = open({ layout = "narrow" })
    assert.not_equals(origin_buf, vim.api.nvim_get_current_buf())
    assert.is_true(session:cancel(true))

    assert.equals(origin_buf, vim.api.nvim_get_current_buf())
    assert.same({ 2, 1 }, vim.api.nvim_win_get_cursor(0))
    assert.is_true(vim.bo[origin_buf].modified)
    assert.equals(origin_cwd, vim.fn.getcwd())
  end)

  it("routes field edits through picker and switches generators", function()
    package.loaded["duke.picker"] = {
      input = function(_, _, callback)
        callback("orders")
      end,
      select_one = function(items, _, callback)
        callback(items[1])
      end,
      confirm = function()
        return true
      end,
    }
    local discoveries = {}
    local session = open({
      layout = "wide",
      discover = function(_, scope)
        discoveries[#discoveries + 1] = scope or "all"
      end,
    })

    assert.same({ "all" }, discoveries)
    assert.is_true(session:activate("field:artifact_id"))
    assert.equals("orders", session:snapshot().model.values.artifact_id)
    assert.is_true(session:activate("generator:gradle"))
    assert.equals("gradle", session:snapshot().model.kind)
    assert.same({ "all", "all" }, discoveries)
  end)

  it("keeps state after failure and accepts only one success callback", function()
    local callbacks = {}
    local finished = {}
    local session = open({
      layout = "wide",
      submit = function(_, _, callback)
        callbacks[#callbacks + 1] = callback
      end,
      finish = function(project_dir)
        finished[#finished + 1] = project_dir
      end,
    })

    assert.is_true(session:submit())
    assert.is_true(session:snapshot().model.busy)
    callbacks[1]("generation failed")
    assert.is_true(session:is_open())
    assert.is_false(session:snapshot().model.busy)
    assert.equals("generation failed", session:snapshot().model.banner)

    assert.is_true(session:submit())
    callbacks[2](nil, "/tmp/demo")
    callbacks[2](nil, "/tmp/duplicate")
    callbacks[2]("late error")

    assert.same({ "/tmp/demo" }, finished)
    assert.is_false(session:is_open())
  end)

  it("edits Spring dependencies inside the same window", function()
    local creation = model.new(config, { kind = "spring", cwd = "/tmp" })
    creation:resolve_async(creation:begin_async("metadata"), {
      values = {
        java_version = "17",
        boot_version = "4.0.0",
        spring_project_type = { id = "maven-project", build = "maven" },
      },
      derived = {
        spring_dependency_items = {
          { id = "web", name = "Spring Web", description = "Web", group = "Web" },
          { id = "data-jpa", name = "Spring Data JPA", description = "SQL", group = "SQL" },
        },
      },
    })
    local session = open({ model = creation, layout = "wide" })

    assert.is_true(session:activate("field:dependency_ids"))
    assert.equals("dependencies", session:snapshot().view)
    assert.is_true(session:dependency_focus("results"))
    assert.is_true(session:dependency_toggle())
    assert.is_true(session:dependency_accept())
    assert.equals("settings", session:snapshot().view)
    assert.same({ "web" }, session:snapshot().model.values.dependency_ids)
  end)

  it("treats external narrow-buffer closure as safe cancellation", function()
    local creation = model.new(config, { cwd = "/tmp" })
    local session = open({ model = creation, layout = "narrow" })
    local token = creation:begin_async("runtimes")

    local ok, err = pcall(vim.api.nvim_buf_delete, session:snapshot().buf, { force = true })

    assert.is_true(ok, err)
    assert.is_false(session:is_open())
    assert.is_false(creation:resolve_async(token, { runner_version = "late" }))
  end)

  it("closes an existing center before opening another", function()
    local first = open({ layout = "narrow" })
    local ok, second = pcall(function()
      return open({ layout = "narrow" })
    end)

    assert.is_true(ok, second)
    assert.is_false(first:is_open())
    assert.is_true(second:is_open())
  end)

  it("contains picker failures without closing the center", function()
    package.loaded["duke.picker"] = {
      input = function()
        error("picker exploded")
      end,
    }
    local session = open({ layout = "wide" })

    local ok, result = pcall(session.activate, session, "field:artifact_id")

    assert.is_true(ok)
    assert.is_false(result)
    assert.is_true(session:is_open())
    assert.is_truthy(session:snapshot().model.banner:find("picker exploded", 1, true))
  end)
end)

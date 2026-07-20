describe("Spring dependency view", function()
  local dependencies
  local items

  before_each(function()
    package.loaded["duke.creation.spring_dependencies"] = nil
    dependencies = require("duke.creation.spring_dependencies")
    items = {
      { id = "web", name = "Spring Web", description = "Web applications", group = "Web" },
      { id = "security", name = "Spring Security", description = "Authentication", group = "Web" },
      { id = "data-jpa", name = "Spring Data JPA", description = "SQL persistence", group = "SQL" },
    }
  end)

  it("groups items and keeps stable selected order", function()
    local view = dependencies.new(items, { "data-jpa", "web" })
    local state = view:snapshot()

    assert.same({ "Web", "SQL" }, state.categories)
    assert.equals("Web", state.active_category)
    assert.same({ "web", "data-jpa" }, state.selected_ids)
    assert.equals(2, state.selected_count)
  end)

  it("filters case-insensitively across searchable fields", function()
    local view = dependencies.new(items, {})

    view:set_query("auth")
    assert.same(
      { "security" },
      vim.tbl_map(function(item)
        return item.id
      end, view:snapshot().results)
    )

    view:set_query("data-jpa")
    assert.same(
      { "data-jpa" },
      vim.tbl_map(function(item)
        return item.id
      end, view:snapshot().results)
    )
  end)

  it("navigates panes and clamps cursors", function()
    local view = dependencies.new(items, {})

    assert.equals("categories", view:snapshot().pane)
    view:focus("results")
    view:move(20)
    assert.equals(2, view:snapshot().result_index)
    view:move(-20)
    assert.equals(1, view:snapshot().result_index)
    assert.is_nil(view:focus("unknown"))
  end)

  it("toggles current result and preserves selection on Back", function()
    local view = dependencies.new(items, {})
    view:focus("results")

    assert.is_true(view:toggle())
    assert.same({ "web" }, view:back())
    assert.same({ "web" }, view:accept())
    assert.is_true(view:toggle())
    assert.same({}, view:accept())
  end)
end)

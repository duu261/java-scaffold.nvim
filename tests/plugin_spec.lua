describe("plugin surface", function()
  before_each(function()
    vim.g.loaded_java_scaffold = nil
    package.loaded["java_scaffold"] = nil
    vim.cmd("runtime plugin/java-scaffold.lua")
  end)

  it("registers lazy user commands", function()
    assert.equals(2, vim.fn.exists(":JavaScaffoldMaven"))
    assert.equals(2, vim.fn.exists(":JavaScaffoldGradle"))
    assert.equals(2, vim.fn.exists(":JavaScaffoldSpring"))
    assert.equals(2, vim.fn.exists(":JavaScaffoldAddDependency"))
    assert.equals(2, vim.fn.exists(":JavaScaffoldLog"))
  end)

  it("loads public API without setup", function()
    local plugin = require("java_scaffold")
    assert.is_function(plugin.new_maven)
    assert.is_function(plugin.new_gradle)
    assert.is_function(plugin.new_spring)
    assert.is_function(plugin.add_dependency)
    assert.is_function(plugin.java_runtimes)
  end)

  it("caches public Java runtime discovery", function()
    local discovery_count = 0
    package.loaded["java_scaffold"] = nil
    package.loaded["java_scaffold.config"] = {
      get = function()
        return { java_homes = {} }
      end,
    }
    package.loaded["java_scaffold.java"] = {
      active = function()
        return "23"
      end,
      discover_homes = function()
        discovery_count = discovery_count + 1
        return { ["23"] = "/jdk/23" }
      end,
    }

    local plugin = require("java_scaffold")
    local first = plugin.java_runtimes()
    first.homes["23"] = "/mutated"
    local second = plugin.java_runtimes()

    assert.equals(1, discovery_count)
    assert.equals("23", second.active)
    assert.equals("/jdk/23", second.homes["23"])

    plugin.java_runtimes({ refresh = true })
    assert.equals(2, discovery_count)

    package.loaded["java_scaffold.config"] = nil
    package.loaded["java_scaffold.java"] = nil
  end)
end)

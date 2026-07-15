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
  end)
end)

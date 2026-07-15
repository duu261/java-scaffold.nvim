describe("configured handoff", function()
  local handoff

  before_each(function()
    package.loaded["java_scaffold.handoff"] = nil
    handoff = require("java_scaffold.handoff")
  end)

  it("appends the completed project to configured command", function()
    assert.same(
      { "project-opener", "/tmp/demo api" },
      handoff.command("/tmp/demo api", { "project-opener" })
    )
  end)

  it("expands project and Java file placeholders", function()
    assert.same(
      {
        "nvim",
        "/tmp/demo api/src/main/java/App.java",
        "--cmd",
        "cd /tmp/demo api",
      },
      handoff.command("/tmp/demo api", {
        "nvim",
        "{file}",
        "--cmd",
        "cd {project}",
      }, "/tmp/demo api/src/main/java/App.java")
    )
  end)
end)
